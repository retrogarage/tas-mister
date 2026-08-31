`timescale 1ns/1ps

module tb_tas_polygon;
reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg [2:0] flag_strobe = 3'd0;
reg dma_erase_strobe = 1'b0;
reg dma_copy_strobe = 1'b0;
wire line_req;
wire [13:0] line_addr;
reg line_ack = 1'b0;
reg [15:0] line_data = 16'd0;
reg [15:0] line_memory [0:16383];
reg [9:0] hcount = 10'd0;
reg [9:0] vcount = 10'd0;
reg display_buffer = 1'b0;
wire [13:0] pixel;
wire pixel_valid;
wire debug_busy;
wire [12:0] debug_span_count;
wire debug_overflow;
wire [12:0] debug_missed_lines;

tas_polygon dut (
    .clk(clk), .reset(reset), .flag_strobe(flag_strobe),
    .dma_erase_strobe(dma_erase_strobe),
    .dma_copy_strobe(dma_copy_strobe),
    .line_req(line_req), .line_addr(line_addr),
    .line_ack(line_ack), .line_data(line_data),
    .hcount(hcount), .vcount(vcount), .display_buffer(display_buffer),
    .terrain_flags(256'd0),
    .pixel(pixel), .pixel_valid(pixel_valid),
    .debug_busy(debug_busy), .debug_span_count(debug_span_count),
    .debug_overflow(debug_overflow),
    .debug_missed_lines(debug_missed_lines)
);

always @(posedge clk) begin
    line_ack <= line_req;
    if (line_req) line_data <= line_memory[line_addr];

    if (reset) begin
        hcount <= 10'd0;
        vcount <= 10'd0;
        display_buffer <= 1'b0;
    end else if (hcount == 10'd639) begin
        hcount <= 10'd0;
        display_buffer <= ~display_buffer;
        if (vcount == 10'd461) vcount <= 10'd0;
        else vcount <= vcount + 1'd1;
    end else begin
        hcount <= hcount + 1'd1;
    end
end

task automatic pulse_copy;
begin
    @(posedge clk);
    flag_strobe <= 3'b010;
    @(posedge clk);
    flag_strobe <= 3'b000;
end
endtask

task automatic pulse_fill;
begin
    @(posedge clk);
    flag_strobe <= 3'b100;
    @(posedge clk);
    flag_strobe <= 3'b000;
end
endtask

task automatic pulse_dma_erase;
begin
    @(posedge clk);
    dma_erase_strobe <= 1'b1;
    @(posedge clk);
    dma_erase_strobe <= 1'b0;
end
endtask

task automatic pulse_dma_copy;
begin
    @(posedge clk);
    dma_copy_strobe <= 1'b1;
    @(posedge clk);
    dma_copy_strobe <= 1'b0;
end
endtask

task automatic write_rectangle(
    inout integer pointer,
    input [15:0] header,
    input integer y1,
    input integer x1,
    input integer x2,
    input integer height
);
begin
    line_memory[pointer] = header; pointer = pointer - 1;
    line_memory[pointer] = y1; pointer = pointer - 1;
    line_memory[pointer] = x1; pointer = pointer - 1;
    line_memory[pointer] = y1; pointer = pointer - 1;
    line_memory[pointer] = x2; pointer = pointer - 1;
    line_memory[pointer] = y1 + height; pointer = pointer - 1;
    line_memory[pointer] = x2; pointer = pointer - 1;
    line_memory[pointer] = y1 + height; pointer = pointer - 1;
    line_memory[pointer] = x1; pointer = pointer - 1;
    line_memory[pointer] = 16'h8000; pointer = pointer - 1;
end
endtask

integer index;
integer colored_pixels;
integer marker_pixels_1;
integer marker_pixels_2;
integer capacity_pixels_ext2;
integer capacity_pixels_ext3;
integer expected_spans;
integer high_links;
integer ext_links;
integer write_pointer;
string line_dump_path;
reg dump_mode;
reg capacity_mode;
reg occlusion_mode;
reg dma_commands_mode;
reg crossing_edges_mode;
reg full_width_mode;
reg bank_swap_race_mode;
reg frame_atomic_publish_mode;
reg list_markers_mode;
reg previous_active_bank;
reg [9:0] previous_hcount;
reg [9:0] previous_vcount;
reg [3:0] previous_paint_state;

// A publication must never swap polygon banks on the same edge on which an
// idle painter starts a line.  The painter would latch the old bank while the
// parser begins clearing it.
always @(negedge clk) begin
    if (reset) begin
        previous_active_bank <= dut.active_bank;
        previous_hcount <= hcount;
        previous_vcount <= vcount;
        previous_paint_state <= dut.paint_state;
    end else begin
        if (dut.active_bank != previous_active_bank && previous_vcount < 400)
            $fatal(1, "polygon framebuffer published during visible video at y=%0d x=%0d",
                   previous_vcount, previous_hcount);
        if (dut.active_bank != previous_active_bank &&
            previous_hcount == 0 && previous_paint_state == dut.P_IDLE &&
            (previous_vcount < 399 || previous_vcount == 461))
            $fatal(1, "polygon bank swapped on paint-start edge");
        previous_active_bank <= dut.active_bank;
        previous_hcount <= hcount;
        previous_vcount <= vcount;
        previous_paint_state <= dut.paint_state;
    end
end

initial begin
    for (index = 0; index < 16384; index = index + 1)
        line_memory[index] = 16'd0;

    capacity_mode = $test$plusargs("CAPACITY_RECLAIM");
    occlusion_mode = $test$plusargs("OCCLUSION_RECLAIM");
    dma_commands_mode = $test$plusargs("DMA_COMMANDS");
    crossing_edges_mode = $test$plusargs("CROSSING_EDGES");
    full_width_mode = $test$plusargs("FULL_WIDTH_PAINT");
    bank_swap_race_mode = $test$plusargs("BANK_SWAP_RACE");
    frame_atomic_publish_mode = $test$plusargs("FRAME_ATOMIC_PUBLISH");
    list_markers_mode = $test$plusargs("LIST_MARKERS");
    dump_mode = $value$plusargs("LINE_ROM=%s", line_dump_path);
    if (capacity_mode) begin
        // Exactly fill the physical store with non-covering vertical
        // rectangles: fifteen at 400 lines and one at 144 lines.
        expected_spans = 6144;
        write_pointer = 16383;
        write_rectangle(write_pointer, 16'h8040, 0, 0,   9, 400);
        write_rectangle(write_pointer, 16'h8041, 0, 20, 29, 400);
        write_rectangle(write_pointer, 16'h8042, 0, 40, 49, 400);
        write_rectangle(write_pointer, 16'h8043, 0, 60, 69, 400);
        write_rectangle(write_pointer, 16'h8044, 0, 80, 89, 400);
        write_rectangle(write_pointer, 16'h8045, 0, 100, 109, 400);
        write_rectangle(write_pointer, 16'h8046, 0, 120, 129, 400);
        write_rectangle(write_pointer, 16'h8047, 0, 140, 149, 400);
        write_rectangle(write_pointer, 16'h8048, 0, 160, 169, 400);
        write_rectangle(write_pointer, 16'h8049, 0, 180, 189, 400);
        write_rectangle(write_pointer, 16'h804a, 0, 200, 209, 400);
        write_rectangle(write_pointer, 16'h804b, 0, 220, 229, 400);
        write_rectangle(write_pointer, 16'h804c, 0, 240, 249, 400);
        write_rectangle(write_pointer, 16'h804d, 0, 260, 269, 400);
        write_rectangle(write_pointer, 16'h804e, 0, 280, 289, 400);
        write_rectangle(write_pointer, 16'h804f, 0, 300, 309, 144);
        line_memory[write_pointer] = 16'h4000;
    end else if (occlusion_mode) begin
        expected_spans = 1;
        write_pointer = 16383;
        write_rectangle(write_pointer, 16'h8040, 52, 0, 99, 1);
        line_memory[write_pointer] = 16'h4000;
    end else if (crossing_edges_mode) begin
        // Real line-RAM polygon 0x3f4b from mame-line-35.hex. Its two edge
        // accumulators cross after Y=159. The reference emits only the 11
        // non-inverted/equal scanline intervals; per-line min/max incorrectly
        // mirrors the edges and emits 40 spans as a widening triangle.
        expected_spans = 11;
        line_memory[14'h3fff] = 16'h8044;
        line_memory[14'h3ffe] = 16'd191;
        line_memory[14'h3ffd] = 16'd272;
        line_memory[14'h3ffc] = 16'd192;
        line_memory[14'h3ffb] = 16'd277;
        line_memory[14'h3ffa] = 16'd152;
        line_memory[14'h3ff9] = 16'd292;
        line_memory[14'h3ff8] = 16'd152;
        line_memory[14'h3ff7] = 16'd293;
        line_memory[14'h3ff6] = 16'h8000;
        line_memory[14'h3ff5] = 16'h4000;
    end else if (full_width_mode || frame_atomic_publish_mode) begin
        expected_spans = frame_atomic_publish_mode ? 400 : 1;
        write_pointer = 16383;
        write_rectangle(write_pointer, 16'h8040,
                        frame_atomic_publish_mode ? 0 : 52,
                        0, 511, frame_atomic_publish_mode ? 400 : 1);
        line_memory[write_pointer] = 16'h4000;
    end else if (list_markers_mode) begin
        // The original C25 producer uses 0x8000 both as a polygon delimiter
        // and as a valid zero-color header. Roles come from list position,
        // not the word value. Keep an explicit 0x8000 header and a later
        // nonzero-color header after a delimiter so a
        // tempting "skip all 0x8000 separators" change cannot drop geometry.
        expected_spans = 2;
        write_pointer = 16383;
        write_rectangle(write_pointer, 16'h8000, 52, 10, 19, 1);
        write_rectangle(write_pointer, 16'h8042, 52, 30, 39, 1);
        line_memory[write_pointer] = 16'h4000;
    end else if (dump_mode) begin
        integer fixture_handle;
        fixture_handle = $fopen(line_dump_path, "r");
        if (!fixture_handle)
            $fatal(1, "cannot open polygon line fixture %s", line_dump_path);
        $fclose(fixture_handle);
        $readmemh(line_dump_path, line_memory);
        if (!$value$plusargs("EXPECTED_SPANS=%d", expected_spans))
            expected_spans = 317;
    end else begin
        expected_spans = 4;
        // One clockwise trapezoid: top x=10..20, bottom x=14..16,
        // visible y=52..56. Its left edge advances one
        // pixel per line while the right retreats one, exercising both signs
        // of the iterative slope divider.
        line_memory[14'h3fff] = 16'h8040;
        line_memory[14'h3ffe] = 16'd52;
        line_memory[14'h3ffd] = 16'd10;
        line_memory[14'h3ffc] = 16'd52;
        line_memory[14'h3ffb] = 16'd20;
        line_memory[14'h3ffa] = 16'd56;
        line_memory[14'h3ff9] = 16'd16;
        line_memory[14'h3ff8] = 16'd56;
        line_memory[14'h3ff7] = 16'd14;
        line_memory[14'h3ff6] = 16'h8000;
        line_memory[14'h3ff5] = 16'h4000;
    end

    repeat (5) @(posedge clk);
    reset <= 1'b0;

    // First copy builds bank zero while displaying the empty bank one.
    pulse_copy();
    wait (debug_busy);
    wait (!debug_busy);
    if (debug_span_count != 0) begin
        $display("FAIL active empty list unexpectedly has %0d spans", debug_span_count);
        $fatal;
    end

    // Second copy makes the completed four-span rectangle visible.
    pulse_copy();
    wait (debug_span_count == expected_spans);
    if (debug_overflow) begin
        $display("FAIL span overflow");
        $fatal;
    end

    if (crossing_edges_mode) begin
        $display("PASS tb_tas_polygon crossing edges stop at 11 reference spans");
        $finish;
    end

    if (bank_swap_race_mode) begin
        wait (!debug_busy);
        // Present the copy flag one edge before the raster wraps to hcount 0.
        // This made the old implementation swap and start painting together.
        wait (dut.paint_state == dut.P_IDLE && hcount == 10'd639);
        @(negedge clk);
        flag_strobe = 3'b010;
        @(negedge clk);
        flag_strobe = 3'b000;
        wait (dut.active_bank != previous_active_bank);
        @(negedge clk);
        $display("PASS tb_tas_polygon publication deferred past paint-start edge");
        $finish;
    end

    if (frame_atomic_publish_mode) begin
        wait (!debug_busy);

        // Prepare a completed off-screen framebuffer with a different solid
        // color, then request publication in the middle of visible video.
        // A real double-buffered display must retain the old bank for the
        // whole current frame and expose the new bank only in vertical blank.
        for (index = 0; index < 16384; index = index + 1)
            line_memory[index] = 16'd0;
        write_pointer = 16383;
        write_rectangle(write_pointer, 16'h8041, 0, 0, 511, 400);
        line_memory[write_pointer] = 16'h4000;
        pulse_fill();
        wait (debug_busy);
        wait (!debug_busy);

        wait (vcount == 10'd100 && hcount == 10'd200);
        pulse_dma_copy();
        wait (debug_busy);
        wait (!debug_busy);

        // Line zero is prepared during the final blank line. Sample the first
        // complete visible frame after publication and require one bank/color
        // across all 400 scanlines.
        wait (vcount == 10'd0 && hcount == 10'd0);
        colored_pixels = 0;
        marker_pixels_1 = 0;
        while (vcount < 10'd400) begin
            @(posedge clk);
            if (vcount < 10'd400 && hcount < 10'd512 && pixel_valid) begin
                if (pixel == 14'h0341)
                    colored_pixels = colored_pixels + 1;
                else
                    marker_pixels_1 = marker_pixels_1 + 1;
            end
        end
        if (colored_pixels != 512 * 400 || marker_pixels_1 != 0 ||
            debug_missed_lines != 0) begin
            $fatal(1, "non-atomic framebuffer publication new=%0d other=%0d missed=%0d",
                   colored_pixels, marker_pixels_1, debug_missed_lines);
        end
        $display("PASS tb_tas_polygon frame-atomic vertical-blank publication");
        $finish;
    end

    if (dma_commands_mode) begin
        wait (!debug_busy);

        // Both banks contain the test rectangle after two C25 copy/fill
        // operations. Queue DMA erase while another C25 fill is active; it
        // must survive the busy interval and then clear only the off-screen
        // build bank.
        pulse_fill();
        wait (debug_busy);
        pulse_dma_erase();
        wait (!dut.pending_dma_erase && !debug_busy);
        if (debug_span_count != expected_spans ||
            (dut.build_bank ? dut.span_count_1 : dut.span_count_0) != 0) begin
            $display("FAIL DMA erase active=%0d build=%0d",
                     debug_span_count,
                     dut.build_bank ? dut.span_count_1 : dut.span_count_0);
            $fatal;
        end

        // DMA copy publishes that now-empty build bank and clears the former
        // display bank. It must not implicitly parse/fill line RAM.
        pulse_dma_copy();
        wait (debug_busy);
        wait (!debug_busy);
        if (debug_span_count != 0 ||
            (dut.build_bank ? dut.span_count_1 : dut.span_count_0) != 0) begin
            $display("FAIL DMA copy active=%0d build=%0d",
                     debug_span_count,
                     dut.build_bank ? dut.span_count_1 : dut.span_count_0);
            $fatal;
        end
        $display("PASS tb_tas_polygon framebuffer DMA erase/copy semantics");
        $finish;
    end

    if (capacity_mode) begin
        wait (!debug_busy);

        // Exercise the physical read mux as well as allocation accounting.
        // Header 0x4b's y=0 record is allocated above the old 4,096-record
        // boundary, and header 0x4f's is allocated in the final 5,120..6,143
        // tier. Both ten-pixel bands must survive publication and painting.
        wait (vcount == 10'd0 && hcount == 10'd0);
        capacity_pixels_ext2 = 0;
        capacity_pixels_ext3 = 0;
        while (vcount < 10'd1) begin
            @(posedge clk);
            if (hcount < 10'd512 && pixel_valid && pixel == 14'h034b)
                capacity_pixels_ext2 = capacity_pixels_ext2 + 1;
            if (hcount < 10'd512 && pixel_valid && pixel == 14'h034f)
                capacity_pixels_ext3 = capacity_pixels_ext3 + 1;
        end
        if (capacity_pixels_ext2 != 10 || capacity_pixels_ext3 != 10 ||
            debug_missed_lines != 0) begin
            $display("FAIL capacity tier paint pixels=%0d/%0d missed=%0d",
                     capacity_pixels_ext2, capacity_pixels_ext3,
                     debug_missed_lines);
            $fatal;
        end

        // A full-screen later span makes all 6,144 live records obsolete.
        // It must reuse their addresses, leaving 400 live spans without ever
        // exceeding the full physical high-water mark.
        for (index = 0; index < 16384; index = index + 1)
            line_memory[index] = 16'd0;
        write_pointer = 16383;
        write_rectangle(write_pointer, 16'h8060, 0, 0, 511, 400);
        line_memory[write_pointer] = 16'h4000;
        pulse_fill();
        wait (debug_busy);
        wait (!debug_busy);
        if ((dut.build_bank ? dut.span_count_1 : dut.span_count_0) != 13'd400 ||
            (dut.build_bank ? dut.span_top_1 : dut.span_top_0) != 13'd6144 ||
            (dut.build_bank ? dut.span_free_count_1 : dut.span_free_count_0) !=
                13'd5744 || debug_overflow) begin
            $display("FAIL first reclaim live=%0d top=%0d free=%0d overflow=%0d",
                     dut.build_bank ? dut.span_count_1 : dut.span_count_0,
                     dut.build_bank ? dut.span_top_1 : dut.span_top_0,
                     dut.build_bank ? dut.span_free_count_1 : dut.span_free_count_0,
                     debug_overflow);
            $fatal;
        end

        // Reclaim and reuse the same 400 addresses once more.
        line_memory[16383] = 16'h8061;
        pulse_fill();
        wait (debug_busy);
        wait (!debug_busy);
        if ((dut.build_bank ? dut.span_count_1 : dut.span_count_0) != 13'd400 ||
            (dut.build_bank ? dut.span_top_1 : dut.span_top_0) != 13'd6144 ||
            (dut.build_bank ? dut.span_free_count_1 : dut.span_free_count_0) !=
                13'd5744 || debug_overflow) begin
            $display("FAIL second reclaim live=%0d top=%0d free=%0d overflow=%0d",
                     dut.build_bank ? dut.span_count_1 : dut.span_count_0,
                     dut.build_bank ? dut.span_top_1 : dut.span_top_0,
                     dut.build_bank ? dut.span_free_count_1 : dut.span_free_count_0,
                     debug_overflow);
            $fatal;
        end
        // Consume every free slot with successively narrower rectangles. A
        // narrower later span cannot reclaim the wider record before it.
        for (index = 0; index < 16384; index = index + 1)
            line_memory[index] = 16'd0;
        write_pointer = 16383;
        write_rectangle(write_pointer, 16'h8050, 0, 1, 510, 400);
        write_rectangle(write_pointer, 16'h8051, 0, 2, 509, 400);
        write_rectangle(write_pointer, 16'h8052, 0, 3, 508, 400);
        write_rectangle(write_pointer, 16'h8053, 0, 4, 507, 400);
        write_rectangle(write_pointer, 16'h8054, 0, 5, 506, 400);
        write_rectangle(write_pointer, 16'h8055, 0, 6, 505, 400);
        write_rectangle(write_pointer, 16'h8056, 0, 7, 504, 400);
        write_rectangle(write_pointer, 16'h8057, 0, 8, 503, 400);
        write_rectangle(write_pointer, 16'h8058, 0, 9, 502, 400);
        write_rectangle(write_pointer, 16'h8059, 0, 10, 501, 400);
        write_rectangle(write_pointer, 16'h805a, 0, 11, 500, 400);
        write_rectangle(write_pointer, 16'h805b, 0, 12, 499, 400);
        write_rectangle(write_pointer, 16'h805c, 0, 13, 498, 400);
        write_rectangle(write_pointer, 16'h805d, 0, 14, 497, 400);
        write_rectangle(write_pointer, 16'h805e, 0, 15, 496, 144);
        line_memory[write_pointer] = 16'h4000;
        pulse_fill();
        wait (debug_busy);
        wait (!debug_busy);
        if ((dut.build_bank ? dut.span_count_1 : dut.span_count_0) != 13'd6144 ||
            (dut.build_bank ? dut.span_top_1 : dut.span_top_0) != 13'd6144 ||
            (dut.build_bank ? dut.span_free_count_1 : dut.span_free_count_0) !=
                13'd0 || debug_overflow) begin
            $display("FAIL refill live=%0d top=%0d free=%0d overflow=%0d",
                     dut.build_bank ? dut.span_count_1 : dut.span_count_0,
                     dut.build_bank ? dut.span_top_1 : dut.span_top_0,
                     dut.build_bank ? dut.span_free_count_1 : dut.span_free_count_0,
                     debug_overflow);
            $fatal;
        end

        // One more non-covering span is the first rejected record.
        for (index = 0; index < 16384; index = index + 1)
            line_memory[index] = 16'd0;
        write_pointer = 16383;
        write_rectangle(write_pointer, 16'h805f, 0, 16, 495, 1);
        line_memory[write_pointer] = 16'h4000;
        pulse_fill();
        wait (debug_busy);
        wait (!debug_busy);
        if (!debug_overflow ||
            (dut.build_bank ? dut.span_count_1 : dut.span_count_0) != 13'd6144) begin
            $display("FAIL expected rejection at span 6145 live=%0d overflow=%0d",
                     dut.build_bank ? dut.span_count_1 : dut.span_count_0,
                     debug_overflow);
            $fatal;
        end
        $display("PASS tb_tas_polygon 6144 physical spans, high-tier paint, reclamation, and 6145 rejection");
        $finish;
    end

    if (occlusion_mode) begin
        wait (!debug_busy);

        // This overwrites only the right edge of the old span. The retained
        // interval must be clipped to 0..49 before the new 50..149 record is
        // appended.
        for (index = 0; index < 16384; index = index + 1)
            line_memory[index] = 16'd0;
        write_pointer = 16383;
        write_rectangle(write_pointer, 16'h8041, 52, 50, 149, 1);
        line_memory[write_pointer] = 16'h4000;
        pulse_fill();
        wait (debug_busy);
        wait (!debug_busy);
        if ((dut.build_bank ? dut.span_count_1 : dut.span_count_0) != 13'd2) begin
            $display("FAIL edge clip append live=%0d",
                     dut.build_bank ? dut.span_count_1 : dut.span_count_0);
            $fatal;
        end

        // Covering 0..49 now reclaims the clipped first record. Without exact
        // edge clipping the original 0..99 record would remain live.
        for (index = 0; index < 16384; index = index + 1)
            line_memory[index] = 16'd0;
        write_pointer = 16383;
        write_rectangle(write_pointer, 16'h8042, 52, 0, 49, 1);
        line_memory[write_pointer] = 16'h4000;
        pulse_fill();
        wait (debug_busy);
        wait (!debug_busy);
        if ((dut.build_bank ? dut.span_count_1 : dut.span_count_0) != 13'd2) begin
            $display("FAIL clipped-span reclaim live=%0d",
                     dut.build_bank ? dut.span_count_1 : dut.span_count_0);
            $fatal;
        end

        // The current tail is color 0x42 over 0..49. Its same-color overlap
        // 40..80 must merge in place, keeping the live count at two.
        for (index = 0; index < 16384; index = index + 1)
            line_memory[index] = 16'd0;
        write_pointer = 16383;
        write_rectangle(write_pointer, 16'h8042, 52, 40, 80, 1);
        line_memory[write_pointer] = 16'h4000;
        pulse_fill();
        wait (debug_busy);
        wait (!debug_busy);
        if ((dut.build_bank ? dut.span_count_1 : dut.span_count_0) != 13'd2 ||
            debug_overflow) begin
            $display("FAIL same-color tail merge live=%0d overflow=%0d",
                     dut.build_bank ? dut.span_count_1 : dut.span_count_0,
                     debug_overflow);
            $fatal;
        end
        $display("PASS tb_tas_polygon exact edge clipping and tail merging");
        $finish;
    end

    if (dump_mode) begin
        // The copy operation also begins filling the new build bank with the
        // current list. Let that complete before exercising an append batch.
        wait (!debug_busy);
        if ($test$plusargs("APPEND_STRESS")) begin
            for (index = 0; index < 16384; index = index + 1)
                line_memory[index] = 16'd0;
            // Cover the captured real landscape with a full-screen later
            // polygon. All old records become safely reclaimable.
            write_pointer = 16383;
            write_rectangle(write_pointer, 16'h8045, 0, 0, 511, 400);
            line_memory[write_pointer] = 16'h4000;
            pulse_fill();
            wait (debug_busy);
            wait (!debug_busy);
            if ((dut.build_bank ? dut.span_count_1 : dut.span_count_0) !=
                    13'd400 || debug_overflow) begin
                $display("FAIL appended real lists spans=%0d overflow=%0d",
                         dut.build_bank ? dut.span_count_1 : dut.span_count_0,
                         debug_overflow);
                $fatal;
            end
        end
        $display("PASS tb_tas_polygon real DSP list spans=%0d",
                 debug_span_count);
        $finish;
    end

    if (list_markers_mode) begin
        wait (vcount == 10'd52 && hcount == 10'd0);
        marker_pixels_1 = 0;
        marker_pixels_2 = 0;
        while (vcount < 10'd53) begin
            @(posedge clk);
            if (hcount < 10'd512 && pixel_valid && pixel == 14'h0300)
                marker_pixels_1 = marker_pixels_1 + 1;
            if (hcount < 10'd512 && pixel_valid && pixel == 14'h0342)
                marker_pixels_2 = marker_pixels_2 + 1;
        end
        if (marker_pixels_1 != 10 || marker_pixels_2 != 10 ||
            debug_span_count != 2 || debug_missed_lines != 0) begin
            $display("FAIL positional 8000 markers spans=%0d pixels=%0d/%0d missed=%0d",
                     debug_span_count, marker_pixels_1, marker_pixels_2,
                     debug_missed_lines);
            $fatal;
        end
        $display("PASS tb_tas_polygon positional 8000 delimiter/header semantics");
        $finish;
    end

    wait (vcount == 10'd52 && hcount == 10'd0);
    colored_pixels = 0;
    while (vcount < (full_width_mode ? 10'd53 : 10'd56)) begin
        @(posedge clk);
        if (hcount < 10'd512 && pixel_valid && pixel == 14'h0340)
            colored_pixels = colored_pixels + 1;
    end
    if (colored_pixels != (full_width_mode ? 512 : 32)) begin
        $display("FAIL expected %0d colored pixels, got %0d",
                 full_width_mode ? 512 : 32, colored_pixels);
        $fatal;
    end
    if (debug_missed_lines != 0) begin
        $display("FAIL painter missed %0d line deadlines",
                 debug_missed_lines);
        $fatal;
    end

    $display("PASS tb_tas_polygon spans=%0d painted_pixels=%0d full_width=%0d",
             debug_span_count, colored_pixels, full_width_mode);
    $finish;
end

initial begin
    repeat (5000000) @(posedge clk);
    $display("FAIL timeout busy=%0d spans=%0d vcount=%0d hcount=%0d",
             debug_busy, debug_span_count, vcount, hcount);
    $fatal;
end
endmodule
