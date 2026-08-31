`timescale 1ns/1ps

module tb_download_control;
reg clk = 0;
always #5 clk = ~clk;

reg reset_hw = 1;
reg reset_sys = 1;
reg ioctl_download = 0;
reg [15:0] ioctl_index = 0;
wire rom_download;
wire rom_loaded;
wire board_reset;

tas_download_control dut (
    .clk(clk),
    .reset_hw(reset_hw),
    .reset_sys(reset_sys),
    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .rom_download(rom_download),
    .rom_loaded(rom_loaded),
    .board_reset(board_reset)
);

task tick;
begin
    @(posedge clk);
    #1;
end
endtask

initial begin
    tick();
    if (rom_loaded || !board_reset)
        $fatal(1, "reset must start with ROM absent and board held");

    reset_hw = 0;
    reset_sys = 0;
    ioctl_index = 16'd1;
    ioctl_download = 1;
    #1;
    if (!rom_download || !board_reset)
        $fatal(1, "DSP ROM transfer must be a board-resetting ROM download");
    tick();
    ioctl_download = 0;
    tick();
    if (!rom_loaded || board_reset)
        $fatal(1, "board must run after the ROM transfer completes");

    ioctl_index = 16'd254;
    ioctl_download = 1;
    #1;
    if (rom_download || !rom_loaded || board_reset)
        $fatal(1, "DIP upload must not disturb the running board");
    tick();
    ioctl_download = 0;
    tick();
    if (!rom_loaded || board_reset)
        $fatal(1, "board must remain running after DIP upload");

    reset_sys = 1;
    #1;
    if (!board_reset || !rom_loaded)
        $fatal(1, "user reset must hold the board without forgetting ROM");
    tick();
    reset_sys = 0;
    tick();
    if (board_reset || !rom_loaded)
        $fatal(1, "board must resume after user reset");

    ioctl_index = 16'd0;
    ioctl_download = 1;
    #1;
    if (!rom_download || !board_reset)
        $fatal(1, "main ROM transfer must still reset the board");

    // A hardware reset in the middle of a transfer forgets the partial ROM.
    reset_hw = 1;
    tick();
    if (rom_loaded || !board_reset)
        $fatal(1, "hardware reset did not discard a partial ROM transfer");
    reset_hw = 0;
    tick();
    ioctl_download = 0;
    tick();
    if (!rom_loaded || board_reset)
        $fatal(1, "clean transfer completion after hardware reset failed");

    $display("PASS tb_download_control");
    $finish;
end
endmodule
