`timescale 1ns/1ps

module tb_vco_ram;
reg clk = 0;
always #5 clk = ~clk;

reg cpu_cs = 0;
reg cpu_we = 0;
reg cpu_uds_n = 0;
reg cpu_lds_n = 0;
reg [16:0] cpu_addr = 0;
reg [15:0] cpu_din = 0;
wire [15:0] cpu_dout;
reg [16:0] video_addr = 0;
wire [15:0] video_dout;

tas_vco_ram dut (
    .clk(clk), .cpu_cs(cpu_cs), .cpu_we(cpu_we),
    .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n),
    .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_dout(cpu_dout),
    .video_addr(video_addr), .video_dout(video_dout)
);

task automatic write_word(input [16:0] address, input [15:0] value);
begin
    @(negedge clk);
    cpu_addr = address;
    cpu_din = value;
    cpu_uds_n = 0;
    cpu_lds_n = 0;
    cpu_we = 1;
    cpu_cs = 1;
    @(negedge clk);
    cpu_cs = 0;
    cpu_we = 0;
end
endtask

task automatic write_bytes(
    input [16:0] address,
    input [15:0] value,
    input uds_n,
    input lds_n
);
begin
    @(negedge clk);
    cpu_addr = address;
    cpu_din = value;
    cpu_uds_n = uds_n;
    cpu_lds_n = lds_n;
    cpu_we = 1;
    cpu_cs = 1;
    @(negedge clk);
    cpu_cs = 0;
    cpu_we = 0;
    cpu_uds_n = 0;
    cpu_lds_n = 0;
end
endtask

task automatic check_cpu(input [16:0] address, input [15:0] expected);
begin
    @(negedge clk);
    cpu_addr = address;
    cpu_we = 0;
    cpu_cs = 1;
    @(negedge clk);
    if (cpu_dout !== expected)
        $fatal(1, "CPU VCO read %05h=%04h expected=%04h",
               address, cpu_dout, expected);
    cpu_cs = 0;
end
endtask

task automatic check_video(input [16:0] address, input [15:0] expected);
begin
    @(negedge clk);
    video_addr = address;
    @(negedge clk);
    if (video_dout !== expected)
        $fatal(1, "video VCO read %05h=%04h expected=%04h",
               address, video_dout, expected);
end
endtask

initial begin
    write_word(17'h00000, 16'h1001);
    write_word(17'h0ffff, 16'h2ffe);
    write_word(17'h10000, 16'h3003);
    write_word(17'h107ff, 16'h4ffc);

    check_cpu(17'h00000, 16'h1001);
    check_cpu(17'h0ffff, 16'h2ffe);
    check_cpu(17'h10000, 16'h3003);
    check_cpu(17'h107ff, 16'h4ffc);

    // Exercise independent byte enables at both sides of the bank boundary.
    write_bytes(17'h0ffff, 16'haa00, 1'b0, 1'b1);
    write_bytes(17'h10000, 16'h00bb, 1'b1, 1'b0);
    check_cpu(17'h0ffff, 16'haafe);
    check_cpu(17'h10000, 16'h30bb);

    check_video(17'h00000, 16'h1001);
    check_video(17'h0ffff, 16'haafe);
    check_video(17'h10000, 16'h30bb);
    check_video(17'h107ff, 16'h4ffc);

    $display("PASS tb_vco_ram 64K+2K boundary and byte lanes");
    $finish;
end
endmodule
