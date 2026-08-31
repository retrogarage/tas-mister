// Separate ROM transfers from auxiliary MRA payloads.  MiSTer sends arcade
// DIP switches as an ioctl download at index 254; that transfer must not clear
// ROM-loaded state or reset the emulated board.
module tas_download_control (
    input              clk,
    input              reset_hw,
    input              reset_sys,
    input              ioctl_download,
    input      [15:0]  ioctl_index,
    output             rom_download,
    output reg         rom_loaded,
    output             board_reset
);

assign rom_download = ioctl_download &&
    ((ioctl_index == 16'd0) || (ioctl_index == 16'd1));

reg old_rom_download;
always @(posedge clk) begin
    if (reset_hw) begin
        old_rom_download <= 1'b0;
        rom_loaded <= 1'b0;
    end else begin
        old_rom_download <= rom_download;
        if (rom_download)
            rom_loaded <= 1'b0;
        else if (old_rom_download)
            rom_loaded <= 1'b1;
    end
end

assign board_reset = reset_sys | !rom_loaded | rom_download;

endmodule
