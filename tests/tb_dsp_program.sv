`timescale 1ns/1ps

module tb_dsp_program;

reg clk = 1'b0;
reg ioctl_wr = 1'b0;
reg [12:0] ioctl_addr = 13'd0;
reg [7:0] ioctl_data = 8'd0;
reg [11:0] cpu_addr = 12'd0;
wire [15:0] cpu_data;

always #5 clk = ~clk;

tas_dsp_program dut (
    .clk(clk), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_data), .cpu_addr(cpu_addr), .cpu_data(cpu_data)
);

task automatic write_byte(input [12:0] address, input [7:0] value);
begin
    @(negedge clk);
    ioctl_addr = address;
    ioctl_data = value;
    ioctl_wr = 1'b1;
    @(posedge clk);
    #1;
    @(negedge clk);
    ioctl_wr = 1'b0;
end
endtask

task automatic expect_word(input [11:0] address, input [15:0] value);
begin
    @(negedge clk);
    cpu_addr = address;
    @(posedge clk);
    #1;
    if (cpu_data !== value)
        $fatal(1, "DSP program word %03h=%04h expected=%04h",
               address, cpu_data, value);
end
endtask

initial begin
    write_byte(13'h246, 8'h12);
    write_byte(13'h247, 8'h34);
    write_byte(13'h1ffe, 8'hab);
    write_byte(13'h1fff, 8'hcd);

    expect_word(12'h123, 16'h1234);
    expect_word(12'hfff, 16'habcd);

    // Writing another word must not perturb the currently addressed word;
    // the CPU port retains its one-clock synchronous-read contract.
    cpu_addr = 12'h123;
    write_byte(13'h400, 8'h55);
    if (cpu_data !== 16'h1234)
        $fatal(1, "DSP program read changed during unrelated write");

    $display("PASS tb_dsp_program");
    $finish;
end

endmodule
