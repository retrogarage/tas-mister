`timescale 1ns/1ps

module tb_sound;
reg clk = 1'b0;
always #15.625 clk = ~clk;

reg reset = 1'b1;
reg main_cs = 1'b0;
reg main_wr = 1'b0;
reg main_port = 1'b0;
reg [3:0] main_din = 4'd0;
wire [3:0] main_dout;
wire sample_req;
wire [23:0] sample_addr;
reg sample_ack = 1'b0;
reg [63:0] sample_data = 64'hffffffffffffffff;
wire signed [15:0] audio_left;
wire signed [15:0] audio_right;
wire [15:0] debug_z80_addr;
wire [2:0] debug_rom_bank;
wire debug_reset_n;
wire debug_z80_halted;
wire [31:0] debug_z80_m1;
wire [31:0] debug_ym_writes;
wire [15:0] debug_sample_a_misses;
wire [15:0] debug_sample_b_misses;
wire [15:0] debug_sample_underruns;
reg sample_pending = 1'b0;
integer sample_delay = 0;
integer rom_file;
integer rom_bytes;
integer adpcma_bytes;
integer adpcmb_bytes;
integer cycle_count;
longint unsigned simulation_cycles = 0;
integer ym_bus_writes = 0;
integer m1_bus_cycles = 0;
integer ym_key_on_writes = 0;
integer ym_key_on_events = 0;
integer ym_trace_count = 0;
integer ym_writes_before_command;
integer adpcma_line_requests = 0;
integer adpcma_requests_before_key = 0;
integer adpcmb_line_requests = 0;
integer adpcmb_requests_before_key = 0;
integer adpcmb_misses_before_key = 0;
longint unsigned audio_abs_sum = 0;
longint unsigned adpcma_abs_sum = 0;
reg measure_audio = 0;
reg old_ym_write_bus = 0;
reg old_m1_n = 1;
reg old_sample_req = 0;
reg trace_ym = 0;
reg saw_adpcma_channel_0 = 0;
reg saw_adpcma_channel_1 = 0;
integer configured_sample_delay = 3;
integer configured_capture_cycles = 10000000;
integer pcm_file = 0;
integer ym_log_file = 0;
integer main_trace_file = 0;
integer pcm_samples = 0;
integer replay_accesses = 0;
reg capture_pcm = 0;
reg rom_audio_only = 0;
reg trace_replay = 0;
reg old_snd_sample = 0;
reg old_fm_key_update = 0;
reg old_adpcma_key_update = 0;
reg old_adpcmb_command_update = 0;
reg [7:0] ym_addr_a = 0;
reg [7:0] ym_addr_b = 0;
string rom_path;
string pcm_path;
string ym_log_path;
string main_trace_path;
longint unsigned replay_cycle;
longint unsigned previous_replay_cycle;
longint unsigned replay_gap;
integer replay_port;
integer replay_wr;
reg [3:0] replay_data;
reg [3:0] replay_expected_dout;
reg [23:0] replay_pc;
integer replay_fields;
reg [7:0] sound_image [0:65535];
reg [7:0] adpcma_image [0:655359];
reg [7:0] adpcmb_image [0:131071];

tas_sound dut (
    .clk(clk), .reset(reset),
    .main_cs(main_cs), .main_wr(main_wr), .main_port(main_port),
    .main_din(main_din), .main_dout(main_dout),
    .sample_req(sample_req), .sample_addr(sample_addr),
    .sample_ack(sample_ack), .sample_data(sample_data),
    .audio_left(audio_left), .audio_right(audio_right),
    .debug_z80_addr(debug_z80_addr), .debug_rom_bank(debug_rom_bank),
    .debug_reset_n(debug_reset_n), .debug_z80_halted(debug_z80_halted),
    .debug_z80_m1(debug_z80_m1),
    .debug_ym_writes(debug_ym_writes),
    .debug_sample_a_misses(debug_sample_a_misses),
    .debug_sample_b_misses(debug_sample_b_misses),
    .debug_sample_underruns(debug_sample_underruns)
);

task main_write(input port, input [3:0] data);
begin
    @(negedge clk);
    main_port = port;
    main_din = data;
    main_wr = 1'b1;
    main_cs = 1'b1;
    @(negedge clk);
    main_cs = 1'b0;
end
endtask

task main_read(input port);
begin
    @(negedge clk);
    main_port = port;
    main_din = 4'd0;
    main_wr = 1'b0;
    main_cs = 1'b1;
    @(negedge clk);
    main_cs = 1'b0;
end
endtask

// Replay the main CPU's TC0140SYT access trace.  The first access is
// rebased to the start of this test; all later gaps retain their exact 32 MHz
// system-clock spacing.  Main reads retain index/status side effects while
// their data comes from the real Z80 rather than the tracing test stub.
task replay_main_accesses;
begin
    previous_replay_cycle = 0;
    while (!$feof(main_trace_file)) begin
        replay_fields = $fscanf(main_trace_file, "%d %d %d %h %h %h\n",
                                replay_cycle, replay_wr, replay_port,
                                replay_data, replay_expected_dout, replay_pc);
        if (replay_fields == 6) begin
            if (replay_wr < 0 || replay_wr > 1)
                $fatal(1, "invalid main trace write flag %0d", replay_wr);
            if (replay_port < 0 || replay_port > 1)
                $fatal(1, "invalid main trace port %0d", replay_port);
            if (replay_accesses != 0) begin
                if (replay_cycle <= previous_replay_cycle)
                    $fatal(1, "non-monotonic main trace cycle %0d after %0d",
                           replay_cycle, previous_replay_cycle);
                replay_gap = replay_cycle - previous_replay_cycle;
                // main_write itself places consecutive access edges two
                // clocks apart, so wait only for the remaining trace gap.
                if (replay_gap > 2)
                    repeat (replay_gap - 2) @(negedge clk);
            end
            if (replay_wr)
                main_write(replay_port[0], replay_data);
            else
                main_read(replay_port[0]);
            previous_replay_cycle = replay_cycle;
            replay_accesses = replay_accesses + 1;
        end else if (!$feof(main_trace_file)) begin
            $fatal(1, "invalid main trace record after %0d accesses",
                   replay_accesses);
        end
    end
    if (replay_accesses == 0)
        $fatal(1, "main trace contains no TC0140SYT accesses");
    $fclose(main_trace_file);
end
endtask

task main_command(input [3:0] mailbox_index, input [7:0] command_byte);
begin
    main_write(1'b0, mailbox_index);
    main_write(1'b1, command_byte[3:0]);
    main_write(1'b1, command_byte[7:4]);
end
endtask

// Freeze only the Z80 clock enable while issuing a focused register sequence
// over the same YM2610 bus.  The real-ROM command seam is exercised first;
// this sequence guarantees two concurrent ADPCM-A streams while retaining
// the driver's own activity during the subsequent integrated measurement.
task direct_ym_write(input [1:0] port, input [7:0] value);
begin
    force dut.z80_addr = 16'he000 | {14'd0, port};
    force dut.z80_dout = value;
    force dut.z80_mreq_n = 1'b0;
    force dut.z80_wr_n = 1'b0;
    force dut.z80_rfsh_n = 1'b1;
    repeat (16) @(negedge clk);
    release dut.z80_addr;
    release dut.z80_dout;
    release dut.z80_mreq_n;
    release dut.z80_wr_n;
    release dut.z80_rfsh_n;
    repeat (512) @(negedge clk);
end
endtask

task adpcma_register_write(input [7:0] register, input [7:0] value);
begin
    direct_ym_write(2'd2, register);
    direct_ym_write(2'd3, value);
end
endtask

task adpcmb_register_write(input [7:0] register, input [7:0] value);
begin
    direct_ym_write(2'd0, register);
    direct_ym_write(2'd1, value);
end
endtask

task key_two_adpcma_channels;
begin
    while (!dut.z80_wr_n || !dut.z80_rd_n || !dut.z80_mreq_n)
        @(negedge clk);
    force dut.ce_4m = 1'b0;
    repeat (16) @(negedge clk);
    adpcma_register_write(8'h01, 8'h00); // Total level.
    adpcma_register_write(8'h08, 8'hdf); // Ch 0: L+R, full level.
    adpcma_register_write(8'h09, 8'hdf); // Ch 1: L+R, full level.
    adpcma_register_write(8'h10, 8'h00); // Ch 0 start = $00000.
    adpcma_register_write(8'h18, 8'h00);
    adpcma_register_write(8'h20, 8'h01); // Ch 0 end = $001ff.
    adpcma_register_write(8'h28, 8'h00);
    adpcma_register_write(8'h11, 8'h10); // Ch 1 start = $01000.
    adpcma_register_write(8'h19, 8'h00);
    adpcma_register_write(8'h21, 8'h11); // Ch 1 end = $011ff.
    adpcma_register_write(8'h29, 8'h00);
    adpcma_register_write(8'h00, 8'h03); // Key on channels 0 and 1.
    repeat (16) @(negedge clk);
    release dut.ce_4m;
end
endtask

task key_adpcmb_stream;
begin
    while (!dut.z80_wr_n || !dut.z80_rd_n || !dut.z80_mreq_n)
        @(negedge clk);
    force dut.ce_4m = 1'b0;
    repeat (16) @(negedge clk);
    adpcmb_register_write(8'h11, 8'hc0); // L+R output.
    adpcmb_register_write(8'h12, 8'h00); // Start = $000000.
    adpcmb_register_write(8'h13, 8'h00);
    adpcmb_register_write(8'h14, 8'h01); // End = $0001ff.
    adpcmb_register_write(8'h15, 8'h00);
    adpcmb_register_write(8'h19, 8'hff); // Maximum Delta-N.
    adpcmb_register_write(8'h1a, 8'hff);
    adpcmb_register_write(8'h1b, 8'hff); // Full output level.
    adpcmb_register_write(8'h10, 8'h80); // Start, no repeat.
    repeat (16) @(negedge clk);
    release dut.ce_4m;
end
endtask

function automatic [15:0] abs16(input signed [15:0] value);
begin
    abs16 = value[15] ? (~value + 1'b1) : value;
end
endfunction

wire ym_write_bus = !dut.ym_cs_n && !dut.z80_wr_n;
always @(posedge clk) begin
    simulation_cycles <= simulation_cycles + 1'd1;
    old_ym_write_bus <= ym_write_bus;
    old_m1_n <= dut.z80_m1_n;
    old_sample_req <= sample_req;
    old_snd_sample <= dut.ym2610.snd_sample;
    old_fm_key_update <= dut.ym2610.u_jt12.u_mmr.up_keyon;
    old_adpcma_key_update <= dut.ym2610.u_jt12.u_mmr.up_aon;
    old_adpcmb_command_update <= dut.ym2610.u_jt12.u_mmr.acmd_up_b;
    // Observe accepted synthesizer commands independently of the Z80 bus
    // edge monitor.  This also covers the focused register injection, whose
    // frozen TV80 bus can remain active across adjacent forced writes.
    if (dut.ym2610.u_jt12.u_mmr.up_keyon && !old_fm_key_update &&
        |dut.ym2610.u_jt12.u_mmr.op_din[7:4])
        ym_key_on_events <= ym_key_on_events + 1;
    if (dut.ym2610.u_jt12.u_mmr.up_aon && !old_adpcma_key_update &&
        !dut.ym2610.u_jt12.u_mmr.aon_a[7] &&
        |dut.ym2610.u_jt12.u_mmr.aon_a[5:0])
        ym_key_on_events <= ym_key_on_events + 1;
    if (dut.ym2610.u_jt12.u_mmr.acmd_up_b &&
        !old_adpcmb_command_update &&
        dut.ym2610.u_jt12.u_mmr.acmd_on_b)
        ym_key_on_events <= ym_key_on_events + 1;
    if (capture_pcm && dut.ym2610.snd_sample && !old_snd_sample) begin
        // Native JT10 output is one signed little-endian stereo frame every
        // 24 operator/channel slots after the YM2610's fixed /6 FM
        // prescaler: 32 MHz / (4 * 6 * 24) = 55555 5/9 frames/s.
        $fwrite(pcm_file, "%c%c%c%c", audio_left[7:0], audio_left[15:8],
                audio_right[7:0], audio_right[15:8]);
        pcm_samples <= pcm_samples + 1;
    end
    if (old_m1_n && !dut.z80_m1_n)
        m1_bus_cycles <= m1_bus_cycles + 1;
    if (ym_write_bus && !old_ym_write_bus) begin
        ym_bus_writes <= ym_bus_writes + 1;
        if (ym_log_file)
            $fwrite(ym_log_file, "%0d %0d %02h %04h\n",
                    simulation_cycles, dut.z80_addr[1:0], dut.z80_dout,
                    debug_z80_addr);
        if (trace_ym && ym_trace_count < 96) begin
            $display("YM write=%0d port=%0d data=%02h pc=%04h",
                     ym_bus_writes, dut.z80_addr[1:0], dut.z80_dout,
                     debug_z80_addr);
            ym_trace_count <= ym_trace_count + 1;
        end
        case (dut.z80_addr[1:0])
            2'd0: ym_addr_a <= dut.z80_dout;
            2'd1: begin
                // FM starts only when at least one operator bit is set.
                // A register-28 write with a zero high nibble is key-off.
                if (ym_addr_a == 8'h28 && |dut.z80_dout[7:4])
                    ym_key_on_writes <= ym_key_on_writes + 1;
                // ADPCM-B register 10 bit 7 is playback start.  Values 01
                // and 00 are reset/stop commands, not audible key-ons.
                if (ym_addr_a == 8'h10 && dut.z80_dout[7])
                    ym_key_on_writes <= ym_key_on_writes + 1;
            end
            2'd2: ym_addr_b <= dut.z80_dout;
            2'd3: begin
                // ADPCM-A register 00 uses bit 7 to select key-off.  Count
                // only key-on commands that select at least one channel.
                if (ym_addr_b == 8'h00 && !dut.z80_dout[7] &&
                    |dut.z80_dout[5:0])
                    ym_key_on_writes <= ym_key_on_writes + 1;
            end
            default: begin end
        endcase
    end
    if (sample_req && !old_sample_req &&
        sample_addr >= 24'h200000 && sample_addr < 24'h2a0000)
        adpcma_line_requests <= adpcma_line_requests + 1;
    if (sample_req && !old_sample_req &&
        sample_addr >= 24'h2a0000 && sample_addr < 24'h2c0000)
        adpcmb_line_requests <= adpcmb_line_requests + 1;
    if (!dut.adpcma_roe_n) begin
        if (dut.adpcma_addr < 20'h00200)
            saw_adpcma_channel_0 <= 1'b1;
        if (dut.adpcma_addr >= 20'h01000 &&
            dut.adpcma_addr < 20'h01200)
            saw_adpcma_channel_1 <= 1'b1;
    end
    if (measure_audio && dut.ce_8m) begin
        audio_abs_sum <= audio_abs_sum + abs16(audio_left) +
            abs16(audio_right);
        adpcma_abs_sum <= adpcma_abs_sum +
            abs16(dut.ym2610.u_jt12.adpcmA_l) +
            abs16(dut.ym2610.u_jt12.adpcmA_r);
    end
end

always @(posedge clk) begin
    sample_ack <= 1'b0;
    if (sample_req && !sample_pending) begin
        sample_pending <= 1'b1;
        sample_delay <= configured_sample_delay;
        if (sample_addr >= 24'h0c0000 && sample_addr < 24'h0d0000) begin
            // Keep instruction-ROM service representative while independently
            // stressing the fixed-latency ADPCM interface.
            sample_delay <= 3;
            sample_data <= {
                sound_image[sample_addr - 24'h0c0000 + 7],
                sound_image[sample_addr - 24'h0c0000 + 6],
                sound_image[sample_addr - 24'h0c0000 + 5],
                sound_image[sample_addr - 24'h0c0000 + 4],
                sound_image[sample_addr - 24'h0c0000 + 3],
                sound_image[sample_addr - 24'h0c0000 + 2],
                sound_image[sample_addr - 24'h0c0000 + 1],
                sound_image[sample_addr - 24'h0c0000]
            };
        end
        else if (sample_addr >= 24'h200000 && sample_addr < 24'h2a0000)
            sample_data <= {
                adpcma_image[sample_addr - 24'h200000 + 7],
                adpcma_image[sample_addr - 24'h200000 + 6],
                adpcma_image[sample_addr - 24'h200000 + 5],
                adpcma_image[sample_addr - 24'h200000 + 4],
                adpcma_image[sample_addr - 24'h200000 + 3],
                adpcma_image[sample_addr - 24'h200000 + 2],
                adpcma_image[sample_addr - 24'h200000 + 1],
                adpcma_image[sample_addr - 24'h200000]
            };
        else if (sample_addr >= 24'h2a0000 && sample_addr < 24'h2c0000)
            sample_data <= {
                adpcmb_image[sample_addr - 24'h2a0000 + 7],
                adpcmb_image[sample_addr - 24'h2a0000 + 6],
                adpcmb_image[sample_addr - 24'h2a0000 + 5],
                adpcmb_image[sample_addr - 24'h2a0000 + 4],
                adpcmb_image[sample_addr - 24'h2a0000 + 3],
                adpcmb_image[sample_addr - 24'h2a0000 + 2],
                adpcmb_image[sample_addr - 24'h2a0000 + 1],
                adpcmb_image[sample_addr - 24'h2a0000]
            };
        else
            sample_data <= 64'hffffffffffffffff;
    end else if (sample_pending && sample_delay != 0) begin
        sample_delay <= sample_delay - 1;
    end else if (sample_pending) begin
        sample_ack <= 1'b1;
        sample_pending <= 1'b0;
    end
end

initial begin
    trace_ym = $test$plusargs("YM_TRACE");
    rom_audio_only = $test$plusargs("ROM_AUDIO_ONLY");
    if ($value$plusargs("MAIN_TRACE=%s", main_trace_path)) begin
        trace_replay = 1'b1;
        main_trace_file = $fopen(main_trace_path, "r");
        if (!main_trace_file)
            $fatal(1, "cannot open main sound trace: %s", main_trace_path);
    end
    if (!$value$plusargs("SAMPLE_DELAY=%d", configured_sample_delay))
        configured_sample_delay = 3;
    if (!$value$plusargs("CAPTURE_CYCLES=%d", configured_capture_cycles))
        configured_capture_cycles = 10000000;
    if ($value$plusargs("PCM=%s", pcm_path)) begin
        pcm_file = $fopen(pcm_path, "wb");
        if (!pcm_file) $fatal(1, "cannot open PCM capture: %s", pcm_path);
    end
    if ($value$plusargs("YM_LOG=%s", ym_log_path)) begin
        ym_log_file = $fopen(ym_log_path, "w");
        if (!ym_log_file) $fatal(1, "cannot open YM trace: %s", ym_log_path);
    end
    if (!$value$plusargs("ROM=%s", rom_path))
        rom_path = "roms/topland.rom";
    rom_file = $fopen(rom_path, "rb");
    if (!rom_file) $fatal(1, "cannot open Top Landing ROM image");
    if ($fseek(rom_file, 32'h000c0000, 0))
        $fatal(1, "cannot seek to Z80 ROM");
    rom_bytes = $fread(sound_image, rom_file);
    $fclose(rom_file);
    if (rom_bytes != 65536)
        $fatal(1, "short Z80 ROM: %0d bytes", rom_bytes);
    rom_file = $fopen(rom_path, "rb");
    if ($fseek(rom_file, 32'h00200000, 0))
        $fatal(1, "cannot seek to ADPCM-A ROM");
    adpcma_bytes = $fread(adpcma_image, rom_file);
    if ($fseek(rom_file, 32'h002a0000, 0))
        $fatal(1, "cannot seek to ADPCM-B ROM");
    adpcmb_bytes = $fread(adpcmb_image, rom_file);
    $fclose(rom_file);
    if (adpcma_bytes != 655360 || adpcmb_bytes != 131072)
        $fatal(1, "short ADPCM ROMs: %0d/%0d", adpcma_bytes, adpcmb_bytes);

    // The MRA copies index 0 directly to DDR. Model that transport through the
    // request responder above rather than an ioctl stream that hardware never
    // receives.
    repeat (16) @(negedge clk);
    reset = 1'b0;
    ym_writes_before_command = debug_ym_writes;
    capture_pcm = pcm_file != 0;

    if (trace_replay) begin
        measure_audio = 1;
        replay_main_accesses();
    end else begin
        main_write(1'b0, 4'd4);
        main_write(1'b1, 4'd0);
        if (!debug_reset_n)
            $fatal(1, "sound CPU reset was not released");

        // Let the original driver initialize and enter its command-poll loop.
        for (cycle_count = 0; cycle_count < 2000000;
             cycle_count = cycle_count + 1)
            @(negedge clk);

        main_command(4'd0, 8'hec);
        for (cycle_count = 0; cycle_count < 3000000;
             cycle_count = cycle_count + 1)
            @(negedge clk);
        if (dut.sound_status[0])
            $fatal(1, "Z80 did not consume command EC");
        main_command(4'd0, 8'hef);
        for (cycle_count = 0; cycle_count < 3000000 && dut.sound_status[0];
             cycle_count = cycle_count + 1)
            @(negedge clk);
        if (dut.sound_status[0])
            $fatal(1, "Z80 did not consume command EF");
        adpcma_requests_before_key = adpcma_line_requests;
        adpcmb_requests_before_key = adpcmb_line_requests;
        adpcmb_misses_before_key = debug_sample_b_misses;
        if (!rom_audio_only) begin
            key_two_adpcma_channels();
            key_adpcmb_stream();
        end
        measure_audio = 1;
    end

    for (cycle_count = 0; cycle_count < configured_capture_cycles;
         cycle_count = cycle_count + 1)
        @(negedge clk);
    measure_audio = 0;
    capture_pcm = 0;
    if (pcm_file) $fclose(pcm_file);
    if (ym_log_file) $fclose(ym_log_file);
    if (!trace_replay && dut.sound_status[0])
        $fatal(1, "Z80 did not consume command EF");

    $display("SOUND pc=%04h bank=%0d halted=%b m1=%0d ym_writes=%0d key_on_writes=%0d key_on_events=%0d sample_miss=%0d/%0d line_fills=%0d/%0d underrun=%0d audio=%0d/%0d abs_sum=%0d adpcma_sum=%0d pcm_samples=%0d rom_only=%0d replay_accesses=%0d",
             debug_z80_addr, debug_rom_bank, debug_z80_halted,
             debug_z80_m1, debug_ym_writes, ym_key_on_writes,
             ym_key_on_events,
             debug_sample_a_misses,
             debug_sample_b_misses,
             adpcma_line_requests - adpcma_requests_before_key,
             adpcmb_line_requests - adpcmb_requests_before_key,
             debug_sample_underruns, audio_left, audio_right,
             audio_abs_sum, adpcma_abs_sum, pcm_samples, rom_audio_only,
             replay_accesses);
    if (debug_z80_m1 < 1000)
        $fatal(1, "Z80 made too little progress: %0d fetches", debug_z80_m1);
    if (debug_z80_m1 !== m1_bus_cycles)
        $fatal(1, "M1 counter=%0d independent bus cycles=%0d",
               debug_z80_m1, m1_bus_cycles);
    if (debug_ym_writes == 0)
        $fatal(1, "original sound program never wrote the YM2610");
    if (debug_ym_writes !== ym_bus_writes)
        $fatal(1, "YM counter=%0d independent bus writes=%0d",
               debug_ym_writes, ym_bus_writes);
    if (debug_ym_writes <= ym_writes_before_command)
        $fatal(1, "commands produced no new YM writes");
    if (!rom_audio_only && ym_key_on_events == 0)
        $fatal(1, "game/focused sequence produced no accepted key-on events");
    if (debug_sample_a_misses == 0 || debug_sample_b_misses == 0)
        $fatal(1, "sample caches were not initialized");
    if (!rom_audio_only && !trace_replay) begin
        if (!saw_adpcma_channel_0 || !saw_adpcma_channel_1)
            $fatal(1, "two independent ADPCM-A streams were not observed");
        if (adpcma_line_requests - adpcma_requests_before_key < 60 ||
            adpcma_line_requests - adpcma_requests_before_key > 200)
            $fatal(1, "unexpected ADPCM-A line-fill count: %0d",
                   adpcma_line_requests - adpcma_requests_before_key);
        if (adpcmb_line_requests - adpcmb_requests_before_key < 40 ||
            adpcmb_line_requests - adpcmb_requests_before_key > 100)
            $fatal(1, "unexpected ADPCM-B line-fill count: %0d",
                   adpcmb_line_requests - adpcmb_requests_before_key);
        if (debug_sample_b_misses != adpcmb_misses_before_key)
            $fatal(1, "ADPCM-B stream demand misses advanced: %0d -> %0d",
                   adpcmb_misses_before_key, debug_sample_b_misses);
    end
    if (debug_sample_underruns != 0)
        $fatal(1, "sample cache underruns: %0d", debug_sample_underruns);
    if (audio_abs_sum == 0)
        $fatal(1, "commands produced no integrated stereo audio");
    if (!rom_audio_only && !trace_replay && adpcma_abs_sum == 0)
        $fatal(1, "two sample streams produced no ADPCM-A contribution");
    if (pcm_file && pcm_samples == 0)
        $fatal(1, "PCM capture produced no frames");
    if (audio_left !== dut.ym_left || audio_right !== dut.ym_right)
        $fatal(1, "top-level audio is not a bit-exact JT10 stereo pass-through");
    $display("PASS tb_sound");
    $finish;
end
endmodule
