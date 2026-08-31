// Dedicated-memory extension row for the MiSTer framebuffer scaler.
// The synchronous read and single write port match ascal's original inferred
// array. The explicit wrapper avoids the mixed feed-through mode and now uses
// spare M10Ks instead of consuming logic-array blocks.
module ascal_linf_ram #(
    parameter integer AW = 8
) (
    input                   clk,
    input                   we,
    input      [AW-1:0]     waddr,
    input      [23:0]       wdata,
    input      [AW-1:0]     raddr,
    output reg [23:0]       rdata
);

(* ramstyle = "M10K, no_rw_check" *) reg [23:0] mem [0:(1 << AW)-1];

always @(posedge clk) begin
    if (we)
        mem[waddr] <= wdata;
    rdata <= mem[raddr];
end

endmodule
