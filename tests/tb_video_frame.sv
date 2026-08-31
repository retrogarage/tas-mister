`timescale 1ns/1ps

// Headless full-frame diagnostic for a captured TC0080VCO/palette snapshot.
// Optional layer suppression identifies whether a visual artefact belongs to
// BG0, BG1, or the motion-object path without modifying synthesizable RTL.
// +INDEX_OUTPUT=<path> also writes the 9-bit palette index for every pixel,
// allowing a PCB color comparison to distinguish palette data from RGB decode.
module tb_video_frame;
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
wire gfx_req;
wire [19:0] gfx_addr;
reg gfx_ack = 0;
reg [63:0] gfx_data = 0;
reg gfx_pending = 0;
reg [2:0] gfx_delay = 0;
reg [19:0] gfx_latched_addr = 0;

wire ce_pix;
wire hblank;
wire vblank;
wire hsync;
wire vsync;
wire [7:0] red;
wire [7:0] green;
wire [7:0] blue;

reg [15:0] vco_memory [0:67591];
reg [15:0] palette_memory [0:4095];
reg [7:0] gfx_memory [0:1048575];
reg [8:0] frame_pixels [0:204799];
reg [4:0] previous_builder_state = 0;
reg capturing = 0;
reg [399:0] captured_lines = 0;
integer captured_count = 0;
integer x;
integer y;
integer file_handle;
integer read_count;
integer seek_result;
integer output_handle;
integer index_handle;
integer palette_word;
integer cloud_above_pixels;
integer cloud_below_pixels;
integer fixture_handle;
string vco_path;
string palette_path;
string rom_path;
string output_path;
string index_path;
reg no_sprites;
reg no_bg0;
reg no_bg1;
reg no_high_sprites;
reg no_low_sprites;
integer sprite_pause;
integer sprite_first;
integer sprite_last;
reg dump_indices;
reg expect_topland_bg0_edge_mask;
reg expect_topland_no_cockpit;
reg expect_cloud_window;
reg expect_noncloud_below;

tas_video dut (
    .clk(clk), .reset(reset), .rom_loaded(1'b1), .download_active(1'b0),
    .throttle_overlay_enable(1'b0),
    .throttle_counter(12'd0),
    .stick_x_counter(12'd0), .stick_y_counter(12'd0),
    .vco_addr(vco_addr), .vco_data(vco_data),
    .palette_addr(palette_addr), .palette_data(palette_data),
    .gradient_addr(gradient_addr),
    .gradient_low(gradient_low), .gradient_high(gradient_high),
    .grw_regs(128'd0), .gradbank(1'b0),
    .bg0_scrollx(10'd0), .bg0_scrolly(10'd0), .bg0_zoom(16'h3f7f),
    .bg1_scrollx(10'd0), .bg1_scrolly(10'd0), .bg1_zoom(16'h3f7f),
    .dsp_flag_strobe(3'd0),
    .dma_fb_erase_strobe(1'b0), .dma_fb_copy_strobe(1'b0),
    .line_req(), .line_addr(), .line_ack(1'b0), .line_data(16'd0),
    .gfx_req(gfx_req), .gfx_addr(gfx_addr),
    .gfx_ack(gfx_ack), .gfx_data(gfx_data),
    .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank),
    .hsync(hsync), .vsync(vsync), .red(red), .green(green), .blue(blue),
    .debug_gradient(), .debug_timing(), .ddr_background_safe(),
    .polygon_hold()
);

function automatic [15:0] filtered_vco(input [16:0] address);
begin
    filtered_vco = vco_memory[address];
    if (no_sprites && address >= 17'h10200 && address < 17'h10400)
        filtered_vco = 16'd0;
    if (no_high_sprites &&
        address >= 17'h10200 + ((sprite_pause + 1) * 4) &&
        address < 17'h10400)
        filtered_vco = 16'd0;
    if (no_low_sprites && address >= 17'h10200 &&
        address < 17'h10200 + (sprite_pause * 4))
        filtered_vco = 16'd0;
    if (sprite_first >= 0 && address >= 17'h10200 &&
        address < 17'h10400 &&
        ((((address - 17'h10200) >> 2) < sprite_first) ||
         (((address - 17'h10200) >> 2) > sprite_last)))
        filtered_vco = 16'd0;
    if (no_bg0 && address >= 17'h06000 && address < 17'h07000)
        filtered_vco = 16'd0;
    if (no_bg1 && address >= 17'h07000 && address < 17'h08000)
        filtered_vco = 16'd0;
end
endfunction

function automatic [8:0] buffered_pixel(
    input [1:0] buffer_select,
    input integer pixel_x
);
begin
    if (buffer_select == 2'd1) begin
        case (pixel_x & 15)
            0: buffered_pixel = dut.line_buffer_1.bank_0[pixel_x >> 4];
            1: buffered_pixel = dut.line_buffer_1.bank_1[pixel_x >> 4];
            2: buffered_pixel = dut.line_buffer_1.bank_2[pixel_x >> 4];
            3: buffered_pixel = dut.line_buffer_1.bank_3[pixel_x >> 4];
            4: buffered_pixel = dut.line_buffer_1.bank_4[pixel_x >> 4];
            5: buffered_pixel = dut.line_buffer_1.bank_5[pixel_x >> 4];
            6: buffered_pixel = dut.line_buffer_1.bank_6[pixel_x >> 4];
            7: buffered_pixel = dut.line_buffer_1.bank_7[pixel_x >> 4];
            8: buffered_pixel = dut.line_buffer_1.bank_8[pixel_x >> 4];
            9: buffered_pixel = dut.line_buffer_1.bank_9[pixel_x >> 4];
            10: buffered_pixel = dut.line_buffer_1.bank_10[pixel_x >> 4];
            11: buffered_pixel = dut.line_buffer_1.bank_11[pixel_x >> 4];
            12: buffered_pixel = dut.line_buffer_1.bank_12[pixel_x >> 4];
            13: buffered_pixel = dut.line_buffer_1.bank_13[pixel_x >> 4];
            14: buffered_pixel = dut.line_buffer_1.bank_14[pixel_x >> 4];
            default: buffered_pixel = dut.line_buffer_1.bank_15[pixel_x >> 4];
        endcase
    end else if (buffer_select == 2'd2) begin
        case (pixel_x & 15)
            0: buffered_pixel = dut.line_buffer_2.bank_0[pixel_x >> 4];
            1: buffered_pixel = dut.line_buffer_2.bank_1[pixel_x >> 4];
            2: buffered_pixel = dut.line_buffer_2.bank_2[pixel_x >> 4];
            3: buffered_pixel = dut.line_buffer_2.bank_3[pixel_x >> 4];
            4: buffered_pixel = dut.line_buffer_2.bank_4[pixel_x >> 4];
            5: buffered_pixel = dut.line_buffer_2.bank_5[pixel_x >> 4];
            6: buffered_pixel = dut.line_buffer_2.bank_6[pixel_x >> 4];
            7: buffered_pixel = dut.line_buffer_2.bank_7[pixel_x >> 4];
            8: buffered_pixel = dut.line_buffer_2.bank_8[pixel_x >> 4];
            9: buffered_pixel = dut.line_buffer_2.bank_9[pixel_x >> 4];
            10: buffered_pixel = dut.line_buffer_2.bank_10[pixel_x >> 4];
            11: buffered_pixel = dut.line_buffer_2.bank_11[pixel_x >> 4];
            12: buffered_pixel = dut.line_buffer_2.bank_12[pixel_x >> 4];
            13: buffered_pixel = dut.line_buffer_2.bank_13[pixel_x >> 4];
            14: buffered_pixel = dut.line_buffer_2.bank_14[pixel_x >> 4];
            default: buffered_pixel = dut.line_buffer_2.bank_15[pixel_x >> 4];
        endcase
    end else if (buffer_select == 2'd3) begin
        case (pixel_x & 15)
            0: buffered_pixel = dut.line_buffer_3.bank_0[pixel_x >> 4];
            1: buffered_pixel = dut.line_buffer_3.bank_1[pixel_x >> 4];
            2: buffered_pixel = dut.line_buffer_3.bank_2[pixel_x >> 4];
            3: buffered_pixel = dut.line_buffer_3.bank_3[pixel_x >> 4];
            4: buffered_pixel = dut.line_buffer_3.bank_4[pixel_x >> 4];
            5: buffered_pixel = dut.line_buffer_3.bank_5[pixel_x >> 4];
            6: buffered_pixel = dut.line_buffer_3.bank_6[pixel_x >> 4];
            7: buffered_pixel = dut.line_buffer_3.bank_7[pixel_x >> 4];
            8: buffered_pixel = dut.line_buffer_3.bank_8[pixel_x >> 4];
            9: buffered_pixel = dut.line_buffer_3.bank_9[pixel_x >> 4];
            10: buffered_pixel = dut.line_buffer_3.bank_10[pixel_x >> 4];
            11: buffered_pixel = dut.line_buffer_3.bank_11[pixel_x >> 4];
            12: buffered_pixel = dut.line_buffer_3.bank_12[pixel_x >> 4];
            13: buffered_pixel = dut.line_buffer_3.bank_13[pixel_x >> 4];
            14: buffered_pixel = dut.line_buffer_3.bank_14[pixel_x >> 4];
            default: buffered_pixel = dut.line_buffer_3.bank_15[pixel_x >> 4];
        endcase
    end else begin
        case (pixel_x & 15)
            0: buffered_pixel = dut.line_buffer_0.bank_0[pixel_x >> 4];
            1: buffered_pixel = dut.line_buffer_0.bank_1[pixel_x >> 4];
            2: buffered_pixel = dut.line_buffer_0.bank_2[pixel_x >> 4];
            3: buffered_pixel = dut.line_buffer_0.bank_3[pixel_x >> 4];
            4: buffered_pixel = dut.line_buffer_0.bank_4[pixel_x >> 4];
            5: buffered_pixel = dut.line_buffer_0.bank_5[pixel_x >> 4];
            6: buffered_pixel = dut.line_buffer_0.bank_6[pixel_x >> 4];
            7: buffered_pixel = dut.line_buffer_0.bank_7[pixel_x >> 4];
            8: buffered_pixel = dut.line_buffer_0.bank_8[pixel_x >> 4];
            9: buffered_pixel = dut.line_buffer_0.bank_9[pixel_x >> 4];
            10: buffered_pixel = dut.line_buffer_0.bank_10[pixel_x >> 4];
            11: buffered_pixel = dut.line_buffer_0.bank_11[pixel_x >> 4];
            12: buffered_pixel = dut.line_buffer_0.bank_12[pixel_x >> 4];
            13: buffered_pixel = dut.line_buffer_0.bank_13[pixel_x >> 4];
            14: buffered_pixel = dut.line_buffer_0.bank_14[pixel_x >> 4];
            default: buffered_pixel = dut.line_buffer_0.bank_15[pixel_x >> 4];
        endcase
    end
end
endfunction

always @(posedge clk) begin
    vco_data <= filtered_vco(vco_addr);
    palette_data <= palette_memory[palette_addr];

    gfx_ack <= 1'b0;
    if (gfx_req && !gfx_pending) begin
        gfx_pending <= 1'b1;
        gfx_delay <= 3'd2;
        gfx_latched_addr <= gfx_addr;
    end else if (gfx_pending && gfx_delay != 0) begin
        gfx_delay <= gfx_delay - 1'd1;
    end else if (gfx_pending) begin
        gfx_data <= {
            gfx_memory[gfx_latched_addr + 7],
            gfx_memory[gfx_latched_addr + 6],
            gfx_memory[gfx_latched_addr + 5],
            gfx_memory[gfx_latched_addr + 4],
            gfx_memory[gfx_latched_addr + 3],
            gfx_memory[gfx_latched_addr + 2],
            gfx_memory[gfx_latched_addr + 1],
            gfx_memory[gfx_latched_addr]
        };
        gfx_ack <= 1'b1;
        if (!gfx_req) gfx_pending <= 1'b0;
    end
    if (!gfx_req && !gfx_ack) gfx_pending <= 1'b0;
end

always @(negedge clk) begin
    previous_builder_state <= dut.builder_state;
    if (!capturing && dut.bg_map_cache_valid && dut.descriptor_cache_valid &&
        dut.sprite_line_masks_valid && dut.target_y == 0 &&
        dut.builder_state != dut.B_IDLE) begin
        capturing <= 1'b1;
    end

    if (capturing && previous_builder_state != dut.B_IDLE &&
        dut.builder_state == dut.B_IDLE && dut.line_valid &&
        !captured_lines[dut.target_y]) begin
        for (x = 0; x < 512; x = x + 1)
            frame_pixels[dut.target_y * 512 + x] =
                buffered_pixel(dut.write_buffer, x);
        captured_lines[dut.target_y] <= 1'b1;
        captured_count <= captured_count + 1;
        if (captured_count == 399) begin
            if (expect_topland_bg0_edge_mask &&
                (frame_pixels[20 * 512 + 0] !== 9'h00d ||
                 frame_pixels[20 * 512 + 1] !== 9'h000 ||
                 frame_pixels[20 * 512 + 2] !== 9'h000 ||
                 frame_pixels[20 * 512 + 511] !== 9'h00d ||
                 frame_pixels[100 * 512 + 0] !== 9'h00d ||
                 frame_pixels[100 * 512 + 1] !== 9'h000 ||
                 frame_pixels[100 * 512 + 2] !== 9'h000 ||
                 frame_pixels[100 * 512 + 511] !== 9'h00d ||
                 // BG1 owns the captured panel edges and must still overwrite
                 // the opaque BG0 mask. This protects full-width menus and
                 // motion objects from a global crop or forced edge color.
                 frame_pixels[273 * 512 + 0] !== 9'h00d ||
                 frame_pixels[273 * 512 + 1] !== 9'h081 ||
                 frame_pixels[273 * 512 + 2] !== 9'h08e ||
                 frame_pixels[273 * 512 + 511] !== 9'h08e))
                $fatal(1,
                    "Top Landing BG0 mask/window mismatch: y20=%03h/%03h/%03h/%03h y100=%03h/%03h/%03h/%03h panel=%03h/%03h/%03h/%03h",
                    frame_pixels[20 * 512 + 0],
                    frame_pixels[20 * 512 + 1],
                    frame_pixels[20 * 512 + 2],
                    frame_pixels[20 * 512 + 511],
                    frame_pixels[100 * 512 + 0],
                    frame_pixels[100 * 512 + 1],
                    frame_pixels[100 * 512 + 2],
                    frame_pixels[100 * 512 + 511],
                    frame_pixels[273 * 512 + 0],
                    frame_pixels[273 * 512 + 1],
                    frame_pixels[273 * 512 + 2],
                    frame_pixels[273 * 512 + 511]);
            if (expect_topland_bg0_edge_mask &&
                dut.flight_cockpit_active !== 1'b1)
                $fatal(1, "captured flight cockpit signature was not detected");
            if (expect_topland_no_cockpit &&
                dut.flight_cockpit_active !== 1'b0)
                $fatal(1, "cockpit detector asserted without BG1");
            if (expect_cloud_window) begin
                cloud_above_pixels = 0;
                cloud_below_pixels = 0;
                for (y = 0; y < 400; y = y + 1)
                    // x=0 is the output aperture mask, not a sprite pixel.
                    for (x = 1; x < 512; x = x + 1)
                        if (frame_pixels[y * 512 + x] != 0) begin
                            if (y < 273)
                                cloud_above_pixels = cloud_above_pixels + 1;
                            else
                                cloud_below_pixels = cloud_below_pixels + 1;
                        end
                if (cloud_above_pixels == 0 || cloud_below_pixels != 0)
                    $fatal(1,
                        "cloud window failed: above=%0d cockpit=%0d",
                        cloud_above_pixels, cloud_below_pixels);
            end
            if (expect_noncloud_below) begin
                cloud_below_pixels = 0;
                for (y = 273; y < 400; y = y + 1)
                    for (x = 1; x < 512; x = x + 1)
                        if (frame_pixels[y * 512 + x] != 0)
                            cloud_below_pixels = cloud_below_pixels + 1;
                if (cloud_below_pixels == 0)
                    $fatal(1, "non-cloud cockpit sprites were clipped");
            end
            output_handle = $fopen(output_path, "w");
            if (!output_handle) $fatal(1, "cannot create %s", output_path);
            $fdisplay(output_handle, "P3");
            $fdisplay(output_handle, "512 400");
            $fdisplay(output_handle, "255");
            for (y = 0; y < 400; y = y + 1) begin
                for (x = 0; x < 512; x = x + 1) begin
                    if (frame_pixels[y * 512 + x] == 0) begin
                        $fwrite(output_handle, "0 0 0 ");
                    end else begin
                        palette_word = palette_memory[
                            frame_pixels[y * 512 + x]];
                        $fwrite(output_handle, "%0d %0d %0d ",
                            (palette_word & 15) * 17,
                            ((palette_word >> 5) & 15) * 17,
                            ((palette_word >> 10) & 15) * 17);
                    end
                end
                $fwrite(output_handle, "\n");
            end
            $fclose(output_handle);
            if (dump_indices) begin
                index_handle = $fopen(index_path, "w");
                if (!index_handle)
                    $fatal(1, "cannot create %s", index_path);
                for (y = 0; y < 400; y = y + 1) begin
                    for (x = 0; x < 512; x = x + 1)
                        $fwrite(index_handle, "%03x ",
                                frame_pixels[y * 512 + x]);
                    $fwrite(index_handle, "\n");
                end
                $fclose(index_handle);
            end
            $display("PASS tb_video_frame: output=%s no_sprites=%0d no_bg0=%0d no_bg1=%0d no_high=%0d no_low=%0d pause=%0d range=%0d..%0d",
                     output_path, no_sprites, no_bg0, no_bg1,
                     no_high_sprites, no_low_sprites, sprite_pause,
                     sprite_first, sprite_last);
            $finish;
        end
    end
end

initial begin
    if (!$value$plusargs("VCO=%s", vco_path))
        $fatal(1, "+VCO is required");
    if (!$value$plusargs("PALETTE=%s", palette_path))
        $fatal(1, "+PALETTE is required");
    if (!$value$plusargs("ROM=%s", rom_path))
        $fatal(1, "+ROM is required");
    if (!$value$plusargs("OUTPUT=%s", output_path))
        $fatal(1, "+OUTPUT is required");
    no_sprites = $test$plusargs("NO_SPRITES");
    no_bg0 = $test$plusargs("NO_BG0");
    no_bg1 = $test$plusargs("NO_BG1");
    no_high_sprites = $test$plusargs("NO_HIGH_SPRITES");
    no_low_sprites = $test$plusargs("NO_LOW_SPRITES");
    if (!$value$plusargs("SPRITE_PAUSE=%d", sprite_pause))
        sprite_pause = 127;
    if (!$value$plusargs("SPRITE_FIRST=%d", sprite_first))
        sprite_first = -1;
    if (!$value$plusargs("SPRITE_LAST=%d", sprite_last))
        sprite_last = 127;
    dump_indices = $value$plusargs("INDEX_OUTPUT=%s", index_path);
    expect_topland_bg0_edge_mask =
        $test$plusargs("EXPECT_TOPLAND_BG0_EDGE_MASK");
    expect_topland_no_cockpit =
        $test$plusargs("EXPECT_TOPLAND_NO_COCKPIT");
    expect_cloud_window = $test$plusargs("EXPECT_CLOUD_WINDOW");
    expect_noncloud_below = $test$plusargs("EXPECT_NONCLOUD_BELOW");

    fixture_handle = $fopen(vco_path, "r");
    if (!fixture_handle) $fatal(1, "cannot open VCO fixture %s", vco_path);
    $fclose(fixture_handle);
    fixture_handle = $fopen(palette_path, "r");
    if (!fixture_handle)
        $fatal(1, "cannot open palette fixture %s", palette_path);
    $fclose(fixture_handle);
    $readmemh(vco_path, vco_memory);
    $readmemh(palette_path, palette_memory);
    file_handle = $fopen(rom_path, "rb");
    if (!file_handle) $fatal(1, "cannot open %s", rom_path);
    seek_result = $fseek(file_handle, 32'h00100000, 0);
    if (seek_result != 0) $fatal(1, "cannot seek graphics region");
    read_count = $fread(gfx_memory, file_handle);
    $fclose(file_handle);
    if (read_count != 1048576)
        $fatal(1, "short graphics read: %0d", read_count);

    repeat (4) @(negedge clk);
    reset = 0;
end

initial begin
    repeat (5000000) @(negedge clk);
    $fatal(1, "frame diagnostic timed out");
end
endmodule
