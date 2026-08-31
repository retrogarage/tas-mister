// Runtime-loaded TMS320C25 program ROM. MRA index 1 streams the 0x2000-byte
// Top Landing DSP image here as 4096 big-endian words.
module tas_dsp_program (
    input               clk,
    input               ioctl_wr,
    input      [12:0]   ioctl_addr,
    input      [7:0]    ioctl_data,
    input      [11:0]   cpu_addr,
    output reg [15:0]   cpu_data
);

// The split VCO RAM leaves enough dedicated memory for this synchronous ROM;
// keeping it in M10Ks avoids spending logic-array blocks on program storage.
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] mem_hi [0:4095];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] mem_lo [0:4095];

always @(posedge clk) begin
    if (ioctl_wr) begin
        if (!ioctl_addr[0]) mem_hi[ioctl_addr[12:1]] <= ioctl_data;
        else                mem_lo[ioctl_addr[12:1]] <= ioctl_data;
    end
    cpu_data <= {mem_hi[cpu_addr], mem_lo[cpu_addr]};
end

endmodule
