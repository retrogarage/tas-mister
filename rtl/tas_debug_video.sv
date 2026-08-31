// 512x400 diagnostic raster. The address of the latest program-space bus
// access is shown as six hexadecimal seven-segment digits.
module tas_debug_video (
    input               clk,
    input               reset,
    input               rom_loaded,
    input               download_active,
    input      [23:0]   fetch_addr,
    input      [31:0]   bus_cycles,
    input      [7:0]    sysctrl,
    input               irq,
    input               halted,
    output              ce_pix,
    output reg          hblank,
    output reg          vblank,
    output reg          hsync,
    output reg          vsync,
    output reg [7:0]    red,
    output reg [7:0]    green,
    output reg [7:0]    blue
);

reg [9:0] hcount;
reg [9:0] vcount;
assign ce_pix = 1'b1;

function automatic [6:0] segments(input [3:0] value);
begin
    case (value)
        4'h0: segments = 7'b1111110;
        4'h1: segments = 7'b0110000;
        4'h2: segments = 7'b1101101;
        4'h3: segments = 7'b1111001;
        4'h4: segments = 7'b0110011;
        4'h5: segments = 7'b1011011;
        4'h6: segments = 7'b1011111;
        4'h7: segments = 7'b1110000;
        4'h8: segments = 7'b1111111;
        4'h9: segments = 7'b1111011;
        4'ha: segments = 7'b1110111;
        4'hb: segments = 7'b0011111;
        4'hc: segments = 7'b1001110;
        4'hd: segments = 7'b0111101;
        4'he: segments = 7'b1001111;
        default: segments = 7'b1000111;
    endcase
end
endfunction

function automatic glyph_pixel(
    input [3:0] value,
    input [4:0] x,
    input [5:0] y
);
    reg [6:0] s;
begin
    s = segments(value);
    glyph_pixel =
        (s[6] && y >= 2  && y <= 5  && x >= 4 && x <= 17) ||
        (s[5] && x >= 17 && x <= 20 && y >= 4 && y <= 18) ||
        (s[4] && x >= 17 && x <= 20 && y >= 19 && y <= 33) ||
        (s[3] && y >= 32 && y <= 35 && x >= 4 && x <= 17) ||
        (s[2] && x >= 1  && x <= 4  && y >= 19 && y <= 33) ||
        (s[1] && x >= 1  && x <= 4  && y >= 4 && y <= 18) ||
        (s[0] && y >= 17 && y <= 20 && x >= 4 && x <= 17);
end
endfunction

integer digit;
reg glyph;
reg [3:0] nibble;
reg [9:0] local_x;

always @(posedge clk) begin
    if (reset) begin
        hcount <= 10'd0;
        vcount <= 10'd0;
    end else if (hcount == 10'd639) begin
        hcount <= 10'd0;
        if (vcount == 10'd524) vcount <= 10'd0;
        else vcount <= vcount + 1'd1;
    end else begin
        hcount <= hcount + 1'd1;
    end

    hblank <= (hcount >= 10'd512);
    vblank <= (vcount >= 10'd400);
    hsync <= !((hcount >= 10'd528) && (hcount < 10'd592));
    vsync <= !((vcount >= 10'd410) && (vcount < 10'd412));

    red   <= 8'h08;
    green <= 8'h0c;
    blue  <= 8'h16;

    if (hcount < 10'd512 && vcount < 10'd400) begin
        // Header conveys loader and CPU state even before the first ROM access.
        if (vcount < 10'd16) begin
            red   <= download_active ? 8'hff : (rom_loaded ? 8'h10 : 8'h80);
            green <= rom_loaded ? 8'hc0 : 8'h20;
            blue  <= download_active ? 8'h10 : 8'h20;
        end

        glyph = 1'b0;
        for (digit = 0; digit < 6; digit = digit + 1) begin
            local_x = hcount - (10'd24 + digit * 10'd32);
            case (digit)
                0: nibble = fetch_addr[23:20];
                1: nibble = fetch_addr[19:16];
                2: nibble = fetch_addr[15:12];
                3: nibble = fetch_addr[11:8];
                4: nibble = fetch_addr[7:4];
                default: nibble = fetch_addr[3:0];
            endcase
            if (vcount >= 10'd40 && vcount < 10'd76 && local_x < 10'd22)
                glyph = glyph | glyph_pixel(nibble, local_x[4:0], vcount - 10'd40);
        end
        if (glyph) begin
            red <= halted ? 8'hff : 8'h20;
            green <= halted ? 8'h20 : 8'hff;
            blue <= irq ? 8'hff : 8'h80;
        end

        // Bus activity, system-control and IRQ bit fields.
        if (vcount >= 10'd112 && vcount < 10'd136 && hcount < bus_cycles[23:14]) begin
            red <= 8'h20;
            green <= 8'ha0;
            blue <= 8'hff;
        end
        if (vcount >= 10'd160 && vcount < 10'd184 && hcount[8:3] < 6'd8)
            if (sysctrl[hcount[5:3]]) begin
                red <= 8'hff;
                green <= 8'hb0;
                blue <= 8'h20;
            end
    end else begin
        red <= 8'd0;
        green <= 8'd0;
        blue <= 8'd0;
    end
end

endmodule

