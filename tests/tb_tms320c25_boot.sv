`timescale 1ns/1ps

// Runs the untouched Top Landing DSP ROM through its reset RAM clears and
// shared-memory command handshake. This is the first board-software contract
// the real C25 must satisfy before replacing the temporary life-check shim.
module tb_tms320c25_boot;
reg clk = 0;
always #25 clk = ~clk;
reg reset = 1;

wire [11:0] prog_addr;
reg [15:0] prog_data;
wire data_req;
wire data_we;
wire [15:0] data_addr;
wire [15:0] data_wdata;
wire [15:0] debug_pc;
wire [15:0] debug_ir;
wire [31:0] debug_instructions;
wire [15:0] debug_illegal;
wire debug_write;

reg [7:0] program_bytes [0:8191];
reg [15:0] data_mem [0:65535];
wire [15:0] data_rdata = data_mem[data_addr];
wire data_ack = data_req;
integer rom_file;
integer rom_bytes;
integer index;
integer clocks;
integer line_writes;
integer command;
string rom_path;

tas_tms320c25 dut (
    .clk(clk), .reset(reset), .hold(1'b0),
    .prog_addr(prog_addr), .prog_data(prog_data),
    .data_req(data_req), .data_we(data_we), .data_addr(data_addr),
    .data_wdata(data_wdata), .data_ack(data_ack), .data_rdata(data_rdata),
    .debug_pc(debug_pc), .debug_ir(debug_ir),
    .debug_instructions(debug_instructions), .debug_illegal(debug_illegal),
    .debug_write(debug_write)
);

always @(posedge clk) begin
    prog_data <= {program_bytes[{prog_addr,1'b0}],
                  program_bytes[{prog_addr,1'b1}]};
    if (data_req && data_we) begin
        data_mem[data_addr] <= data_wdata;
        if (data_addr >= 16'h4000 && data_addr <= 16'h7fff)
            line_writes <= line_writes + 1;
    end
end

initial begin
    if (!$value$plusargs("ROM=%s", rom_path)) rom_path = "roms/topland.rom";
    if (!$value$plusargs("COMMAND=%d", command)) command = 1;
    for (index = 0; index < 65536; index = index + 1) data_mem[index] = 16'd0;
    data_mem[16'h8000] = 16'hffff;
    for (index = 0; index < 8192; index = index + 1) program_bytes[index] = 8'hff;
    line_writes = 0;
    prog_data = 16'hffff;

    rom_file = $fopen(rom_path, "rb");
    if (!rom_file) $fatal(1, "cannot open Top Landing ROM image");
    if ($fseek(rom_file, 32'h000d0000, 0)) $fatal(1, "cannot seek to DSP ROM");
    rom_bytes = $fread(program_bytes, rom_file);
    $fclose(rom_file);
    if (rom_bytes != 8192) $fatal(1, "short DSP program: %0d bytes", rom_bytes);

    repeat (6) @(negedge clk);
    reset = 0;

    // The ROM clears 544 internal words before publishing the handshake.
    for (clocks = 0; clocks < 100000 && data_mem[16'h8000] != 0;
         clocks = clocks + 1)
        @(negedge clk);
    if (data_mem[16'h8000] != 0)
        $fatal(1, "DSP never cleared shared word 8000; pc=%04h ir=%04h count=%0d illegal=%0d",
               debug_pc, debug_ir, debug_instructions, debug_illegal);

    // Emulate the 68000 acknowledging the life check and issuing command 1.
    data_mem[16'h8003] = command[15:0];
    for (clocks = 0; clocks < 20000 && data_mem[16'h8000] != 16'h5555;
         clocks = clocks + 1)
        @(negedge clk);
    if (data_mem[16'h8000] != 16'h5555)
        $fatal(1, "DSP never wrote 5555; pc=%04h ir=%04h count=%0d illegal=%0d",
               debug_pc, debug_ir, debug_instructions, debug_illegal);
    repeat (200000) @(negedge clk);
    if (debug_illegal != 0) $fatal(1, "illegal opcode count %0d", debug_illegal);

    $display("PASS tb_tms320c25_boot command=%0d pc=%04h ir=%04h instructions=%0d line_writes=%0d",
             command, debug_pc, debug_ir, debug_instructions, line_writes);
    $finish;
end
endmodule
