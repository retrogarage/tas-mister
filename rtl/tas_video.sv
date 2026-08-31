// Taito Air video path: TC0080VCO background and motion-object planes around
// the board's polygon framebuffer and TC0430GRW gradient generator.
module tas_video (
    input               clk,
    input               reset,
    input               rom_loaded,
    input               download_active,
    input               throttle_overlay_enable,
    input      [11:0]   throttle_counter,
    input      [11:0]   stick_x_counter,
    input      [11:0]   stick_y_counter,

    output reg [16:0]   vco_addr,
    input      [15:0]   vco_data,
    output     [11:0]   palette_addr,
    input      [15:0]   palette_data,
    output     [12:0]   gradient_addr,
    input      [15:0]   gradient_low,
    input      [15:0]   gradient_high,
    input      [127:0]  grw_regs,
    input               gradbank,
    input      [9:0]    bg0_scrollx,
    input      [9:0]    bg0_scrolly,
    input      [15:0]   bg0_zoom,
    input      [9:0]    bg1_scrollx,
    input      [9:0]    bg1_scrolly,
    input      [15:0]   bg1_zoom,

    input      [2:0]    dsp_flag_strobe,
    input               dma_fb_erase_strobe,
    input               dma_fb_copy_strobe,
    output              line_req,
    output     [13:0]   line_addr,
    input               line_ack,
    input      [15:0]   line_data,

    output reg          gfx_req,
    output reg [19:0]   gfx_addr,
    input               gfx_ack,
    input      [63:0]   gfx_data,

    output              ce_pix,
    output reg          hblank,
    output reg          vblank,
    output reg          hsync,
    output reg          vsync,
    output reg [7:0]    red,
    output reg [7:0]    green,
    output reg [7:0]    blue,
    output     [63:0]   debug_gradient,
    output     [63:0]   debug_timing,
    output              ddr_background_safe,
    output              polygon_hold
);

