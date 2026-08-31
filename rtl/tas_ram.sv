// Byte-writeable synchronous RAM used for the board's 16-bit memory regions.
module tas_ram #(
    parameter AW = 15,
    parameter SECOND_PORT = 0,
    parameter INFERRED_DUAL = 0,
    parameter DISTRIBUTED = 0
) (
    input                 clk,
    input                 cs,
    input                 we,
    input                 uds_n,
    input                 lds_n,
    input        [AW-1:0] addr,
    input        [15:0]   din,
    output       [15:0]   dout,

    input        [AW-1:0] rd2_addr,
    input                 rd2_cs,
    input                 rd2_we,
    input        [15:0]   rd2_din,
    output       [15:0]   rd2_dout
);

generate
if (SECOND_PORT) begin : g_dual
`ifdef VERILATOR
    // Portable behavioral model for regression tests.
    reg [15:0] mem [0:(1<<AW)-1];
    reg [15:0] dout_r;
    reg [15:0] rd2_dout_r;

    always @(posedge clk) begin
        if (cs) begin
            if (we && !uds_n) mem[addr][15:8] <= din[15:8];
            if (we && !lds_n) mem[addr][7:0] <= din[7:0];
            dout_r <= mem[addr];
        end
        if (rd2_cs) begin
            if (rd2_we) mem[rd2_addr] <= rd2_din;
            rd2_dout_r <= mem[rd2_addr];
        end
    end

    assign dout = dout_r;
    assign rd2_dout = rd2_dout_r;
`else
if (INFERRED_DUAL) begin : g_inferred
    // Some board memories require byte writes on the 68000 port and full-word
    // writes on the DSP port.  Express those as two ordinary byte-wide true
    // dual-port RAMs so Quartus owns all port registering and collision
    // details.  This exactly matches the behavioral model's registered,
    // hold-last-value outputs and avoids relying on the less explicit
    // BIDIR_DUAL_PORT byte-enable configuration below.
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] mem_hi [0:(1<<AW)-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] mem_lo [0:(1<<AW)-1];
    reg [7:0] dout_hi;
    reg [7:0] dout_lo;
    reg [7:0] rd2_dout_hi;
    reg [7:0] rd2_dout_lo;

    always @(posedge clk) begin
        if (cs) begin
            if (we && !uds_n) mem_hi[addr] <= din[15:8];
            if (we && !lds_n) mem_lo[addr] <= din[7:0];
            dout_hi <= mem_hi[addr];
            dout_lo <= mem_lo[addr];
        end
    end

    always @(posedge clk) begin
        if (rd2_cs) begin
            if (rd2_we) begin
                mem_hi[rd2_addr] <= rd2_din[15:8];
                mem_lo[rd2_addr] <= rd2_din[7:0];
            end
            rd2_dout_hi <= mem_hi[rd2_addr];
            rd2_dout_lo <= mem_lo[rd2_addr];
        end
    end

    assign dout = {dout_hi, dout_lo};
    assign rd2_dout = {rd2_dout_hi, rd2_dout_lo};
end else begin : g_native
    // Use the native true-dual-port primitive for the two memories observed
    // by video. Explicit byte enables avoid Quartus duplicating a byte-sliced
    // VCO RAM and mapping the palette's other byte lane into flip-flops.
    altsyncram dual_mem (
        .clock0(clk),
        .address_a(addr),
        .data_a(din),
        .wren_a(cs && we),
        // Port A has the same request/response shape as port B: cs pulses
        // when tas_main accepts the bus cycle, then the CPU samples q_a on
        // the following clock after cs has fallen.  The behavioral RAM holds
        // its last read value, so keep the native primitive output enabled as
        // well.  Otherwise the POST's first shared-RAM read can see a
        // withdrawn q_a even though the write completed correctly.
        .rden_a(1'b1),
        .byteena_a({!uds_n, !lds_n}),
        .q_a(dout),

        .clock1(clk),
        .address_b(rd2_addr),
        .data_b(rd2_din),
        .wren_b(rd2_cs && rd2_we),
        // Keep the unregistered B output enabled. rd2_cs is a one-cycle
        // request pulse, while consumers latch q_b on the following clock;
        // gating rden_b with that pulse can make the native Cyclone V RAM
        // withdraw q_b before it is sampled. Address/data/write controls
        // remain request-gated, so an always-enabled read is harmless.
        .rden_b(1'b1),
        .byteena_b(2'b11),
        .q_b(rd2_dout),

        .aclr0(1'b0),
        .aclr1(1'b0),
        .addressstall_a(1'b0),
        .addressstall_b(1'b0),
        .clocken0(1'b1),
        .clocken1(1'b1),
        .clocken2(1'b1),
        .clocken3(1'b1),
        .eccstatus()
    );
    defparam
        dual_mem.numwords_a = 1 << AW,
        dual_mem.widthad_a = AW,
        dual_mem.width_a = 16,
        dual_mem.numwords_b = 1 << AW,
        dual_mem.widthad_b = AW,
        dual_mem.width_b = 16,
        dual_mem.address_reg_b = "CLOCK1",
        dual_mem.clock_enable_input_a = "BYPASS",
        dual_mem.clock_enable_input_b = "BYPASS",
        dual_mem.clock_enable_output_a = "BYPASS",
        dual_mem.clock_enable_output_b = "BYPASS",
        dual_mem.indata_reg_b = "CLOCK1",
        dual_mem.intended_device_family = "Cyclone V",
        dual_mem.lpm_type = "altsyncram",
        dual_mem.operation_mode = "BIDIR_DUAL_PORT",
        dual_mem.outdata_aclr_a = "NONE",
        dual_mem.outdata_aclr_b = "NONE",
        dual_mem.outdata_reg_a = "UNREGISTERED",
        dual_mem.outdata_reg_b = "UNREGISTERED",
        dual_mem.power_up_uninitialized = "TRUE",
        dual_mem.read_during_write_mode_mixed_ports = "DONT_CARE",
        dual_mem.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        dual_mem.width_byteena_a = 2,
        dual_mem.width_byteena_b = 2,
        dual_mem.wrcontrol_wraddress_reg_b = "CLOCK1";
end
`endif
end else if (DISTRIBUTED) begin : g_single_mlab
    // DISTRIBUTED is the legacy selection used by these small single-clock
    // memories. VCO splitting restored enough M10Ks to keep them out of ALMs.
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] mem_hi [0:(1<<AW)-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] mem_lo [0:(1<<AW)-1];
    reg [15:0] dout_r;

    always @(posedge clk) begin
        if (cs) begin
            if (we && !uds_n) mem_hi[addr] <= din[15:8];
            if (we && !lds_n) mem_lo[addr] <= din[7:0];
            dout_r <= {mem_hi[addr], mem_lo[addr]};
        end
    end

    assign dout = dout_r;
    assign rd2_dout = 16'd0;
end else begin : g_single
    reg [7:0] mem_hi [0:(1<<AW)-1];
    reg [7:0] mem_lo [0:(1<<AW)-1];
    reg [15:0] dout_r;

    always @(posedge clk) begin
        if (cs) begin
            if (we && !uds_n) mem_hi[addr] <= din[15:8];
            if (we && !lds_n) mem_lo[addr] <= din[7:0];
            dout_r <= {mem_hi[addr], mem_lo[addr]};
        end
    end

    assign dout = dout_r;
    assign rd2_dout = 16'd0;
end
endgenerate

endmodule
