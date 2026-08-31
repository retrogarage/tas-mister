`timescale 1ns/1ps

// Focused architectural checks for instructions that Top Landing's attract
// path does not necessarily execute. BIO is intentionally inactive-high in
// the Taito Air wrapper.
module tb_tms320c25_ops;
reg clk = 1'b0;
always #25 clk = ~clk;
reg reset = 1'b1;

wire [11:0] prog_addr;
reg [15:0] prog_data = 16'hffff;
wire data_req;
wire data_we;
wire [15:0] data_addr;
wire [15:0] data_wdata;
wire [31:0] debug_instructions;
wire [15:0] debug_illegal;

reg [15:0] program_mem [0:4095];
reg [15:0] data_mem [0:65535];
reg [15:0] data_rdata = 16'd0;
reg data_ack = 1'b0;
integer index;

tas_tms320c25 dut (
    .clk(clk), .reset(reset), .hold(1'b0),
    .prog_addr(prog_addr), .prog_data(prog_data),
    .data_req(data_req), .data_we(data_we), .data_addr(data_addr),
    .data_wdata(data_wdata), .data_ack(data_ack), .data_rdata(data_rdata),
    .debug_pc(), .debug_ir(), .debug_instructions(debug_instructions),
    .debug_illegal(debug_illegal), .debug_write()
);

always @(posedge clk) begin
    prog_data <= program_mem[prog_addr];
    data_ack <= data_req;
    if (data_req) begin
        data_rdata <= data_mem[data_addr];
        if (data_we) data_mem[data_addr] <= data_wdata;
    end
end

initial begin
    for (index = 0; index < 4096; index = index + 1)
        program_mem[index] = 16'h5500;
    for (index = 0; index < 65536; index = index + 1)
        data_mem[index] = 16'd0;

    // LTD copies within local RAM, but its DMOV side effect must not write the
    // following word for an external source at 0x4010. BIOZ then falls through
    // and stores 0x1234 at 0x20; an incorrect branch stores 0x5678 instead.
    program_mem[0]  = 16'h3f10;
    program_mem[1]  = 16'hc880;
    program_mem[2]  = 16'h3f10;
    program_mem[3]  = 16'hc800;
    program_mem[4]  = 16'hfa00;
    program_mem[5]  = 16'h000c;
    program_mem[6]  = 16'hd001;
    program_mem[7]  = 16'h1234;
    program_mem[8]  = 16'h6020;
    program_mem[9]  = 16'hff00;
    program_mem[10] = 16'h0011;
    program_mem[12] = 16'hd001;
    program_mem[13] = 16'h5678;
    program_mem[14] = 16'h6020;
    program_mem[15] = 16'hff00;
    program_mem[16] = 16'h0011;
    program_mem[17] = 16'hff00;
    program_mem[18] = 16'h0011;
    data_mem[16'h0010] = 16'hcafe;
    data_mem[16'h0011] = 16'hdead;
    data_mem[16'h4010] = 16'hbeef;
    data_mem[16'h4011] = 16'hdead;

    repeat (6) @(negedge clk);
    reset = 1'b0;
    repeat (300) @(negedge clk);

    if (data_mem[16'h0011] != 16'hcafe)
        $fatal(1, "LTD DMOV failed: %04h", data_mem[16'h0011]);
    if (data_mem[16'h4011] != 16'hdead)
        $fatal(1, "external LTD incorrectly performed DMOV: %04h",
               data_mem[16'h4011]);
    if (data_mem[16'h0020] != 16'h1234)
        $fatal(1, "inactive BIO did not fall through: %04h",
               data_mem[16'h0020]);
    if (debug_illegal != 0)
        $fatal(1, "unexpected illegal opcodes: %0d", debug_illegal);

    $display("PASS tb_tms320c25_ops local-only LTD DMOV and inactive BIOZ");
    $finish;
end
endmodule