reg [9:0] hcount;
reg [9:0] vcount;
reg [9:0] hcount_d1;
reg [9:0] hcount_d2;
reg [9:0] vcount_d1;
reg [9:0] vcount_d2;
reg pixel_div;
// The full-width output must stop before hcount 512. The synchronous line
// buffers use hcount[8:0], so including 512 wraps their address to x=0 and
// produces x=1..511,x=0: raw x=0 disappears from the left and reappears as a
// false right-edge column. The diagnostic 508-pixel aperture has been removed;
// the accepted path permanently emits native x=0..511 in order.
wire native_hactive = hcount < 10'd512;
// Polygon scanout remains a two-bank ping-pong path. Tile scanout has a
// separate four-bank queue so shared-DDR latency can be absorbed without
// dropping a complete cockpit line.
reg display_buffer;
reg [1:0] tile_display_buffer;
reg [1:0] write_buffer;
wire [8:0] line_pixel_0;
wire [8:0] line_pixel_1;
wire [8:0] line_pixel_2;
wire [8:0] line_pixel_3;
wire [8:0] display_pixel = tile_display_buffer == 2'd0 ? line_pixel_0 :
    (tile_display_buffer == 2'd1 ? line_pixel_1 :
     (tile_display_buffer == 2'd2 ? line_pixel_2 : line_pixel_3));
// The board video master is 16 MHz.  The core runs at 32 MHz so every second
// system clock is a pixel enable, leaving two renderer clocks per raster
// pixel without adding a second clock domain.
assign ce_pix = ~pixel_div;

wire throttle_overlay_draw;
wire [7:0] throttle_overlay_red;
wire [7:0] throttle_overlay_green;
wire [7:0] throttle_overlay_blue;
tas_throttle_overlay throttle_overlay (
    .enable(throttle_overlay_enable),
    .x(hcount_d2),
    .y(vcount_d2),
    .throttle_counter(throttle_counter),
    .stick_x_counter(stick_x_counter),
    .stick_y_counter(stick_y_counter),
    .draw(throttle_overlay_draw),
    .red(throttle_overlay_red),
    .green(throttle_overlay_green),
    .blue(throttle_overlay_blue)
);

wire [13:0] polygon_pixel;
wire polygon_pixel_valid;
wire polygon_busy;
wire [12:0] polygon_span_count;
wire polygon_overflow;
wire [12:0] polygon_missed_lines;
assign polygon_hold = polygon_busy;
reg [255:0] terrain_flags;

tas_polygon polygon_renderer (
    .clk(clk), .reset(reset), .flag_strobe(dsp_flag_strobe),
    .dma_erase_strobe(dma_fb_erase_strobe),
    .dma_copy_strobe(dma_fb_copy_strobe),
    .line_req(line_req), .line_addr(line_addr),
    .line_ack(line_ack), .line_data(line_data),
    .hcount(hcount), .vcount(vcount), .display_buffer(display_buffer),
    .terrain_flags(terrain_flags),
    .pixel(polygon_pixel), .pixel_valid(polygon_pixel_valid),
    .debug_busy(polygon_busy), .debug_span_count(polygon_span_count),
    .debug_overflow(polygon_overflow),
    .debug_missed_lines(polygon_missed_lines)
);

reg active_d1;
reg active_d2;
reg hactive_d1;
reg hactive_d2;
reg vactive_d1;
reg vactive_d2;
reg hsync_d1;
reg hsync_d2;
reg vsync_d1;
reg vsync_d2;
reg foreground_valid_d;
reg foreground_gradient_d;
reg line_valid_0;
reg line_valid_1;
reg line_valid_2;
reg line_valid_3;
reg [8:0] line_tag_0;
reg [8:0] line_tag_1;
reg [8:0] line_tag_2;
reg [8:0] line_tag_3;
reg display_line_ready;
wire [8:0] next_raster_y = vcount == 10'd461
    ? 9'd0 : vcount[8:0] + 1'd1;
wire next_line_ready_0 = line_valid_0 && line_tag_0 == next_raster_y;
wire next_line_ready_1 = line_valid_1 && line_tag_1 == next_raster_y;
wire next_line_ready_2 = line_valid_2 && line_tag_2 == next_raster_y;
wire next_line_ready_3 = line_valid_3 && line_tag_3 == next_raster_y;
wire next_display_line_ready = next_line_ready_0 || next_line_ready_1 ||
    next_line_ready_2 || next_line_ready_3;
wire [1:0] next_tile_display_buffer = next_line_ready_0 ? 2'd0 :
    (next_line_ready_1 ? 2'd1 :
     (next_line_ready_2 ? 2'd2 :
      (next_line_ready_3 ? 2'd3 : tile_display_buffer)));
wire display_line_valid = display_line_ready;
wire tile_foreground = display_line_valid && display_pixel != 0;
wire polygon_foreground = !tile_foreground && polygon_pixel_valid;
wire foreground_valid = tile_foreground || polygon_foreground;
wire foreground_gradient = polygon_foreground && polygon_pixel[13];
wire [11:0] foreground_palette_addr = tile_foreground
    ? {3'd0, display_pixel} : polygon_pixel[11:0];
wire left_edge_black_fill;
reg flight_cockpit_active;
reg cockpit_left_marker_seen;
reg cockpit_right_marker_seen;
wire title_active;

// The title's red disc, grey logo and blue Taito mark form a stable signature
// that does not occur in the course selector. Detect bounded regions rather
// than individual pixels: final RGB is registered, so an exact coordinate
// comparison against the output registers can observe the preceding pixel.
// Qualify the title separately so its x=3 mask cannot crop the selector's
// edge-traversing cursor.
tas_topland_title_detector title_detector (
    .clk(clk),
    .reset(reset),
    .pixel_valid(ce_pix && active_d2),
    .frame_end(ce_pix && active_d2 && hcount_d2 == 10'd511 &&
               vcount_d2 == 10'd399),
    .x(hcount_d2),
    .y(vcount_d2[8:0]),
    .red(red),
    .green(green),
    .blue(blue),
    .title_active(title_active)
);

// The flight view has a stable BG1 cockpit edge at native line 273. Publish
// that scene identity once per completed frame so the empty polygon/GRW strip
// can be blacked without affecting the title or full-width level selector.
tas_topland_left_edge_fill left_edge_fill (
    .x(hcount_d2),
    .y(vcount_d2[8:0]),
    .cockpit_active(flight_cockpit_active),
    .title_active(title_active),
    .foreground_valid(foreground_valid_d),
    .fill(left_edge_black_fill)
);

// Palette bit 15 marks which polygon headers select the terrain-gradient
// RAM.  Cache the 256 possible header entries during vertical blank, when the
// tile/polygon mixer does not need the palette port.
localparam C_IDLE  = 2'd0;
localparam C_WAIT  = 2'd1;
localparam C_LATCH = 2'd2;
reg [1:0] terrain_cache_state;
reg [7:0] terrain_cache_index;
assign palette_addr = terrain_cache_state != C_IDLE
    ? (12'h300 + {4'd0, terrain_cache_index})
    : foreground_palette_addr;

// TC0430GRW gradient palette. The board stores each color in two RAM words,
// so copy the 2 banks x 2 sources x 64 entries into synchronous memory during
// vertical blank. VCO splitting leaves enough M10Ks for one color lookup per
// pixel without consuming logic-array blocks.
localparam G_IDLE  = 2'd0;
localparam G_WAIT  = 2'd1;
localparam G_LATCH = 2'd2;

(* ramstyle = "M10K, no_rw_check" *) reg [23:0] gradient_cache [0:255];
reg [1:0] gradient_state;
reg [7:0] gradient_cache_index;
wire [7:0] gradient_next_index = gradient_cache_index + 1'd1;
reg gradient_cache_valid;
reg [23:0] gradient_cache_zero;
reg [12:0] gradient_cache_addr;
assign gradient_addr = gradient_state != G_IDLE
    ? gradient_cache_addr : polygon_pixel[12:0];

wire [15:0] grw_reg0 = grw_regs[15:0];
wire [15:0] grw_reg1 = grw_regs[31:16];
wire [15:0] grw_reg2 = grw_regs[47:32];
wire [15:0] grw_reg3 = grw_regs[63:48];
wire [15:0] grw_reg4 = grw_regs[79:64];
wire [15:0] grw_reg5 = grw_regs[95:80];
wire [15:0] grw_reg6 = grw_regs[111:96];
wire [15:0] grw_reg7 = grw_regs[127:112];
wire signed [31:0] gradient_inc1x = {{16{grw_reg2[15]}}, grw_reg2};
wire signed [31:0] gradient_inc1y = {{16{grw_reg3[15]}}, grw_reg3};
wire signed [31:0] gradient_inc2x = {{16{grw_reg6[15]}}, grw_reg6};
wire signed [31:0] gradient_inc2y = {{16{grw_reg7[15]}}, grw_reg7};

// The original visible area starts at raw Y=48. TC0430GRW's measured origin
// correction is therefore x+118, y+31 in this core's 512x400 coordinate space.
wire [31:0] gradient_frame_start1 = {grw_reg0, grw_reg1} +
    (gradient_inc1x <<< 7) - (gradient_inc1x <<< 3) -
    (gradient_inc1x <<< 1) + (gradient_inc1y <<< 5) - gradient_inc1y;
wire [31:0] gradient_frame_start2 = {grw_reg4, grw_reg5} +
    (gradient_inc2x <<< 7) - (gradient_inc2x <<< 3) -
    (gradient_inc2x <<< 1) + (gradient_inc2y <<< 5) - gradient_inc2y;
reg [31:0] gradient_line_counter1;
reg [31:0] gradient_line_counter2;
reg [31:0] gradient_pixel_counter1;
reg [31:0] gradient_pixel_counter2;
wire gradient_source = gradient_pixel_counter2[23];
wire gradient_active = gradient_source || gradient_pixel_counter1[23];
wire [31:0] gradient_selected_counter = gradient_source
                                            ? gradient_pixel_counter2
                                            : gradient_pixel_counter1;
// With neither counter selected the GRW still emits palette entry 0 (or the
// banked equivalent); it is not transparent. This full-raster underlay is what
// shows through pixels left uncovered by the polygon framebuffer.
wire [5:0] gradient_level = !gradient_active ? 6'd0 :
                            (gradient_selected_counter >= 32'h0083f000
                                ? 6'h3f
                                : gradient_selected_counter[17:12]);
wire [7:0] gradient_lookup = {gradbank, gradient_source, gradient_level};
reg [7:0] gradient_lookup_d1;
reg [23:0] gradient_rgb;

// Latched diagnostics avoid adding a second read port to the gradient cache.
assign debug_gradient = {
    gradbank, polygon_overflow,
    polygon_span_count, gradient_addr, gradient_cache_zero,
    builder_missed_lines[11:0]
};
assign debug_timing = {
    2'd0, builder_first_miss_valid, builder_first_miss_state,
    builder_first_miss_vcount, builder_missed_state_mask,
    builder_first_miss_gfx_req, builder_first_miss_layer,
    polygon_missed_lines, builder_missed_lines
};

// A registered lookup maps the cache to block RAM. Address d1 lines the result
// up with the existing two-cycle palette/video pipeline.
always @(posedge clk)
    gradient_rgb <= gradient_cache[gradient_lookup_d1];

localparam B_IDLE              = 5'd0;
localparam B_CLEAR             = 5'd1;
localparam B_BG_NUM_WAIT       = 5'd2;
localparam B_BG_NUM_LATCH      = 5'd3;
localparam B_BG_ATTR_WAIT      = 5'd4;
localparam B_BG_ATTR_LATCH     = 5'd5;
localparam B_BG_GFX_WAIT       = 5'd6;
localparam B_BG_EMIT           = 5'd7;
localparam B_SPR_SCAN          = 5'd8;
localparam B_SPR_ROW           = 5'd9;
localparam B_SPR_CHAIN0_WAIT   = 5'd10;
localparam B_SPR_CHAIN0_LATCH  = 5'd11;
localparam B_SPR_CHAIN1_WAIT   = 5'd12;
localparam B_SPR_CHAIN1_LATCH  = 5'd13;
localparam B_SPR_GFX_WAIT      = 5'd14;
localparam B_SPR_EMIT          = 5'd15;
localparam B_BG_DONE           = 5'd16;
localparam B_SPR_DONE          = 5'd17;
localparam B_SPR_CACHE         = 5'd18;

localparam D_IDLE         = 3'd0;
localparam D_WAIT         = 3'd1;
localparam D_LATCH        = 3'd2;
localparam D_CHAIN_START  = 3'd3;
localparam D_CHAIN0_WAIT  = 3'd4;
localparam D_CHAIN0_LATCH = 3'd5;
localparam D_CHAIN1_WAIT  = 3'd6;
localparam D_CHAIN1_LATCH = 3'd7;

localparam M_IDLE       = 3'd0;
localparam M_NUM_WAIT   = 3'd1;
localparam M_NUM_LATCH  = 3'd2;
localparam M_ATTR_WAIT  = 3'd3;
localparam M_ATTR_LATCH = 3'd4;

reg [4:0] builder_state;
reg [8:0] render_x;
reg [8:0] target_y;
reg [8:0] next_build_y;
reg render_layer;
reg [9:0] source_x;
reg [9:0] source_y;
reg [11:0] map_index;
reg [12:0] tile_number;
reg [7:0] tile_attr;
reg [63:0] tile_line;
reg line_valid;
reg [12:0] builder_missed_lines;
reg [18:0] builder_missed_state_mask;
reg builder_first_miss_valid;
reg [4:0] builder_first_miss_state;
reg [8:0] builder_first_miss_vcount;
reg builder_first_miss_gfx_req;
reg builder_first_miss_layer;
wire video_cache_ready = bg_map_cache_valid && descriptor_cache_valid &&
    sprite_line_masks_valid;
wire builder_line_missed = ce_pix && hcount == 10'd639 &&
    ((vcount < 10'd399) || vcount == 10'd461) &&
    video_cache_ready && !next_display_line_ready;

// A bank can be reused once its line has already been displayed. During
// vertical blank no tagged line from the new frame is reclaimable: the three
// banks hold the initial look-ahead queue (normally lines 0, 1 and 2).
wire reclaim_line_0 = !line_valid_0 ||
    (vcount < 10'd400 && line_tag_0 < vcount[8:0] &&
     tile_display_buffer != 2'd0);
wire reclaim_line_1 = !line_valid_1 ||
    (vcount < 10'd400 && line_tag_1 < vcount[8:0] &&
     tile_display_buffer != 2'd1);
wire reclaim_line_2 = !line_valid_2 ||
    (vcount < 10'd400 && line_tag_2 < vcount[8:0] &&
     tile_display_buffer != 2'd2);
wire reclaim_line_3 = !line_valid_3 ||
    (vcount < 10'd400 && line_tag_3 < vcount[8:0] &&
     tile_display_buffer != 2'd3);
wire build_bank_available = reclaim_line_0 || reclaim_line_1 ||
    reclaim_line_2 || reclaim_line_3;
wire [1:0] next_write_buffer = reclaim_line_0 ? 2'd0 :
    (reclaim_line_1 ? 2'd1 : (reclaim_line_2 ? 2'd2 : 2'd3));

// MiSTer maps the board's independent program, graphics, and sound ROM buses
// onto one physical DDR port. Less urgent CPU and telemetry traffic waits for
// two future lines. Audio remains time-critical, while graphics cache hits are
// served independently of an outstanding physical-DDR transaction.
wire future_line_0 = line_valid_0 && vcount < 10'd400 &&
    line_tag_0 > vcount[8:0];
wire future_line_1 = line_valid_1 && vcount < 10'd400 &&
    line_tag_1 > vcount[8:0];
wire future_line_2 = line_valid_2 && vcount < 10'd400 &&
    line_tag_2 > vcount[8:0];
wire future_line_3 = line_valid_3 && vcount < 10'd400 &&
    line_tag_3 > vcount[8:0];
wire two_future_lines = (future_line_0 && future_line_1) ||
    (future_line_0 && future_line_2) ||
    (future_line_0 && future_line_3) ||
    (future_line_1 && future_line_2) ||
    (future_line_1 && future_line_3) ||
    (future_line_2 && future_line_3);
assign ddr_background_safe = !video_cache_ready || vcount >= 10'd400 ||
    two_future_lines;
// BG0/BG1 tile numbers and attributes occupy four 4K-word VCO planes. Copy
// them into distributed memory once per frame during vertical blank. Visible
// rendering can then obtain the complete 20-bit cell in one clock instead of
// serializing four synchronous VCO-port cycles for every tile.
// Attribute bit 5 is unused by TC0080VCO; the other seven bits are X/Y flip
// and the five-bit color bank. A 20-bit cell maps exactly to sixteen M10Ks.
(* ramstyle = "M10K, no_rw_check" *) reg [19:0] bg_map_cache [0:8191];
reg [2:0] map_cache_state;
reg [12:0] map_cache_index;
reg [12:0] map_cache_number;
reg bg_map_cache_valid;
wire [12:0] map_cache_next_index = map_cache_index + 1'd1;
reg [12:0] bg_map_read_index;
reg [19:0] cached_map_cell;
wire [12:0] cached_tile_number = cached_map_cell[19:7];
wire [7:0] cached_tile_attr =
    {cached_map_cell[6:5], 1'b0, cached_map_cell[4:0]};

always @(posedge clk)
    cached_map_cell <= bg_map_cache[bg_map_read_index];

// Sprite descriptors are only 8 KiB.  Snapshot them during vertical blank so
// the scanline renderer can test one complete descriptor per clock instead of
// spending eight clocks on four narrow VCO-RAM reads for every visible line.
(* ramstyle = "MLAB, no_rw_check" *) reg [15:0] sprite_desc_0 [0:127];
(* ramstyle = "MLAB, no_rw_check" *) reg [15:0] sprite_desc_1 [0:127];
(* ramstyle = "MLAB, no_rw_check" *) reg [15:0] sprite_desc_2 [0:127];
(* ramstyle = "MLAB, no_rw_check" *) reg [15:0] sprite_desc_3 [0:127];
reg [2:0] descriptor_state;
reg [6:0] descriptor_index;
reg [1:0] descriptor_word;
reg [3:0] descriptor_cell;
reg descriptor_cache_valid;
reg [6:0] sprite_pause_index;

// Precompute the descriptors that touch each visible scanline during blanking.
// A 128-bit line mask replaces the old 128-descriptor linear walk on every
// line; dense dashboard lines then spend clocks only on objects they draw.
(* ramstyle = "M10K, no_rw_check" *) reg [127:0] sprite_line_masks [0:399];
reg [127:0] sprite_line_mask_q;
reg sprite_line_masks_valid;
reg sprite_mask_build_active;
reg [8:0] sprite_mask_line;
reg [6:0] sprite_mask_descriptor;
reg [127:0] sprite_mask_accumulator;

// Cache each descriptor's 4x4 chain cells during vertical blank. The source
// RAM is narrow and split into number/attribute halves; rereading it for every
// visible scanline costs sixteen renderer clocks per active descriptor.
// Split the four horizontal cells into independent banks.  The renderer can
// inspect the current and following cells in parallel without turning one
// inferred memory into an unsupported multi-read-port RAM.
(* ramstyle = "MLAB, no_rw_check" *) reg [12:0] sprite_chain_tile_0 [0:511];
(* ramstyle = "MLAB, no_rw_check" *) reg [12:0] sprite_chain_tile_1 [0:511];
(* ramstyle = "MLAB, no_rw_check" *) reg [12:0] sprite_chain_tile_2 [0:511];
(* ramstyle = "MLAB, no_rw_check" *) reg [12:0] sprite_chain_tile_3 [0:511];
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] sprite_chain_attr_0 [0:511];
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] sprite_chain_attr_1 [0:511];
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] sprite_chain_attr_2 [0:511];
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] sprite_chain_attr_3 [0:511];
wire [14:0] descriptor_chain_offset =
    {sprite_desc_3[descriptor_index][12:0], 2'b00} + descriptor_cell;
wire [10:0] descriptor_cache_address = {descriptor_index, descriptor_cell};

reg sprite_high_pass;
reg [7:0] sprite_index;
reg [127:0] sprite_scan_mask;
reg signed [11:0] sprite_x0;
reg signed [11:0] sprite_y0;
reg [5:0] sprite_dx;
reg [5:0] sprite_dy;
reg [5:0] sprite_draw_width;
reg [5:0] sprite_draw_height;
reg [2:0] sprite_row;
reg [3:0] sprite_pending_rows;
reg [1:0] sprite_column;
reg [14:0] sprite_tile_base;
reg [14:0] sprite_chain_offset;
reg [3:0] sprite_source_y;
reg [9:0] sprite_emit_end;
reg [20:0] sprite_source_fp;
reg [17:0] sprite_source_step;

function automatic [7:0] highest_sprite_index(input [127:0] mask);
    integer mask_index;
begin
    highest_sprite_index = 8'd0;
    for (mask_index = 0; mask_index < 128; mask_index = mask_index + 1)
        if (mask[mask_index]) highest_sprite_index = mask_index[7:0];
end
endfunction

wire [7:0] sprite_scan_index = highest_sprite_index(sprite_scan_mask);
wire [7:0] descriptor_select_index = builder_state == B_SPR_SCAN
    ? sprite_scan_index : sprite_index;
wire [15:0] selected_desc_0 =
    sprite_desc_0[descriptor_select_index[6:0]];
wire [15:0] selected_desc_1 =
    sprite_desc_1[descriptor_select_index[6:0]];
wire [15:0] selected_desc_2 =
    sprite_desc_2[descriptor_select_index[6:0]];
wire [15:0] selected_desc_3 =
    sprite_desc_3[descriptor_select_index[6:0]];
wire [8:0] selected_chain_row = {sprite_index[6:0], sprite_row[1:0]};
wire [12:0] selected_chain_tile_0 = sprite_chain_tile_0[selected_chain_row];
wire [12:0] selected_chain_tile_1 = sprite_chain_tile_1[selected_chain_row];
wire [12:0] selected_chain_tile_2 = sprite_chain_tile_2[selected_chain_row];
wire [12:0] selected_chain_tile_3 = sprite_chain_tile_3[selected_chain_row];
wire [7:0] selected_chain_attr_0 = sprite_chain_attr_0[selected_chain_row];
wire [7:0] selected_chain_attr_1 = sprite_chain_attr_1[selected_chain_row];
wire [7:0] selected_chain_attr_2 = sprite_chain_attr_2[selected_chain_row];
wire [7:0] selected_chain_attr_3 = sprite_chain_attr_3[selected_chain_row];
wire [12:0] selected_chain_tile = sprite_column == 2'd0
    ? selected_chain_tile_0 : sprite_column == 2'd1
    ? selected_chain_tile_1 : sprite_column == 2'd2
    ? selected_chain_tile_2 : selected_chain_tile_3;
wire [7:0] selected_chain_attr = sprite_column == 2'd0
    ? selected_chain_attr_0 : sprite_column == 2'd1
    ? selected_chain_attr_1 : sprite_column == 2'd2
    ? selected_chain_attr_2 : selected_chain_attr_3;
wire later_chain_nonzero =
    (sprite_column < 2'd1 && selected_chain_tile_1 != 0) ||
    (sprite_column < 2'd2 && selected_chain_tile_2 != 0) ||
    (sprite_column < 2'd3 && selected_chain_tile_3 != 0);
wire [1:0] sprite_next_column = sprite_column + 1'd1;
wire [12:0] selected_next_chain_tile = sprite_next_column == 2'd1
    ? selected_chain_tile_1 : sprite_next_column == 2'd2
    ? selected_chain_tile_2 : selected_chain_tile_3;
wire [7:0] selected_next_chain_attr = sprite_next_column == 2'd1
    ? selected_chain_attr_1 : sprite_next_column == 2'd2
    ? selected_chain_attr_2 : selected_chain_attr_3;
wire signed [12:0] sprite_next_column_x = sprite_x0 +
    $signed({1'b0, sprite_next_column}) * $signed({1'b0, sprite_dx});
function automatic signed [11:0] signed_sprite_coord(input [9:0] value);
begin
    signed_sprite_coord = value[9]
        ? $signed({2'b11, value}) : $signed({2'b00, value});
end
endfunction

function automatic [5:0] sprite_extent(input [7:0] zoom);
begin
    if (zoom < 7'd63)
        sprite_extent = 6'd8 + ((zoom + 2'd2) >> 3);
    else
        sprite_extent = 6'd16 + ((zoom - 7'd63) >> 2);
end
endfunction

// The TC0080VCO advances the next tile by dx/dy, but the scaled tile itself
// can be a few pixels wider.  Those overlaps are intentional and prevent
// seams between cells in a zoomed motion-object chain.
function automatic [5:0] sprite_draw_extent(input [7:0] zoom);
    reg [5:0] spacing;
    reg [3:0] remainder;
begin
    spacing = sprite_extent(zoom);
    if (zoom < 7'd63) begin
        remainder = (zoom + 2'd2) & 4'd7;
        sprite_draw_extent = spacing + ((remainder + 1'd1) >> 1);
    end else begin
        remainder = (zoom - 7'd63) & 4'd3;
        sprite_draw_extent = spacing + remainder;
    end
end
endfunction

// 16.16 source-pixel increment for a scaled 16-pixel cell.  This matches the
// integer stepping used by the established software model without inferring
// a variable divider in the render path.
function automatic [17:0] sprite_step(input [5:0] extent);
begin
    case (extent)
        6'd8:  sprite_step = 18'd131072;
        6'd9:  sprite_step = 18'd116508;
        6'd10: sprite_step = 18'd104857;
        6'd11: sprite_step = 18'd95325;
        6'd12: sprite_step = 18'd87381;
        6'd13: sprite_step = 18'd80659;
        6'd14: sprite_step = 18'd74898;
        6'd15: sprite_step = 18'd69905;
        6'd16: sprite_step = 18'd65536;
        6'd17: sprite_step = 18'd61680;
        6'd18: sprite_step = 18'd58254;
        6'd19: sprite_step = 18'd55188;
        6'd20: sprite_step = 18'd52428;
        6'd21: sprite_step = 18'd49932;
        6'd22: sprite_step = 18'd47662;
        6'd23: sprite_step = 18'd45590;
        6'd24: sprite_step = 18'd43690;
        6'd25: sprite_step = 18'd41943;
        6'd26: sprite_step = 18'd40329;
        6'd27: sprite_step = 18'd38836;
        6'd28: sprite_step = 18'd37449;
        6'd29: sprite_step = 18'd36157;
        6'd30: sprite_step = 18'd34952;
        6'd31: sprite_step = 18'd33825;
        6'd32: sprite_step = 18'd32768;
        6'd33: sprite_step = 18'd31775;
        default: sprite_step = 18'd30840;
    endcase
end
endfunction

// The Y register is encoded differently from X.  These are the measured,
// hand-tuned TC0080VCO conversion values used by the existing device model.
function automatic [7:0] sprite_zoomy(input [6:0] raw_zoom);
begin
    case (raw_zoom)
        7'h00: sprite_zoomy=7'h00; 7'h01: sprite_zoomy=7'h01;
        7'h02: sprite_zoomy=7'h01; 7'h03: sprite_zoomy=7'h02;
        7'h04: sprite_zoomy=7'h02; 7'h05: sprite_zoomy=7'h03;
        7'h06: sprite_zoomy=7'h04; 7'h07: sprite_zoomy=7'h05;
        7'h08: sprite_zoomy=7'h06; 7'h09: sprite_zoomy=7'h06;
        7'h0a: sprite_zoomy=7'h07; 7'h0b: sprite_zoomy=7'h08;
        7'h0c: sprite_zoomy=7'h09; 7'h0d: sprite_zoomy=7'h0a;
        7'h0e: sprite_zoomy=7'h0a; 7'h0f: sprite_zoomy=7'h0b;
        7'h10: sprite_zoomy=7'h0b; 7'h11: sprite_zoomy=7'h0c;
        7'h12: sprite_zoomy=7'h0c; 7'h13: sprite_zoomy=7'h0d;
        7'h14: sprite_zoomy=7'h0e; 7'h15: sprite_zoomy=7'h0e;
        7'h16: sprite_zoomy=7'h0f; 7'h17: sprite_zoomy=7'h10;
        7'h18: sprite_zoomy=7'h10; 7'h19: sprite_zoomy=7'h11;
        7'h1a: sprite_zoomy=7'h12; 7'h1b: sprite_zoomy=7'h13;
        7'h1c: sprite_zoomy=7'h14; 7'h1d: sprite_zoomy=7'h15;
        7'h1e: sprite_zoomy=7'h16; 7'h1f: sprite_zoomy=7'h16;
        7'h20: sprite_zoomy=7'h17; 7'h21: sprite_zoomy=7'h18;
        7'h22: sprite_zoomy=7'h19; 7'h23: sprite_zoomy=7'h1a;
        7'h24: sprite_zoomy=7'h1b; 7'h25: sprite_zoomy=7'h1c;
        7'h26: sprite_zoomy=7'h1d; 7'h27: sprite_zoomy=7'h1e;
        7'h28: sprite_zoomy=7'h1f; 7'h29: sprite_zoomy=7'h20;
        7'h2a: sprite_zoomy=7'h21; 7'h2b: sprite_zoomy=7'h22;
        7'h2c: sprite_zoomy=7'h24; 7'h2d: sprite_zoomy=7'h25;
        7'h2e: sprite_zoomy=7'h26; 7'h2f: sprite_zoomy=7'h27;
        7'h30: sprite_zoomy=7'h28; 7'h31: sprite_zoomy=7'h2a;
        7'h32: sprite_zoomy=7'h2b; 7'h33: sprite_zoomy=7'h2c;
        7'h34: sprite_zoomy=7'h2e; 7'h35: sprite_zoomy=7'h30;
        7'h36: sprite_zoomy=7'h31; 7'h37: sprite_zoomy=7'h32;
        7'h38: sprite_zoomy=7'h34; 7'h39: sprite_zoomy=7'h36;
        7'h3a: sprite_zoomy=7'h37; 7'h3b: sprite_zoomy=7'h38;
        7'h3c: sprite_zoomy=7'h3a; 7'h3d: sprite_zoomy=7'h3c;
        7'h3e: sprite_zoomy=7'h3e; 7'h3f: sprite_zoomy=7'h3f;
        7'h40: sprite_zoomy=7'h40; 7'h41: sprite_zoomy=7'h41;
        7'h42: sprite_zoomy=7'h42; 7'h43: sprite_zoomy=7'h42;
        7'h44: sprite_zoomy=7'h43; 7'h45: sprite_zoomy=7'h43;
        7'h46: sprite_zoomy=7'h44; 7'h47: sprite_zoomy=7'h44;
        7'h48: sprite_zoomy=7'h45; 7'h49: sprite_zoomy=7'h45;
        7'h4a: sprite_zoomy=7'h46; 7'h4b: sprite_zoomy=7'h46;
        7'h4c: sprite_zoomy=7'h47; 7'h4d: sprite_zoomy=7'h47;
        7'h4e: sprite_zoomy=7'h48; 7'h4f: sprite_zoomy=7'h49;
        7'h50: sprite_zoomy=7'h4a; 7'h51: sprite_zoomy=7'h4a;
        7'h52: sprite_zoomy=7'h4b; 7'h53: sprite_zoomy=7'h4b;
        7'h54: sprite_zoomy=7'h4c; 7'h55: sprite_zoomy=7'h4d;
        7'h56: sprite_zoomy=7'h4e; 7'h57: sprite_zoomy=7'h4f;
        7'h58: sprite_zoomy=7'h4f; 7'h59: sprite_zoomy=7'h50;
        7'h5a: sprite_zoomy=7'h51; 7'h5b: sprite_zoomy=7'h51;
        7'h5c: sprite_zoomy=7'h52; 7'h5d: sprite_zoomy=7'h53;
        7'h5e: sprite_zoomy=7'h54; 7'h5f: sprite_zoomy=7'h55;
        7'h60: sprite_zoomy=7'h56; 7'h61: sprite_zoomy=7'h57;
        7'h62: sprite_zoomy=7'h58; 7'h63: sprite_zoomy=7'h59;
        7'h64: sprite_zoomy=7'h5a; 7'h65: sprite_zoomy=7'h5b;
        7'h66: sprite_zoomy=7'h5c; 7'h67: sprite_zoomy=7'h5d;
        7'h68: sprite_zoomy=7'h5e; 7'h69: sprite_zoomy=7'h5f;
        7'h6a: sprite_zoomy=7'h60; 7'h6b: sprite_zoomy=7'h61;
        7'h6c: sprite_zoomy=7'h62; 7'h6d: sprite_zoomy=7'h63;
        7'h6e: sprite_zoomy=7'h64; 7'h6f: sprite_zoomy=7'h66;
        7'h70: sprite_zoomy=7'h67; 7'h71: sprite_zoomy=7'h68;
        7'h72: sprite_zoomy=7'h6a; 7'h73: sprite_zoomy=7'h6b;
        7'h74: sprite_zoomy=7'h6c; 7'h75: sprite_zoomy=7'h6e;
        7'h76: sprite_zoomy=7'h6f; 7'h77: sprite_zoomy=7'h71;
        7'h78: sprite_zoomy=7'h72; 7'h79: sprite_zoomy=7'h74;
        7'h7a: sprite_zoomy=7'h76; 7'h7b: sprite_zoomy=7'h78;
        7'h7c: sprite_zoomy=8'h80; 7'h7d: sprite_zoomy=8'h7b;
        7'h7e: sprite_zoomy=8'h7d; default: sprite_zoomy=8'h7f;
    endcase
end
endfunction

// Visible logical line zero is raw VCO line 48. The configured +1 Y offset
// makes the source coordinate raw_y + scroll_y - 1. Retain the complete raw
// VCO line. Top Landing deliberately supplies opaque BG0 wrap-mask texels near
// both horizontal edges; keep them in the complete 512-column composition.
wire [9:0] bg0_start_source_x = ~bg0_scrollx;
wire [9:0] bg0_start_source_y = target_y + bg0_scrolly + 10'd47;
wire [11:0] bg0_start_map_index =
    {bg0_start_source_y[9:4], 6'b000000} +
    {8'd0, bg0_start_source_x[9:4]};
wire [9:0] bg1_start_source_x = ~bg1_scrollx;
wire [9:0] bg1_start_source_y = target_y + bg1_scrolly + 10'd47;
wire [11:0] bg1_start_map_index =
    {bg1_start_source_y[9:4], 6'b000000} +
    {8'd0, bg1_start_source_x[9:4]};

function automatic [3:0] tile_pixel(
    input [63:0] row_data,
    input [3:0] pixel_x
);
    reg [7:0] pixel_byte;
begin
    // TC0080VCO x bit offsets are 60,56,...,0.  MAME's STEP4(0,1)
    // plane layout numbers bits from the LSB, so screen-left starts at
    // the low nibble of byte seven in the aligned DDR row.
    case (pixel_x[3:1])
        3'd0: pixel_byte = row_data[63:56];
        3'd1: pixel_byte = row_data[55:48];
        3'd2: pixel_byte = row_data[47:40];
        3'd3: pixel_byte = row_data[39:32];
        3'd4: pixel_byte = row_data[31:24];
        3'd5: pixel_byte = row_data[23:16];
        3'd6: pixel_byte = row_data[15:8];
        default: pixel_byte = row_data[7:0];
    endcase
    tile_pixel = pixel_x[0] ? pixel_byte[7:4] : pixel_byte[3:0];
end
endfunction

wire [4:0] bg_tile_remainder = 5'd16 - {1'b0, source_x[3:0]};
wire [9:0] bg_line_remainder = 10'd512 - {1'b0, render_x};
wire [4:0] emit_count = bg_line_remainder < bg_tile_remainder
    ? bg_line_remainder[3:0]
    : bg_tile_remainder;
wire [9:0] bg_skip_count = bg_line_remainder < bg_tile_remainder
    ? bg_line_remainder : bg_tile_remainder;
wire [9:0] bg_skipped_source_x = source_x + bg_skip_count;
wire [9:0] bg_emitted_source_x = source_x + emit_count;
wire [11:0] bg_skipped_map_index =
    {source_y[9:4], 6'b000000} + {8'd0, bg_skipped_source_x[9:4]};
wire [11:0] bg_emitted_map_index =
    {source_y[9:4], 6'b000000} + {8'd0, bg_emitted_source_x[9:4]};

wire [8:0] emit_pixels [0:15];
genvar bg_emit_index;
generate
    for (bg_emit_index = 0; bg_emit_index < 16;
         bg_emit_index = bg_emit_index + 1) begin : g_bg_emit_pixel
        wire [3:0] source_pixel_x = source_x[3:0] + bg_emit_index;
        wire [3:0] oriented_pixel_x = tile_attr[6]
            ? (4'd15 - source_pixel_x) : source_pixel_x;
        wire [3:0] pixel_value = tile_pixel(tile_line, oriented_pixel_x);
        assign emit_pixels[bg_emit_index] = pixel_value == 0
            ? 9'd0 : {tile_attr[4:0], pixel_value};
    end
endgenerate

wire [20:0] sprite_source_positions [0:15];
genvar sprite_source_index;
generate
    for (sprite_source_index = 0; sprite_source_index < 16;
         sprite_source_index = sprite_source_index + 1) begin : g_sprite_source
        // Compute every sample from the registered base.  Chaining each
        // sample from its predecessor creates a fifteen-adder path into the
        // line-buffer RAM at 32 MHz; a genvar constant lets synthesis reduce
        // this to a small independent shift/add network for each lane.
        assign sprite_source_positions[sprite_source_index] =
            sprite_source_fp + (sprite_source_step * sprite_source_index);
    end
endgenerate
wire [8:0] sprite_emit_pixels [0:15];
genvar sprite_emit_index;
generate
    for (sprite_emit_index = 0; sprite_emit_index < 16;
         sprite_emit_index = sprite_emit_index + 1) begin : g_sprite_emit_pixel
        wire [3:0] source_pixel_x =
            sprite_source_positions[sprite_emit_index][19:16];
        wire [3:0] oriented_pixel_x = tile_attr[6]
            ? (4'd15 - source_pixel_x) : source_pixel_x;
        wire [3:0] pixel_value = tile_pixel(tile_line, oriented_pixel_x);
        assign sprite_emit_pixels[sprite_emit_index] = pixel_value == 0
            ? 9'd0 : {tile_attr[4:0], pixel_value};
    end
endgenerate
wire [9:0] sprite_emit_remaining = sprite_emit_end - {1'b0, render_x};
wire [4:0] sprite_emit_count = sprite_emit_remaining >= 10'd16
    ? 5'd16 : sprite_emit_remaining[4:0];

wire signed [12:0] sprite_row_y = sprite_y0 +
    $signed({1'b0, sprite_row}) * $signed({1'b0, sprite_dy});
wire signed [12:0] sprite_raw_target_y =
    $signed({4'd0, target_y}) + 13'sd48;
wire signed [12:0] sprite_column_x = sprite_x0 +
    $signed({1'b0, sprite_column}) * $signed({1'b0, sprite_dx});
wire [20:0] sprite_y_product =
    $unsigned(sprite_raw_target_y - sprite_row_y) *
    sprite_step(sprite_draw_height);

// Reject descriptors that do not touch the target line in the scan state.
// Walking all four possible rows serially consumed most of the line budget in
// the dashboard scene even though only a handful actually intersected it.
wire signed [11:0] selected_sprite_y0 =
    signed_sprite_coord(selected_desc_0[9:0]) + 12'sd2;
wire [7:0] selected_sprite_zoomy = sprite_zoomy(selected_desc_2[6:0]);
wire [5:0] selected_sprite_dy = sprite_extent(selected_sprite_zoomy);
wire [5:0] selected_sprite_draw_height =
    sprite_draw_extent(selected_sprite_zoomy);
wire [2:0] selected_sprite_rows = selected_desc_0[11:10] == 2'd0
    ? 3'd1 : (selected_desc_0[11:10] == 2'd1 ? 3'd2 : 3'd4);
wire signed [12:0] selected_row_y_0 = selected_sprite_y0;
wire signed [12:0] selected_row_y_1 = selected_sprite_y0 +
    $signed({1'b0, selected_sprite_dy});
wire signed [12:0] selected_row_y_2 = selected_sprite_y0 +
    ($signed({1'b0, selected_sprite_dy}) <<< 1);
wire signed [12:0] selected_row_y_3 = selected_row_y_2 +
    $signed({1'b0, selected_sprite_dy});
wire selected_row_hit_0 = sprite_raw_target_y >= selected_row_y_0 &&
    sprite_raw_target_y < selected_row_y_0 +
        $signed({1'b0, selected_sprite_draw_height});
wire selected_row_hit_1 = selected_sprite_rows >= 2 &&
    sprite_raw_target_y >= selected_row_y_1 &&
    sprite_raw_target_y < selected_row_y_1 +
        $signed({1'b0, selected_sprite_draw_height});
wire selected_row_hit_2 = selected_sprite_rows >= 3 &&
    sprite_raw_target_y >= selected_row_y_2 &&
    sprite_raw_target_y < selected_row_y_2 +
        $signed({1'b0, selected_sprite_draw_height});
wire selected_row_hit_3 = selected_sprite_rows >= 4 &&
    sprite_raw_target_y >= selected_row_y_3 &&
    sprite_raw_target_y < selected_row_y_3 +
        $signed({1'b0, selected_sprite_draw_height});
wire [3:0] selected_sprite_row_hits = {
    selected_row_hit_3, selected_row_hit_2,
    selected_row_hit_1, selected_row_hit_0
};
wire [2:0] selected_sprite_row = selected_row_hit_0 ? 3'd0 :
    (selected_row_hit_1 ? 3'd1 : (selected_row_hit_2 ? 3'd2 : 3'd3));
wire signed [12:0] selected_sprite_row_y = selected_row_hit_0
    ? selected_row_y_0 : (selected_row_hit_1 ? selected_row_y_1 :
        (selected_row_hit_2 ? selected_row_y_2 : selected_row_y_3));
wire [20:0] selected_sprite_y_product =
    $unsigned(sprite_raw_target_y - selected_sprite_row_y) *
    sprite_step(selected_sprite_draw_height);
wire [2:0] sprite_next_row = sprite_pending_rows[0] ? 3'd0 :
    (sprite_pending_rows[1] ? 3'd1 :
     (sprite_pending_rows[2] ? 3'd2 : 3'd3));
wire [3:0] sprite_remaining_rows = sprite_pending_rows &
    ~(4'b0001 << sprite_next_row);

wire [15:0] mask_desc_0 = sprite_desc_0[sprite_mask_descriptor];
wire [15:0] mask_desc_2 = sprite_desc_2[sprite_mask_descriptor];
wire [15:0] mask_desc_3 = sprite_desc_3[sprite_mask_descriptor];
wire signed [11:0] mask_sprite_y0 =
    signed_sprite_coord(mask_desc_0[9:0]) + 12'sd2;
wire [7:0] mask_sprite_zoomy = sprite_zoomy(mask_desc_2[6:0]);
wire [5:0] mask_sprite_dy = sprite_extent(mask_sprite_zoomy);
wire [5:0] mask_sprite_draw_height =
    sprite_draw_extent(mask_sprite_zoomy);
wire [2:0] mask_sprite_rows = mask_desc_0[11:10] == 2'd0
    ? 3'd1 : (mask_desc_0[11:10] == 2'd1 ? 3'd2 : 3'd4);
wire signed [12:0] mask_raw_y =
    $signed({4'd0, sprite_mask_line}) + 13'sd48;
wire signed [12:0] mask_row_y_0 = mask_sprite_y0;
wire signed [12:0] mask_row_y_1 = mask_sprite_y0 +
    $signed({1'b0, mask_sprite_dy});
wire signed [12:0] mask_row_y_2 = mask_sprite_y0 +
    ($signed({1'b0, mask_sprite_dy}) <<< 1);
wire signed [12:0] mask_row_y_3 = mask_row_y_2 +
    $signed({1'b0, mask_sprite_dy});
wire mask_descriptor_hits_line = mask_desc_3[12:0] != 0 && (
    (mask_raw_y >= mask_row_y_0 &&
     mask_raw_y < mask_row_y_0 + $signed({1'b0, mask_sprite_draw_height})) ||
    (mask_sprite_rows >= 2 && mask_raw_y >= mask_row_y_1 &&
     mask_raw_y < mask_row_y_1 + $signed({1'b0, mask_sprite_draw_height})) ||
    (mask_sprite_rows >= 3 && mask_raw_y >= mask_row_y_2 &&
     mask_raw_y < mask_row_y_2 + $signed({1'b0, mask_sprite_draw_height})) ||
    (mask_sprite_rows >= 4 && mask_raw_y >= mask_row_y_3 &&
     mask_raw_y < mask_row_y_3 + $signed({1'b0, mask_sprite_draw_height})));
reg [127:0] sprite_mask_accumulator_next;
always @* begin
    sprite_mask_accumulator_next = sprite_mask_accumulator;
    sprite_mask_accumulator_next[sprite_mask_descriptor] =
        mask_descriptor_hits_line;
end

wire [127:0] sprite_high_line_mask;
wire [127:0] sprite_low_line_mask;
genvar sprite_mask_index;
generate
    for (sprite_mask_index = 0; sprite_mask_index < 128;
         sprite_mask_index = sprite_mask_index + 1) begin : g_sprite_priority
        assign sprite_high_line_mask[sprite_mask_index] =
            sprite_line_mask_q[sprite_mask_index] &&
            sprite_mask_index > sprite_pause_index;
        assign sprite_low_line_mask[sprite_mask_index] =
            sprite_line_mask_q[sprite_mask_index] &&
            sprite_mask_index < sprite_pause_index;
    end
endgenerate

reg [15:0] line_write_enable;
reg [4:0] line_write_addr [0:15];
reg [8:0] line_write_data [0:15];
integer line_lane;
integer line_bank;
integer cockpit_lane;

// Top Landing builds its cloud field from the 4x4 chain at $08c4. The
// descriptors deliberately extend below the playfield, but the arcade-derived
// reference requires that world object to stop at the cockpit boundary. The
// current device model lacks an equivalent window, which is why a smaller form
// of the leak is visible in MAME too. Keep every other motion object untouched:
// descriptors on both sides of the pause marker include valid cockpit graphics
// and runway personnel.
wire sprite_window_visible;
tas_topland_sprite_window sprite_window (
    .chain_base(sprite_tile_base),
    .target_y(target_y),
    .visible(sprite_window_visible)
);

// Sixteen interleaved MLAB banks accept a complete 16-pixel tile row per
// clock. At 32 MHz this is enough to compose both backgrounds and the dense
// dashboard motion objects before the following 16 MHz scanline begins.
always @* begin
    line_write_enable = 16'd0;
    line_bank = 0;
    for (line_lane = 0; line_lane < 16; line_lane = line_lane + 1) begin
        line_write_addr[line_lane] = render_x[8:4];
        line_write_data[line_lane] = 9'd0;
    end

    if (builder_state == B_CLEAR) begin
        line_write_enable = 16'hffff;
        // Establish the left aperture at the true output boundary even when
        // BG0 begins with an empty tile that the builder skips wholesale.
        if (render_x == 9'd0)
            line_write_data[0] = 9'h00d;
    end else if (builder_state == B_BG_EMIT) begin
        for (line_lane = 0; line_lane < 16; line_lane = line_lane + 1) begin
            // Top Landing's BG0 wrap places its palette-$00d left aperture
            // mask at logical x=1..2, leaving a one-pixel image sliver at x=0.
            // Relocate that mask to the actual x=0 boundary without shifting
            // the 512-pixel composition. BG1 and motion objects run later and
            // retain their normal ability to overwrite the boundary pixel.
            // Keep the independently correct right-edge texel untouched.
            if (line_lane < emit_count && emit_pixels[line_lane] != 0 &&
                !(!render_layer && emit_pixels[line_lane] == 9'h00d &&
                  ({1'b0, render_x} + line_lane) >= 10'd1 &&
                  ({1'b0, render_x} + line_lane) <= 10'd2)) begin
                line_bank = (render_x[3:0] + line_lane) & 15;
                line_write_enable[line_bank] = 1'b1;
                line_write_addr[line_bank] =
                    ({1'b0, render_x} + line_lane) >> 4;
                line_write_data[line_bank] = emit_pixels[line_lane];
            end
        end
    end else if (builder_state == B_SPR_EMIT) begin
        for (line_lane = 0; line_lane < 16; line_lane = line_lane + 1) begin
            if (sprite_window_visible && line_lane < sprite_emit_count &&
                sprite_emit_pixels[line_lane] != 0) begin
                line_bank = (render_x[3:0] + line_lane) & 15;
                line_write_enable[line_bank] = 1'b1;
                line_write_addr[line_bank] =
                    ({1'b0, render_x} + line_lane) >> 4;
                line_write_data[line_bank] = sprite_emit_pixels[line_lane];
            end
        end
    end
end

tas_line_buffer line_buffer_0 (
    .clk(clk),
    .read_addr(hcount[8:0]),
    .read_data(line_pixel_0),
    .write_enable(line_write_enable & {16{write_buffer == 2'd0}}),
    .write_addr_0(line_write_addr[0]), .write_data_0(line_write_data[0]),
    .write_addr_1(line_write_addr[1]), .write_data_1(line_write_data[1]),
    .write_addr_2(line_write_addr[2]), .write_data_2(line_write_data[2]),
    .write_addr_3(line_write_addr[3]), .write_data_3(line_write_data[3]),
    .write_addr_4(line_write_addr[4]), .write_data_4(line_write_data[4]),
    .write_addr_5(line_write_addr[5]), .write_data_5(line_write_data[5]),
    .write_addr_6(line_write_addr[6]), .write_data_6(line_write_data[6]),
    .write_addr_7(line_write_addr[7]), .write_data_7(line_write_data[7]),
    .write_addr_8(line_write_addr[8]), .write_data_8(line_write_data[8]),
    .write_addr_9(line_write_addr[9]), .write_data_9(line_write_data[9]),
    .write_addr_10(line_write_addr[10]), .write_data_10(line_write_data[10]),
    .write_addr_11(line_write_addr[11]), .write_data_11(line_write_data[11]),
    .write_addr_12(line_write_addr[12]), .write_data_12(line_write_data[12]),
    .write_addr_13(line_write_addr[13]), .write_data_13(line_write_data[13]),
    .write_addr_14(line_write_addr[14]), .write_data_14(line_write_data[14]),
    .write_addr_15(line_write_addr[15]), .write_data_15(line_write_data[15])
);

tas_line_buffer line_buffer_1 (
    .clk(clk),
    .read_addr(hcount[8:0]),
    .read_data(line_pixel_1),
    .write_enable(line_write_enable & {16{write_buffer == 2'd1}}),
    .write_addr_0(line_write_addr[0]), .write_data_0(line_write_data[0]),
    .write_addr_1(line_write_addr[1]), .write_data_1(line_write_data[1]),
    .write_addr_2(line_write_addr[2]), .write_data_2(line_write_data[2]),
    .write_addr_3(line_write_addr[3]), .write_data_3(line_write_data[3]),
    .write_addr_4(line_write_addr[4]), .write_data_4(line_write_data[4]),
    .write_addr_5(line_write_addr[5]), .write_data_5(line_write_data[5]),
    .write_addr_6(line_write_addr[6]), .write_data_6(line_write_data[6]),
    .write_addr_7(line_write_addr[7]), .write_data_7(line_write_data[7]),
    .write_addr_8(line_write_addr[8]), .write_data_8(line_write_data[8]),
    .write_addr_9(line_write_addr[9]), .write_data_9(line_write_data[9]),
    .write_addr_10(line_write_addr[10]), .write_data_10(line_write_data[10]),
    .write_addr_11(line_write_addr[11]), .write_data_11(line_write_data[11]),
    .write_addr_12(line_write_addr[12]), .write_data_12(line_write_data[12]),
    .write_addr_13(line_write_addr[13]), .write_data_13(line_write_data[13]),
    .write_addr_14(line_write_addr[14]), .write_data_14(line_write_data[14]),
    .write_addr_15(line_write_addr[15]), .write_data_15(line_write_data[15])
);

tas_line_buffer line_buffer_2 (
    .clk(clk),
    .read_addr(hcount[8:0]),
    .read_data(line_pixel_2),
    .write_enable(line_write_enable & {16{write_buffer == 2'd2}}),
    .write_addr_0(line_write_addr[0]), .write_data_0(line_write_data[0]),
    .write_addr_1(line_write_addr[1]), .write_data_1(line_write_data[1]),
    .write_addr_2(line_write_addr[2]), .write_data_2(line_write_data[2]),
    .write_addr_3(line_write_addr[3]), .write_data_3(line_write_data[3]),
    .write_addr_4(line_write_addr[4]), .write_data_4(line_write_data[4]),
    .write_addr_5(line_write_addr[5]), .write_data_5(line_write_data[5]),
    .write_addr_6(line_write_addr[6]), .write_data_6(line_write_data[6]),
    .write_addr_7(line_write_addr[7]), .write_data_7(line_write_data[7]),
    .write_addr_8(line_write_addr[8]), .write_data_8(line_write_data[8]),
    .write_addr_9(line_write_addr[9]), .write_data_9(line_write_data[9]),
    .write_addr_10(line_write_addr[10]), .write_data_10(line_write_data[10]),
    .write_addr_11(line_write_addr[11]), .write_data_11(line_write_data[11]),
    .write_addr_12(line_write_addr[12]), .write_data_12(line_write_data[12]),
    .write_addr_13(line_write_addr[13]), .write_data_13(line_write_data[13]),
    .write_addr_14(line_write_addr[14]), .write_data_14(line_write_data[14]),
    .write_addr_15(line_write_addr[15]), .write_data_15(line_write_data[15])
);

tas_line_buffer line_buffer_3 (
    .clk(clk),
    .read_addr(hcount[8:0]),
    .read_data(line_pixel_3),
    .write_enable(line_write_enable & {16{write_buffer == 2'd3}}),
    .write_addr_0(line_write_addr[0]), .write_data_0(line_write_data[0]),
    .write_addr_1(line_write_addr[1]), .write_data_1(line_write_data[1]),
    .write_addr_2(line_write_addr[2]), .write_data_2(line_write_data[2]),
    .write_addr_3(line_write_addr[3]), .write_data_3(line_write_data[3]),
    .write_addr_4(line_write_addr[4]), .write_data_4(line_write_data[4]),
    .write_addr_5(line_write_addr[5]), .write_data_5(line_write_data[5]),
    .write_addr_6(line_write_addr[6]), .write_data_6(line_write_data[6]),
    .write_addr_7(line_write_addr[7]), .write_data_7(line_write_data[7]),
    .write_addr_8(line_write_addr[8]), .write_data_8(line_write_data[8]),
    .write_addr_9(line_write_addr[9]), .write_data_9(line_write_data[9]),
    .write_addr_10(line_write_addr[10]), .write_data_10(line_write_data[10]),
    .write_addr_11(line_write_addr[11]), .write_data_11(line_write_data[11]),
    .write_addr_12(line_write_addr[12]), .write_data_12(line_write_data[12]),
    .write_addr_13(line_write_addr[13]), .write_data_13(line_write_data[13]),
    .write_addr_14(line_write_addr[14]), .write_data_14(line_write_data[14]),
    .write_addr_15(line_write_addr[15]), .write_data_15(line_write_data[15])
);

always @(posedge clk) begin
    if (reset) begin
        hcount <= 10'd0;
        vcount <= 10'd0;
        hcount_d1 <= 10'd0;
        hcount_d2 <= 10'd0;
        vcount_d1 <= 10'd0;
        vcount_d2 <= 10'd0;
        pixel_div <= 1'b0;
        display_buffer <= 1'b0;
        tile_display_buffer <= 2'd0;
        write_buffer <= 2'd0;
        active_d1 <= 1'b0;
        active_d2 <= 1'b0;
        hactive_d1 <= 1'b0;
        hactive_d2 <= 1'b0;
        vactive_d1 <= 1'b0;
        vactive_d2 <= 1'b0;
        hsync_d1 <= 1'b1;
        hsync_d2 <= 1'b1;
        vsync_d1 <= 1'b1;
        vsync_d2 <= 1'b1;
        foreground_valid_d <= 1'b0;
        foreground_gradient_d <= 1'b0;
        flight_cockpit_active <= 1'b0;
        cockpit_left_marker_seen <= 1'b0;
        cockpit_right_marker_seen <= 1'b0;
        terrain_flags <= 256'd0;
        terrain_cache_state <= C_IDLE;
        terrain_cache_index <= 8'd0;
        gradient_state <= G_IDLE;
        gradient_cache_index <= 8'd0;
        gradient_cache_addr <= 13'd0;
        gradient_cache_valid <= 1'b0;
        gradient_cache_zero <= 24'd0;
        gradient_line_counter1 <= 32'd0;
        gradient_line_counter2 <= 32'd0;
        gradient_pixel_counter1 <= 32'd0;
        gradient_pixel_counter2 <= 32'd0;
        gradient_lookup_d1 <= 8'd0;
        line_valid_0 <= 1'b0;
        line_valid_1 <= 1'b0;
        line_valid_2 <= 1'b0;
        line_valid_3 <= 1'b0;
        line_tag_0 <= 9'd0;
        line_tag_1 <= 9'd0;
        line_tag_2 <= 9'd0;
        line_tag_3 <= 9'd0;
        display_line_ready <= 1'b0;
        hblank <= 1'b1;
        vblank <= 1'b1;
        hsync <= 1'b1;
        vsync <= 1'b1;
        red <= 8'd0;
        green <= 8'd0;
        blue <= 8'd0;
        builder_state <= B_IDLE;
        render_x <= 9'd0;
        target_y <= 9'd0;
        next_build_y <= 9'd0;
        render_layer <= 1'b0;
        source_x <= 10'd0;
        source_y <= 10'd0;
        map_index <= 12'd0;
        tile_number <= 13'd0;
        tile_attr <= 8'd0;
        tile_line <= 64'd0;
        line_valid <= 1'b0;
        builder_missed_lines <= 13'd0;
        builder_missed_state_mask <= 19'd0;
        builder_first_miss_valid <= 1'b0;
        builder_first_miss_state <= B_IDLE;
        builder_first_miss_vcount <= 9'd0;
        builder_first_miss_gfx_req <= 1'b0;
        builder_first_miss_layer <= 1'b0;
        map_cache_state <= M_IDLE;
        map_cache_index <= 13'd0;
        map_cache_number <= 13'd0;
        bg_map_cache_valid <= 1'b0;
        bg_map_read_index <= 13'd0;
        descriptor_state <= D_IDLE;
        descriptor_index <= 7'd0;
        descriptor_word <= 2'd0;
        descriptor_cell <= 4'd0;
        descriptor_cache_valid <= 1'b0;
        sprite_pause_index <= 7'd127;
        sprite_line_mask_q <= 128'd0;
        sprite_line_masks_valid <= 1'b0;
        sprite_mask_build_active <= 1'b0;
        sprite_mask_line <= 9'd0;
        sprite_mask_descriptor <= 7'd0;
        sprite_mask_accumulator <= 128'd0;
        sprite_high_pass <= 1'b0;
        sprite_index <= 8'd0;
        sprite_scan_mask <= 128'd0;
        sprite_x0 <= 12'sd0;
        sprite_y0 <= 12'sd0;
        sprite_dx <= 6'd16;
        sprite_dy <= 6'd16;
        sprite_draw_width <= 6'd16;
        sprite_draw_height <= 6'd16;
        sprite_row <= 3'd0;
        sprite_pending_rows <= 4'd0;
        sprite_column <= 2'd0;
        sprite_tile_base <= 15'd0;
        sprite_chain_offset <= 15'd0;
        sprite_source_y <= 4'd0;
        sprite_emit_end <= 10'd0;
        sprite_source_fp <= 12'd0;
        sprite_source_step <= 18'd65536;
        vco_addr <= 17'd0;
        gfx_req <= 1'b0;
        gfx_addr <= 20'd0;
    end else begin
        hcount_d1 <= hcount;
        hcount_d2 <= hcount_d1;
        vcount_d1 <= vcount;
        vcount_d2 <= vcount_d1;
        sprite_line_mask_q <= sprite_line_masks[target_y];
        pixel_div <= ~pixel_div;
        if (builder_line_missed) begin
            if (!(&builder_missed_lines))
                builder_missed_lines <= builder_missed_lines + 1'd1;
            if (builder_state <= B_SPR_CACHE)
                builder_missed_state_mask[builder_state] <= 1'b1;
            if (!builder_first_miss_valid) begin
                builder_first_miss_valid <= 1'b1;
                builder_first_miss_state <= builder_state;
                builder_first_miss_vcount <= vcount[8:0];
                builder_first_miss_gfx_req <= gfx_req;
                builder_first_miss_layer <= render_layer;
            end
        end
        if (ce_pix) begin
            if (hcount == 10'd639) begin
                hcount <= 10'd0;
                display_buffer <= ~display_buffer;
                tile_display_buffer <= next_tile_display_buffer;
                // A late builder may finish during the following scanline.
                // Latch readiness only at the swap so an incomplete tile line
                // remains absent for the entire scanline instead of popping in
                // part-way across it.
                display_line_ready <= next_display_line_ready;
                if (vcount == 10'd461) vcount <= 10'd0;
                else vcount <= vcount + 1'd1;
            end else begin
                hcount <= hcount + 1'd1;
            end
        end

        // Palette RAM is synchronous, so delay timing and transparency by
        // the same pixel as its read result.
        active_d1 <= native_hactive && (vcount < 10'd400);
        active_d2 <= active_d1;
        hactive_d1 <= native_hactive;
        hactive_d2 <= hactive_d1;
        vactive_d1 <= vcount < 10'd400;
        vactive_d2 <= vactive_d1;
        hsync_d1 <= !((hcount >= 10'd528) && (hcount < 10'd592));
        hsync_d2 <= hsync_d1;
        vsync_d1 <= !((vcount >= 10'd410) && (vcount < 10'd412));
        vsync_d2 <= vsync_d1;
        foreground_valid_d <= foreground_valid;
        foreground_gradient_d <= foreground_gradient;
        gradient_lookup_d1 <= gradient_lookup;
        hblank <= !hactive_d2;
        vblank <= !vactive_d2;
        hsync <= hsync_d2;
        vsync <= vsync_d2;

        if (active_d2 && foreground_valid_d && !foreground_gradient_d &&
            rom_loaded && !download_active) begin
            // Taito Air palette RAM is xxBBBBxGGGGxRRRR.  The PCB/MAME
            // decoder takes red from the low nibble and green from bits 8:5.
            // Swapping these produces the conspicuous purple instrument
            // panel and green (instead of red) speed needle.
            red   <= {palette_data[3:0], palette_data[3:0]};
            green <= {palette_data[8:5], palette_data[8:5]};
            blue  <= {palette_data[13:10], palette_data[13:10]};
        end else if (active_d2 && foreground_valid_d &&
                     foreground_gradient_d && rom_loaded &&
                     !download_active) begin
            red <= {gradient_low[6:0], gradient_low[0]};
            green <= {gradient_low[14:8], gradient_low[8]};
            blue <= {gradient_high[6:0], gradient_high[0]};
        end else if (active_d2 && gradient_cache_valid &&
                     rom_loaded && !download_active) begin
            red <= gradient_rgb[23:16];
            green <= gradient_rgb[15:8];
            blue <= gradient_rgb[7:0];
        end else if (active_d2 && !rom_loaded) begin
            red <= 8'h40;
            green <= 8'h10;
            blue <= 8'h10;
        end else begin
            red <= 8'd0;
            green <= 8'd0;
            blue <= 8'd0;
        end

        // Cover the accepted flight strip and the title-only x=3 column.
        // Outside the qualified title, valid tile/polygon/sprite pixels retain
        // priority so the course-select cursor can traverse both raster edges.
        if (active_d2 && left_edge_black_fill && rom_loaded &&
            !download_active) begin
            red <= 8'd0;
            green <= 8'd0;
            blue <= 8'd0;
        end

        // Accessibility overlay is applied after the native game mixer. With
        // the menu option off, this block never writes and the RGB path is
        // bit-for-bit unchanged.
        if (active_d2 && throttle_overlay_draw) begin
            red <= throttle_overlay_red;
            green <= throttle_overlay_green;
            blue <= throttle_overlay_blue;
        end

        // Prepare line zero at the frame boundary and advance the affine
        // counters once per pixel/scanline thereafter. Register writes take
        // effect together at the following frame boundary.
        if (ce_pix) begin
            if (hcount == 10'd639) begin
                if (vcount == 10'd461) begin
                    gradient_line_counter1 <= gradient_frame_start1;
                    gradient_line_counter2 <= gradient_frame_start2;
                    gradient_pixel_counter1 <= gradient_frame_start1;
                    gradient_pixel_counter2 <= gradient_frame_start2;
                end else begin
                    gradient_line_counter1 <= gradient_line_counter1 + gradient_inc1y;
                    gradient_line_counter2 <= gradient_line_counter2 + gradient_inc2y;
                    gradient_pixel_counter1 <= gradient_line_counter1 + gradient_inc1y;
                    gradient_pixel_counter2 <= gradient_line_counter2 + gradient_inc2y;
                end
            end else begin
                gradient_pixel_counter1 <= gradient_pixel_counter1 + gradient_inc1x;
                gradient_pixel_counter2 <= gradient_pixel_counter2 + gradient_inc2x;
            end
        end

        // Refresh the polygon terrain selectors and background-gradient
        // colors in parallel at the beginning of vertical blank.
        if (hcount == 10'd0 && vcount == 10'd400 &&
            terrain_cache_state == C_IDLE) begin
            terrain_cache_index <= 8'd0;
            terrain_cache_state <= C_WAIT;
        end
        case (terrain_cache_state)
            C_IDLE: ;
            C_WAIT: terrain_cache_state <= C_LATCH;
            C_LATCH: begin
                terrain_flags[terrain_cache_index] <= palette_data[15];
                if (terrain_cache_index == 8'hff)
                    terrain_cache_state <= C_IDLE;
                else begin
                    terrain_cache_index <= terrain_cache_index + 1'd1;
                    terrain_cache_state <= C_WAIT;
                end
            end
            default: terrain_cache_state <= C_IDLE;
        endcase

        if (hcount == 10'd0 && vcount == 10'd400 &&
            gradient_state == G_IDLE) begin
            gradient_cache_index <= 8'd0;
            gradient_cache_addr <= 13'd0;
            gradient_cache_valid <= 1'b0;
            gradient_state <= G_WAIT;
        end
        case (gradient_state)
            G_IDLE: ;
            G_WAIT: gradient_state <= G_LATCH;
            G_LATCH: begin
                gradient_cache[gradient_cache_index] <= {
                    gradient_low[6:0], gradient_low[0],
                    gradient_low[14:8], gradient_low[8],
                    gradient_high[6:0], gradient_high[0]
                };
                if (gradient_cache_index == 8'd0)
                    gradient_cache_zero <= {
                        gradient_low[6:0], gradient_low[0],
                        gradient_low[14:8], gradient_low[8],
                        gradient_high[6:0], gradient_high[0]
                    };
                if (gradient_cache_index == 8'hff) begin
                    gradient_cache_valid <= 1'b1;
                    gradient_state <= G_IDLE;
                end else begin
                    gradient_cache_index <= gradient_cache_index + 1'd1;
                    gradient_cache_addr <= {
                        gradient_next_index[7], 5'd0,
                        gradient_next_index[6:0]};
                    gradient_state <= G_WAIT;
                end
            end
            default: gradient_state <= G_IDLE;
        endcase

        // Snapshot the four-word motion-object descriptors during the first
        // blank line.  The VCO port is otherwise devoted to the scanline
        // renderer during visible lines.
        if (hcount == 10'd0 && vcount == 10'd400 &&
            descriptor_state == D_IDLE && map_cache_state == M_IDLE) begin
            // End the old frame's queue before refreshing the VCO snapshots.
            // A line is published again only after a complete new-frame
            // build, so an old tag cannot be mistaken for current content.
            line_valid_0 <= 1'b0;
            line_valid_1 <= 1'b0;
            line_valid_2 <= 1'b0;
            line_valid_3 <= 1'b0;
            next_build_y <= 9'd0;
            descriptor_index <= 7'd0;
            descriptor_word <= 2'd0;
            descriptor_cache_valid <= 1'b0;
            bg_map_cache_valid <= 1'b0;
            sprite_line_masks_valid <= 1'b0;
            sprite_mask_build_active <= 1'b0;
            sprite_pause_index <= 7'd127;
            vco_addr <= 17'h10200;
            descriptor_state <= D_WAIT;
        end
        case (descriptor_state)
            D_IDLE: ;
            D_WAIT: descriptor_state <= D_LATCH;
            D_LATCH: begin
                case (descriptor_word)
                    2'd0: begin
                        sprite_desc_0[descriptor_index] <= vco_data;
                        if (vco_data == 16'h0c00 || vco_data == 16'h0cff)
                            sprite_pause_index <= descriptor_index;
                    end
                    2'd1: sprite_desc_1[descriptor_index] <= vco_data;
                    2'd2: sprite_desc_2[descriptor_index] <= vco_data;
                    default: sprite_desc_3[descriptor_index] <= vco_data;
                endcase
                if (descriptor_word == 2'd3) begin
                    descriptor_word <= 2'd0;
                    if (descriptor_index == 7'd127) begin
                        descriptor_index <= 7'd0;
                        descriptor_cell <= 4'd0;
                        sprite_mask_line <= 9'd0;
                        sprite_mask_descriptor <= 7'd0;
                        sprite_mask_accumulator <= 128'd0;
                        sprite_mask_build_active <= 1'b1;
                        descriptor_state <= D_CHAIN_START;
                    end else begin
                        descriptor_index <= descriptor_index + 1'd1;
                        vco_addr <= 17'h10200 +
                            {8'd0, descriptor_index + 1'd1, 2'b00};
                        descriptor_state <= D_WAIT;
                    end
                end else begin
                    descriptor_word <= descriptor_word + 1'd1;
                    vco_addr <= 17'h10200 +
                        {8'd0, descriptor_index, descriptor_word + 1'd1};
                    descriptor_state <= D_WAIT;
                end
            end
            D_CHAIN_START: begin
                if (sprite_desc_3[descriptor_index][12:0] == 0) begin
                    if (descriptor_index == 7'd127) begin
                        descriptor_cache_valid <= 1'b1;
                        descriptor_state <= D_IDLE;
                        map_cache_index <= 13'd0;
                        vco_addr <= 17'h06000;
                        map_cache_state <= M_NUM_WAIT;
                    end else begin
                        descriptor_index <= descriptor_index + 1'd1;
                        descriptor_cell <= 4'd0;
                    end
                end else begin
                    vco_addr <= descriptor_chain_offset;
                    descriptor_state <= D_CHAIN0_WAIT;
                end
            end
            D_CHAIN0_WAIT: descriptor_state <= D_CHAIN0_LATCH;
            D_CHAIN0_LATCH: begin
                case (descriptor_cache_address[1:0])
                    2'd0: sprite_chain_tile_0[descriptor_cache_address[10:2]] <= vco_data[12:0];
                    2'd1: sprite_chain_tile_1[descriptor_cache_address[10:2]] <= vco_data[12:0];
                    2'd2: sprite_chain_tile_2[descriptor_cache_address[10:2]] <= vco_data[12:0];
                    default: sprite_chain_tile_3[descriptor_cache_address[10:2]] <= vco_data[12:0];
                endcase
                vco_addr <= 17'h08000 + descriptor_chain_offset;
                descriptor_state <= D_CHAIN1_WAIT;
            end
            D_CHAIN1_WAIT: descriptor_state <= D_CHAIN1_LATCH;
            D_CHAIN1_LATCH: begin
                case (descriptor_cache_address[1:0])
                    2'd0: sprite_chain_attr_0[descriptor_cache_address[10:2]] <= vco_data[7:0];
                    2'd1: sprite_chain_attr_1[descriptor_cache_address[10:2]] <= vco_data[7:0];
                    2'd2: sprite_chain_attr_2[descriptor_cache_address[10:2]] <= vco_data[7:0];
                    default: sprite_chain_attr_3[descriptor_cache_address[10:2]] <= vco_data[7:0];
                endcase
                if (descriptor_cell == 4'd15) begin
                    descriptor_cell <= 4'd0;
                    if (descriptor_index == 7'd127) begin
                        descriptor_cache_valid <= 1'b1;
                        descriptor_state <= D_IDLE;
                        map_cache_index <= 13'd0;
                        vco_addr <= 17'h06000;
                        map_cache_state <= M_NUM_WAIT;
                    end else begin
                        descriptor_index <= descriptor_index + 1'd1;
                        descriptor_state <= D_CHAIN_START;
                    end
                end else begin
                    descriptor_cell <= descriptor_cell + 1'd1;
                    descriptor_state <= D_CHAIN_START;
                end
            end
            default: descriptor_state <= D_IDLE;
        endcase

        case (map_cache_state)
            M_IDLE: ;
            M_NUM_WAIT: map_cache_state <= M_NUM_LATCH;
            M_NUM_LATCH: begin
                map_cache_number <= vco_data[12:0];
                vco_addr <= (map_cache_index[12]
                    ? 17'h0f000 : 17'h0e000) + map_cache_index[11:0];
                map_cache_state <= M_ATTR_WAIT;
            end
            M_ATTR_WAIT: map_cache_state <= M_ATTR_LATCH;
            M_ATTR_LATCH: begin
                bg_map_cache[map_cache_index] <=
                    {map_cache_number, vco_data[7:6], vco_data[4:0]};
                if (map_cache_index == 13'h1fff) begin
                    bg_map_cache_valid <= 1'b1;
                    map_cache_state <= M_IDLE;
                end else begin
                    map_cache_index <= map_cache_index + 1'd1;
                    vco_addr <= (map_cache_next_index[12]
                        ? 17'h07000 : 17'h06000) +
                        map_cache_next_index[11:0];
                    map_cache_state <= M_NUM_WAIT;
                end
            end
            default: map_cache_state <= M_IDLE;
        endcase

        if (sprite_mask_build_active) begin
            if (sprite_mask_descriptor == 7'd127) begin
                sprite_line_masks[sprite_mask_line] <=
                    sprite_mask_accumulator_next;
                sprite_mask_descriptor <= 7'd0;
                sprite_mask_accumulator <= 128'd0;
                if (sprite_mask_line == 9'd399) begin
                    sprite_mask_build_active <= 1'b0;
                    sprite_line_masks_valid <= 1'b1;
                end else begin
                    sprite_mask_line <= sprite_mask_line + 1'd1;
                end
            end else begin
                sprite_mask_accumulator <= sprite_mask_accumulator_next;
                sprite_mask_descriptor <= sprite_mask_descriptor + 1'd1;
            end
        end

        if (builder_state == B_CLEAR && target_y == 9'd0 &&
            render_x == 9'd0) begin
            cockpit_left_marker_seen <= 1'b0;
            cockpit_right_marker_seen <= 1'b0;
        end
        if (builder_state == B_BG_EMIT && render_layer &&
            target_y == 9'd273) begin
            for (cockpit_lane = 0; cockpit_lane < 16;
                 cockpit_lane = cockpit_lane + 1) begin
                if (cockpit_lane < emit_count &&
                    ({1'b0, render_x} + cockpit_lane) == 10'd1 &&
                    emit_pixels[cockpit_lane] == 9'h081)
                    cockpit_left_marker_seen <= 1'b1;
                if (cockpit_lane < emit_count &&
                    ({1'b0, render_x} + cockpit_lane) == 10'd2 &&
                    emit_pixels[cockpit_lane] == 9'h08e)
                    cockpit_right_marker_seen <= 1'b1;
            end
        end
        if (builder_state == B_BG_DONE && render_layer &&
            target_y == 9'd399)
            flight_cockpit_active <=
                cockpit_left_marker_seen && cockpit_right_marker_seen;

        // Compose visible lines continuously into a four-bank queue. One
        // bank is scanned out while the other three absorb variation in shared
        // DDR response time. This removes the old all-or-nothing dependency
        // on completing each line within one raster plus 248 clocks.
        if (builder_state == B_IDLE && video_cache_ready &&
            next_build_y < 9'd400 && build_bank_available &&
            !(hcount == 10'd0 && vcount == 10'd400)) begin
            target_y <= next_build_y;
            write_buffer <= next_write_buffer;
            render_x <= 9'd0;
            render_layer <= 1'b0;
            builder_state <= B_CLEAR;
            line_valid <= 1'b0;
            gfx_req <= 1'b0;
            case (next_write_buffer)
                2'd0: line_valid_0 <= 1'b0;
                2'd1: line_valid_1 <= 1'b0;
                2'd2: line_valid_2 <= 1'b0;
                default: line_valid_3 <= 1'b0;
            endcase
        end

        case (builder_state)
            B_IDLE: gfx_req <= 1'b0;

            B_CLEAR: begin
                // Sixteen interleaved banks clear one 16-pixel group per
                // clock, so a complete 512-pixel line takes 32 clocks.
                if (render_x == 9'd496) begin
                    if (!bg_map_cache_valid) begin
                        builder_state <= B_IDLE;
                        line_valid <= 1'b1;
                        next_build_y <= target_y == 9'd399
                            ? 9'd400 : target_y + 1'd1;
                        case (write_buffer)
                            2'd0: begin
                                line_valid_0 <= 1'b1;
                                line_tag_0 <= target_y;
                            end
                            2'd1: begin
                                line_valid_1 <= 1'b1;
                                line_tag_1 <= target_y;
                            end
                            2'd2: begin
                                line_valid_2 <= 1'b1;
                                line_tag_2 <= target_y;
                            end
                            default: begin
                                line_valid_3 <= 1'b1;
                                line_tag_3 <= target_y;
                            end
                        endcase
                    end else begin
                        render_x <= 9'd0;
                        render_layer <= 1'b0;
                        source_x <= bg0_start_source_x;
                        source_y <= bg0_start_source_y;
                        map_index <= bg0_start_map_index;
                        bg_map_read_index <= {1'b0, bg0_start_map_index};
                        builder_state <= B_BG_NUM_WAIT;
                    end
                end else begin
                    render_x <= render_x + 9'd16;
                end
            end

            B_BG_NUM_WAIT: builder_state <= B_BG_NUM_LATCH;

            B_BG_NUM_LATCH: begin
                tile_number <= cached_tile_number;
                tile_attr <= cached_tile_attr;
                if (cached_tile_number == 0) begin
                    if ({1'b0, render_x} + bg_skip_count >= 10'd512) begin
                        builder_state <= B_BG_DONE;
                    end else begin
                        render_x <= render_x + bg_skip_count[8:0];
                        source_x <= bg_skipped_source_x;
                        map_index <= bg_skipped_map_index;
                        bg_map_read_index <=
                            {render_layer, bg_skipped_map_index};
                        builder_state <= B_BG_NUM_WAIT;
                    end
                end else begin
                    bg_map_read_index <=
                        {render_layer, bg_emitted_map_index};
                    gfx_addr <= {cached_tile_number, 7'b0000000} + {
                        13'd0,
                        (cached_tile_attr[7]
                            ? (4'd15 - source_y[3:0]) : source_y[3:0]),
                        3'b000
                    };
                    gfx_req <= 1'b1;
                    builder_state <= B_BG_GFX_WAIT;
                end
            end

            B_BG_ATTR_WAIT, B_BG_ATTR_LATCH:
                builder_state <= B_BG_NUM_WAIT;

            B_BG_GFX_WAIT: if (gfx_ack) begin
                gfx_req <= 1'b0;
                tile_line <= gfx_data;
                builder_state <= B_BG_EMIT;
            end

            B_BG_EMIT: begin
                if ({1'b0, render_x} + emit_count >= 10'd512) begin
                    builder_state <= B_BG_DONE;
                end else begin
                    render_x <= render_x + emit_count;
                    source_x <= bg_emitted_source_x;
                    if (source_x[3:0] + emit_count >= 5'd16) begin
                        map_index <= bg_emitted_map_index;
                        builder_state <= B_BG_NUM_LATCH;
                    end
                end
            end

            B_BG_DONE: begin
                if (!render_layer) begin
                    if (descriptor_cache_valid && sprite_line_masks_valid) begin
                        sprite_high_pass <= 1'b1;
                        sprite_scan_mask <= sprite_high_line_mask;
                        builder_state <= B_SPR_SCAN;
                    end else begin
                        render_layer <= 1'b1;
                        render_x <= 9'd0;
                        source_x <= bg1_start_source_x;
                        source_y <= bg1_start_source_y;
                        map_index <= bg1_start_map_index;
                        bg_map_read_index <= {1'b1, bg1_start_map_index};
                        builder_state <= B_BG_NUM_WAIT;
                    end
                end else if (descriptor_cache_valid &&
                             sprite_line_masks_valid) begin
                    sprite_high_pass <= 1'b0;
                    sprite_scan_mask <= sprite_low_line_mask;
                    builder_state <= B_SPR_SCAN;
                end else begin
                    builder_state <= B_IDLE;
                    line_valid <= 1'b1;
                    next_build_y <= target_y == 9'd399
                        ? 9'd400 : target_y + 1'd1;
                    case (write_buffer)
                        2'd0: begin
                            line_valid_0 <= 1'b1;
                            line_tag_0 <= target_y;
                        end
                        2'd1: begin
                            line_valid_1 <= 1'b1;
                            line_tag_1 <= target_y;
                        end
                        2'd2: begin
                            line_valid_2 <= 1'b1;
                            line_tag_2 <= target_y;
                        end
                        default: begin
                            line_valid_3 <= 1'b1;
                            line_tag_3 <= target_y;
                        end
                    endcase
                end
            end

            B_SPR_SCAN: begin
                if (sprite_scan_mask == 0) begin
                    builder_state <= B_SPR_DONE;
                end else begin
                    sprite_index <= sprite_scan_index;
                    sprite_scan_mask[sprite_scan_index] <= 1'b0;
                    sprite_x0 <= signed_sprite_coord(selected_desc_1[9:0]) + 12'sd1;
                    sprite_y0 <= selected_sprite_y0;
                    sprite_dx <= sprite_extent(selected_desc_2[14:8]);
                    sprite_dy <= selected_sprite_dy;
                    sprite_draw_width <= sprite_draw_extent(selected_desc_2[14:8]);
                    sprite_draw_height <= selected_sprite_draw_height;
                    sprite_tile_base <= {selected_desc_3[12:0], 2'b00};
                    sprite_row <= selected_sprite_row;
                    // The per-line descriptor mask says at least one row
                    // intersects. Retain every later matching row so overlap
                    // is drawn in increasing chain order without walking
                    // non-intersecting rows in the visible-line budget.
                    sprite_pending_rows <= selected_sprite_row_hits &
                        ~(4'b0001 << selected_sprite_row);
                    sprite_source_y <= selected_sprite_y_product[20]
                        ? 4'd15 : selected_sprite_y_product[19:16];
                    sprite_column <= 2'd0;
                    sprite_chain_offset <= {selected_desc_3[12:0], 2'b00} +
                        {selected_sprite_row, 2'b00};
                    builder_state <= B_SPR_CACHE;
                end
            end

            B_SPR_ROW: begin
                sprite_source_y <= sprite_y_product[20]
                    ? 4'd15 : sprite_y_product[19:16];
                sprite_column <= 2'd0;
                sprite_chain_offset <= sprite_tile_base +
                    {sprite_row, 2'b00};
                builder_state <= B_SPR_CACHE;
            end

            B_SPR_CHAIN0_WAIT: builder_state <= B_SPR_CHAIN0_LATCH;

            B_SPR_CHAIN0_LATCH: begin
                tile_number <= vco_data[12:0];
                vco_addr <= 17'h08000 + sprite_chain_offset;
                builder_state <= B_SPR_CHAIN1_WAIT;
            end

            B_SPR_CHAIN1_WAIT: builder_state <= B_SPR_CHAIN1_LATCH;

            B_SPR_CHAIN1_LATCH: begin
                tile_attr <= vco_data[7:0];
                if (sprite_chain_offset < 15'h1000 || tile_number == 0 ||
                    sprite_column_x >= 13'sd512 ||
                    sprite_column_x + $signed({1'b0, sprite_draw_width}) <= 0) begin
                    if (sprite_column == 2'd3) begin
                        if (sprite_pending_rows != 0) begin
                            sprite_row <= sprite_next_row;
                            sprite_pending_rows <= sprite_remaining_rows;
                            builder_state <= B_SPR_ROW;
                        end else begin
                            builder_state <= B_SPR_SCAN;
                        end
                    end else begin
                        sprite_column <= sprite_column + 1'd1;
                        sprite_chain_offset <= sprite_chain_offset + 1'd1;
                        vco_addr <= sprite_chain_offset + 1'd1;
                        builder_state <= B_SPR_CHAIN0_WAIT;
                    end
                end else begin
                    render_x <= sprite_column_x < 0
                        ? 9'd0 : sprite_column_x[8:0];
                    sprite_emit_end <=
                        sprite_column_x + $signed({1'b0, sprite_draw_width}) > 13'sd512
                        ? 10'd512
                        : sprite_column_x + $signed({1'b0, sprite_draw_width});
                    sprite_source_step <= sprite_step(sprite_draw_width);
                    sprite_source_fp <= sprite_column_x < 0
                        ? $unsigned(-sprite_column_x) * sprite_step(sprite_draw_width)
                        : 21'd0;
                    gfx_addr <= {tile_number, 7'b0000000} + {
                        13'd0,
                        (vco_data[7] ? (4'd15 - sprite_source_y) : sprite_source_y),
                        3'b000
                    };
                    gfx_req <= 1'b1;
                    builder_state <= B_SPR_GFX_WAIT;
                end
            end

            B_SPR_CACHE: begin
                tile_number <= selected_chain_tile;
                tile_attr <= selected_chain_attr;
                if (sprite_chain_offset < 15'h1000 ||
                    selected_chain_tile == 0 ||
                    sprite_column_x >= 13'sd512 ||
                    sprite_column_x + $signed({1'b0, sprite_draw_width}) <= 0) begin
                    if (sprite_column == 2'd3 ||
                        (selected_chain_tile == 0 &&
                         !later_chain_nonzero)) begin
                        if (sprite_pending_rows != 0) begin
                            // Rows can overlap when draw height exceeds dy.
                            // Continue in increasing chain order so a later
                            // row has the same overwrite priority as the
                            // established device implementation.
                            sprite_row <= sprite_next_row;
                            sprite_pending_rows <= sprite_remaining_rows;
                            builder_state <= B_SPR_ROW;
                        end else begin
                            builder_state <= B_SPR_SCAN;
                        end
                    end else begin
                        sprite_column <= sprite_column + 1'd1;
                        sprite_chain_offset <= sprite_chain_offset + 1'd1;
                    end
                end else begin
                    render_x <= sprite_column_x < 0
                        ? 9'd0 : sprite_column_x[8:0];
                    sprite_emit_end <=
                        sprite_column_x + $signed({1'b0, sprite_draw_width}) > 13'sd512
                        ? 10'd512
                        : sprite_column_x + $signed({1'b0, sprite_draw_width});
                    sprite_source_step <= sprite_step(sprite_draw_width);
                    sprite_source_fp <= sprite_column_x < 0
                        ? $unsigned(-sprite_column_x) * sprite_step(sprite_draw_width)
                        : 21'd0;
                    gfx_addr <= {selected_chain_tile, 7'b0000000} + {
                        13'd0,
                        (selected_chain_attr[7]
                            ? (4'd15 - sprite_source_y) : sprite_source_y),
                        3'b000
                    };
                    gfx_req <= 1'b1;
                    builder_state <= B_SPR_GFX_WAIT;
                end
            end

            B_SPR_GFX_WAIT: if (gfx_ack) begin
                gfx_req <= 1'b0;
                tile_line <= gfx_data;
                builder_state <= B_SPR_EMIT;
            end

            B_SPR_EMIT: begin
                if ({1'b0, render_x} + sprite_emit_count >= sprite_emit_end) begin
                    if (sprite_column == 2'd3) begin
                        if (sprite_pending_rows != 0) begin
                            sprite_row <= sprite_next_row;
                            sprite_pending_rows <= sprite_remaining_rows;
                            builder_state <= B_SPR_ROW;
                        end else begin
                            builder_state <= B_SPR_SCAN;
                        end
                    end else if (sprite_chain_offset + 1'd1 >= 15'h1000 &&
                                 selected_next_chain_tile != 0 &&
                                 sprite_next_column_x < 13'sd512 &&
                                 sprite_next_column_x +
                                     $signed({1'b0, sprite_draw_width}) > 0) begin
                        // Start the following visible cell's lookup directly;
                        // each horizontal chain cell has its own cache bank.
                        sprite_column <= sprite_next_column;
                        sprite_chain_offset <= sprite_chain_offset + 1'd1;
                        tile_number <= selected_next_chain_tile;
                        tile_attr <= selected_next_chain_attr;
                        render_x <= sprite_next_column_x < 0
                            ? 9'd0 : sprite_next_column_x[8:0];
                        sprite_emit_end <= sprite_next_column_x +
                            $signed({1'b0, sprite_draw_width}) > 13'sd512
                            ? 10'd512
                            : sprite_next_column_x +
                                $signed({1'b0, sprite_draw_width});
                        sprite_source_step <= sprite_step(sprite_draw_width);
                        sprite_source_fp <= sprite_next_column_x < 0
                            ? $unsigned(-sprite_next_column_x) *
                                sprite_step(sprite_draw_width)
                            : 21'd0;
                        gfx_addr <= {selected_next_chain_tile, 7'b0000000} + {
                            13'd0,
                            (selected_next_chain_attr[7]
                                ? (4'd15 - sprite_source_y)
                                : sprite_source_y),
                            3'b000
                        };
                        gfx_req <= 1'b1;
                        builder_state <= B_SPR_GFX_WAIT;
                    end else begin
                        sprite_column <= sprite_column + 1'd1;
                        sprite_chain_offset <= sprite_chain_offset + 1'd1;
                        builder_state <= B_SPR_CACHE;
                    end
                end else begin
                    render_x <= render_x + sprite_emit_count;
                    sprite_source_fp <= sprite_source_fp +
                        {sprite_source_step, 4'b0000};
                end
            end

            B_SPR_DONE: begin
                if (sprite_high_pass) begin
                    render_layer <= 1'b1;
                    render_x <= 9'd0;
                    source_x <= bg1_start_source_x;
                    source_y <= bg1_start_source_y;
                    map_index <= bg1_start_map_index;
                    bg_map_read_index <= {1'b1, bg1_start_map_index};
                    builder_state <= B_BG_NUM_WAIT;
                end else begin
                    builder_state <= B_IDLE;
                    line_valid <= 1'b1;
                    next_build_y <= target_y == 9'd399
                        ? 9'd400 : target_y + 1'd1;
                    case (write_buffer)
                        2'd0: begin
                            line_valid_0 <= 1'b1;
                            line_tag_0 <= target_y;
                        end
                        2'd1: begin
                            line_valid_1 <= 1'b1;
                            line_tag_1 <= target_y;
                        end
                        2'd2: begin
                            line_valid_2 <= 1'b1;
                            line_tag_2 <= target_y;
                        end
                        default: begin
                            line_valid_3 <= 1'b1;
                            line_tag_3 <= target_y;
                        end
                    endcase
                end
            end

            default: begin
                gfx_req <= 1'b0;
                builder_state <= B_IDLE;
            end
        endcase
    end
end

// Background zoom values are captured now and will drive the source DDA when
// a title uses non-default geometry. Top Landing programs normal 3f/7f zoom.
wire _unused_zoom = ^bg0_zoom ^ ^bg1_zoom;

endmodule

// The available Taito Air documentation does not expose the external video
// priority wiring. The original game data nevertheless gives a precise,
// stable world/cockpit discriminator: every cloud descriptor in the captured
// scene uses chain $08c4, while the mixed pause group also contains unrelated
// cockpit readouts. Clip only that cloud chain at native line 273.
module tas_topland_sprite_window (
    input      [14:0] chain_base,
    input      [8:0]  target_y,
    output            visible
);

localparam [14:0] TOPLAND_CLOUD_CHAIN = {13'h08c4, 2'b00};
localparam [8:0] TOPLAND_COCKPIT_TOP = 9'd273;

assign visible = chain_base != TOPLAND_CLOUD_CHAIN ||
    target_y < TOPLAND_COCKPIT_TOP;

endmodule

// Keep the user-accepted three-pixel flight fill unchanged. The title has
// valid artwork at x=3, so only a separately qualified title may override that
// column; all other non-flight foreground, especially the course cursor,
// remains protected.
module tas_topland_left_edge_fill (
    input      [9:0] x,
    input      [8:0] y,
    input            cockpit_active,
    input            title_active,
    input            foreground_valid,
    output           fill
);

assign fill = (title_active && x == 10'd3) ||
    (!foreground_valid &&
     ((cockpit_active && y < 9'd273 && x >= 10'd1 && x <= 10'd3) ||
      (!cockpit_active && x == 10'd1)));

endmodule

module tas_topland_title_detector (
    input            clk,
    input            reset,
    input            pixel_valid,
    input            frame_end,
    input      [9:0] x,
    input      [8:0] y,
    input      [7:0] red,
    input      [7:0] green,
    input      [7:0] blue,
    output reg       title_active
);

reg red_disc_seen;
reg grey_logo_seen;
reg blue_mark_seen;
reg publisher_blue_seen;
reg publisher_grey_seen;
reg publisher_edge_content_seen;
reg [9:0] intro_bridge_frames;

wire red_disc_pixel = x >= 10'd240 && x <= 10'd290 &&
    y >= 9'd60 && y <= 9'd110 &&
    red >= 8'hc0 && green <= 8'h40 && blue <= 8'h40;
wire grey_logo_pixel = x >= 10'd140 && x <= 10'd475 &&
    y >= 9'd45 && y <= 9'd170 &&
    red >= 8'h80 && green >= 8'h80 && blue >= 8'h80 &&
    {1'b0, red} + 9'h020 >= {1'b0, green} &&
    {1'b0, green} + 9'h020 >= {1'b0, red} &&
    {1'b0, red} + 9'h020 >= {1'b0, blue} &&
    {1'b0, blue} + 9'h020 >= {1'b0, red};
wire blue_mark_pixel = x >= 10'd205 && x <= 10'd275 &&
    y >= 9'd270 && y <= 9'd315 &&
    blue >= 8'hc0 && red <= 8'h40 && green <= 8'h40;
// The publisher splash immediately precedes the runway/title animation. Its
// centered dark-blue mark and grey TAITO word remain visible through the fade,
// while the surrounding raster is black. Arming here covers the first runway
// frame instead of waiting one completed title frame to recognize the logo.
wire publisher_blue_pixel = x >= 10'd180 && x <= 10'd345 &&
    y >= 9'd80 && y <= 9'd230 &&
    blue >= 8'h10 && blue > red && blue > green;
wire publisher_grey_pixel = x >= 10'd170 && x <= 10'd340 &&
    y >= 9'd235 && y <= 9'd280 &&
    red >= 8'h10 && green >= 8'h10 && blue >= 8'h10 &&
    {1'b0, red} + 9'h010 >= {1'b0, green} &&
    {1'b0, green} + 9'h010 >= {1'b0, red} &&
    {1'b0, red} + 9'h010 >= {1'b0, blue} &&
    {1'b0, blue} + 9'h010 >= {1'b0, red};
wire publisher_edge_content_pixel = y < 9'd350 &&
    (x < 10'd100 || x > 10'd411) && (red != 0 || green != 0 || blue != 0);

always @(posedge clk) begin
    if (reset) begin
        title_active <= 1'b0;
        red_disc_seen <= 1'b0;
        grey_logo_seen <= 1'b0;
        blue_mark_seen <= 1'b0;
        publisher_blue_seen <= 1'b0;
        publisher_grey_seen <= 1'b0;
        publisher_edge_content_seen <= 1'b0;
        intro_bridge_frames <= 10'd0;
    end else begin
        if (pixel_valid && red_disc_pixel)
            red_disc_seen <= 1'b1;
        if (pixel_valid && grey_logo_pixel)
            grey_logo_seen <= 1'b1;
        if (pixel_valid && blue_mark_pixel)
            blue_mark_seen <= 1'b1;
        if (pixel_valid && publisher_blue_pixel)
            publisher_blue_seen <= 1'b1;
        if (pixel_valid && publisher_grey_pixel)
            publisher_grey_seen <= 1'b1;
        if (pixel_valid && publisher_edge_content_pixel)
            publisher_edge_content_seen <= 1'b1;

        if (frame_end) begin
            if (red_disc_seen && grey_logo_seen && blue_mark_seen) begin
                title_active <= 1'b1;
                // Once the title itself is recognized, stop using the bridge;
                // the first following non-title frame clears immediately.
                intro_bridge_frames <= 10'd0;
            end else if (publisher_blue_seen && publisher_grey_seen &&
                         !publisher_edge_content_seen) begin
                title_active <= 1'b1;
                // 600 frames at 54.1 Hz bridges the publisher fade, runway
                // fly-in and title formation. The title signature takes over
                // before this expires.
                intro_bridge_frames <= 10'd600;
            end else if (intro_bridge_frames != 0) begin
                title_active <= 1'b1;
                intro_bridge_frames <= intro_bridge_frames - 1'd1;
            end else begin
                title_active <= 1'b0;
            end
            red_disc_seen <= 1'b0;
            grey_logo_seen <= 1'b0;
            blue_mark_seen <= 1'b0;
            publisher_blue_seen <= 1'b0;
            publisher_grey_seen <= 1'b0;
            publisher_edge_content_seen <= 1'b0;
        end
    end
end

endmodule

// A 512-pixel scanline split into sixteen MLAB banks. Consecutive pixels land
// in different banks, allowing one complete tile row to be written per clock
// while each memory still has only one write port.
module tas_line_buffer (
    input             clk,
    input      [8:0]  read_addr,
    output reg [8:0]  read_data,
    input      [15:0] write_enable,
    input      [4:0]  write_addr_0,
    input      [4:0]  write_addr_1,
    input      [4:0]  write_addr_2,
    input      [4:0]  write_addr_3,
    input      [4:0]  write_addr_4,
    input      [4:0]  write_addr_5,
    input      [4:0]  write_addr_6,
    input      [4:0]  write_addr_7,
    input      [4:0]  write_addr_8,
    input      [4:0]  write_addr_9,
    input      [4:0]  write_addr_10,
    input      [4:0]  write_addr_11,
    input      [4:0]  write_addr_12,
    input      [4:0]  write_addr_13,
    input      [4:0]  write_addr_14,
    input      [4:0]  write_addr_15,
    input      [8:0]  write_data_0,
    input      [8:0]  write_data_1,
    input      [8:0]  write_data_2,
    input      [8:0]  write_data_3,
    input      [8:0]  write_data_4,
    input      [8:0]  write_data_5,
    input      [8:0]  write_data_6,
    input      [8:0]  write_data_7,
    input      [8:0]  write_data_8,
    input      [8:0]  write_data_9,
    input      [8:0]  write_data_10,
    input      [8:0]  write_data_11,
    input      [8:0]  write_data_12,
    input      [8:0]  write_data_13,
    input      [8:0]  write_data_14,
    input      [8:0]  write_data_15
);

(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_0 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_1 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_2 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_3 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_4 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_5 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_6 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_7 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_8 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_9 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_10 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_11 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_12 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_13 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_14 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] bank_15 [0:31];
reg [8:0] read_0;
reg [8:0] read_1;
reg [8:0] read_2;
reg [8:0] read_3;
reg [8:0] read_4;
reg [8:0] read_5;
reg [8:0] read_6;
reg [8:0] read_7;
reg [8:0] read_8;
reg [8:0] read_9;
reg [8:0] read_10;
reg [8:0] read_11;
reg [8:0] read_12;
reg [8:0] read_13;
reg [8:0] read_14;
reg [8:0] read_15;
reg [3:0] read_select;

always @* begin
    case (read_select)
        4'd0: read_data = read_0;
        4'd1: read_data = read_1;
        4'd2: read_data = read_2;
        4'd3: read_data = read_3;
        4'd4: read_data = read_4;
        4'd5: read_data = read_5;
        4'd6: read_data = read_6;
        4'd7: read_data = read_7;
        4'd8: read_data = read_8;
        4'd9: read_data = read_9;
        4'd10: read_data = read_10;
        4'd11: read_data = read_11;
        4'd12: read_data = read_12;
        4'd13: read_data = read_13;
        4'd14: read_data = read_14;
        default: read_data = read_15;
    endcase
end

always @(posedge clk) begin
    read_0 <= bank_0[read_addr[8:4]];
    read_1 <= bank_1[read_addr[8:4]];
    read_2 <= bank_2[read_addr[8:4]];
    read_3 <= bank_3[read_addr[8:4]];
    read_4 <= bank_4[read_addr[8:4]];
    read_5 <= bank_5[read_addr[8:4]];
    read_6 <= bank_6[read_addr[8:4]];
    read_7 <= bank_7[read_addr[8:4]];
    read_8 <= bank_8[read_addr[8:4]];
    read_9 <= bank_9[read_addr[8:4]];
    read_10 <= bank_10[read_addr[8:4]];
    read_11 <= bank_11[read_addr[8:4]];
    read_12 <= bank_12[read_addr[8:4]];
    read_13 <= bank_13[read_addr[8:4]];
    read_14 <= bank_14[read_addr[8:4]];
    read_15 <= bank_15[read_addr[8:4]];
    read_select <= read_addr[3:0];
    if (write_enable[0]) bank_0[write_addr_0] <= write_data_0;
    if (write_enable[1]) bank_1[write_addr_1] <= write_data_1;
    if (write_enable[2]) bank_2[write_addr_2] <= write_data_2;
    if (write_enable[3]) bank_3[write_addr_3] <= write_data_3;
    if (write_enable[4]) bank_4[write_addr_4] <= write_data_4;
    if (write_enable[5]) bank_5[write_addr_5] <= write_data_5;
    if (write_enable[6]) bank_6[write_addr_6] <= write_data_6;
    if (write_enable[7]) bank_7[write_addr_7] <= write_data_7;
    if (write_enable[8]) bank_8[write_addr_8] <= write_data_8;
    if (write_enable[9]) bank_9[write_addr_9] <= write_data_9;
    if (write_enable[10]) bank_10[write_addr_10] <= write_data_10;
    if (write_enable[11]) bank_11[write_addr_11] <= write_data_11;
    if (write_enable[12]) bank_12[write_addr_12] <= write_data_12;
    if (write_enable[13]) bank_13[write_addr_13] <= write_data_13;
    if (write_enable[14]) bank_14[write_addr_14] <= write_data_14;
    if (write_enable[15]) bank_15[write_addr_15] <= write_data_15;
end

endmodule
