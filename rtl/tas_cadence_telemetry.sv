// Frame-boundary work and event telemetry.  This module is observational:
// none of its outputs feed back into emulated board or video timing.
module tas_cadence_telemetry (
    input               clk,
    input               reset,
    input               vblank,
    input      [31:0]   cpu_bus_cycles,
    input               dsp_reset,
    input      [31:0]   dsp_instructions,
    input      [2:0]    dsp_flag_strobe,
    input               dma_copy_strobe,
    input               dma_erase_strobe,
    input               polygon_hold,
    output reg [31:0]   frame_count,
    output reg [31:0]   frame_cpu_bus_cycles,
    output reg [31:0]   frame_dsp_instructions,
    output reg [31:0]   total_dsp_instructions,
    output reg [15:0]   flag_count_0,
    output reg [15:0]   flag_count_1,
    output reg [15:0]   flag_count_2,
    output reg [15:0]   dma_copy_count,
    output reg [15:0]   dma_erase_count,
    output reg [31:0]   polygon_hold_total,
    output reg [31:0]   polygon_hold_max
);

reg old_vblank;
reg [31:0] previous_cpu_bus_cycles;
reg [31:0] previous_dsp_raw;
reg [31:0] previous_frame_dsp_total;
reg [31:0] polygon_hold_run;

// The C25 instruction counter is local to the processor and returns to zero
// whenever the 68000 resets that subsystem between scenes.  Accumulate raw
// increments only while reset is inactive so the exported total and per-frame
// delta remain monotonic across those scene boundaries.  Unsigned subtraction
// intentionally handles a natural 32-bit raw-counter wrap.
wire [31:0] dsp_increment = dsp_reset
    ? 32'd0 : dsp_instructions - previous_dsp_raw;
wire [31:0] next_dsp_total = total_dsp_instructions + dsp_increment;

always @(posedge clk) begin
    if (reset) begin
        // Sampling the current level avoids manufacturing a vblank edge when
        // reset happens to be released during vertical blank.
        old_vblank <= vblank;
        frame_count <= 32'd0;
        previous_cpu_bus_cycles <= 32'd0;
        previous_dsp_raw <= 32'd0;
        previous_frame_dsp_total <= 32'd0;
        frame_cpu_bus_cycles <= 32'd0;
        frame_dsp_instructions <= 32'd0;
        total_dsp_instructions <= 32'd0;
        flag_count_0 <= 16'd0;
        flag_count_1 <= 16'd0;
        flag_count_2 <= 16'd0;
        dma_copy_count <= 16'd0;
        dma_erase_count <= 16'd0;
        polygon_hold_run <= 32'd0;
        polygon_hold_total <= 32'd0;
        polygon_hold_max <= 32'd0;
    end else begin
        old_vblank <= vblank;

        if (dsp_reset) begin
            previous_dsp_raw <= 32'd0;
        end else begin
            previous_dsp_raw <= dsp_instructions;
            total_dsp_instructions <= next_dsp_total;
        end

        if (vblank && !old_vblank) begin
            frame_count <= frame_count + 1'd1;
            frame_cpu_bus_cycles <=
                cpu_bus_cycles - previous_cpu_bus_cycles;
            frame_dsp_instructions <=
                next_dsp_total - previous_frame_dsp_total;
            previous_cpu_bus_cycles <= cpu_bus_cycles;
            previous_frame_dsp_total <= next_dsp_total;
        end

        if (dsp_flag_strobe[0])
            flag_count_0 <= flag_count_0 + 1'd1;
        if (dsp_flag_strobe[1])
            flag_count_1 <= flag_count_1 + 1'd1;
        if (dsp_flag_strobe[2])
            flag_count_2 <= flag_count_2 + 1'd1;
        if (dma_copy_strobe)
            dma_copy_count <= dma_copy_count + 1'd1;
        if (dma_erase_strobe)
            dma_erase_count <= dma_erase_count + 1'd1;

        if (polygon_hold) begin
            if (!(&polygon_hold_total))
                polygon_hold_total <= polygon_hold_total + 1'd1;
            if (!(&polygon_hold_run))
                polygon_hold_run <= polygon_hold_run + 1'd1;
            if (polygon_hold_run + 1'd1 > polygon_hold_max)
                polygon_hold_max <= polygon_hold_run + 1'd1;
        end else begin
            polygon_hold_run <= 32'd0;
        end
    end
end

endmodule
