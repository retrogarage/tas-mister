`timescale 1ns/1ps

module tb_ddr_rom;
reg clk = 0;
always #25 clk = ~clk;

reg reset = 1;
reg background_safe = 1;
reg ioctl_wr = 0;
reg [26:0] ioctl_addr = 0;
reg [7:0] ioctl_data = 0;
wire ioctl_wait;
reg cpu_req = 0;
reg [23:0] cpu_addr = 0;
wire cpu_ack;
wire [15:0] cpu_data;
reg gfx_req = 0;
reg [19:0] gfx_addr = 0;
wire gfx_ack;
wire [63:0] gfx_data;
reg audio_req = 0;
reg [23:0] audio_addr = 0;
wire audio_ack;
wire [63:0] audio_data;
reg debug_wr_req = 0;
reg [27:0] debug_wr_addr = 0;
reg [63:0] debug_wr_data = 0;
wire debug_wr_ack;
wire [31:0] debug_cpu_blocked_clocks;
wire [31:0] debug_cpu_unsafe_cache_hits;
reg ddram_busy = 0;
reg [63:0] ddram_dout = 64'h00040000fcff0c00;
reg ddram_dout_ready = 0;
wire [7:0] ddram_burstcnt;
wire [28:0] ddram_addr;
wire [63:0] ddram_din;
wire [7:0] ddram_be;
wire ddram_rd;
wire ddram_we;
integer accepted_reads = 0;

// DDRAM_RD is a level-sensitive Avalon-MM command. With waitrequest low,
// every asserted clock is a distinct accepted command.
always @(posedge clk) begin
    if (ddram_rd && !ddram_busy)
        accepted_reads <= accepted_reads + 1;
end

tas_ddr_rom dut (
    .clk(clk), .reset(reset), .background_safe(background_safe),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_data(ioctl_data),
    .ioctl_wait(ioctl_wait),
    .cpu_req(cpu_req), .cpu_addr(cpu_addr), .cpu_ack(cpu_ack), .cpu_data(cpu_data),
    .gfx_req(gfx_req), .gfx_addr(gfx_addr), .gfx_ack(gfx_ack), .gfx_data(gfx_data),
    .audio_req(audio_req), .audio_addr(audio_addr),
    .audio_ack(audio_ack), .audio_data(audio_data),
    .debug_wr_req(debug_wr_req), .debug_wr_addr(debug_wr_addr),
    .debug_wr_data(debug_wr_data), .debug_wr_ack(debug_wr_ack),
    .debug_cpu_blocked_clocks(debug_cpu_blocked_clocks),
    .debug_cpu_unsafe_cache_hits(debug_cpu_unsafe_cache_hits),
    .DDRAM_BUSY(ddram_busy), .DDRAM_DOUT(ddram_dout),
    .DDRAM_DOUT_READY(ddram_dout_ready), .DDRAM_BURSTCNT(ddram_burstcnt),
    .DDRAM_ADDR(ddram_addr), .DDRAM_DIN(ddram_din), .DDRAM_BE(ddram_be),
    .DDRAM_RD(ddram_rd), .DDRAM_WE(ddram_we)
);

task request_word(input [23:0] address, input [15:0] expected);
begin
    @(negedge clk);
    cpu_addr = address;
    cpu_req = 1;
    while (!cpu_ack) @(negedge clk);
    if (cpu_data !== expected) begin
        $display("FAIL addr=%h data=%h expected=%h", address, cpu_data, expected);
        $fatal(1);
    end
    cpu_req = 0;
    @(negedge clk);
    if (cpu_ack) $fatal(1, "duplicate CPU acknowledgement at %h", address);
end
endtask

task request_audio_line(input [23:0] address, input [63:0] expected);
begin
    @(negedge clk);
    audio_addr = address;
    audio_req = 1;
    while (!audio_ack) @(negedge clk);
    if (audio_data !== expected)
        $fatal(1, "audio addr=%h data=%h expected=%h", address, audio_data, expected);
    audio_req = 0;
    @(negedge clk);
    if (audio_ack) $fatal(1, "duplicate audio acknowledgement at %h", address);
end
endtask

task request_gfx_line(input [19:0] address, input [63:0] expected);
begin
    @(negedge clk);
    gfx_addr = address;
    gfx_req = 1;
    while (!gfx_ack) @(negedge clk);
    if (gfx_data !== expected)
        $fatal(1, "gfx addr=%h data=%h expected=%h", address, gfx_data, expected);
    gfx_req = 0;
    @(negedge clk);
    if (gfx_ack) $fatal(1, "duplicate graphics acknowledgement at %h", address);
end
endtask

initial begin
    repeat (3) @(negedge clk);
    reset = 0;

    // First word misses the cache and must issue a DDR read.
    fork
        begin
            wait(ddram_rd);
            if (ddram_addr !== 29'h06000000) $fatal(1, "wrong DDR base: %h", ddram_addr);
            repeat (10) @(negedge clk);
            ddram_dout_ready = 1;
            @(negedge clk);
            ddram_dout_ready = 0;
        end
        request_word(24'h000000, 16'h000c);
    join
    if (accepted_reads !== 1)
        $fatal(1, "DDR read command was accepted %0d times", accepted_reads);

    // Same 64-bit line is served from cache with 68000 big-endian ordering.
    request_word(24'h000002, 16'hfffc);
    request_word(24'h000006, 16'h0400);

    // The gate protects physical DDR bandwidth, not the CPU's local line
    // cache. A hit must still complete while unsafe, whereas a miss must
    // remain pending without issuing a DDR command.
    background_safe = 0;
    request_word(24'h000002, 16'hfffc);
    if (debug_cpu_unsafe_cache_hits !== 1)
        $fatal(1, "unsafe CPU cache hit was not counted");
    @(negedge clk);
    cpu_addr = 24'h000008;
    cpu_req = 1;
    repeat (6) begin
        @(negedge clk);
        if (cpu_ack || ddram_rd)
            $fatal(1, "CPU miss escaped the background-safe gate");
    end
    cpu_req = 0;
    @(negedge clk);
    if (debug_cpu_blocked_clocks < 5)
        $fatal(1, "CPU background stall was not counted: %0d",
               debug_cpu_blocked_clocks);
    background_safe = 1;

    // A graphics tile row is returned as one aligned 64-bit DDR line from
    // the image's 0x100000 graphics-region offset.
    fork
        begin
            wait(ddram_rd);
            if (ddram_addr !== 29'h06020000)
                $fatal(1, "wrong graphics DDR address: %h", ddram_addr);
            repeat (5) @(negedge clk);
            ddram_dout_ready = 1;
            @(negedge clk);
            ddram_dout_ready = 0;
        end
        request_gfx_line(20'h00000, 64'h00040000fcff0c00);
    join
    if (accepted_reads !== 2)
        $fatal(1, "expected two accepted DDR reads, got %0d", accepted_reads);

    // Audio clients provide flat-image byte addresses and receive one aligned
    // line.  Give the stream its own hold/ack path so a level request cannot
    // be accepted twice.
    ddram_dout = 64'h8877665544332211;
    fork
        begin
            wait(ddram_rd);
            if (ddram_addr !== 29'h06040000)
                $fatal(1, "wrong audio DDR address: %h", ddram_addr);
            repeat (4) @(negedge clk);
            ddram_dout_ready = 1;
            @(negedge clk);
            ddram_dout_ready = 0;
        end
        request_audio_line(24'h200000, 64'h8877665544332211);
    join
    if (accepted_reads !== 3)
        $fatal(1, "expected three accepted DDR reads, got %0d", accepted_reads);

    // When graphics and audio miss together, graphics goes first after an
    // audio grant, then the fairness token guarantees the waiting audio line
    // is served next instead of either client monopolizing DDR.
    fork
        begin
            wait(ddram_rd);
            if (ddram_addr !== 29'h06020001)
                $fatal(1, "simultaneous request did not serve graphics first: %h",
                       ddram_addr);
            repeat (2) @(negedge clk);
            ddram_dout = 64'h1111222233334444;
            ddram_dout_ready = 1;
            @(negedge clk);
            ddram_dout_ready = 0;
            wait(!ddram_rd);
            wait(ddram_rd);
            if (ddram_addr !== 29'h06040001)
                $fatal(1, "waiting audio request was not served next: %h",
                       ddram_addr);
            repeat (2) @(negedge clk);
            ddram_dout = 64'h5555666677778888;
            ddram_dout_ready = 1;
            @(negedge clk);
            ddram_dout_ready = 0;
        end
        request_gfx_line(20'h00008, 64'h1111222233334444);
        request_audio_line(24'h200008, 64'h5555666677778888);
    join
    if (accepted_reads !== 5)
        $fatal(1, "simultaneous clients issued %0d total reads, expected 5",
               accepted_reads);

    // Diagnostic writes are observational and must not jump ahead of a
    // waiting graphics row.  Hold both requests together: the graphics DDR
    // read must complete first, after which the telemetry write may proceed.
    ddram_dout = 64'ha1a2a3a4a5a6a7a8;
    @(negedge clk);
    gfx_addr = 20'h00010;
    gfx_req = 1;
    debug_wr_addr = 28'h0300008;
    debug_wr_data = 64'h1020304050607080;
    debug_wr_req = 1;
    fork
        begin
            wait(ddram_rd);
            if (ddram_addr !== 29'h06020002)
                $fatal(1, "debug write pre-empted graphics: %h", ddram_addr);
            if (ddram_we)
                $fatal(1, "debug write asserted with pending graphics read");
            repeat (3) @(negedge clk);
            ddram_dout_ready = 1;
            @(negedge clk);
            ddram_dout_ready = 0;
        end
        begin
            wait(gfx_ack);
            if (gfx_data !== 64'ha1a2a3a4a5a6a7a8)
                $fatal(1, "graphics data corrupted by pending debug write");
            @(negedge clk);
            gfx_req = 0;
        end
        begin
            wait(ddram_we);
            if (ddram_addr !== 29'h06060001)
                $fatal(1, "wrong deferred debug address: %h", ddram_addr);
            if (ddram_din !== debug_wr_data)
                $fatal(1, "wrong deferred debug data");
            wait(debug_wr_ack);
            @(negedge clk);
            debug_wr_req = 0;
        end
    join
    if (accepted_reads !== 6)
        $fatal(1, "deferred debug test issued %0d reads, expected 6",
               accepted_reads);

    // Loader byte write selects the correct DDR lane at the same physical base.
    @(negedge clk);
    ioctl_addr = 27'd1;
    ioctl_data = 8'haa;
    ioctl_wr = 1;
    @(negedge clk);
    ioctl_wr = 0;
    wait(ddram_we);
    if (ddram_addr !== 29'h06000000) $fatal(1, "wrong write address: %h", ddram_addr);
    if (ddram_be !== 8'h02) $fatal(1, "wrong byte enable: %h", ddram_be);
    if (ddram_din !== 64'haaaaaaaaaaaaaaaa) $fatal(1, "wrong write data");
    wait(!ioctl_wait);

    // Full-word telemetry lands 3 MiB above the physical ROM base.
    @(negedge clk);
    debug_wr_addr = 28'h0300000;
    debug_wr_data = 64'h0123456789abcdef;
    debug_wr_req = 1;
    wait(ddram_we);
    if (ddram_addr !== 29'h06060000) $fatal(1, "wrong debug address: %h", ddram_addr);
    if (ddram_be !== 8'hff) $fatal(1, "wrong debug byte enable: %h", ddram_be);
    if (ddram_din !== debug_wr_data) $fatal(1, "wrong debug data");
    wait(debug_wr_ack);
    @(negedge clk);
    debug_wr_req = 0;

    $display("PASS tb_ddr_rom");
    $finish;
end
endmodule
