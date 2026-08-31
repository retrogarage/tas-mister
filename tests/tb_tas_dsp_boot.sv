`timescale 1ns/1ps

// Board-level DSP regression using the real C25 core and Taito Air math,
// clipping, shared-RAM and line-RAM wrapper. This complements the CPU-only
// opcode test by exercising the wait-stated sequential multiply/divide path.
module tb_tas_dsp_boot;
reg clk = 0;
always #25 clk = ~clk;
reg reset = 1;

wire [11:0] prog_addr;
reg [15:0] prog_data = 16'hffff;
wire line_cs;
wire line_we;
wire [13:0] line_addr;
wire [15:0] line_wdata;
reg [15:0] line_rdata = 16'd0;
wire shared_cs;
wire shared_we;
wire [14:0] shared_addr;
wire [15:0] shared_wdata;
reg [15:0] shared_rdata = 16'd0;
wire [15:0] debug_pc;
wire [15:0] debug_ir;
wire [31:0] debug_instructions;
wire [15:0] debug_illegal;
wire [15:0] debug_last_addr;
wire [15:0] debug_last_data;
wire [2:0] debug_flags;

reg [7:0] program_bytes [0:8191];
reg [15:0] line_mem [0:16383];
reg [15:0] shared_mem [0:32767];
integer rom_file;
integer rom_bytes;
integer index;
integer clocks;
integer command;
integer line_writes;
reg [2:0] old_flags;
integer flag0_edges;
integer flag1_edges;
integer flag2_edges;
string rom_path;
string line_dump_path;
reg trace_line_writes;

tas_dsp dut (
    .clk(clk), .reset(reset), .hold(1'b0),
    .prog_addr(prog_addr), .prog_data(prog_data),
    .line_cs(line_cs), .line_we(line_we), .line_addr(line_addr),
    .line_wdata(line_wdata), .line_rdata(line_rdata),
    .shared_cs(shared_cs), .shared_we(shared_we),
    .shared_addr(shared_addr), .shared_wdata(shared_wdata),
    .shared_grant(1'b1),
    .shared_rdata(shared_rdata),
    .debug_pc(debug_pc), .debug_ir(debug_ir),
    .debug_instructions(debug_instructions),
    .debug_illegal(debug_illegal), .debug_last_addr(debug_last_addr),
    .debug_last_data(debug_last_data), .debug_flags(debug_flags),
    .flag_strobe()
);

always @(posedge clk) begin
    prog_data <= {program_bytes[{prog_addr,1'b0}],
                  program_bytes[{prog_addr,1'b1}]};
    if (line_cs) begin
        line_rdata <= line_mem[line_addr];
        if (line_we) begin
            line_mem[line_addr] <= line_wdata;
            line_writes <= line_writes + 1;
            if (trace_line_writes)
                $display("LINE_WRITE pc=%04h ir=%04h addr=%04h data=%04h",
                         debug_pc, debug_ir, line_addr, line_wdata);
        end
    end
    if (shared_cs) begin
        shared_rdata <= shared_mem[shared_addr];
        if (shared_we) shared_mem[shared_addr] <= shared_wdata;
    end
    if (debug_flags[0] != old_flags[0]) flag0_edges <= flag0_edges + 1;
    if (debug_flags[1] != old_flags[1]) flag1_edges <= flag1_edges + 1;
    if (debug_flags[2] != old_flags[2]) flag2_edges <= flag2_edges + 1;
    old_flags <= debug_flags;
end

initial begin
    if (!$value$plusargs("ROM=%s", rom_path)) rom_path = "roms/topland.rom";
    if (!$value$plusargs("COMMAND=%d", command)) command = 1;
    for (index = 0; index < 16384; index = index + 1) line_mem[index] = 16'd0;
    for (index = 0; index < 32768; index = index + 1) shared_mem[index] = 16'd0;
    shared_mem[0] = 16'hffff;
    for (index = 0; index < 8192; index = index + 1) program_bytes[index] = 8'hff;
    line_writes = 0;
    old_flags = 3'd0;
    flag0_edges = 0;
    flag1_edges = 0;
    flag2_edges = 0;
    trace_line_writes = $test$plusargs("TRACE_LINE_WRITES");

    rom_file = $fopen(rom_path, "rb");
    if (!rom_file) $fatal(1, "cannot open Top Landing ROM image");
    if ($fseek(rom_file, 32'h000d0000, 0)) $fatal(1, "cannot seek to DSP ROM");
    rom_bytes = $fread(program_bytes, rom_file);
    $fclose(rom_file);
    if (rom_bytes != 8192) $fatal(1, "short DSP program: %0d bytes", rom_bytes);

    repeat (6) @(negedge clk);
    reset = 0;
    for (clocks = 0; clocks < 100000 && shared_mem[0] != 0; clocks = clocks + 1)
        @(negedge clk);
    if (shared_mem[0] != 0)
        $fatal(1, "DSP never published reset handshake pc=%04h ir=%04h",
               debug_pc, debug_ir);
    shared_mem[3] = command[15:0];
    for (clocks = 0; clocks < 500000 && shared_mem[0] != 16'h5555;
         clocks = clocks + 1)
        @(negedge clk);
    if (shared_mem[0] != 16'h5555)
        $fatal(1, "DSP command timeout pc=%04h ir=%04h", debug_pc, debug_ir);
    repeat (200000) @(negedge clk);

    if (debug_illegal != 0) $fatal(1, "illegal opcode count %0d", debug_illegal);
    $display("DSP command=%0d pc=%04h ir=%04h instructions=%0d line_writes=%0d flags=%0d/%0d/%0d tail=%04h",
             command, debug_pc, debug_ir, debug_instructions, line_writes,
             flag0_edges, flag1_edges, flag2_edges, line_mem[14'h3fff]);
    if ($value$plusargs("LINE_DUMP=%s", line_dump_path)) begin
        $writememh(line_dump_path, line_mem);
        $display("Wrote DSP line RAM to %s", line_dump_path);
    end
    $display("PASS tb_tas_dsp_boot");
    $finish;
end
endmodule
