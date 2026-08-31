// Taito Air polygon list parser and scanline renderer.
//
// The TMS320C25 writes a backwards polygon list into line RAM, then pulses
// 0x3001 to display the previously built list and start a fresh one, or
// 0x3002 to append another batch. The 68000 framebuffer-DMA register can also
// erase the off-screen framebuffer or publish it without starting a fill.
// This block converts each convex polygon into ordered scanline spans. Two
// span-list banks preserve the original draw/display buffering without
// spending enough M10Ks for a full bitmap.
module tas_polygon (
    input               clk,
    input               reset,
    input      [2:0]    flag_strobe,
    input               dma_erase_strobe,
    input               dma_copy_strobe,

    output              line_req,
    output     [13:0]   line_addr,
    input               line_ack,
    input      [15:0]   line_data,

    input      [9:0]    hcount,
    input      [9:0]    vcount,
    input               display_buffer,
    input      [255:0]  terrain_flags,

    output     [13:0]   pixel,
    output              pixel_valid,
    output              debug_busy,
    output     [12:0]   debug_span_count,
    output reg          debug_overflow,
    output reg [12:0]   debug_missed_lines
);

// Each bank stores 6,144 records behind 13-bit links. A 2,048-entry base and
// four 1,024-entry tiers keep every inferred memory in an efficient native
// M10K geometry. Before appending, overwritten portions of older spans are
// discarded and dead records are returned to a per-bank free list. These
// transformations are exact because the new span has later painter priority.
localparam [12:0] SPAN_CAPACITY = 13'd6144;

// Polygon-list parser/rasterizer states.  Every external RAM read has a
// setup bubble so the level request cannot accidentally consume the previous
// synchronous address a second time.
localparam [5:0]
    R_IDLE          = 6'd0,
    R_CLEAR         = 6'd1,
    R_HEADER_SET    = 6'd2,
    R_HEADER_READ   = 6'd3,
    R_Y_SET         = 6'd4,
    R_Y_READ        = 6'd5,
    R_X_SET         = 6'd6,
    R_X_READ        = 6'd7,
    R_CHECK_SET     = 6'd8,
    R_CHECK_READ    = 6'd9,
    R_SPECIAL_SET   = 6'd10,
    R_SPECIAL_READ  = 6'd11,
    R_POLY_INIT     = 6'd12,
    R_EDGE_A        = 6'd13,
    R_DIV_A_WAIT    = 6'd14,
    R_EDGE_B        = 6'd15,
    R_DIV_B_WAIT    = 6'd16,
    R_SPAN          = 6'd17,
    R_APPEND_LOOKUP = 6'd18,
    R_APPEND_WRITE  = 6'd19,
    R_ADVANCE       = 6'd20,
    R_POLY_SCAN     = 6'd21,
    R_POLY_START    = 6'd22,
    R_RECLAIM_REQ   = 6'd23,
    R_RECLAIM_WAIT  = 6'd24,
    R_RECLAIM_CHECK = 6'd25,
    R_RECLAIM_FREE  = 6'd26,
    R_ALLOC_REQ     = 6'd27,
    R_ALLOC_WAIT    = 6'd28,
    R_ALLOC_WRITE   = 6'd29,
    R_ORIENT        = 6'd30;

reg [5:0] raster_state;
reg pending_copy;
reg pending_fill;
reg pending_dma_erase;
reg pending_dma_copy;
reg clear_then_fill;
reg active_bank;
reg build_bank;
reg bank_valid_0;
reg bank_valid_1;
reg [8:0] clear_y;
reg [13:0] list_pointer;
reg [15:0] polygon_header;
reg [4:0] point_count;
reg signed [15:0] vertex_x [0:15];
reg signed [16:0] vertex_y [0:15];

wire parser_read_state = raster_state == R_HEADER_READ ||
                         raster_state == R_Y_READ ||
                         raster_state == R_X_READ ||
                         raster_state == R_CHECK_READ ||
                         raster_state == R_SPECIAL_READ;
assign line_req = parser_read_state;
assign line_addr = list_pointer;
// Keep the producer interlock asserted from the publication strobe until the
// complete list has been consumed. Without the pending terms there is a short
// R_IDLE window in which the C25 can overwrite the first unread RAM words.
assign debug_busy = raster_state != R_IDLE || pending_copy || pending_fill ||
                    pending_dma_erase || pending_dma_copy;
// The display bank is sampled a scanline ahead by the painter. Publishing it
// during visible video tears one output frame between two polygon buffers and
// can leave a long horizontal boundary through the world or cockpit. Keep the
// copy/swap operation in vertical blank, before line zero is prepared on raw
// line 461. Parsing into the former display bank may continue afterward; the
// painter reads only the newly published bank.
wire publish_window = vcount >= 10'd400 && vcount < 10'd461;

// The list heads and tails are small distributed memories.  Appending rather
// than prepending keeps polygon overwrite priority identical to list order.
(* ramstyle = "MLAB, no_rw_check" *) reg [12:0] span_head_0 [0:399];
(* ramstyle = "MLAB, no_rw_check" *) reg [12:0] span_tail_0 [0:399];
(* ramstyle = "MLAB, no_rw_check" *) reg [12:0] span_head_1 [0:399];
(* ramstyle = "MLAB, no_rw_check" *) reg [12:0] span_tail_1 [0:399];
(* ramstyle = "MLAB, no_rw_check" *) reg span_valid_0 [0:399];
(* ramstyle = "MLAB, no_rw_check" *) reg span_valid_1 [0:399];
reg [12:0] span_count_0;
reg [12:0] span_count_1;
reg [12:0] span_top_0;
reg [12:0] span_top_1;
reg [12:0] span_free_count_0;
reg [12:0] span_free_count_1;
reg [12:0] span_free_head_0;
reg [12:0] span_free_head_1;
assign debug_span_count = active_bank ? span_count_1 : span_count_0;

reg span_data_we;
reg span_next_we;
reg [12:0] span_write_addr;
reg [25:0] span_write_data;
reg [12:0] span_next_addr;
reg [12:0] span_next_data;
reg span_read_en;
reg [12:0] span_read_addr;
reg reclaim_read_en;
reg [12:0] reclaim_read_addr;
wire [25:0] span_read_data_0;
wire [25:0] span_read_data_1;
wire [12:0] span_read_next_0;
wire [12:0] span_read_next_1;

tas_polygon_span_bank span_bank_0 (
    .clk(clk),
    .read_enable((span_read_en && !paint_list_bank) ||
                 (reclaim_read_en && !build_bank)),
    .read_addr(reclaim_read_en && !build_bank
                   ? reclaim_read_addr : span_read_addr),
    .read_data(span_read_data_0), .read_next(span_read_next_0),
    .data_write_enable(span_data_we && !build_bank),
    .data_write_addr(span_write_addr), .data_write(span_write_data),
    .next_write_enable(span_next_we && !build_bank),
    .next_write_addr(span_next_addr), .next_write(span_next_data)
);

