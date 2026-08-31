`timescale 1ns/1ps

module tb_dip_switches;

reg clk = 1'b0;
reg ioctl_wr = 1'b0;
reg [15:0] ioctl_index = 16'd0;
reg [26:0] ioctl_addr = 27'd0;
reg [7:0] ioctl_data = 8'd0;
wire [7:0] dswa;
wire [7:0] dswb;

always #5 clk = ~clk;

tas_dip_switches dut (
    .clk(clk),
    .ioctl_wr(ioctl_wr),
    .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_data),
    .dswa(dswa),
    .dswb(dswb)
);

task automatic write_byte(
    input [15:0] index,
    input [26:0] address,
    input [7:0] data
);
begin
    @(negedge clk);
    ioctl_index = index;
    ioctl_addr = address;
    ioctl_data = data;
    ioctl_wr = 1'b1;
    @(negedge clk);
    ioctl_wr = 1'b0;
end
endtask

initial begin
    #1;
    if ({dswb, dswa} !== 16'hffff)
        $fatal(1, "DIP factory defaults are not all open");

    // A payload present on the bus without its write qualifier must be inert.
    @(negedge clk);
    ioctl_index = 16'd254;
    ioctl_addr = 27'd0;
    ioctl_data = 8'h3c;
    ioctl_wr = 1'b0;
    @(negedge clk);
    if ({dswb, dswa} !== 16'hffff)
        $fatal(1, "DIP state changed without ioctl_wr");

    write_byte(16'd0, 27'd0, 8'h00);
    if ({dswb, dswa} !== 16'hffff)
        $fatal(1, "ROM download changed DIP state");

    write_byte(16'd254, 27'd0, 8'ha5);
    if (dswa !== 8'ha5 || dswb !== 8'hff)
        $fatal(1, "MRA SWA byte was not captured");

    write_byte(16'd254, 27'd1, 8'h5a);
    if (dswa !== 8'ha5 || dswb !== 8'h5a)
        $fatal(1, "MRA SWB byte was not captured");

    write_byte(16'd254, 27'd2, 8'h00);
    if ({dswb, dswa} !== 16'h5aa5)
        $fatal(1, "out-of-range DIP byte changed state");

    $display("PASS tb_dip_switches");
    $finish;
end

endmodule
