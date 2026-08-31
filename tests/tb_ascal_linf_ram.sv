`timescale 1ns/1ps

module tb_ascal_linf_ram;

reg clk = 1'b0;
reg we = 1'b0;
reg [7:0] waddr = 8'd0;
reg [23:0] wdata = 24'd0;
reg [7:0] raddr = 8'd0;
wire [23:0] rdata;

always #5 clk = ~clk;

ascal_linf_ram dut (
    .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
    .raddr(raddr), .rdata(rdata)
);

task automatic tick;
begin
    @(posedge clk);
    #1;
end
endtask

initial begin
    // Write one row, then prove the original one-clock synchronous read.
    we = 1'b1;
    waddr = 8'h35;
    wdata = 24'h123456;
    raddr = 8'h00;
    tick();

    we = 1'b0;
    raddr = 8'h35;
    tick();
    if (rdata !== 24'h123456)
        $fatal(1, "first scaler row read %06h", rdata);

    // The independent read address must remain usable during a write.
    we = 1'b1;
    waddr = 8'hc2;
    wdata = 24'ha55a3c;
    raddr = 8'h35;
    tick();
    if (rdata !== 24'h123456)
        $fatal(1, "read-during-other-address-write changed %06h", rdata);

    we = 1'b0;
    raddr = 8'hc2;
    tick();
    if (rdata !== 24'ha55a3c)
        $fatal(1, "second scaler row read %06h", rdata);

    $display("PASS tb_ascal_linf_ram synchronous read/write behavior");
    $finish;
end

endmodule
