`timescale 1ns/1ps

module tb_muldiv;
reg clk = 0;
always #25 clk = ~clk;
reg start = 0;
reg [15:0] a = 0;
reg [15:0] b = 0;
reg [15:0] divisor = 1;
wire busy;
wire [31:0] result;
wire [15:0] remainder;

sys_umuldiv #(.NB_MUL1(16), .NB_MUL2(16), .NB_DIV(16)) dut (
    .clk(clk), .start(start), .busy(busy), .mul1(a), .mul2(b),
    .div(divisor), .result(result), .remainder(remainder)
);

task automatic check(
    input [15:0] test_a,
    input [15:0] test_b,
    input [15:0] test_divisor
);
reg [31:0] expected_product;
reg [31:0] expected_result;
begin
    a = test_a;
    b = test_b;
    divisor = test_divisor;
    expected_product = test_a * test_b;
    expected_result = expected_product / test_divisor;
    @(negedge clk);
    start = 1;
    @(negedge clk);
    start = 0;
    while (!busy) @(negedge clk);
    while (busy) @(negedge clk);
    if (result != expected_result)
        $fatal(1, "%0d*%0d/%0d produced %0d, expected %0d",
               test_a, test_b, test_divisor, result, expected_result);
end
endtask

initial begin
    repeat (3) @(negedge clk);
    check(16'd100, 16'd200, 16'd25);
    check(16'hffff, 16'hffff, 16'hffff);
    check(16'd32767, 16'd12345, 16'd97);
    $display("PASS tb_muldiv");
    $finish;
end
endmodule