tas_polygon_span_bank span_bank_1 (
    .clk(clk),
    .read_enable((span_read_en && paint_list_bank) ||
                 (reclaim_read_en && build_bank)),
    .read_addr(reclaim_read_en && build_bank
                   ? reclaim_read_addr : span_read_addr),
    .read_data(span_read_data_1), .read_next(span_read_next_1),
    .data_write_enable(span_data_we && build_bank),
    .data_write_addr(span_write_addr), .data_write(span_write_data),
    .next_write_enable(span_next_we && build_bank),
    .next_write_addr(span_next_addr), .next_write(span_next_data)
);

wire [25:0] selected_span_data = paint_list_bank
                                      ? span_read_data_1 : span_read_data_0;
wire [12:0] selected_span_next = paint_list_bank
                                      ? span_read_next_1 : span_read_next_0;
wire [25:0] selected_reclaim_data = build_bank
                                         ? span_read_data_1 : span_read_data_0;
wire [12:0] selected_reclaim_next = build_bank
                                         ? span_read_next_1 : span_read_next_0;
wire [8:0] reclaim_x1 = selected_reclaim_data[8:0];
wire [8:0] reclaim_x2 = selected_reclaim_data[17:9];
wire reclaim_tail_merge = reclaim_pointer == append_tail &&
                          selected_reclaim_data[25:18] == append_header &&
                          {1'b0, reclaim_x1} <=
                              ({1'b0, append_x2} + 10'd1) &&
                          {1'b0, append_x1} <=
                              ({1'b0, reclaim_x2} + 10'd1);
wire reclaim_clip_right = reclaim_x1 < append_x1 &&
                          reclaim_x2 >= append_x1 &&
                          reclaim_x2 <= append_x2;
wire reclaim_clip_left = reclaim_x1 >= append_x1 &&
                         reclaim_x1 <= append_x2 &&
                         reclaim_x2 > append_x2;
wire [8:0] reclaim_merged_x1 = reclaim_x1 < append_x1
                                   ? reclaim_x1 : append_x1;
wire [8:0] reclaim_merged_x2 = reclaim_x2 > append_x2
                                   ? reclaim_x2 : append_x2;

reg [3:0] minimum_index;
reg signed [16:0] minimum_y;
reg signed [16:0] maximum_y;
reg [3:0] scan_index;

reg [3:0] side_a;
reg [3:0] side_b;
reg [3:0] target_a;
reg [3:0] target_b;
reg need_edge_a;
reg need_edge_b;
reg signed [16:0] current_y;
reg signed [16:0] limit_y;
reg signed [31:0] edge_x_a;
reg signed [31:0] edge_x_b;
reg signed [31:0] slope_a;
reg signed [31:0] slope_b;
reg edge_order_swapped;
wire [3:0] previous_a = side_a == 0 ? point_count[3:0] - 1'd1
                                             : side_a - 1'd1;
wire [3:0] next_b = side_b + 1'd1 >= point_count
                          ? 4'd0 : side_b + 1'd1;
wire signed [16:0] edge_denominator_a = vertex_y[previous_a] - current_y;
wire signed [16:0] edge_denominator_b = vertex_y[next_b] - current_y;

function automatic signed [31:0] slope_numerator(
    input signed [15:0] to_x,
    input signed [15:0] from_x
);
    reg signed [16:0] delta;
begin
    delta = to_x - from_x;
    slope_numerator = $signed(delta) * 32'sd65536;
end
endfunction

function automatic signed [31:0] fixed_x(input signed [15:0] value);
begin
    fixed_x = {value, 16'd0};
end
endfunction

reg divider_start;
reg signed [31:0] divider_numerator;
reg [15:0] divider_denominator;
wire divider_busy;
wire divider_done;
wire signed [31:0] divider_result;
tas_signed_divider slope_divider (
    .clk(clk), .reset(reset), .start(divider_start),
    .numerator(divider_numerator), .denominator(divider_denominator),
    .busy(divider_busy), .done(divider_done), .quotient(divider_result)
);

reg [8:0] append_y;
reg [8:0] append_x1;
reg [8:0] append_x2;
reg [7:0] append_header;
reg [12:0] append_tail;
reg append_empty;
reg [12:0] reclaim_pointer;
reg [12:0] reclaim_previous;
reg reclaim_previous_valid;
reg [12:0] reclaim_deleted_next;
reg reclaim_deleted_tail;
reg [12:0] allocated_span;
reg allocate_from_free;
wire signed [31:0] integer_x_a = edge_x_a >>> 16;
wire signed [31:0] integer_x_b = edge_x_b >>> 16;
wire signed [31:0] integer_left = edge_order_swapped
                                      ? integer_x_b : integer_x_a;
wire signed [31:0] integer_right = edge_order_swapped
                                       ? integer_x_a : integer_x_b;

// Scanline painter.  It clears and draws the next line while the video path
// displays the current line from the other distributed-memory buffer.
localparam [3:0]
    P_IDLE       = 4'd0,
    P_CLEAR      = 4'd1,
    P_HEAD       = 4'd2,
    P_SPAN_REQ   = 4'd3,
    P_SPAN_WAIT  = 4'd4,
    P_SPAN_BEGIN = 4'd5,
    P_FILL       = 4'd6,
    P_NEXT       = 4'd7;
reg [3:0] paint_state;
reg paint_list_bank;
reg paint_buffer;
reg [8:0] paint_y;
reg [8:0] paint_x;
reg [8:0] paint_x2;
reg [13:0] paint_color;
reg [12:0] paint_pointer;
reg [12:0] paint_tail;
reg line_valid_0;
reg line_valid_1;
reg [9:0] paint_previous_hcount;

// Each physical bank is either being built or painted, never both. Funnel
// those mutually exclusive head-table reads through one address expression so
// Quartus infers one-port MLABs instead of expanding a second logical read
// site into thousands of registers.
wire [8:0] span_head_read_y_0 =
    (raster_state == R_APPEND_LOOKUP && !build_bank) ? append_y : paint_y;
wire [8:0] span_head_read_y_1 =
    (raster_state == R_APPEND_LOOKUP && build_bank) ? append_y : paint_y;
wire [12:0] span_head_read_0 = span_head_0[span_head_read_y_0];
wire [12:0] span_head_read_1 = span_head_1[span_head_read_y_1];

// Keep the inclusive width and end comparison at ten bits.  Column 511 is a
// valid right edge, so a 9-bit x+count wraps to zero after writing that pixel
// and would leave the painter permanently stuck in P_FILL.
wire [9:0] fill_remaining = {1'b0, paint_x2} -
                            {1'b0, paint_x} + 10'd1;
wire [2:0] fill_count = fill_remaining >= 10'd4
                              ? 3'd4 : fill_remaining[2:0];
wire [8:0] paint_raw_y = paint_y + 9'd48;
reg [3:0] poly_write_enable;
reg [6:0] poly_write_addr_0;
reg [6:0] poly_write_addr_1;
reg [6:0] poly_write_addr_2;
reg [6:0] poly_write_addr_3;
reg [13:0] poly_write_data;

always @* begin
    poly_write_enable = 4'd0;
    poly_write_addr_0 = paint_x[8:2];
    poly_write_addr_1 = paint_x[8:2];
    poly_write_addr_2 = paint_x[8:2];
    poly_write_addr_3 = paint_x[8:2];
    poly_write_data = paint_state == P_CLEAR ? 14'd0 : paint_color;
    if (paint_state == P_CLEAR) begin
        poly_write_enable = 4'b1111;
    end else if (paint_state == P_FILL) begin
        case (paint_x[1:0])
            2'd0: poly_write_enable = {
                fill_count >= 4, fill_count >= 3, fill_count >= 2, 1'b1};
            2'd1: begin
                poly_write_enable = {
                    fill_count >= 3, fill_count >= 2, 1'b1, fill_count >= 4};
                poly_write_addr_0 = paint_x[8:2] + 1'd1;
            end
            2'd2: begin
                poly_write_enable = {
                    fill_count >= 2, 1'b1, fill_count >= 4, fill_count >= 3};
                poly_write_addr_0 = paint_x[8:2] + 1'd1;
                poly_write_addr_1 = paint_x[8:2] + 1'd1;
            end
            default: begin
                poly_write_enable = {
                    1'b1, fill_count >= 4, fill_count >= 3, fill_count >= 2};
                poly_write_addr_0 = paint_x[8:2] + 1'd1;
                poly_write_addr_1 = paint_x[8:2] + 1'd1;
                poly_write_addr_2 = paint_x[8:2] + 1'd1;
            end
        endcase
    end
end

wire [13:0] polygon_line_0;
wire [13:0] polygon_line_1;
tas_polygon_line_buffer polygon_buffer_0 (
    .clk(clk), .read_addr(hcount[8:0]), .read_data(polygon_line_0),
    .write_enable(poly_write_enable & {4{!paint_buffer}}),
    .write_addr_0(poly_write_addr_0), .write_addr_1(poly_write_addr_1),
    .write_addr_2(poly_write_addr_2), .write_addr_3(poly_write_addr_3),
    .write_data(poly_write_data)
);
tas_polygon_line_buffer polygon_buffer_1 (
    .clk(clk), .read_addr(hcount[8:0]), .read_data(polygon_line_1),
    .write_enable(poly_write_enable & {4{paint_buffer}}),
    .write_addr_0(poly_write_addr_0), .write_addr_1(poly_write_addr_1),
    .write_addr_2(poly_write_addr_2), .write_addr_3(poly_write_addr_3),
    .write_data(poly_write_data)
);
assign pixel = display_buffer ? polygon_line_1 : polygon_line_0;
assign pixel_valid = (display_buffer ? line_valid_1 : line_valid_0) &&
                     pixel != 0;

always @(posedge clk) begin
    divider_start <= 1'b0;
    span_data_we <= 1'b0;
    span_next_we <= 1'b0;
    reclaim_read_en <= 1'b0;

    if (reset) begin
        raster_state <= R_IDLE;
        pending_copy <= 1'b0;
        pending_fill <= 1'b0;
        pending_dma_erase <= 1'b0;
        pending_dma_copy <= 1'b0;
        clear_then_fill <= 1'b0;
        active_bank <= 1'b0;
        build_bank <= 1'b1;
        bank_valid_0 <= 1'b0;
        bank_valid_1 <= 1'b0;
        clear_y <= 9'd0;
        list_pointer <= 14'h3fff;
        polygon_header <= 16'd0;
        point_count <= 5'd0;
        span_count_0 <= 13'd0;
        span_count_1 <= 13'd0;
        span_top_0 <= 13'd0;
        span_top_1 <= 13'd0;
        span_free_count_0 <= 13'd0;
        span_free_count_1 <= 13'd0;
        span_free_head_0 <= 13'd0;
        span_free_head_1 <= 13'd0;
        debug_overflow <= 1'b0;
        divider_numerator <= 32'sd0;
        divider_denominator <= 16'd1;
        minimum_index <= 4'd0;
        minimum_y <= 17'sd0;
        maximum_y <= 17'sd0;
        scan_index <= 4'd0;
        side_a <= 4'd0;
        side_b <= 4'd0;
        target_a <= 4'd0;
        target_b <= 4'd0;
        need_edge_a <= 1'b0;
        need_edge_b <= 1'b0;
        current_y <= 17'sd0;
        limit_y <= 17'sd0;
        edge_x_a <= 32'sd0;
        edge_x_b <= 32'sd0;
        slope_a <= 32'sd0;
        slope_b <= 32'sd0;
        edge_order_swapped <= 1'b0;
        append_y <= 9'd0;
        append_x1 <= 9'd0;
        append_x2 <= 9'd0;
        append_header <= 8'd0;
        append_tail <= 13'd0;
        append_empty <= 1'b1;
        reclaim_pointer <= 13'd0;
        reclaim_previous <= 13'd0;
        reclaim_previous_valid <= 1'b0;
        reclaim_deleted_next <= 13'd0;
        reclaim_deleted_tail <= 1'b0;
        allocated_span <= 13'd0;
        allocate_from_free <= 1'b0;
        reclaim_read_addr <= 13'd0;
        span_write_addr <= 13'd0;
        span_write_data <= 26'd0;
        span_next_addr <= 13'd0;
        span_next_data <= 13'd0;
    end else begin
        if (flag_strobe[1]) pending_copy <= 1'b1;
        if (flag_strobe[2]) pending_fill <= 1'b1;
        if (dma_erase_strobe) pending_dma_erase <= 1'b1;
        if (dma_copy_strobe) pending_dma_copy <= 1'b1;

        case (raster_state)
            R_IDLE: begin
                // Do not recycle the old display list while the scanline
                // painter still has a record from it in flight.
                if (pending_dma_erase && paint_state == P_IDLE) begin
                    // The 68000 framebuffer DMA command 0x1fff erases only
                    // the off-screen build framebuffer.  This is separate
                    // from the C25 copy flag, and is used at scene/batch
                    // boundaries before more polygons are appended.
                    pending_dma_erase <= 1'b0;
                    build_bank <= ~active_bank;
                    clear_then_fill <= 1'b0;
                    clear_y <= 9'd0;
                    debug_overflow <= 1'b0;
                    if (active_bank) begin
                        span_count_0 <= 13'd0;
                        span_top_0 <= 13'd0;
                        span_free_count_0 <= 13'd0;
                        span_free_head_0 <= 13'd0;
                        bank_valid_0 <= 1'b0;
                    end else begin
                        span_count_1 <= 13'd0;
                        span_top_1 <= 13'd0;
                        span_free_count_1 <= 13'd0;
                        span_free_head_1 <= 13'd0;
                        bank_valid_1 <= 1'b0;
                    end
                    raster_state <= R_CLEAR;
                end else if (pending_dma_copy && paint_state == P_IDLE &&
                             publish_window) begin
                    // DMA bit 15 publishes the completed build framebuffer
                    // and clears the old display framebuffer for subsequent
                    // drawing, but unlike C25 flag 1 it does not also parse
                    // the current line-RAM list.
                    pending_dma_copy <= 1'b0;
                    active_bank <= ~active_bank;
                    build_bank <= active_bank;
                    clear_then_fill <= 1'b0;
                    clear_y <= 9'd0;
                    debug_overflow <= 1'b0;
                    if (active_bank) begin
                        span_count_1 <= 13'd0;
                        span_top_1 <= 13'd0;
                        span_free_count_1 <= 13'd0;
                        span_free_head_1 <= 13'd0;
                        bank_valid_1 <= 1'b0;
                    end else begin
                        span_count_0 <= 13'd0;
                        span_top_0 <= 13'd0;
                        span_free_count_0 <= 13'd0;
                        span_free_head_0 <= 13'd0;
                        bank_valid_0 <= 1'b0;
                    end
                    raster_state <= R_CLEAR;
                end else if (pending_copy && paint_state == P_IDLE &&
                             publish_window) begin
                    pending_copy <= 1'b0;
                    active_bank <= ~active_bank;
                    build_bank <= active_bank;
                    clear_then_fill <= 1'b1;
                    clear_y <= 9'd0;
                    debug_overflow <= 1'b0;
                    if (active_bank) begin
                        span_count_1 <= 13'd0;
                        span_top_1 <= 13'd0;
                        span_free_count_1 <= 13'd0;
                        span_free_head_1 <= 13'd0;
                    end else begin
                        span_count_0 <= 13'd0;
                        span_top_0 <= 13'd0;
                        span_free_count_0 <= 13'd0;
                        span_free_head_0 <= 13'd0;
                    end
                    if (active_bank) bank_valid_1 <= 1'b0;
                    else bank_valid_0 <= 1'b0;
                    raster_state <= R_CLEAR;
                end else if (pending_fill) begin
                    pending_fill <= 1'b0;
                    build_bank <= ~active_bank;
                    list_pointer <= 14'h3fff;
                    raster_state <= R_HEADER_SET;
                end
            end

            R_CLEAR: begin
                if (build_bank) begin
                    span_valid_1[clear_y] <= 1'b0;
                end else begin
                    span_valid_0[clear_y] <= 1'b0;
                end
                if (clear_y == 9'd399) begin
                    if (clear_then_fill) begin
                        list_pointer <= 14'h3fff;
                        raster_state <= R_HEADER_SET;
                    end else begin
                        raster_state <= R_IDLE;
                    end
                end else begin
                    clear_y <= clear_y + 1'd1;
                end
            end

            R_HEADER_SET: raster_state <= R_HEADER_READ;
            R_HEADER_READ: if (line_ack) begin
                if (line_data == 0 || line_data == 16'h4000) begin
                    if (build_bank) bank_valid_1 <= 1'b1;
                    else bank_valid_0 <= 1'b1;
                    raster_state <= R_IDLE;
                end else begin
                    polygon_header <= line_data;
                    point_count <= 5'd0;
                    list_pointer <= list_pointer - 1'd1;
                    raster_state <= R_Y_SET;
                end
            end

            R_Y_SET: raster_state <= R_Y_READ;
            R_Y_READ: if (line_ack) begin
                if (line_data[15:14] != 0) begin
                    list_pointer <= list_pointer - 1'd1;
                    raster_state <= R_CHECK_SET;
                end else begin
                    // Line-RAM Y is already relative to the 400-line visible
                    // window. Software renderers add 48 only because their
                    // bitmap retains the board's raw blank lines 0..47; this
                    // core rebases raw 48..447 to output lines 0..399.
                    vertex_y[point_count[3:0]] <= $signed(line_data);
                    list_pointer <= list_pointer - 1'd1;
                    raster_state <= R_X_SET;
                end
            end

            R_X_SET: raster_state <= R_X_READ;
            R_X_READ: if (line_ack) begin
                vertex_x[point_count[3:0]] <= line_data;
                point_count <= point_count + 1'd1;
                if (point_count == 5'd15) begin
                    // Match the board parser's maximum-point termination:
                    // skip the unconsumed delimiter before the next check.
                    list_pointer <= list_pointer - 14'd2;
                    raster_state <= R_CHECK_SET;
                end else begin
                    list_pointer <= list_pointer - 1'd1;
                    raster_state <= R_Y_SET;
                end
            end

            R_CHECK_SET: raster_state <= R_CHECK_READ;
            R_CHECK_READ: if (line_ack) begin
                if (line_data[15] || line_data[15:14] != 0) begin
                    raster_state <= R_POLY_INIT;
                end else if (list_pointer == 0) begin
                    raster_state <= R_POLY_INIT;
                end else begin
                    list_pointer <= list_pointer - 1'd1;
                    raster_state <= R_SPECIAL_SET;
                end
            end

            R_SPECIAL_SET: raster_state <= R_SPECIAL_READ;
            R_SPECIAL_READ: if (line_ack) begin
                if (line_data[15:14] != 0 || list_pointer == 0)
                    raster_state <= R_POLY_INIT;
                else begin
                    list_pointer <= list_pointer - 1'd1;
                    raster_state <= R_SPECIAL_SET;
                end
            end

            R_POLY_INIT: begin
                if (point_count < 3) begin
                    raster_state <= R_HEADER_SET;
                end else begin
                    // Scan one captured point per clock.  The previous
                    // 16-way combinational minimum tree was the core's only
                    // failing 20 MHz path (55 logic levels).
                    minimum_index <= 4'd0;
                    minimum_y <= vertex_y[0];
                    maximum_y <= vertex_y[0];
                    scan_index <= 4'd1;
                    raster_state <= R_POLY_SCAN;
                end
            end

            R_POLY_SCAN: begin
                if (vertex_y[scan_index] < minimum_y) begin
                    minimum_y <= vertex_y[scan_index];
                    minimum_index <= scan_index;
                end
                if (vertex_y[scan_index] > maximum_y)
                    maximum_y <= vertex_y[scan_index];
                if ({1'b0, scan_index} + 5'd1 >= point_count)
                    raster_state <= R_POLY_START;
                else
                    scan_index <= scan_index + 1'd1;
            end

            R_POLY_START: begin
                if (minimum_y == maximum_y) begin
                    raster_state <= R_HEADER_SET;
                end else begin
                    current_y <= minimum_y;
                    limit_y <= maximum_y;
                    side_a <= minimum_index;
                    side_b <= minimum_index;
                    edge_x_a <= fixed_x(vertex_x[minimum_index]);
                    edge_x_b <= fixed_x(vertex_x[minimum_index]);
                    need_edge_a <= 1'b1;
                    need_edge_b <= 1'b1;
                    raster_state <= R_EDGE_A;
                end
            end

            R_EDGE_A: begin
                if (!need_edge_a) begin
                    raster_state <= R_EDGE_B;
                end else if (vertex_y[previous_a] <= current_y) begin
                    side_a <= previous_a;
                    edge_x_a <= fixed_x(vertex_x[previous_a]);
                end else begin
                    divider_numerator <= slope_numerator(
                        vertex_x[previous_a], vertex_x[side_a]);
                    divider_denominator <= edge_denominator_a[15:0];
                    divider_start <= 1'b1;
                    target_a <= previous_a;
                    raster_state <= R_DIV_A_WAIT;
                end
            end
            R_DIV_A_WAIT: if (divider_done) begin
                slope_a <= divider_result;
                need_edge_a <= 1'b0;
                raster_state <= R_EDGE_B;
            end

            R_EDGE_B: begin
                if (!need_edge_b) begin
                    raster_state <= R_ORIENT;
                end else if (vertex_y[next_b] <= current_y) begin
                    side_b <= next_b;
                    edge_x_b <= fixed_x(vertex_x[next_b]);
                end else begin
                    divider_numerator <= slope_numerator(
                        vertex_x[next_b], vertex_x[side_b]);
                    divider_denominator <= edge_denominator_b[15:0];
                    divider_start <= 1'b1;
                    target_b <= next_b;
                    raster_state <= R_DIV_B_WAIT;
                end
            end
            R_DIV_B_WAIT: if (divider_done) begin
                slope_b <= divider_result;
                need_edge_b <= 1'b0;
                raster_state <= R_ORIENT;
            end

            // fill_slope orders the two edges once at the beginning of an
            // edge segment.  It does not reorder them again if rounding or a
            // non-convex source makes them cross before the next vertex; the
            // resulting inverted interval emits no pixels.  Recomputing
            // min/max on every line mirrors the polygon after the crossing
            // and creates a widening triangular artefact.
            R_ORIENT: begin
                edge_order_swapped <= edge_x_a > edge_x_b ||
                    (edge_x_a == edge_x_b && slope_a > slope_b);
                raster_state <= R_SPAN;
            end

            R_SPAN: begin
                if (current_y >= limit_y) begin
                    raster_state <= R_HEADER_SET;
                end else if (current_y >= 0 && current_y < 400 &&
                             integer_left <= integer_right &&
                             integer_left <= 511 && integer_right >= 0) begin
                    append_y <= current_y[8:0];
                    append_x1 <= integer_left < 0 ? 9'd0 : integer_left[8:0];
                    append_x2 <= integer_right > 511 ? 9'd511 : integer_right[8:0];
                    append_header <= polygon_header[7:0];
                    raster_state <= R_APPEND_LOOKUP;
                end else begin
                    raster_state <= R_ADVANCE;
                end
            end

            R_APPEND_LOOKUP: begin
                if (build_bank) begin
                    append_tail <= span_tail_1[append_y];
                    append_empty <= !span_valid_1[append_y];
                    reclaim_pointer <= span_head_read_1;
                end else begin
                    append_tail <= span_tail_0[append_y];
                    append_empty <= !span_valid_0[append_y];
                    reclaim_pointer <= span_head_read_0;
                end
                reclaim_previous_valid <= 1'b0;
                raster_state <= R_RECLAIM_REQ;
            end

            // Walk this scanline's old spans before appending. A record fully
            // covered by the new (last-priority) span can never affect the
            // final pixels, so unlink it and use its next field as a free-list
            // link. The build and display banks are distinct, allowing this
            // read to proceed alongside the scanline painter.
            R_RECLAIM_REQ: begin
                if (append_empty) begin
                    raster_state <= R_ALLOC_REQ;
                end else begin
                    reclaim_read_addr <= reclaim_pointer;
                    reclaim_read_en <= 1'b1;
                    raster_state <= R_RECLAIM_WAIT;
                end
            end

            R_RECLAIM_WAIT: raster_state <= R_RECLAIM_CHECK;

            R_RECLAIM_CHECK: begin
                // The old tail and the new span are consecutive painter
                // operations. If their color matches and their intervals
                // touch, replacing the tail with their union avoids a record
                // without changing a pixel.
                if (reclaim_tail_merge) begin
                    span_write_addr <= reclaim_pointer;
                    span_write_data <= {append_header, reclaim_merged_x2,
                                        reclaim_merged_x1};
                    span_data_we <= 1'b1;
                    raster_state <= R_ADVANCE;
                end else if (reclaim_x1 >= append_x1 &&
                             reclaim_x2 <= append_x2) begin
                    reclaim_deleted_next <= selected_reclaim_next;
                    reclaim_deleted_tail <= reclaim_pointer == append_tail;

                    if (reclaim_previous_valid) begin
                        // Bypass the deleted record. If it was the tail, the
                        // preceding live record becomes the new tail.
                        span_next_addr <= reclaim_previous;
                        span_next_data <= selected_reclaim_next;
                        span_next_we <= 1'b1;
                        if (reclaim_pointer == append_tail) begin
                            append_tail <= reclaim_previous;
                            if (build_bank)
                                span_tail_1[append_y] <= reclaim_previous;
                            else
                                span_tail_0[append_y] <= reclaim_previous;
                        end
                    end else if (reclaim_pointer == append_tail) begin
                        // The only remaining record was reclaimed.
                        append_empty <= 1'b1;
                        if (build_bank)
                            span_valid_1[append_y] <= 1'b0;
                        else
                            span_valid_0[append_y] <= 1'b0;
                    end else if (build_bank) begin
                        span_head_1[append_y] <= selected_reclaim_next;
                    end else begin
                        span_head_0[append_y] <= selected_reclaim_next;
                    end
                    raster_state <= R_RECLAIM_FREE;
                end else if (reclaim_clip_right || reclaim_clip_left) begin
                    // A partial overwrite can be retained as one record when
                    // it removes only one edge. A middle overwrite would
                    // split the old interval and is deliberately left alone.
                    span_write_addr <= reclaim_pointer;
                    if (reclaim_clip_right)
                        span_write_data <= {selected_reclaim_data[25:18],
                                            append_x1 - 1'd1, reclaim_x1};
                    else
                        span_write_data <= {selected_reclaim_data[25:18],
                                            reclaim_x2, append_x2 + 1'd1};
                    span_data_we <= 1'b1;
                    if (reclaim_pointer == append_tail) begin
                        raster_state <= R_ALLOC_REQ;
                    end else begin
                        reclaim_previous <= reclaim_pointer;
                        reclaim_previous_valid <= 1'b1;
                        reclaim_pointer <= selected_reclaim_next;
                        raster_state <= R_RECLAIM_REQ;
                    end
                end else if (reclaim_pointer == append_tail) begin
                    raster_state <= R_ALLOC_REQ;
                end else begin
                    reclaim_previous <= reclaim_pointer;
                    reclaim_previous_valid <= 1'b1;
                    reclaim_pointer <= selected_reclaim_next;
                    raster_state <= R_RECLAIM_REQ;
                end
            end

            R_RECLAIM_FREE: begin
                // Serialize this write one clock after the predecessor bypass;
                // the link memory therefore still needs only one write port.
                span_next_addr <= reclaim_pointer;
                span_next_data <= build_bank ? span_free_head_1
                                             : span_free_head_0;
                span_next_we <= 1'b1;
                if (build_bank) begin
                    span_free_head_1 <= reclaim_pointer;
                    span_free_count_1 <= span_free_count_1 + 1'd1;
                    span_count_1 <= span_count_1 - 1'd1;
                end else begin
                    span_free_head_0 <= reclaim_pointer;
                    span_free_count_0 <= span_free_count_0 + 1'd1;
                    span_count_0 <= span_count_0 - 1'd1;
                end

                if (reclaim_deleted_tail) begin
                    raster_state <= R_ALLOC_REQ;
                end else begin
                    reclaim_pointer <= reclaim_deleted_next;
                    raster_state <= R_RECLAIM_REQ;
                end
            end

            R_ALLOC_REQ: begin
                if ((build_bank ? span_free_count_1 : span_free_count_0) != 0) begin
                    allocated_span <= build_bank ? span_free_head_1
                                                : span_free_head_0;
                    reclaim_read_addr <= build_bank ? span_free_head_1
                                                   : span_free_head_0;
                    reclaim_read_en <= 1'b1;
                    allocate_from_free <= 1'b1;
                    raster_state <= R_ALLOC_WAIT;
                end else if ((build_bank ? span_top_1 : span_top_0) >=
                             SPAN_CAPACITY) begin
                    debug_overflow <= 1'b1;
                    raster_state <= R_ADVANCE;
                end else begin
                    allocated_span <= build_bank ? span_top_1
                                                : span_top_0;
                    allocate_from_free <= 1'b0;
                    raster_state <= R_ALLOC_WRITE;
                end
            end

            // Capture the free-list successor through the synchronous span
            // read port before overwriting the reclaimed record.
            R_ALLOC_WAIT: raster_state <= R_ALLOC_WRITE;

            R_ALLOC_WRITE: begin
                    span_write_addr <= allocated_span;
                    span_write_data <= {append_header, append_x2, append_x1};
                    span_data_we <= 1'b1;
                    if (append_empty) begin
                        if (build_bank) begin
                            span_head_1[append_y] <= allocated_span;
                            span_valid_1[append_y] <= 1'b1;
                        end else begin
                            span_head_0[append_y] <= allocated_span;
                            span_valid_0[append_y] <= 1'b1;
                        end
                    end else begin
                        span_next_addr <= append_tail;
                        span_next_data <= allocated_span;
                        span_next_we <= 1'b1;
                    end
                    if (build_bank) begin
                        span_tail_1[append_y] <= allocated_span;
                        span_count_1 <= span_count_1 + 1'd1;
                        if (allocate_from_free) begin
                            span_free_head_1 <= selected_reclaim_next;
                            span_free_count_1 <= span_free_count_1 - 1'd1;
                        end else begin
                            span_top_1 <= span_top_1 + 1'd1;
                        end
                    end else begin
                        span_tail_0[append_y] <= allocated_span;
                        span_count_0 <= span_count_0 + 1'd1;
                        if (allocate_from_free) begin
                            span_free_head_0 <= selected_reclaim_next;
                            span_free_count_0 <= span_free_count_0 - 1'd1;
                        end else begin
                            span_top_0 <= span_top_0 + 1'd1;
                        end
                    end
                raster_state <= R_ADVANCE;
            end

            R_ADVANCE: begin
                current_y <= current_y + 1'd1;
                edge_x_a <= edge_x_a + slope_a;
                edge_x_b <= edge_x_b + slope_b;
                if (current_y + 1'd1 >= limit_y) begin
                    raster_state <= R_HEADER_SET;
                end else if (current_y + 1'd1 == vertex_y[target_a] ||
                             current_y + 1'd1 == vertex_y[target_b]) begin
                    if (current_y + 1'd1 == vertex_y[target_a]) begin
                        side_a <= target_a;
                        edge_x_a <= fixed_x(vertex_x[target_a]);
                        need_edge_a <= 1'b1;
                    end
                    if (current_y + 1'd1 == vertex_y[target_b]) begin
                        side_b <= target_b;
                        edge_x_b <= fixed_x(vertex_x[target_b]);
                        need_edge_b <= 1'b1;
                    end
                    raster_state <= R_EDGE_A;
                end else begin
                    raster_state <= R_SPAN;
                end
            end

            default: raster_state <= R_IDLE;
        endcase
    end
end

always @(posedge clk) begin
    span_read_en <= 1'b0;
    if (reset) begin
        paint_state <= P_IDLE;
        paint_list_bank <= 1'b0;
        paint_buffer <= 1'b1;
        paint_y <= 9'd0;
        paint_x <= 9'd0;
        paint_x2 <= 9'd0;
        paint_color <= 14'd0;
        paint_pointer <= 13'd0;
        paint_tail <= 13'd0;
        span_read_addr <= 13'd0;
        line_valid_0 <= 1'b0;
        line_valid_1 <= 1'b0;
        paint_previous_hcount <= 10'd0;
        debug_missed_lines <= 13'd0;
    end else begin
        // The completed line becomes visible when the raster wraps. A busy
        // painter at that boundary means the newly selected line buffer was
        // incomplete; retain a saturated counter for hardware telemetry.
        paint_previous_hcount <= hcount;
        if (paint_previous_hcount == 10'd639 && hcount == 10'd0 &&
            paint_state != P_IDLE && !(&debug_missed_lines))
            debug_missed_lines <= debug_missed_lines + 1'd1;

        case (paint_state)
            P_IDLE: if (hcount == 0 &&
                        ((vcount < 10'd399) || vcount == 10'd461)) begin
                paint_y <= vcount == 10'd461 ? 9'd0 : vcount[8:0] + 1'd1;
                paint_x <= 9'd0;
                paint_buffer <= ~display_buffer;
                paint_list_bank <= active_bank;
                if (display_buffer) line_valid_0 <= 1'b0;
                else line_valid_1 <= 1'b0;
                paint_state <= P_CLEAR;
            end

            P_CLEAR: begin
                if (paint_x == 9'd508) begin
                    paint_x <= 9'd0;
                    paint_state <= P_HEAD;
                end else begin
                    paint_x <= paint_x + 9'd4;
                end
            end

            P_HEAD: begin
                if (!(paint_list_bank ? bank_valid_1 : bank_valid_0)) begin
                    if (paint_buffer) line_valid_1 <= 1'b1;
                    else line_valid_0 <= 1'b1;
                    paint_state <= P_IDLE;
                end else if (paint_list_bank) begin
                    paint_tail <= span_tail_1[paint_y];
                    if (!span_valid_1[paint_y]) begin
                        if (paint_buffer) line_valid_1 <= 1'b1;
                        else line_valid_0 <= 1'b1;
                        paint_state <= P_IDLE;
                    end else begin
                        paint_pointer <= span_head_read_1;
                        span_read_addr <= span_head_read_1;
                        paint_state <= P_SPAN_REQ;
                    end
                end else begin
                    paint_tail <= span_tail_0[paint_y];
                    if (!span_valid_0[paint_y]) begin
                        if (paint_buffer) line_valid_1 <= 1'b1;
                        else line_valid_0 <= 1'b1;
                        paint_state <= P_IDLE;
                    end else begin
                        paint_pointer <= span_head_read_0;
                        span_read_addr <= span_head_read_0;
                        paint_state <= P_SPAN_REQ;
                    end
                end
            end

            P_SPAN_REQ: begin
                span_read_en <= 1'b1;
                paint_state <= P_SPAN_WAIT;
            end
            P_SPAN_WAIT: paint_state <= P_SPAN_BEGIN;
            P_SPAN_BEGIN: begin
                paint_x <= selected_span_data[8:0];
                paint_x2 <= selected_span_data[17:9];
                if (terrain_flags[selected_span_data[25:18]]) begin
                    // Terrain shading is indexed by raw raster Y even though
                    // span storage is in rebased visible coordinates.
                    paint_color <= 14'h2040 +
                        {selected_span_data[23:18], 7'b0000000} +
                        {8'd0, paint_raw_y[8:3]};
                end else begin
                    paint_color <= 14'h0300 +
                                   {6'd0, selected_span_data[25:18]};
                end
                paint_state <= P_FILL;
            end

            P_FILL: begin
                if ({1'b0, paint_x} + {7'd0, fill_count} >
                    {1'b0, paint_x2})
                    paint_state <= P_NEXT;
                else
                    paint_x <= paint_x + {6'd0, fill_count};
            end

            P_NEXT: begin
                if (paint_pointer == paint_tail) begin
                    if (paint_buffer) line_valid_1 <= 1'b1;
                    else line_valid_0 <= 1'b1;
                    paint_state <= P_IDLE;
                end else begin
                    paint_pointer <= selected_span_next;
                    span_read_addr <= selected_span_next;
                    paint_state <= P_SPAN_REQ;
                end
            end
            default: paint_state <= P_IDLE;
        endcase
    end
end

endmodule

// One bank physically holds 6,144 compact spans. Data and link memories are
// separate so appending can write the new record and the old tail link in the
// same clock. Splitting the extension into native 1,024-entry tiers avoids the
// severe width waste of one flat 13-bit-addressed M10K array.
module tas_polygon_span_bank (
    input               clk,
    input               read_enable,
    input      [12:0]   read_addr,
    output     [25:0]   read_data,
    output     [12:0]   read_next,
    input               data_write_enable,
    input      [12:0]   data_write_addr,
    input      [25:0]   data_write,
    input               next_write_enable,
    input      [12:0]   next_write_addr,
    input      [12:0]   next_write
);
reg [2:0] read_region;
wire [25:0] read_data_base;
wire [25:0] read_data_ext_0;
wire [25:0] read_data_ext_1;
wire [25:0] read_data_ext_2;
wire [25:0] read_data_ext_3;
wire [12:0] read_next_base;
wire [12:0] read_next_ext_0;
wire [12:0] read_next_ext_1;
wire [12:0] read_next_ext_2;
wire [12:0] read_next_ext_3;
assign read_data = read_region == 3'd4 ? read_data_ext_3 :
                   read_region == 3'd3 ? read_data_ext_2 :
                   read_region == 3'd2 ? read_data_ext_1 :
                   read_region == 3'd1 ? read_data_ext_0 : read_data_base;
assign read_next = read_region == 3'd4 ? read_next_ext_3 :
                   read_region == 3'd3 ? read_next_ext_2 :
                   read_region == 3'd2 ? read_next_ext_1 :
                   read_region == 3'd1 ? read_next_ext_0 : read_next_base;

tas_polygon_m10k_ram #(.AW(11), .DW(26)) data_base (
    .clk(clk),
    .read_enable(read_enable && !read_addr[12] && !read_addr[11]),
    .read_addr(read_addr[10:0]), .read_data(read_data_base),
    .write_enable(data_write_enable && !data_write_addr[12] &&
                  !data_write_addr[11]),
    .write_addr(data_write_addr[10:0]), .write_data(data_write)
);
tas_polygon_m10k_ram #(.AW(10), .DW(26)) data_ext_0 (
    .clk(clk),
    .read_enable(read_enable && read_addr[12:10] == 3'b010),
    .read_addr(read_addr[9:0]), .read_data(read_data_ext_0),
    .write_enable(data_write_enable &&
                  data_write_addr[12:10] == 3'b010),
    .write_addr(data_write_addr[9:0]), .write_data(data_write)
);
tas_polygon_m10k_ram #(.AW(10), .DW(26)) data_ext_1 (
    .clk(clk),
    .read_enable(read_enable && read_addr[12:10] == 3'b011),
    .read_addr(read_addr[9:0]), .read_data(read_data_ext_1),
    .write_enable(data_write_enable &&
                  data_write_addr[12:10] == 3'b011),
    .write_addr(data_write_addr[9:0]), .write_data(data_write)
);
tas_polygon_m10k_ram #(.AW(10), .DW(26)) data_ext_2 (
    .clk(clk),
    .read_enable(read_enable && read_addr[12:10] == 3'b100),
    .read_addr(read_addr[9:0]), .read_data(read_data_ext_2),
    .write_enable(data_write_enable &&
                  data_write_addr[12:10] == 3'b100),
    .write_addr(data_write_addr[9:0]), .write_data(data_write)
);
tas_polygon_m10k_ram #(.AW(10), .DW(26)) data_ext_3 (
    .clk(clk),
    .read_enable(read_enable && read_addr[12:10] == 3'b101),
    .read_addr(read_addr[9:0]), .read_data(read_data_ext_3),
    .write_enable(data_write_enable &&
                  data_write_addr[12:10] == 3'b101),
    .write_addr(data_write_addr[9:0]), .write_data(data_write)
);
tas_polygon_m10k_ram #(.AW(11), .DW(13)) next_base (
    .clk(clk),
    .read_enable(read_enable && !read_addr[12] && !read_addr[11]),
    .read_addr(read_addr[10:0]), .read_data(read_next_base),
    .write_enable(next_write_enable && !next_write_addr[12] &&
                  !next_write_addr[11]),
    .write_addr(next_write_addr[10:0]), .write_data(next_write)
);
tas_polygon_m10k_ram #(.AW(10), .DW(13)) next_ext_0 (
    .clk(clk),
    .read_enable(read_enable && read_addr[12:10] == 3'b010),
    .read_addr(read_addr[9:0]), .read_data(read_next_ext_0),
    .write_enable(next_write_enable && next_write_addr[12:10] == 3'b010),
    .write_addr(next_write_addr[9:0]), .write_data(next_write)
);
tas_polygon_m10k_ram #(.AW(10), .DW(13)) next_ext_1 (
    .clk(clk),
    .read_enable(read_enable && read_addr[12:10] == 3'b011),
    .read_addr(read_addr[9:0]), .read_data(read_next_ext_1),
    .write_enable(next_write_enable && next_write_addr[12:10] == 3'b011),
    .write_addr(next_write_addr[9:0]), .write_data(next_write)
);
tas_polygon_m10k_ram #(.AW(10), .DW(13)) next_ext_2 (
    .clk(clk),
    .read_enable(read_enable && read_addr[12:10] == 3'b100),
    .read_addr(read_addr[9:0]), .read_data(read_next_ext_2),
    .write_enable(next_write_enable && next_write_addr[12:10] == 3'b100),
    .write_addr(next_write_addr[9:0]), .write_data(next_write)
);
tas_polygon_m10k_ram #(.AW(10), .DW(13)) next_ext_3 (
    .clk(clk),
    .read_enable(read_enable && read_addr[12:10] == 3'b101),
    .read_addr(read_addr[9:0]), .read_data(read_next_ext_3),
    .write_enable(next_write_enable && next_write_addr[12:10] == 3'b101),
    .write_addr(next_write_addr[9:0]), .write_data(next_write)
);

always @(posedge clk) begin
    if (read_enable) begin
        case (read_addr[12:10])
            3'b010: read_region <= 3'd1;
            3'b011: read_region <= 3'd2;
            3'b100: read_region <= 3'd3;
            3'b101: read_region <= 3'd4;
            default: read_region <= 3'd0;
        endcase
    end
end
endmodule

// Keeping each physical tier behind a simple synchronous one-port wrapper
// prevents Quartus from interpreting the top-level tier-selection mux as an
// asynchronous memory read.
module tas_polygon_m10k_ram #(
    parameter AW = 10,
    parameter DW = 16
) (
    input                 clk,
    input                 read_enable,
    input        [AW-1:0] read_addr,
    output reg   [DW-1:0] read_data,
    input                 write_enable,
    input        [AW-1:0] write_addr,
    input        [DW-1:0] write_data
);
(* ramstyle = "M10K, no_rw_check" *) reg [DW-1:0] memory [0:(1<<AW)-1];
always @(posedge clk) begin
    if (read_enable) read_data <= memory[read_addr];
    if (write_enable) memory[write_addr] <= write_data;
end
endmodule

module tas_polygon_mlab_ram #(
    parameter AW = 8,
    parameter DW = 12
) (
    input                 clk,
    input                 read_enable,
    input        [AW-1:0] read_addr,
    output reg   [DW-1:0] read_data,
    input                 write_enable,
    input        [AW-1:0] write_addr,
    input        [DW-1:0] write_data
);
(* ramstyle = "MLAB, no_rw_check" *) reg [DW-1:0] memory [0:(1<<AW)-1];
always @(posedge clk) begin
    if (read_enable) read_data <= memory[read_addr];
    if (write_enable) memory[write_addr] <= write_data;
end
endmodule

// Four independent banks allow four adjacent pixels to be cleared or painted
// in one clock. Spare M10Ks keep these small synchronous banks out of ALMs.
module tas_polygon_line_buffer (
    input               clk,
    input      [8:0]    read_addr,
    output reg [13:0]   read_data,
    input      [3:0]    write_enable,
    input      [6:0]    write_addr_0,
    input      [6:0]    write_addr_1,
    input      [6:0]    write_addr_2,
    input      [6:0]    write_addr_3,
    input      [13:0]   write_data
);
(* ramstyle = "M10K, no_rw_check" *) reg [13:0] bank_0 [0:127];
(* ramstyle = "M10K, no_rw_check" *) reg [13:0] bank_1 [0:127];
(* ramstyle = "M10K, no_rw_check" *) reg [13:0] bank_2 [0:127];
(* ramstyle = "M10K, no_rw_check" *) reg [13:0] bank_3 [0:127];
reg [13:0] read_0;
reg [13:0] read_1;
reg [13:0] read_2;
reg [13:0] read_3;
reg [1:0] read_select;
always @* begin
    case (read_select)
        2'd0: read_data = read_0;
        2'd1: read_data = read_1;
        2'd2: read_data = read_2;
        default: read_data = read_3;
    endcase
end
always @(posedge clk) begin
    read_0 <= bank_0[read_addr[8:2]];
    read_1 <= bank_1[read_addr[8:2]];
    read_2 <= bank_2[read_addr[8:2]];
    read_3 <= bank_3[read_addr[8:2]];
    read_select <= read_addr[1:0];
    if (write_enable[0]) bank_0[write_addr_0] <= write_data;
    if (write_enable[1]) bank_1[write_addr_1] <= write_data;
    if (write_enable[2]) bank_2[write_addr_2] <= write_data;
    if (write_enable[3]) bank_3[write_addr_3] <= write_data;
end
endmodule

// Iterative signed 32/16 divider used only when the parser advances to a new
// polygon edge.  Thirty-two clocks per edge are negligible beside a frame and
// avoid a large combinational divider on the 20 MHz system-clock path.
module tas_signed_divider (
    input                       clk,
    input                       reset,
    input                       start,
    input signed      [31:0]    numerator,
    input             [15:0]    denominator,
    output reg                  busy,
    output reg                  done,
    output reg signed [31:0]    quotient
);
reg negative;
reg [31:0] dividend;
reg [31:0] quotient_work;
reg [16:0] remainder;
reg [15:0] divisor;
reg [5:0] divide_count;
wire [16:0] shifted_remainder = {remainder[15:0], dividend[31]};
wire subtract_enable = shifted_remainder >= {1'b0, divisor};
wire [16:0] next_remainder = subtract_enable
                                  ? shifted_remainder - {1'b0, divisor}
                                  : shifted_remainder;
wire [31:0] next_quotient = {quotient_work[30:0], subtract_enable};

always @(posedge clk) begin
    done <= 1'b0;
    if (reset) begin
        busy <= 1'b0;
        quotient <= 32'sd0;
        negative <= 1'b0;
        dividend <= 32'd0;
        quotient_work <= 32'd0;
        remainder <= 17'd0;
        divisor <= 16'd1;
        divide_count <= 6'd0;
    end else if (start && !busy) begin
        if (denominator == 0) begin
            quotient <= 32'sh7fffffff;
            done <= 1'b1;
        end else begin
            busy <= 1'b1;
            negative <= numerator[31];
            dividend <= numerator[31] ? (~numerator + 1'd1) : numerator;
            quotient_work <= 32'd0;
            remainder <= 17'd0;
            divisor <= denominator;
            divide_count <= 6'd0;
        end
    end else if (busy) begin
        dividend <= dividend << 1;
        remainder <= next_remainder;
        quotient_work <= next_quotient;
        if (divide_count == 6'd31) begin
            busy <= 1'b0;
            done <= 1'b1;
            quotient <= negative ? -$signed(next_quotient)
                                 : $signed(next_quotient);
        end else begin
            divide_count <= divide_count + 1'd1;
        end
    end
end
endmodule
