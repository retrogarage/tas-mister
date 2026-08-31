`timescale 1ns/1ps

// Real-scene scanline budget regression. It replays a TC0080VCO RAM snapshot
// from Top Landing attract mode and varies the graphics-ROM response latency.
module tb_video_budget;
reg clk = 1'b0;
always #5 clk = ~clk;
reg reset = 1'b1;

wire [16:0] vco_addr;
reg [15:0] vco_data = 16'd0;
reg [15:0] vco_memory [0:67591];
wire gfx_req;
wire [19:0] gfx_addr;
wire gfx_ack;
wire [63:0] gfx_data;
integer gfx_delay = 2;
wire [28:0] ddram_addr;
wire [7:0] ddram_burstcnt;
wire ddram_rd;
wire ddram_we;
wire [63:0] ddram_din;
wire [7:0] ddram_be;
reg ddram_ready = 1'b0;
reg ddram_pending = 1'b0;
integer ddram_countdown = 0;
integer cycle_count;
integer max_builder_clocks = 0;
integer current_builder_clocks = 0;
integer completed_builds = 0;
integer first_visible_misses = 0;
integer long_builds_printed = 0;
integer warm_builder_clocks = 0;
integer warm_misses_start = 0;
integer state_clocks [0:31];
integer current_state_clocks [0:31];
integer max_state_clocks [0:31];
integer state_index;
integer gfx_requests = 0;
integer ddram_reads = 0;
integer background_stress = 0;
integer audio_acks = 0;
integer audio_wait_clocks = 0;
integer max_audio_wait_clocks = 0;
integer audio_gap_clocks = 0;
integer audio_burst_remaining = 0;
integer fixture_handle;
string vco_path;
reg audio_req = 1'b0;
reg [23:0] audio_addr = 24'h200000;
wire audio_ack;
wire ddr_background_safe;

tas_video dut (
    .clk(clk), .reset(reset), .rom_loaded(1'b1), .download_active(1'b0),
    .throttle_overlay_enable(1'b0),
    .throttle_counter(12'd0),
    .stick_x_counter(12'd0), .stick_y_counter(12'd0),
    .vco_addr(vco_addr), .vco_data(vco_data),
    .palette_addr(), .palette_data(16'd0),
    .gradient_addr(), .gradient_low(16'd0), .gradient_high(16'd0),
    .grw_regs(128'd0), .gradbank(1'b0),
    .bg0_scrollx(10'd0), .bg0_scrolly(10'd0), .bg0_zoom(16'h3f7f),
    .bg1_scrollx(10'd0), .bg1_scrolly(10'd0), .bg1_zoom(16'h3f7f),
    .dsp_flag_strobe(3'd0),
    .dma_fb_erase_strobe(1'b0), .dma_fb_copy_strobe(1'b0),
    .line_req(), .line_addr(),
    .line_ack(1'b0), .line_data(16'd0),
    .gfx_req(gfx_req), .gfx_addr(gfx_addr),
    .gfx_ack(gfx_ack), .gfx_data(gfx_data),
    .ce_pix(), .hblank(), .vblank(), .hsync(), .vsync(),
    .red(), .green(), .blue(), .debug_gradient(), .debug_timing(),
    .ddr_background_safe(ddr_background_safe),
    .polygon_hold()
);

tas_ddr_rom rom_cache (
    .clk(clk), .reset(reset), .background_safe(ddr_background_safe),
    .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_data(8'd0),
    .ioctl_wait(), .cpu_req(1'b0), .cpu_addr(24'd0),
    .cpu_ack(), .cpu_data(),
    .gfx_req(gfx_req), .gfx_addr(gfx_addr),
    .gfx_ack(gfx_ack), .gfx_data(gfx_data),
    .audio_req(audio_req), .audio_addr(audio_addr),
    .audio_ack(audio_ack), .audio_data(),
    .debug_wr_req(1'b0), .debug_wr_addr(28'd0),
    .debug_wr_data(64'd0), .debug_wr_ack(),
    .debug_cpu_blocked_clocks(), .debug_cpu_unsafe_cache_hits(),
    .DDRAM_BUSY(1'b0), .DDRAM_DOUT(64'h1111111111111111),
    .DDRAM_DOUT_READY(ddram_ready), .DDRAM_BURSTCNT(ddram_burstcnt),
    .DDRAM_ADDR(ddram_addr), .DDRAM_DIN(ddram_din),
    .DDRAM_BE(ddram_be), .DDRAM_RD(ddram_rd), .DDRAM_WE(ddram_we)
);

always @(posedge clk) begin
    vco_data <= vco_memory[vco_addr];
    ddram_ready <= 1'b0;
    if (ddram_rd && !ddram_pending) begin
        ddram_pending <= 1'b1;
        ddram_countdown <= gfx_delay;
    end else if (ddram_pending && ddram_countdown != 0) begin
        ddram_countdown <= ddram_countdown - 1;
    end else if (ddram_pending) begin
        ddram_ready <= 1'b1;
        ddram_pending <= 1'b0;
    end

    if (reset) begin
        audio_req <= 1'b0;
        audio_addr <= 24'h200000;
        audio_acks <= 0;
        audio_wait_clocks <= 0;
        max_audio_wait_clocks <= 0;
        audio_gap_clocks <= 0;
        audio_burst_remaining <= 0;
    end else if (background_stress != 0) begin
        if (audio_ack) begin
            if (audio_wait_clocks > max_audio_wait_clocks)
                max_audio_wait_clocks <= audio_wait_clocks;
            audio_wait_clocks <= 0;
            if (background_stress == 1) begin
                if (audio_burst_remaining > 1)
                    audio_burst_remaining <= audio_burst_remaining - 1;
                else begin
                    audio_burst_remaining <= 0;
                    audio_gap_clocks <= 4096;
                end
            end else begin
                audio_gap_clocks <= 4096;
            end
            audio_req <= 1'b0;
            audio_addr <= audio_addr + 24'd8;
            audio_acks <= audio_acks + 1;
        end else if (audio_req) begin
            audio_wait_clocks <= audio_wait_clocks + 1;
        end else if (!dut.video_cache_ready) begin
            // Start pressure only after the frame caches are populated.
        end else if (audio_gap_clocks != 0) begin
            audio_gap_clocks <= audio_gap_clocks - 1;
        end else if (!audio_req) begin
            if (background_stress == 1 && audio_burst_remaining == 0)
                audio_burst_remaining <= 8;
            audio_req <= 1'b1;
        end
    end
end

initial begin
    if (!$value$plusargs("VCO=%s", vco_path))
        vco_path = "tmp/mame-vco-35.hex";
    void'($value$plusargs("GFX_DELAY=%d", gfx_delay));
    void'($value$plusargs("BACKGROUND_STRESS=%d", background_stress));
    fixture_handle = $fopen(vco_path, "r");
    if (!fixture_handle)
        $fatal(1, "cannot open required VCO fixture %s", vco_path);
    $fclose(fixture_handle);
    $readmemh(vco_path, vco_memory);
    for (state_index = 0; state_index < 32; state_index = state_index + 1)
    begin
        state_clocks[state_index] = 0;
        current_state_clocks[state_index] = 0;
        max_state_clocks[state_index] = 0;
    end
    repeat (4) @(negedge clk);
    reset = 1'b0;
    // Two frames load the descriptor snapshot and then exercise every visible
    // line with the real dashboard/world sprite population.
    for (cycle_count = 0; cycle_count < 1800000; cycle_count = cycle_count + 1) begin
        @(negedge clk);
        if (dut.builder_state != dut.B_IDLE) begin
            current_builder_clocks = current_builder_clocks + 1;
            state_clocks[dut.builder_state] =
                state_clocks[dut.builder_state] + 1;
            current_state_clocks[dut.builder_state] =
                current_state_clocks[dut.builder_state] + 1;
        end else if (current_builder_clocks != 0) begin
            if (current_builder_clocks > max_builder_clocks) begin
                max_builder_clocks = current_builder_clocks;
                for (state_index = 0; state_index < 32;
                     state_index = state_index + 1)
                    max_state_clocks[state_index] =
                        current_state_clocks[state_index];
            end
            if (cycle_count > 1200000 &&
                current_builder_clocks > warm_builder_clocks)
                warm_builder_clocks = current_builder_clocks;
            if (current_builder_clocks > 1280 && long_builds_printed < 16) begin
                $display("LONG target_y=%0d clocks=%0d", dut.target_y,
                         current_builder_clocks);
                long_builds_printed = long_builds_printed + 1;
            end
            completed_builds = completed_builds + 1;
            current_builder_clocks = 0;
            for (state_index = 0; state_index < 32;
                 state_index = state_index + 1)
                current_state_clocks[state_index] = 0;
        end
        if (cycle_count == 512000)
            first_visible_misses = dut.builder_missed_lines;
        if (cycle_count == 1200000)
            warm_misses_start = dut.builder_missed_lines;
        if (gfx_req && !rom_cache.gfx_ack)
            gfx_requests = gfx_requests + 1;
        if (ddram_rd && !ddram_pending)
            ddram_reads = ddram_reads + 1;
    end
    $display("BUDGET gfx_delay=%0d background_stress=%0d missed_lines=%0d warm_misses=%0d first_visible=%0d max_clocks=%0d warm_max=%0d builds=%0d final_state=%0d audio_acks=%0d max_audio_wait=%0d",
             gfx_delay, background_stress, dut.builder_missed_lines,
             dut.builder_missed_lines - warm_misses_start,
             first_visible_misses, max_builder_clocks, warm_builder_clocks,
             completed_builds, dut.builder_state, audio_acks,
             max_audio_wait_clocks);
    $write("STATE");
    for (state_index = 1; state_index < 32; state_index = state_index + 1)
        if (state_clocks[state_index] != 0)
            $write(" %0d:%0d", state_index, state_clocks[state_index]);
    $display(" gfx_wait_clocks=%0d ddram_reads=%0d", gfx_requests,
             ddram_reads);
    $write("MAXSTATE");
    for (state_index = 1; state_index < 32; state_index = state_index + 1)
        if (max_state_clocks[state_index] != 0)
            $write(" %0d:%0d", state_index, max_state_clocks[state_index]);
    $display("");
    if (dut.builder_missed_lines != warm_misses_start)
        $fatal(1, "VCO renderer exceeded one or more scanline budgets");
    if (background_stress != 0 && audio_acks < 100)
        $fatal(1, "background DDR client starved: %0d acknowledgements",
               audio_acks);
    if (background_stress != 0 && max_audio_wait_clocks > 128)
        $fatal(1, "background audio latency exceeded look-ahead budget: %0d",
               max_audio_wait_clocks);
    $finish;
end
endmodule
