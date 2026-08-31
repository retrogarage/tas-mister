// TC0080VCO board RAM. The 68000 window exposes 0x10800 16-bit words:
// one complete 64K-word bank followed by a 2K-word control/object tail.
// Keeping those banks explicit avoids rounding the region up to 128K words.
module tas_vco_ram (
    input               clk,
    input               cpu_cs,
    input               cpu_we,
    input               cpu_uds_n,
    input               cpu_lds_n,
    input      [16:0]   cpu_addr,
    input      [15:0]   cpu_din,
    output     [15:0]   cpu_dout,

    input      [16:0]   video_addr,
    output     [15:0]   video_dout
);

wire [15:0] low_cpu_q;
wire [15:0] high_cpu_q;
wire [15:0] low_video_q;
wire [15:0] high_video_q;

tas_ram #(.AW(16), .SECOND_PORT(1)) low_ram (
    .clk(clk), .cs(cpu_cs && !cpu_addr[16]),
    .we(cpu_we), .uds_n(cpu_uds_n), .lds_n(cpu_lds_n),
    .addr(cpu_addr[15:0]), .din(cpu_din), .dout(low_cpu_q),
    .rd2_addr(video_addr[15:0]), .rd2_cs(1'b1), .rd2_we(1'b0),
    .rd2_din(16'd0), .rd2_dout(low_video_q)
);

tas_ram #(.AW(11), .SECOND_PORT(1)) high_ram (
    .clk(clk), .cs(cpu_cs && cpu_addr[16]),
    .we(cpu_we), .uds_n(cpu_uds_n), .lds_n(cpu_lds_n),
    .addr(cpu_addr[10:0]), .din(cpu_din), .dout(high_cpu_q),
    .rd2_addr(video_addr[10:0]), .rd2_cs(1'b1), .rd2_we(1'b0),
    .rd2_din(16'd0), .rd2_dout(high_video_q)
);

assign cpu_dout = cpu_addr[16] ? high_cpu_q : low_cpu_q;
assign video_dout = video_addr[16] ? high_video_q : low_video_q;

endmodule
