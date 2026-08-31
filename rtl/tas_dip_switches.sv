// MiSTer arcade DIP-switch payload receiver.  hps_io writes MRA switch bytes
// at ioctl index 254; byte 0 is SWA and byte 1 is SWB.
module tas_dip_switches (
    input             clk,
    input             ioctl_wr,
    input      [15:0] ioctl_index,
    input      [26:0] ioctl_addr,
    input       [7:0] ioctl_data,
    output      [7:0] dswa,
    output      [7:0] dswb
);

reg [15:0] dipsw = 16'hffff;

always @(posedge clk) begin
    if (ioctl_wr && (ioctl_index == 16'd254) &&
        (ioctl_addr[26:1] == 26'd0))
        dipsw[{ioctl_addr[0], 3'b000} +: 8] <= ioctl_data;
end

assign dswa = dipsw[7:0];
assign dswb = dipsw[15:8];

endmodule
