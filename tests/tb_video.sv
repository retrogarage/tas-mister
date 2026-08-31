`timescale 1ns/1ps

module tb_video;
reg clk = 0;
always #5 clk = ~clk;

reg reset = 1;
wire [16:0] vco_addr;
reg [15:0] vco_data = 0;
wire [11:0] palette_addr;
reg [15:0] palette_data = 0;
wire [12:0] gradient_addr;
reg [15:0] gradient_low = 0;
reg [15:0] gradient_high = 0;
reg saw_palette_channels = 0;
wire gfx_req;
wire [19:0] gfx_addr;
reg gfx_ack = 0;
reg [63:0] gfx_data = 64'h123456789abcdef0;
reg gfx_pending = 0;
reg [2:0] gfx_delay = 0;
reg stall_gfx = 0;
integer clocks = 0;
integer gradient_wait = 0;
integer sprite_wait = 0;
integer miss_wait = 0;
integer wait_guard = 0;
reg [23:0] edge_rgb [0:7];
reg [63:0] current_gfx_data = 64'h123456789abcdef0;
reg throttle_overlay_enable = 1'b0;
reg [11:0] throttle_counter = 12'h000;
reg [11:0] stick_x_counter = 12'h000;
reg [11:0] stick_y_counter = 12'h000;
reg [127:0] grw_regs = {64'd0, 16'd0, 16'd0, 16'd0, 16'h0080};

wire ce_pix;
wire hblank;
wire vblank;
wire hsync;
wire vsync;
wire [7:0] red;
wire [7:0] green;
wire [7:0] blue;
wire [63:0] debug_timing;

tas_video dut (
    .clk(clk), .reset(reset), .rom_loaded(1'b1), .download_active(1'b0),
    .throttle_overlay_enable(throttle_overlay_enable),
    .throttle_counter(throttle_counter),
    .stick_x_counter(stick_x_counter),
    .stick_y_counter(stick_y_counter),
    .vco_addr(vco_addr), .vco_data(vco_data),
    .palette_addr(palette_addr), .palette_data(palette_data),
    .gradient_addr(gradient_addr),
    .gradient_low(gradient_low), .gradient_high(gradient_high),
    .grw_regs(grw_regs),
    .gradbank(1'b0),
    .bg0_scrollx(10'd0), .bg0_scrolly(10'd0), .bg0_zoom(16'h3f7f),
    .bg1_scrollx(10'd0), .bg1_scrolly(10'd0), .bg1_zoom(16'h3f7f),
    .dsp_flag_strobe(3'd0),
    .dma_fb_erase_strobe(1'b0), .dma_fb_copy_strobe(1'b0),
    .line_req(), .line_addr(),
    .line_ack(1'b0), .line_data(16'd0),
    .gfx_req(gfx_req), .gfx_addr(gfx_addr),
    .gfx_ack(gfx_ack), .gfx_data(gfx_data),
    .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank),
    .hsync(hsync), .vsync(vsync), .red(red), .green(green), .blue(blue),
    .debug_gradient(), .debug_timing(debug_timing),
    .ddr_background_safe(), .polygon_hold()
);

// Give the two raw raster edges distinct opaque tile colors, then prove that
// the full-width DE window carries x=0 first and x=511 last.  A width-only
// check cannot detect a one-pixel RGB/DE displacement that replaces one edge
// with the neighboring blanking pixel.
task automatic check_full_width_edge_identity;
    integer edge_wait;
    integer edge_pixels;
begin
    edge_wait = 0;
    while (!vblank && edge_wait < 700000) begin
        @(negedge clk);
        edge_wait = edge_wait + 1;
    end
    while (vblank && edge_wait < 1400000) begin
        @(negedge clk);
        edge_wait = edge_wait + 1;
    end
    if (edge_wait == 1400000)
        $fatal(1, "timed out reaching visible frame for edge identity");

    // Write every queued bank because the tagged queue, not the testbench,
    // decides which complete line owns the next raster scanline.
    dut.line_buffer_0.bank_0[0] = 9'h001;
    dut.line_buffer_1.bank_0[0] = 9'h001;
    dut.line_buffer_2.bank_0[0] = 9'h001;
    dut.line_buffer_3.bank_0[0] = 9'h001;
    dut.line_buffer_0.bank_1[0] = 9'h002;
    dut.line_buffer_1.bank_1[0] = 9'h002;
    dut.line_buffer_2.bank_1[0] = 9'h002;
    dut.line_buffer_3.bank_1[0] = 9'h002;
    dut.line_buffer_0.bank_2[0] = 9'h003;
    dut.line_buffer_1.bank_2[0] = 9'h003;
    dut.line_buffer_2.bank_2[0] = 9'h003;
    dut.line_buffer_3.bank_2[0] = 9'h003;
    dut.line_buffer_0.bank_3[0] = 9'h004;
    dut.line_buffer_1.bank_3[0] = 9'h004;
    dut.line_buffer_2.bank_3[0] = 9'h004;
    dut.line_buffer_3.bank_3[0] = 9'h004;
    dut.line_buffer_0.bank_12[31] = 9'h005;
    dut.line_buffer_1.bank_12[31] = 9'h005;
    dut.line_buffer_2.bank_12[31] = 9'h005;
    dut.line_buffer_3.bank_12[31] = 9'h005;
    dut.line_buffer_0.bank_13[31] = 9'h006;
    dut.line_buffer_1.bank_13[31] = 9'h006;
    dut.line_buffer_2.bank_13[31] = 9'h006;
    dut.line_buffer_3.bank_13[31] = 9'h006;
    dut.line_buffer_0.bank_14[31] = 9'h007;
    dut.line_buffer_1.bank_14[31] = 9'h007;
    dut.line_buffer_2.bank_14[31] = 9'h007;
    dut.line_buffer_3.bank_14[31] = 9'h007;
    dut.line_buffer_0.bank_15[31] = 9'h008;
    dut.line_buffer_1.bank_15[31] = 9'h008;
    dut.line_buffer_2.bank_15[31] = 9'h008;
    dut.line_buffer_3.bank_15[31] = 9'h008;

    edge_wait = 0;
    while ((!hblank || vblank) && edge_wait < 700000) begin
        @(negedge clk);
        edge_wait = edge_wait + 1;
    end
    while ((hblank || vblank) && edge_wait < 1400000) begin
        @(negedge clk);
        edge_wait = edge_wait + 1;
    end
    if (edge_wait == 1400000)
        $fatal(1, "timed out reaching full-width identity line");

    edge_pixels = 0;
    while (!hblank) begin
        if (ce_pix) begin
            if (edge_pixels < 4)
                edge_rgb[edge_pixels] = {red, green, blue};
            if (edge_pixels >= 508)
                edge_rgb[edge_pixels - 504] = {red, green, blue};
            edge_pixels = edge_pixels + 1;
        end
        @(negedge clk);
    end
    if (edge_pixels != 512)
        $fatal(1, "full-width identity line has %0d pixels", edge_pixels);
    if ({edge_rgb[0], edge_rgb[1], edge_rgb[2], edge_rgb[3],
         edge_rgb[4], edge_rgb[5], edge_rgb[6], edge_rgb[7]} !==
        {24'hbb4411, 24'h887722, 24'h996633, 24'hee1144,
         24'hff0055, 24'hcc3366, 24'hdd2277, 24'h22dd88})
        $fatal(1,
            "full-width RGB edge order is not raw x=0..511: %h %h %h %h / %h %h %h %h",
            edge_rgb[0], edge_rgb[1], edge_rgb[2], edge_rgb[3],
            edge_rgb[4], edge_rgb[5], edge_rgb[6], edge_rgb[7]);
end
endtask

// TC0430GRW is an opaque full-raster underlay. When neither affine counter's
// select bit is set, the hardware still emits palette entry zero rather than
// turning transparent polygon pixels into black.
task automatic check_inactive_gradient_underlay;
    integer gradient_underlay_wait;
begin
    grw_regs = 128'd0;
    dut.line_buffer_0.bank_4[6] = 9'd0;
    dut.line_buffer_1.bank_4[6] = 9'd0;
    dut.line_buffer_2.bank_4[6] = 9'd0;
    dut.line_buffer_3.bank_4[6] = 9'd0;
    gradient_underlay_wait = 0;
    while (!(dut.vcount == 10'd0 && dut.hcount_d2 == 10'd100 &&
             dut.active_d2 && !dut.foreground_valid_d &&
             !dut.gradient_active) && gradient_underlay_wait < 1400000) begin
        @(posedge clk);
        gradient_underlay_wait = gradient_underlay_wait + 1;
    end
    if (gradient_underlay_wait == 1400000)
        $fatal(1, "timed out reaching inactive GRW underlay pixel");
    #1;
    if ({red, green, blue} !== 24'h234467)
        $fatal(1, "inactive GRW underlay became black: %h",
               {red, green, blue});
end
endtask

// Model the VCO and palette synchronous read ports.
always @(posedge clk) begin
    case (vco_addr)
        // Descriptor 127 is the priority pause marker. Descriptor 126 is a
        // normal-size four-cell sprite whose first chain cell covers x=1.
        // Descriptor 125 has two 30-pixel-tall rows spaced 28 pixels apart;
        // both cover raw VCO line 48. Row 1 must be drawn after row 0.
        17'h103fc: vco_data <= 16'h0c00;
        17'h103f4: vco_data <= 16'h0412;
        17'h103f5: vco_data <= 16'h0028;
        17'h103f6: vco_data <= 16'h7777;
        17'h103f7: vco_data <= 16'h0404;
        17'h103f8: vco_data <= 16'h002e;
        17'h103f9: vco_data <= 16'h0000;
        17'h103fa: vco_data <= 16'h3f3f;
        17'h103fb: vco_data <= 16'h0400;
        17'h01000: vco_data <= 16'h0001;
        17'h09000: vco_data <= 16'h0005;
        17'h01010: vco_data <= 16'h0002;
        17'h09010: vco_data <= 16'h0006;
        17'h01014: vco_data <= 16'h0003;
        17'h09014: vco_data <= 16'h0007;
        default: begin
            // Give BG0 opaque edge texels. The final BG1/sprite composition
            // covers them, but the intermediate BG0 assertion below ensures
            // origin correction sources real content in columns 0-2 instead
            // of erasing a special palette value there.
            if (vco_addr >= 17'h06000 && vco_addr < 17'h07000)
                vco_data <= 16'h0003;
            else if (vco_addr >= 17'h07000 && vco_addr < 17'h08000)
                vco_data <= 16'h0001;
            else if (vco_addr >= 17'h0f000 && vco_addr < 17'h10000)
                vco_data <= 16'h0002;
            else
                vco_data <= 16'd0;
        end
    endcase
    // Make all three palette fields distinct so the regression catches an
    // R/G/B wiring permutation. Pixel 1 of color bank 5 uses address 0x051:
    // blue=1, green=4, red=b.
    palette_data <= {2'd0, palette_addr[3:0], 1'b0,
                     (palette_addr[3:0] ^ 4'h5), 1'b0,
                     (palette_addr[3:0] ^ 4'ha)};
    gradient_low <= {1'b0, 7'h22, 1'b0, 7'h11};
    gradient_high <= 16'h0033;

    gfx_ack <= 1'b0;
    if (gfx_req && !gfx_pending) begin
        gfx_pending <= 1'b1;
        gfx_delay <= 3'd2;
    end else if (gfx_pending && gfx_delay != 0) begin
        gfx_delay <= gfx_delay - 1'd1;
    end else if (gfx_pending && !stall_gfx) begin
        gfx_ack <= 1'b1;
        if (!gfx_req) gfx_pending <= 1'b0;
    end
    if (!gfx_req && !gfx_ack) gfx_pending <= 1'b0;
    if (red == 8'hbb && green == 8'h44 && blue == 8'h11)
        saw_palette_channels <= 1'b1;
end

initial begin
    repeat (4) @(negedge clk);
    reset = 0;
    wait_guard = 0;
    while (!dut.bg_map_cache_valid || !dut.descriptor_cache_valid ||
           !dut.sprite_line_masks_valid) begin
        @(negedge clk);
        wait_guard = wait_guard + 1;
        if (wait_guard == 700000)
            $fatal(1, "timed out warming VCO metadata caches");
    end
    wait_guard = 0;
    while (!(dut.builder_state == dut.B_BG_DONE && !dut.render_layer)) begin
        @(negedge clk);
        wait_guard = wait_guard + 1;
        if (wait_guard == 700000)
            $fatal(1, "timed out waiting for BG0 build completion");
    end
    case (dut.write_buffer)
        2'd0: begin
            if (dut.line_buffer_0.bank_0[0] !== 9'h00f ||
                dut.line_buffer_0.bank_1[0] !== 9'h002 ||
                dut.line_buffer_0.bank_2[0] !== 9'h001)
                $fatal(1, "BG0 left edge was lost in buffer 0: %h %h %h",
                    dut.line_buffer_0.bank_0[0],
                    dut.line_buffer_0.bank_1[0],
                    dut.line_buffer_0.bank_2[0]);
        end
        2'd1: begin
            if (dut.line_buffer_1.bank_0[0] !== 9'h00f ||
                dut.line_buffer_1.bank_1[0] !== 9'h002 ||
                dut.line_buffer_1.bank_2[0] !== 9'h001)
                $fatal(1, "BG0 left edge was lost in buffer 1: %h %h %h",
                    dut.line_buffer_1.bank_0[0],
                    dut.line_buffer_1.bank_1[0],
                    dut.line_buffer_1.bank_2[0]);
        end
        2'd2: begin
            if (dut.line_buffer_2.bank_0[0] !== 9'h00f ||
                dut.line_buffer_2.bank_1[0] !== 9'h002 ||
                dut.line_buffer_2.bank_2[0] !== 9'h001)
                $fatal(1, "BG0 left edge was lost in buffer 2: %h %h %h",
                    dut.line_buffer_2.bank_0[0],
                    dut.line_buffer_2.bank_1[0],
                    dut.line_buffer_2.bank_2[0]);
        end
        default: begin
            if (dut.line_buffer_3.bank_0[0] !== 9'h00f ||
                dut.line_buffer_3.bank_1[0] !== 9'h002 ||
                dut.line_buffer_3.bank_2[0] !== 9'h001)
                $fatal(1, "BG0 left edge was lost in buffer 3: %h %h %h",
                    dut.line_buffer_3.bank_0[0],
                    dut.line_buffer_3.bank_1[0],
                    dut.line_buffer_3.bank_2[0]);
        end
    endcase
    wait_guard = 0;
    while (dut.line_valid && wait_guard < 2000) begin
        @(negedge clk);
        wait_guard = wait_guard + 1;
    end
    if (wait_guard == 2000)
        $fatal(1, "timed out waiting for completed line to retire");
    clocks = 0;
    while (!dut.line_valid && clocks < 1280) begin
        @(negedge clk);
        clocks = clocks + 1;
    end
    if (!dut.line_valid)
        $fatal(1, "VCO scanline builder missed its 1280-clock budget");
    if (dut.write_buffer == 2'd1) begin
        if (dut.line_buffer_1.bank_0[0] !== {5'd2, 4'hf} ||
            dut.line_buffer_1.bank_1[0] !== {5'd5, 4'h2} ||
            dut.line_buffer_1.bank_2[0] !== {5'd5, 4'h1})
            $fatal(1, "wrong TC0080VCO nibble order in buffer 1: %h %h %h",
                   dut.line_buffer_1.bank_0[0],
                   dut.line_buffer_1.bank_1[0],
                   dut.line_buffer_1.bank_2[0]);
    end else if (dut.write_buffer == 2'd2) begin
        if (dut.line_buffer_2.bank_0[0] !== {5'd2, 4'hf} ||
            dut.line_buffer_2.bank_1[0] !== {5'd5, 4'h2} ||
            dut.line_buffer_2.bank_2[0] !== {5'd5, 4'h1})
            $fatal(1, "wrong TC0080VCO nibble order in buffer 2: %h %h %h",
                   dut.line_buffer_2.bank_0[0],
                   dut.line_buffer_2.bank_1[0],
                   dut.line_buffer_2.bank_2[0]);
    end else begin
        if (dut.line_buffer_0.bank_0[0] !== {5'd2, 4'hf} ||
            dut.line_buffer_0.bank_1[0] !== {5'd5, 4'h2} ||
            dut.line_buffer_0.bank_2[0] !== {5'd5, 4'h1})
            $fatal(1, "wrong TC0080VCO nibble order in buffer 0: %h %h %h",
                   dut.line_buffer_0.bank_0[0],
                   dut.line_buffer_0.bank_1[0],
                   dut.line_buffer_0.bank_2[0]);
    end
    if (gfx_addr[2:0] != 0)
        $fatal(1, "graphics request was not eight-byte row aligned");
    while (!dut.gradient_cache_valid && gradient_wait < 600000) begin
        @(negedge clk);
        gradient_wait = gradient_wait + 1;
    end
    if (!dut.gradient_cache_valid)
        $fatal(1, "gradient cache did not refresh during vertical blank");
    if (dut.gradient_cache[0] !== 24'h234467 ||
        dut.gradient_cache[255] !== 24'h234467)
        $fatal(1, "wrong 7-to-8-bit gradient expansion: %h %h",
               dut.gradient_cache[0], dut.gradient_cache[255]);
    while (!((dut.target_y == 0) &&
             (dut.builder_state != dut.B_IDLE)) && sprite_wait < 700000) begin
        @(negedge clk);
        sprite_wait = sprite_wait + 1;
    end
    if (sprite_wait == 700000)
        $fatal(1, "did not see the frame-boundary sprite scanline build");
    wait_guard = 0;
    while (dut.builder_state != dut.B_IDLE && wait_guard < 2000) begin
        @(negedge clk);
        wait_guard = wait_guard + 1;
    end
    if (wait_guard == 2000)
        $fatal(1, "timed out waiting for sprite builder to become idle");
    if (dut.write_buffer == 2'd1) begin
        if (dut.line_buffer_1.bank_1[0] !== {5'd5, 4'h2} ||
            dut.line_buffer_1.bank_2[0] !== {5'd5, 4'h1} ||
            dut.line_buffer_1.bank_3[0] !== {5'd5, 4'h4} ||
            dut.line_buffer_1.bank_4[0] !== {5'd5, 4'h3} ||
            dut.line_buffer_1.bank_14[0] !== {5'd5, 4'hd} ||
            dut.line_buffer_1.bank_0[1] !== {5'd5, 4'hf})
            $fatal(1, "sixteen-pixel sprite emitter/transparent tail mismatch: %h %h %h %h %h %h",
                dut.line_buffer_1.bank_1[0], dut.line_buffer_1.bank_2[0],
                dut.line_buffer_1.bank_3[0], dut.line_buffer_1.bank_4[0],
                dut.line_buffer_1.bank_14[0], dut.line_buffer_1.bank_0[1]);
        if (dut.line_buffer_1.bank_9[2] !== {5'd7, 4'h2})
            $fatal(1, "later overlapping sprite row was not drawn last: %h",
                   dut.line_buffer_1.bank_9[2]);
    end else if (dut.write_buffer == 2'd2) begin
        if (dut.line_buffer_2.bank_1[0] !== {5'd5, 4'h2} ||
            dut.line_buffer_2.bank_2[0] !== {5'd5, 4'h1} ||
            dut.line_buffer_2.bank_3[0] !== {5'd5, 4'h4} ||
            dut.line_buffer_2.bank_4[0] !== {5'd5, 4'h3} ||
            dut.line_buffer_2.bank_14[0] !== {5'd5, 4'hd} ||
            dut.line_buffer_2.bank_0[1] !== {5'd5, 4'hf})
            $fatal(1, "sixteen-pixel sprite emitter/transparent tail mismatch: %h %h %h %h %h %h",
                dut.line_buffer_2.bank_1[0], dut.line_buffer_2.bank_2[0],
                dut.line_buffer_2.bank_3[0], dut.line_buffer_2.bank_4[0],
                dut.line_buffer_2.bank_14[0], dut.line_buffer_2.bank_0[1]);
        if (dut.line_buffer_2.bank_9[2] !== {5'd7, 4'h2})
            $fatal(1, "later overlapping sprite row was not drawn last: %h",
                   dut.line_buffer_2.bank_9[2]);
    end else begin
        if (dut.line_buffer_0.bank_1[0] !== {5'd5, 4'h2} ||
            dut.line_buffer_0.bank_2[0] !== {5'd5, 4'h1} ||
            dut.line_buffer_0.bank_3[0] !== {5'd5, 4'h4} ||
            dut.line_buffer_0.bank_4[0] !== {5'd5, 4'h3} ||
            dut.line_buffer_0.bank_14[0] !== {5'd5, 4'hd} ||
            dut.line_buffer_0.bank_0[1] !== {5'd5, 4'hf})
            $fatal(1, "sixteen-pixel sprite emitter/transparent tail mismatch: %h %h %h %h %h %h",
                dut.line_buffer_0.bank_1[0], dut.line_buffer_0.bank_2[0],
                dut.line_buffer_0.bank_3[0], dut.line_buffer_0.bank_4[0],
                dut.line_buffer_0.bank_14[0], dut.line_buffer_0.bank_0[1]);
        if (dut.line_buffer_0.bank_9[2] !== {5'd7, 4'h2})
            $fatal(1, "later overlapping sprite row was not drawn last: %h",
                   dut.line_buffer_0.bank_9[2]);
    end
    sprite_wait = 0;
    while (!saw_palette_channels && sprite_wait < 700000) begin
        @(negedge clk);
        sprite_wait = sprite_wait + 1;
    end
    if (!saw_palette_channels)
        $fatal(1, "tile palette R/G/B fields were not decoded correctly");
    check_full_width_edge_identity();
    current_gfx_data = 64'd0;
    check_inactive_gradient_underlay();
    wait_guard = 0;
    while (!((dut.vcount == 0) && (dut.hcount < 20) &&
             red == 8'h23 && green == 8'h44 && blue == 8'h67) &&
           wait_guard < 700000) begin
        @(negedge clk);
        wait_guard = wait_guard + 1;
    end
    if (wait_guard == 700000)
        $fatal(1, "timed out waiting for frame-zero gradient pixel");

    // Deliberately withhold one graphics acknowledgement until a scanline
    // boundary. This checks the exact telemetry encoding used on hardware,
    // including the sticky first-miss state and per-state mask.
    stall_gfx = 1'b1;
    miss_wait = 0;
    while (debug_timing[12:0] == 0 && miss_wait < 100000) begin
        @(negedge clk);
        miss_wait = miss_wait + 1;
    end
    if (miss_wait == 100000)
        $fatal(1, "failed to induce a builder deadline miss");
    if (!debug_timing[61] || debug_timing[60:56] != dut.B_BG_GFX_WAIT ||
        !debug_timing[34] || !debug_timing[27] ||
        debug_timing[55:47] >= 9'd400 || debug_timing[25:13] != 0)
        $fatal(1, "bad builder miss telemetry: %h", debug_timing);
    stall_gfx = 1'b0;

    // Enable the user overlay and verify that its center marker is applied
    // after the native palette/gradient mixer at the aligned raster position.
    throttle_overlay_enable = 1'b1;
    throttle_counter = 12'h000;
    wait_guard = 0;
    while (!(dut.active_d2 && dut.throttle_overlay_draw &&
             dut.hcount_d2 == 10'd500 && dut.vcount_d2 == 10'd193) &&
           wait_guard < 700000) begin
        @(posedge clk);
        wait_guard = wait_guard + 1;
    end
    if (wait_guard == 700000)
        $fatal(1, "timed out waiting for throttle overlay marker");
    #1;
    if ({red, green, blue} !== 24'hffc000)
        $fatal(1, "throttle overlay was not applied to final RGB: %h",
               {red, green, blue});
    throttle_overlay_enable = 1'b0;
    $display("PASS tb_video: BG1 in %0d clocks, sprite priority/zoom/row overlap and gradient verified",
             clocks);
    $finish;
end

always @* gfx_data = current_gfx_data;
endmodule
