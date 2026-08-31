`timescale 1ns/1ps

module tb_main;
reg clk = 0;
always #25 clk = ~clk;

reg reset = 1;
reg vblank = 0;
reg [31:0] traced_controls = 32'd0;
reg [15:0] traced_joystick_l_analog = 16'd0;
reg [15:0] traced_joystick_r_analog = 16'd0;
reg [1:0] traced_throttle_mode = 2'd0;
wire coin_pulse = coin_at >= 0 && simulation_cycles >= coin_at &&
                  simulation_cycles < coin_at + input_pulse_clocks;
wire start_pulse = start_at >= 0 && simulation_cycles >= start_at &&
                   simulation_cycles < start_at + input_pulse_clocks;
wire [31:0] controls = traced_controls |
                       (coin_pulse ? 32'h00000020 : 32'd0) |
                       (start_pulse ? 32'h00000010 : 32'd0);
wire rom_req;
wire [23:0] rom_addr;
reg rom_ack = 0;
reg [15:0] rom_data = 16'hffff;
wire [23:0] debug_addr;
wire [23:0] debug_fetch_addr;
wire [31:0] debug_cycles;
wire [7:0] debug_sysctrl;
wire debug_irq;
wire debug_halted;
wire debug_fault;
wire [23:0] debug_fault_addr;
wire [31:0] debug_fault_cycles;
wire [11:0] dsp_prog_addr;
reg [15:0] dsp_prog_data = 16'hffff;
wire [15:0] debug_dsp_pc;
wire [15:0] debug_dsp_ir;
wire [31:0] debug_dsp_instructions;
wire [15:0] debug_dsp_illegal;
wire [15:0] debug_dsp_addr;
wire [15:0] debug_dsp_data;
wire [2:0] debug_dsp_flags;
wire [2:0] dsp_flag_strobe;
wire dma_fb_erase_strobe;
wire dma_fb_copy_strobe;
wire [127:0] video_grw_regs;
wire video_line_req;
wire [13:0] video_line_addr;
wire video_line_ack;
wire [15:0] video_line_data;
wire [13:0] polygon_pixel;
wire polygon_pixel_valid;
wire polygon_busy;
wire [12:0] polygon_span_count;
wire polygon_overflow;
wire [12:0] polygon_missed_lines;
reg [9:0] polygon_hcount = 10'd0;
reg [9:0] polygon_vcount = 10'd0;
reg polygon_display_buffer = 1'b0;
wire sound_main_cs;
wire sound_main_wr;
wire sound_main_port;
wire [3:0] sound_main_din;
wire [3:0] sound_main_dout;
integer sound_main_writes = 0;
integer sound_lane_mismatches = 0;
integer sound_main_accesses = 0;
longint unsigned simulation_cycles = 0;
integer sound_log_file = 0;
integer input_trace_file = 0;
integer input_trace_result = 0;
wire sound_reset_n;
wire sound_stub_cs;
wire sound_stub_wr;
wire sound_stub_port;
wire [3:0] sound_stub_din;
wire [3:0] sound_status;

reg [7:0] rom [0:20'hbffff];
reg [7:0] dsp_program_bytes [0:8191];
reg rom_pending = 0;
reg [23:0] pending_addr = 0;
reg rom_wait_release = 0;
integer rom_delay = 1;
integer rom_delay_count = 0;
integer rom_file;
integer rom_bytes;
integer dsp_rom_bytes;
integer fetch_changes = 0;
integer history_index = 0;
integer history_print;
integer simulation_clocks = 20000000;
longint signed coin_at = -1;
longint signed start_at = -1;
integer input_pulse_clocks = 2000000;
bit video_trace = 1'b0;
integer vco_scan;
integer vco_nonzero [0:10];
integer vco_region;
integer sprite_scan;
integer sprite_nonzero;
integer vco_dump_handle;
integer flag_copy_events;
integer flag_fill_events;
integer flag_while_busy_events;
integer flag_already_pending_events;
integer line_writes_while_busy;
integer line_unread_write_races;
integer parser_busy_cycles;
integer palette_write_count;
integer palette_low_write_count;
integer palette_flush_fetches;
integer dma_write_count;
integer dma_erase_events;
integer dma_copy_events;
integer dma_command_while_busy;
integer max_physical_span_count;
integer polygon_overflow_events;
reg previous_polygon_overflow = 1'b0;
reg previous_sysctrl_write = 1'b0;
reg [23:0] old_fetch = 24'hffffff;
reg [23:0] fetch_history [0:15];
reg [19:0] raster_count = 0;
string rom_path;
string line_dump_path;
string main_dump_path;
string palette_dump_path;
string gradient_dump_path;
string vco_dump_path;
string sound_log_path;
string input_trace_path;
longint unsigned next_input_cycle = 64'hffffffffffffffff;
reg [31:0] next_input_controls = 32'd0;
reg [15:0] next_input_joystick_l_analog = 16'd0;
reg [15:0] next_input_joystick_r_analog = 16'd0;
integer next_input_throttle_mode = 0;

task read_input_trace_event;
begin
    if ($feof(input_trace_file)) begin
        $fclose(input_trace_file);
        input_trace_file = 0;
        next_input_cycle = 64'hffffffffffffffff;
    end else begin
        input_trace_result = $fscanf(
            input_trace_file, "%d %h %h %h %d\n",
            next_input_cycle, next_input_controls,
            next_input_joystick_l_analog, next_input_joystick_r_analog,
            next_input_throttle_mode
        );
        if (input_trace_result != 5 && $feof(input_trace_file)) begin
            $fclose(input_trace_file);
            input_trace_file = 0;
            next_input_cycle = 64'hffffffffffffffff;
        end else if (input_trace_result != 5) begin
            $fatal(1, "malformed input trace event after simulation clock %0d",
                   simulation_cycles);
        end else if (next_input_throttle_mode < 0 ||
                     next_input_throttle_mode > 3) begin
            $fatal(1, "invalid throttle mode %0d in input trace",
                   next_input_throttle_mode);
        end
    end
end
endtask

function automatic [15:0] vco_memory_word(input [16:0] address);
begin
    if (!address[16])
        vco_memory_word =
            dut.tc0080vco_ram.low_ram.g_dual.mem[address[15:0]];
    else if (address < 17'h10800)
        vco_memory_word =
            dut.tc0080vco_ram.high_ram.g_dual.mem[address[10:0]];
    else
        vco_memory_word = 16'd0;
end
endfunction

tas_main dut (
    .clk(clk), .reset(reset), .vblank(vblank),
    .controls(controls),
    .joystick_l_analog(traced_joystick_l_analog),
    .joystick_r_analog(traced_joystick_r_analog),
    .throttle_mode(traced_throttle_mode),
    .dswa(8'ha5), .dswb(8'h5a),
    .flight_throttle_counter(),
    .flight_stick_x_counter(), .flight_stick_y_counter(),
    .sound_main_cs(sound_main_cs), .sound_main_wr(sound_main_wr),
    .sound_main_port(sound_main_port), .sound_main_din(sound_main_din),
    .sound_main_dout(sound_main_dout),
    .video_vco_addr(17'd0), .video_vco_data(),
    .video_palette_addr(12'd0), .video_palette_data(),
    .video_gradient_addr(13'd0),
    .video_gradient_low(), .video_gradient_high(),
    .video_grw_regs(video_grw_regs), .video_gradbank(),
    .video_bg0_scrollx(), .video_bg0_scrolly(), .video_bg0_zoom(),
    .video_bg1_scrollx(), .video_bg1_scrolly(), .video_bg1_zoom(),
    .video_line_req(video_line_req), .video_line_addr(video_line_addr),
    .video_line_ack(video_line_ack), .video_line_data(video_line_data),
    .video_polygon_hold(polygon_busy),
    .dsp_prog_addr(dsp_prog_addr), .dsp_prog_data(dsp_prog_data),
    .rom_req(rom_req), .rom_addr(rom_addr),
    .rom_ack(rom_ack), .rom_data(rom_data),
    .debug_addr(debug_addr), .debug_fetch_addr(debug_fetch_addr),
    .debug_cycles(debug_cycles), .debug_sysctrl(debug_sysctrl),
    .debug_irq(debug_irq), .debug_halted(debug_halted),
    .debug_fault(debug_fault), .debug_fault_addr(debug_fault_addr),
    .debug_fault_cycles(debug_fault_cycles),
    .debug_hist0(), .debug_hist1(), .debug_hist2(), .debug_hist3(),
    .debug_hist4(), .debug_hist5(), .debug_hist6(), .debug_hist7(),
    .debug_dsp_pc(debug_dsp_pc), .debug_dsp_ir(debug_dsp_ir),
    .debug_dsp_instructions(debug_dsp_instructions),
    .debug_dsp_illegal(debug_dsp_illegal),
    .debug_dsp_addr(debug_dsp_addr), .debug_dsp_data(debug_dsp_data),
    .debug_dsp_flags(debug_dsp_flags), .dsp_flag_strobe(dsp_flag_strobe),
    .dma_fb_erase_strobe(dma_fb_erase_strobe),
    .dma_fb_copy_strobe(dma_fb_copy_strobe)
);

initial begin
    #1;
    if (dut.peripheral_read(24'ha00200) !== 16'h00a5)
        $fatal(1, "DSWA is not visible at TC0220IOC register 0");
    if (dut.peripheral_read(24'ha00202) !== 16'h005a)
        $fatal(1, "DSWB is not visible at TC0220IOC register 1");
end

// Keep the main-board regression focused on the 68000/DSP/video path.  Its
// legal sound-side responder remains outside tas_main now that the production
// top level instantiates the real sound board.
tas_tc0140syt sound_comm (
    .clk(clk), .reset(reset),
    .main_cs(sound_main_cs), .main_wr(sound_main_wr),
    .main_port(sound_main_port), .main_din(sound_main_din),
    .main_dout(sound_main_dout),
    .sound_cs(sound_stub_cs), .sound_wr(sound_stub_wr),
    .sound_port(sound_stub_port), .sound_din(sound_stub_din),
    .sound_dout(), .sound_reset_n(sound_reset_n), .sound_nmi_n(),
    .status(sound_status)
);

tas_sound_boot_stub sound_stub (
    .clk(clk), .reset(reset), .sound_reset_n(sound_reset_n),
    .status(sound_status), .sound_cs(sound_stub_cs),
    .sound_wr(sound_stub_wr), .sound_port(sound_stub_port),
    .sound_din(sound_stub_din)
);

tas_polygon polygon_renderer (
    .clk(clk), .reset(reset), .flag_strobe(dsp_flag_strobe),
    .dma_erase_strobe(dma_fb_erase_strobe),
    .dma_copy_strobe(dma_fb_copy_strobe),
    .line_req(video_line_req), .line_addr(video_line_addr),
    .line_ack(video_line_ack), .line_data(video_line_data),
    .hcount(polygon_hcount), .vcount(polygon_vcount),
    .display_buffer(polygon_display_buffer), .terrain_flags(256'd0),
    .pixel(polygon_pixel), .pixel_valid(polygon_pixel_valid),
    .debug_busy(polygon_busy), .debug_span_count(polygon_span_count),
    .debug_overflow(polygon_overflow),
    .debug_missed_lines(polygon_missed_lines)
);

always @(posedge clk)
    dsp_prog_data <= {dsp_program_bytes[{dsp_prog_addr,1'b0}],
                      dsp_program_bytes[{dsp_prog_addr,1'b1}]};

always @(posedge clk) begin
    simulation_cycles <= simulation_cycles + 1'd1;
    previous_sysctrl_write <= dut.bus_active && !dut.cpu_rnw &&
                              dut.cpu_addr == 24'h140000;
    if (input_trace_file && simulation_cycles >= next_input_cycle) begin
        traced_controls <= next_input_controls;
        traced_joystick_l_analog <= next_input_joystick_l_analog;
        traced_joystick_r_analog <= next_input_joystick_r_analog;
        traced_throttle_mode <= next_input_throttle_mode[1:0];
        $display("INPUT trace sim=%0d controls=%08h left=%04h right=%04h throttle_mode=%0d",
                 simulation_cycles, next_input_controls,
                 next_input_joystick_l_analog,
                 next_input_joystick_r_analog, next_input_throttle_mode);
        read_input_trace_event();
    end
    if (simulation_cycles == coin_at)
        $display("INPUT coin pulse sim=%0d", simulation_cycles);
    if (simulation_cycles == start_at)
        $display("INPUT start pulse sim=%0d", simulation_cycles);

    if (video_trace && dut.bus_active && !dut.cpu_rnw &&
        dut.cpu_addr == 24'h140000 && !previous_sysctrl_write)
        $display("VIDEO SYSCTRL sim=%0d cpu=%0d data=%04h uds_n=%b lds_n=%b",
                 simulation_cycles, debug_cycles, dut.cpu_dout,
                 dut.uds_n, dut.lds_n);
    if (video_trace && dut.grw_cs && !dut.cpu_rnw)
        $display("VIDEO GRW sim=%0d cpu=%0d addr=%06h data=%04h regs=%032h",
                 simulation_cycles, debug_cycles, dut.cpu_addr,
                 dut.cpu_dout, video_grw_regs);
    if (video_trace && (dma_fb_erase_strobe || dma_fb_copy_strobe))
        $display("VIDEO DMA sim=%0d cpu=%0d erase=%b copy=%b sysctrl=%02h grw=%032h spans=%0d",
                 simulation_cycles, debug_cycles, dma_fb_erase_strobe,
                 dma_fb_copy_strobe, debug_sysctrl, video_grw_regs,
                 polygon_span_count);
    if (video_trace && |dsp_flag_strobe)
        $display("VIDEO DSPFLAG sim=%0d cpu=%0d flags=%03b sysctrl=%02h grw=%032h spans=%0d overflow=%b",
                 simulation_cycles, debug_cycles, dsp_flag_strobe,
                 debug_sysctrl, video_grw_regs, polygon_span_count,
                 polygon_overflow);
    if (sound_main_cs) begin
        sound_main_accesses <= sound_main_accesses + 1;
        if (sound_log_file) begin
            // Reads are part of the protocol trace: they advance main_index
            // and clear reverse-mailbox status just like writes update it.
            // Record the observed stub value for audit, but replay lets the
            // real sound CPU supply its own response.
            $fwrite(sound_log_file, "%0d %0d %0d %01h %01h %06h\n",
                    simulation_cycles, sound_main_wr, sound_main_port,
                    sound_main_din, sound_main_dout, debug_fetch_addr);
            $fflush(sound_log_file);
        end
        if (sound_main_accesses < 32)
            $display("TC0140SYT access=%0d addr=%06h wr=%b uds_n=%b lds_n=%b dout=%04h nibbles=%h/%h/%h din=%h dout_chip=%h",
                     sound_main_accesses, dut.cpu_addr, sound_main_wr,
                     dut.uds_n, dut.lds_n, dut.cpu_dout,
                     dut.cpu_dout[15:12], dut.cpu_dout[11:8],
                     dut.cpu_dout[3:0], sound_main_din, sound_main_dout);
        if (sound_main_wr) begin
            sound_main_writes <= sound_main_writes + 1;
            if (sound_main_din !== dut.cpu_dout[3:0])
                sound_lane_mismatches <= sound_lane_mismatches + 1;
        end
    end

    rom_ack <= 1'b0;
    if (rom_wait_release && !rom_req) rom_wait_release <= 1'b0;
    if (rom_req && !rom_pending && !rom_wait_release) begin
        pending_addr <= rom_addr;
        rom_pending <= 1'b1;
        rom_delay_count <= rom_delay;
    end
    if (rom_pending) begin
        if (rom_delay_count == 0) begin
            rom_data <= {rom[pending_addr], rom[pending_addr + 1'd1]};
            rom_ack <= 1'b1;
            rom_pending <= 1'b0;
            rom_wait_release <= 1'b1;
        end else begin
            rom_delay_count <= rom_delay_count - 1;
        end
    end

    if (!reset && debug_fetch_addr != old_fetch) begin
        old_fetch <= debug_fetch_addr;
        fetch_changes <= fetch_changes + 1;
        fetch_history[history_index[3:0]] <= debug_fetch_addr;
        history_index <= history_index + 1;
        if (fetch_changes < 32)
            $display("fetch=%06h bus=%06h cycles=%0d", debug_fetch_addr,
                     debug_addr, debug_cycles);
        if (debug_fetch_addr >= 24'h0c0000) begin
            $display("INVALID FETCH history at %0t, cycles=%0d:",
                     $time, debug_cycles);
            for (history_print = 0; history_print < 16; history_print = history_print + 1)
                $display("  %06h", fetch_history[(history_index + history_print) & 15]);
            $fatal(1, "invalid instruction fetch %06h", debug_fetch_addr);
        end
        if (debug_fetch_addr == 24'h001b62) begin
            $display("POST ERROR history at %0t, cycles=%0d sysctrl=%02h bus=%06h:",
                     $time, debug_cycles, debug_sysctrl, debug_addr);
            for (history_print = 0; history_print < 16; history_print = history_print + 1)
                $display("  %06h", fetch_history[(history_index + history_print) & 15]);
            $display("  %06h <- error handler", debug_fetch_addr);
            $finish;
        end
    end

end

// Unknown C25 opcodes are a correctness failure, not a statistic. Stop at the
// first one so a long gameplay trace cannot hide the causal PC/IR under later
// state corruption.
always @(posedge clk) begin
    if (!reset && debug_dsp_illegal != 0)
        $fatal(1, "C25 illegal opcode at pc=%04h ir=%04h count=%0d",
               debug_dsp_pc, debug_dsp_ir, debug_dsp_illegal);
end

// Measure whether the software publishes a new polygon batch before the
// scan-list engine has consumed the previous line-RAM contents. Such overlap
// would explain corrupted large triangles and missing small cockpit parts.
always @(posedge clk) begin
    if (reset) begin
        flag_copy_events <= 0;
        flag_fill_events <= 0;
        flag_while_busy_events <= 0;
        flag_already_pending_events <= 0;
        line_writes_while_busy <= 0;
        line_unread_write_races <= 0;
        parser_busy_cycles <= 0;
        palette_write_count <= 0;
        palette_low_write_count <= 0;
        palette_flush_fetches <= 0;
        dma_write_count <= 0;
        dma_erase_events <= 0;
        dma_copy_events <= 0;
        dma_command_while_busy <= 0;
        max_physical_span_count <= 0;
        polygon_overflow_events <= 0;
        previous_polygon_overflow <= 1'b0;
    end else begin
        previous_polygon_overflow <= polygon_overflow;
        if (polygon_overflow && !previous_polygon_overflow)
            polygon_overflow_events <= polygon_overflow_events + 1;
        if (polygon_renderer.span_count_0 > max_physical_span_count)
            max_physical_span_count <= polygon_renderer.span_count_0;
        if (polygon_renderer.span_count_1 > max_physical_span_count)
            max_physical_span_count <= polygon_renderer.span_count_1;
        if (dma_fb_erase_strobe) dma_erase_events <= dma_erase_events + 1;
        if (dma_fb_copy_strobe) dma_copy_events <= dma_copy_events + 1;
        if ((dma_fb_erase_strobe || dma_fb_copy_strobe) && polygon_busy)
            dma_command_while_busy <= dma_command_while_busy + 1;
        if (dut.dma_cs && !dut.cpu_rnw) begin
            if (dma_write_count < 32)
                $display("FRAMEBUFFER DMA write addr=%06h data=%04h uds_n=%b lds_n=%b cycles=%0d",
                         dut.cpu_addr, dut.cpu_dout, dut.uds_n, dut.lds_n,
                         debug_cycles);
            dma_write_count <= dma_write_count + 1;
        end
        if (dut.pal_cs && !dut.cpu_rnw) begin
            palette_write_count <= palette_write_count + 1;
            if (dut.cpu_addr[12:1] < 12'h200)
                palette_low_write_count <= palette_low_write_count + 1;
        end
        if (debug_fetch_addr == 24'h00153a && old_fetch != 24'h00153a)
            palette_flush_fetches <= palette_flush_fetches + 1;
        if (dsp_flag_strobe[1]) flag_copy_events <= flag_copy_events + 1;
        if (dsp_flag_strobe[2]) flag_fill_events <= flag_fill_events + 1;
        if ((dsp_flag_strobe[1] || dsp_flag_strobe[2]) && polygon_busy)
            flag_while_busy_events <= flag_while_busy_events + 1;
        if ((dsp_flag_strobe[1] && polygon_renderer.pending_copy) ||
            (dsp_flag_strobe[2] && polygon_renderer.pending_fill))
            flag_already_pending_events <= flag_already_pending_events + 1;
        if (polygon_busy) begin
            parser_busy_cycles <= parser_busy_cycles + 1;
            if (dut.dsp_line_cs && dut.dsp_line_we)
                line_writes_while_busy <= line_writes_while_busy + 1;
        end
        // Both producer and parser walk line RAM from high to low addresses.
        // A DSP write at or below list_pointer changes a word the active
        // parser has not consumed yet. Writes during the initial head-table
        // clear, or while an event is pending but waiting for the painter,
        // can race the first header as well.
        if (dut.dsp_line_cs && dut.dsp_line_we &&
            (polygon_busy || polygon_renderer.pending_copy ||
             polygon_renderer.pending_fill) &&
            (polygon_renderer.raster_state == 6'd1 ||
             polygon_renderer.raster_state == 6'd0 ||
             dut.dsp_line_addr <= polygon_renderer.list_pointer)) begin
            if (line_unread_write_races < 8)
                $display("POLYGON LINE-RAM RACE dsp=%04h parser=%04h state=%0d cycles=%0d",
                         dut.dsp_line_addr, polygon_renderer.list_pointer,
                         polygon_renderer.raster_state, debug_cycles);
            line_unread_write_races <= line_unread_write_races + 1;
        end
    end
end

// Match the 16 MHz board raster inside the 32 MHz system domain: 640 pixels x
// 462 lines, with a two-clock pixel enable and vblank after visible line 399.
always @(posedge clk) begin
    if (reset) begin
        raster_count <= 0;
        vblank <= 0;
        polygon_hcount <= 10'd0;
        polygon_vcount <= 10'd0;
        polygon_display_buffer <= 1'b0;
    end else begin
        if (raster_count == 20'd591359) raster_count <= 0;
        else raster_count <= raster_count + 1'd1;
        vblank <= (raster_count >= 20'd512000);
        if (!raster_count[0]) begin
            if (polygon_hcount == 10'd639) begin
                polygon_hcount <= 10'd0;
                polygon_display_buffer <= ~polygon_display_buffer;
                if (polygon_vcount == 10'd461) polygon_vcount <= 10'd0;
                else polygon_vcount <= polygon_vcount + 1'd1;
            end else begin
                polygon_hcount <= polygon_hcount + 1'd1;
            end
        end
    end
end

initial begin
    if (!$value$plusargs("ROM=%s", rom_path))
        rom_path = "roms/topland.rom";
    void'($value$plusargs("CYCLES=%d", simulation_clocks));
    void'($value$plusargs("ROM_DELAY=%d", rom_delay));
    void'($value$plusargs("COIN_AT=%d", coin_at));
    void'($value$plusargs("START_AT=%d", start_at));
    void'($value$plusargs("INPUT_PULSE=%d", input_pulse_clocks));
    video_trace = $test$plusargs("VIDEO_TRACE");
    if ($value$plusargs("INPUT_TRACE=%s", input_trace_path)) begin
        input_trace_file = $fopen(input_trace_path, "r");
        if (!input_trace_file)
            $fatal(1, "cannot open input trace: %s", input_trace_path);
        read_input_trace_event();
    end
    if ($value$plusargs("SOUND_LOG=%s", sound_log_path)) begin
        sound_log_file = $fopen(sound_log_path, "w");
        if (!sound_log_file)
            $fatal(1, "cannot create sound command trace: %s",
                   sound_log_path);
    end
    rom_file = $fopen(rom_path, "rb");
    if (!rom_file) $fatal(1, "cannot open Top Landing ROM image");
    rom_bytes = $fread(rom, rom_file);
    $fclose(rom_file);
    if (rom_bytes < 20'hc0000)
        $fatal(1, "short main ROM: %0d bytes", rom_bytes);

    rom_file = $fopen(rom_path, "rb");
    if ($fseek(rom_file, 32'h000d0000, 0)) $fatal(1, "cannot seek to DSP ROM");
    dsp_rom_bytes = $fread(dsp_program_bytes, rom_file);
    $fclose(rom_file);
    if (dsp_rom_bytes != 8192)
        $fatal(1, "short DSP ROM: %0d bytes", dsp_rom_bytes);

    repeat (8) @(negedge clk);
    reset = 0;

    // One second is long enough to pass early RAM/device self-tests while
    // still making this a quick software regression on a modern host.
    repeat (simulation_clocks) @(negedge clk);

    if (input_trace_file)
        $fatal(1, "simulation ended before the input trace was exhausted");

    if (sound_log_file) begin
        $fclose(sound_log_file);
        $display("Wrote TC0140SYT main accesses to %s", sound_log_path);
    end

    $display("FINAL fetch=%06h bus=%06h cycles=%0d sysctrl=%02h irq=%b halt=%b",
             debug_fetch_addr, debug_addr, debug_cycles, debug_sysctrl,
             debug_irq, debug_halted);
    $display("DSP pc=%04h ir=%04h instructions=%0d illegal=%0d",
             debug_dsp_pc, debug_dsp_ir, debug_dsp_instructions,
             debug_dsp_illegal);
    $display("DSP last=%04h:%04h flags=%03b GRW=%032h",
             debug_dsp_addr, debug_dsp_data, debug_dsp_flags,
             video_grw_regs);
    if (debug_cycles < 100) $fatal(1, "68000 made too little progress");
    if (debug_fault)
        $fatal(1, "sticky fault %06h at cycle %0d", debug_fault_addr,
               debug_fault_cycles);

    for (vco_region = 0; vco_region < 11; vco_region = vco_region + 1)
        vco_nonzero[vco_region] = 0;
    for (vco_scan = 0; vco_scan < 17'h10808; vco_scan = vco_scan + 1) begin
        if (vco_memory_word(vco_scan[16:0]) != 0) begin
            if (vco_scan < 17'h00800) vco_region = 0;       // FG character low
            else if (vco_scan < 17'h01000) vco_region = 1;  // FG tilemap
            else if (vco_scan < 17'h06000) vco_region = 2;  // chain RAM 0
            else if (vco_scan < 17'h07000) vco_region = 3;  // BG0 tile numbers
            else if (vco_scan < 17'h08000) vco_region = 4;  // BG1 tile numbers
            else if (vco_scan < 17'h08800) vco_region = 5;  // FG character high
            else if (vco_scan < 17'h09000) vco_region = 6;  // unused
            else if (vco_scan < 17'h0e000) vco_region = 7;  // chain RAM 1
            else if (vco_scan < 17'h0f000) vco_region = 8;  // BG0 attributes
            else if (vco_scan < 17'h10000) vco_region = 9;  // BG1 attributes
            else vco_region = 10;                           // row/sprite/control
            vco_nonzero[vco_region] = vco_nonzero[vco_region] + 1;
        end
    end
    $display("VCO nonzero words: fgcharlo=%0d fgtile=%0d chain0=%0d bg0=%0d bg1=%0d fgcharhi=%0d unused=%0d chain1=%0d bg0attr=%0d bg1attr=%0d tail=%0d",
             vco_nonzero[0], vco_nonzero[1], vco_nonzero[2],
             vco_nonzero[3], vco_nonzero[4], vco_nonzero[5],
             vco_nonzero[6], vco_nonzero[7], vco_nonzero[8],
             vco_nonzero[9], vco_nonzero[10]);
    sprite_nonzero = 0;
    for (sprite_scan = 0; sprite_scan < 128; sprite_scan = sprite_scan + 1) begin
        if (vco_memory_word(17'h10200 + sprite_scan * 4 + 3) != 0) begin
            sprite_nonzero = sprite_nonzero + 1;
            $display("SPR %0d: %04h %04h %04h %04h",
                     sprite_scan,
                     vco_memory_word(17'h10200 + sprite_scan * 4),
                     vco_memory_word(17'h10200 + sprite_scan * 4 + 1),
                     vco_memory_word(17'h10200 + sprite_scan * 4 + 2),
                     vco_memory_word(17'h10200 + sprite_scan * 4 + 3));
        end
    end
    $display("Sprite descriptors with a chain pointer: %0d", sprite_nonzero);
    $display("Polygon renderer spans=%0d busy=%0d overflow=%0d missed=%0d pixel=%04h/%0d",
             polygon_span_count, polygon_busy, polygon_overflow,
             polygon_missed_lines,
             polygon_pixel, polygon_pixel_valid);
    $display("Polygon physical high-water=%0d overflow_events=%0d capacity=%0d",
             max_physical_span_count, polygon_overflow_events,
             polygon_renderer.SPAN_CAPACITY);
    $display("Polygon cadence copy=%0d fill=%0d while_busy=%0d already_pending=%0d busy_cycles=%0d line_writes_while_busy=%0d",
             flag_copy_events, flag_fill_events, flag_while_busy_events,
             flag_already_pending_events, parser_busy_cycles,
             line_writes_while_busy);
    $display("Polygon unread line-RAM write races=%0d",
             line_unread_write_races);
    $display("Palette writes=%0d low512=%0d flush_entries=%0d",
             palette_write_count, palette_low_write_count,
             palette_flush_fetches);
    $display("Framebuffer DMA writes=%0d erase=%0d copy=%0d while_busy=%0d",
             dma_write_count, dma_erase_events, dma_copy_events,
             dma_command_while_busy);
    if (simulation_clocks >= 300000000) begin
        if (debug_dsp_instructions < 1000)
            $fatal(1, "C25 made too little progress: %0d instructions",
                   debug_dsp_instructions);
        if (debug_dsp_illegal != 0)
            $fatal(1, "C25 executed %0d illegal opcodes", debug_dsp_illegal);
        if (dut.dsp_bootstrap_active)
            $fatal(1, "C25 never retired the shared-RAM bootstrap response");
        if (polygon_missed_lines != 0)
            $fatal(1, "polygon painter missed %0d line deadlines",
                   polygon_missed_lines);
    end
    if (simulation_clocks >= 1000000000 && polygon_span_count == 0)
        $fatal(1, "C25 did not publish a polygon span list");
    if (simulation_clocks >= 1000000000 && line_unread_write_races != 0)
        $fatal(1, "%0d unread polygon line-RAM write races",
               line_unread_write_races);
    if (simulation_clocks >= 1000000000 && polygon_overflow)
        $fatal(1, "polygon span store overflowed");
    if ($value$plusargs("LINE_DUMP=%s", line_dump_path)) begin
        $writememh(line_dump_path, dut.line_ram.g_dual.mem);
        $display("Wrote DSP line RAM to %s", line_dump_path);
    end
    if ($value$plusargs("MAIN_DUMP=%s", main_dump_path)) begin
        $writememh($sformatf("%s-hi.hex", main_dump_path),
                   dut.main_ram.g_single.mem_hi);
        $writememh($sformatf("%s-lo.hex", main_dump_path),
                   dut.main_ram.g_single.mem_lo);
        $display("Wrote main RAM byte planes to %s-[hi,lo].hex",
                 main_dump_path);
    end
    if ($value$plusargs("PALETTE_DUMP=%s", palette_dump_path)) begin
        $writememh(palette_dump_path, dut.palette_ram.g_dual.mem);
        $display("Wrote palette RAM to %s", palette_dump_path);
    end
    if ($value$plusargs("GRADIENT_DUMP=%s", gradient_dump_path)) begin
        $writememh($sformatf("%s-low.hex", gradient_dump_path),
                   dut.gradient_low_ram.g_dual.mem);
        $writememh($sformatf("%s-high.hex", gradient_dump_path),
                   dut.gradient_high_ram.g_dual.mem);
        $display("Wrote gradient RAM planes to %s-[low,high].hex",
                 gradient_dump_path);
    end
    if ($value$plusargs("VCO_DUMP=%s", vco_dump_path)) begin
        vco_dump_handle = $fopen(vco_dump_path, "w");
        if (!vco_dump_handle)
            $fatal(1, "cannot create VCO dump %s", vco_dump_path);
        for (vco_scan = 0; vco_scan < 17'h10800; vco_scan = vco_scan + 1)
            $fdisplay(vco_dump_handle, "%04h",
                      vco_memory_word(vco_scan[16:0]));
        $fclose(vco_dump_handle);
        $display("Wrote TC0080VCO RAM to %s", vco_dump_path);
    end
    if (sound_lane_mismatches != 0)
        $fatal(1, "TC0140SYT writes used the wrong 68000 data nibble");
    $display("PASS tb_main sound_accesses=%0d sound_writes=%0d",
             sound_main_accesses, sound_main_writes);
    $finish;
end
endmodule
