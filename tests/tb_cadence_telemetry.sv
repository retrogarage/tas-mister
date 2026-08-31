`timescale 1ns/1ps

module tb_cadence_telemetry;

reg clk = 1'b0;
always #5 clk = ~clk;

reg reset = 1'b1;
reg vblank = 1'b0;
reg [31:0] cpu_bus_cycles = 32'd0;
reg dsp_reset = 1'b1;
reg [31:0] dsp_instructions = 32'd0;
reg [2:0] dsp_flag_strobe = 3'd0;
reg dma_copy_strobe = 1'b0;
reg dma_erase_strobe = 1'b0;
reg polygon_hold = 1'b0;
wire [31:0] frame_count;
wire [31:0] frame_cpu_bus_cycles;
wire [31:0] frame_dsp_instructions;
wire [31:0] total_dsp_instructions;
wire [15:0] flag_count_0;
wire [15:0] flag_count_1;
wire [15:0] flag_count_2;
wire [15:0] dma_copy_count;
wire [15:0] dma_erase_count;
wire [31:0] polygon_hold_total;
wire [31:0] polygon_hold_max;

tas_cadence_telemetry dut (
    .clk(clk), .reset(reset), .vblank(vblank),
    .cpu_bus_cycles(cpu_bus_cycles),
    .dsp_reset(dsp_reset), .dsp_instructions(dsp_instructions),
    .dsp_flag_strobe(dsp_flag_strobe),
    .dma_copy_strobe(dma_copy_strobe),
    .dma_erase_strobe(dma_erase_strobe),
    .polygon_hold(polygon_hold),
    .frame_count(frame_count),
    .frame_cpu_bus_cycles(frame_cpu_bus_cycles),
    .frame_dsp_instructions(frame_dsp_instructions),
    .total_dsp_instructions(total_dsp_instructions),
    .flag_count_0(flag_count_0), .flag_count_1(flag_count_1),
    .flag_count_2(flag_count_2), .dma_copy_count(dma_copy_count),
    .dma_erase_count(dma_erase_count),
    .polygon_hold_total(polygon_hold_total),
    .polygon_hold_max(polygon_hold_max)
);

task automatic tick;
begin
    @(posedge clk);
    #1;
end
endtask

task automatic frame_edge;
begin
    vblank = 1'b1;
    tick();
    vblank = 1'b0;
    tick();
end
endtask

initial begin
    tick();
    tick();
    reset = 1'b0;
    dsp_reset = 1'b0;

    cpu_bus_cycles = 32'd1000;
    dsp_instructions = 32'd100;
    dsp_flag_strobe = 3'b101;
    dma_copy_strobe = 1'b1;
    tick();
    dsp_flag_strobe = 3'd0;
    dma_copy_strobe = 1'b0;
    polygon_hold = 1'b1;
    repeat (7) tick();
    polygon_hold = 1'b0;
    tick();
    polygon_hold = 1'b1;
    repeat (3) tick();
    polygon_hold = 1'b0;
    frame_edge();
    if (frame_count != 1 || frame_cpu_bus_cycles != 1000 ||
        frame_dsp_instructions != 100 || total_dsp_instructions != 100)
        $fatal(1, "bad first frame: frame=%0d cpu=%0d dsp=%0d total=%0d",
               frame_count, frame_cpu_bus_cycles, frame_dsp_instructions,
               total_dsp_instructions);

    cpu_bus_cycles = 32'd1500;
    dsp_instructions = 32'd150;
    tick();
    frame_edge();
    if (frame_count != 2 || frame_cpu_bus_cycles != 500 ||
        frame_dsp_instructions != 50 || total_dsp_instructions != 150)
        $fatal(1, "bad ordinary delta: frame=%0d cpu=%0d dsp=%0d total=%0d",
               frame_count, frame_cpu_bus_cycles, frame_dsp_instructions,
               total_dsp_instructions);

    // Model the 68000 resetting the C25 between scenes.  The raw counter falls
    // from 150 to zero, then retires 30 new instructions before the next frame.
    // The old direct subtraction produced a value near 2^32 here.
    dsp_reset = 1'b1;
    tick();
    dsp_instructions = 32'd0;
    tick();
    dsp_reset = 1'b0;
    dsp_instructions = 32'd30;
    cpu_bus_cycles = 32'd1900;
    dsp_flag_strobe = 3'b010;
    dma_erase_strobe = 1'b1;
    tick();
    dsp_flag_strobe = 3'd0;
    dma_erase_strobe = 1'b0;
    frame_edge();
    if (frame_count != 3 || frame_cpu_bus_cycles != 400 ||
        frame_dsp_instructions != 30 || total_dsp_instructions != 180)
        $fatal(1, "bad reset delta: frame=%0d cpu=%0d dsp=%0d total=%0d",
               frame_count, frame_cpu_bus_cycles, frame_dsp_instructions,
               total_dsp_instructions);
    if (flag_count_0 != 1 || flag_count_1 != 1 || flag_count_2 != 1 ||
        dma_copy_count != 1 || dma_erase_count != 1)
        $fatal(1, "bad event counters: %0d %0d %0d %0d %0d",
               flag_count_0, flag_count_1, flag_count_2,
               dma_copy_count, dma_erase_count);
    if (polygon_hold_total != 10 || polygon_hold_max != 7)
        $fatal(1, "bad polygon hold counters: total=%0d max=%0d",
               polygon_hold_total, polygon_hold_max);

    $display("PASS tb_cadence_telemetry");
    $finish;
end

endmodule
