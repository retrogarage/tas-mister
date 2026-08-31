// Top Landing sound board: 4 MHz Z80, TC0140SYT communication interface and
// 8 MHz YM2610.  The address decode follows the FPGA-proven Taito F2 sound
// board implementation; Top Landing's original b62-42.34 program ROM uses
// the same map.
module tas_sound (
    input                    clk,
    input                    reset,

    input                    main_cs,
    input                    main_wr,
    input                    main_port,
    input      [3:0]         main_din,
    output     [3:0]         main_dout,

    output reg               sample_req,
    output reg [23:0]        sample_addr,
    input                    sample_ack,
    input      [63:0]        sample_data,

    output signed [15:0]     audio_left,
    output signed [15:0]     audio_right,

    output     [15:0]        debug_z80_addr,
    output     [2:0]         debug_rom_bank,
    output                   debug_reset_n,
    output                   debug_z80_halted,
    output reg [31:0]        debug_z80_m1,
    output reg [31:0]        debug_ym_writes,
    output reg [15:0]        debug_sample_a_misses,
    output reg [15:0]        debug_sample_b_misses,
    output reg [15:0]        debug_sample_underruns
);

localparam [23:0] AUDIO_ROM_BASE = 24'h0c0000;
localparam [23:0] ADPCMA_BASE    = 24'h200000;
localparam [23:0] ADPCMB_BASE    = 24'h2a0000;

(* ramstyle = "M10K, no_rw_check" *) reg [7:0] sound_ram [0:8191];

reg [7:0] sound_ram_q;
reg [1:0] rom_bank;
reg [2:0] audio_div;

wire ce_8m = audio_div[1:0] == 2'd0;
wire ce_4m = audio_div == 3'd0;

wire [15:0] z80_addr;
wire [7:0] z80_dout;
reg  [7:0] z80_din;
wire z80_m1_n;
wire z80_mreq_n;
wire z80_iorq_n;
wire z80_rd_n;
wire z80_wr_n;
wire z80_rfsh_n;
wire z80_halt_n;
wire z80_busak_n;

wire fixed_rom_cs = !z80_mreq_n && z80_addr[15:14] == 2'b00;
wire bank_rom_cs = !z80_mreq_n && z80_addr[15:14] == 2'b01;
wire sound_ram_cs = !z80_mreq_n && z80_addr[15:13] == 3'b110;
wire ym_access = !z80_mreq_n && z80_addr >= 16'he000 &&
    z80_addr <= 16'he003;
wire ym_cs_n = !ym_access;
wire syt_access = !z80_mreq_n && z80_addr >= 16'he200 &&
    z80_addr <= 16'he201;
wire bank_access = !z80_mreq_n && z80_addr == 16'hf200;
wire [15:0] sound_rom_addr = fixed_rom_cs
    ? {2'b00, z80_addr[13:0]}
    : {rom_bank, z80_addr[13:0]};
wire [23:0] sound_rom_image_addr = AUDIO_ROM_BASE + sound_rom_addr;
wire [20:0] sound_rom_tag = sound_rom_image_addr[23:3];

wire [3:0] syt_sound_dout;
wire sound_reset_n;
wire sound_nmi_n;
wire [3:0] sound_status;
reg old_syt_access;
reg old_bank_access;
reg old_z80_m1_n;
reg old_ym_write_active;
reg old_sample_underrun_active;

tas_tc0140syt sound_comm (
    .clk(clk),
    .reset(reset),
    .main_cs(main_cs),
    .main_wr(main_wr),
    .main_port(main_port),
    .main_din(main_din),
    .main_dout(main_dout),
    // The Z80 bus strobes span several 32 MHz clocks.  Present a one-clock
    // access pulse so the nibble index advances exactly once per bus cycle.
    .sound_cs(syt_access && !old_syt_access),
    .sound_wr(!z80_wr_n),
    .sound_port(z80_addr[0]),
    .sound_din(z80_dout[3:0]),
    .sound_dout(syt_sound_dout),
    .sound_reset_n(sound_reset_n),
    .sound_nmi_n(sound_nmi_n),
    .status(sound_status)
);

wire [7:0] ym_dout;
wire ym_irq_n;
wire [19:0] adpcma_addr;
wire [3:0] adpcma_bank;
wire adpcma_roe_n;
wire [19:0] adpcma_lookahead_addr;
wire [3:0] adpcma_lookahead_bank;
wire adpcma_lookahead_roe_n;
wire [23:0] adpcmb_addr;
wire adpcmb_roe_n;
wire signed [15:0] ym_left;
wire signed [15:0] ym_right;

wire [23:0] adpcma_image_addr = ADPCMA_BASE +
    {adpcma_bank, adpcma_addr};
wire [23:0] adpcmb_image_addr = ADPCMB_BASE + adpcmb_addr;
wire [23:0] adpcma_lookahead_image_addr = ADPCMA_BASE +
    {adpcma_lookahead_bank, adpcma_lookahead_addr};
wire [20:0] adpcma_tag = adpcma_image_addr[23:3];
wire [20:0] adpcmb_tag = adpcmb_image_addr[23:3];
wire [20:0] adpcmb_next_tag = adpcmb_tag + 21'd1;
wire [20:0] adpcma_lookahead_tag =
    adpcma_lookahead_image_addr[23:3];

reg [20:0] sound_rom_cache_tag;
reg [63:0] sound_rom_cache_data;
reg sound_rom_cache_valid;
reg [1:0] request_kind;

localparam [1:0] REQUEST_ROM = 2'd0;
localparam [1:0] REQUEST_A   = 2'd1;
localparam [1:0] REQUEST_B   = 2'd2;

wire adpcma_cache_hit;
wire adpcma_lookahead_cache_hit;
wire adpcmb_cache_hit;
wire adpcmb_next_cache_hit;
wire [63:0] adpcma_cache_data;
wire [63:0] adpcmb_cache_data;
wire adpcma_cache_fill = sample_req && sample_ack &&
    request_kind == REQUEST_A;
wire adpcmb_cache_fill = sample_req && sample_ack &&
    request_kind == REQUEST_B;
wire sound_rom_cache_hit = sound_rom_cache_valid &&
    sound_rom_cache_tag == sound_rom_tag;
wire sound_rom_required = (fixed_rom_cs || bank_rom_cs) &&
    z80_rfsh_n;
wire z80_wait_n = !sound_rom_required || sound_rom_cache_hit;
wire [7:0] sound_rom_data = sound_rom_cache_data[
    {sound_rom_image_addr[2:0], 3'b000} +: 8];
wire [7:0] adpcma_data = adpcma_cache_hit
    ? adpcma_cache_data[{adpcma_image_addr[2:0], 3'b000} +: 8]
    : 8'hff;
wire [7:0] adpcmb_data = adpcmb_cache_hit
    ? adpcmb_cache_data[{adpcmb_image_addr[2:0], 3'b000} +: 8]
    : 8'hff;

tas_audio_line_cache #(.LINES(8)) adpcma_cache (
    .clk(clk), .reset(reset),
    .lookup_tag(adpcma_tag), .lookup_hit(adpcma_cache_hit),
    .lookup_data(adpcma_cache_data),
    .probe_tag(adpcma_lookahead_tag),
    .probe_hit(adpcma_lookahead_cache_hit),
    .fill(adpcma_cache_fill), .fill_tag(sample_addr[23:3]),
    .fill_data(sample_data)
);

tas_audio_line_cache #(.LINES(2)) adpcmb_cache (
    .clk(clk), .reset(reset),
    .lookup_tag(adpcmb_tag), .lookup_hit(adpcmb_cache_hit),
    .lookup_data(adpcmb_cache_data),
    .probe_tag(adpcmb_next_tag), .probe_hit(adpcmb_next_cache_hit),
    .fill(adpcmb_cache_fill), .fill_tag(sample_addr[23:3]),
    .fill_data(sample_data)
);

jt10 ym2610 (
    .rst(!sound_reset_n),
    .clk(clk),
    .cen(ce_8m),
    .din(z80_dout),
    .addr(z80_addr[1:0]),
    .cs_n(ym_cs_n),
    .wr_n(z80_wr_n),
    .dout(ym_dout),
    .irq_n(ym_irq_n),
    .adpcma_addr(adpcma_addr),
    .adpcma_bank(adpcma_bank),
    .adpcma_roe_n(adpcma_roe_n),
    .adpcma_lookahead_addr(adpcma_lookahead_addr),
    .adpcma_lookahead_bank(adpcma_lookahead_bank),
    .adpcma_lookahead_roe_n(adpcma_lookahead_roe_n),
    .adpcma_data(adpcma_data),
    .adpcmb_addr(adpcmb_addr),
    .adpcmb_roe_n(adpcmb_roe_n),
    .adpcmb_data(adpcmb_data),
    .psg_A(),
    .psg_B(),
    .psg_C(),
    .fm_snd(),
    .psg_snd(),
    .snd_right(ym_right),
    .snd_left(ym_left),
    .snd_sample(),
    .ch_enable(6'b111111)
);

tv80s z80 (
    .reset_n(sound_reset_n),
    .clk(clk),
    .cen(ce_4m),
    .wait_n(z80_wait_n),
    .int_n(ym_irq_n),
    .nmi_n(sound_nmi_n),
    .busrq_n(1'b1),
    .m1_n(z80_m1_n),
    .mreq_n(z80_mreq_n),
    .iorq_n(z80_iorq_n),
    .rd_n(z80_rd_n),
    .wr_n(z80_wr_n),
    .rfsh_n(z80_rfsh_n),
    .halt_n(z80_halt_n),
    .busak_n(z80_busak_n),
    .A(z80_addr),
    .di(z80_din),
    .dout(z80_dout)
);

always @* begin
    z80_din = 8'hff;
    if (fixed_rom_cs || bank_rom_cs)
        z80_din = sound_rom_data;
    else if (sound_ram_cs)
        z80_din = sound_ram_q;
    else if (!ym_cs_n)
        z80_din = ym_dout;
    else if (syt_access)
        z80_din = {4'd0, syt_sound_dout};
end

// JT10's combined outputs already contain FM, ADPCM and SSG. Preserve the
// independent left/right channels without adding the SSG a second time.
assign audio_left = ym_left;
assign audio_right = ym_right;

assign debug_z80_addr = z80_addr;
assign debug_rom_bank = {1'b0, rom_bank};
assign debug_reset_n = sound_reset_n;
assign debug_z80_halted = !z80_halt_n;

wire ym_write_active = !ym_cs_n && !z80_wr_n;
wire sample_underrun_active =
    (!adpcma_roe_n && !adpcma_cache_hit) ||
    (!adpcmb_roe_n && !adpcmb_cache_hit);

// Sound RAM is independent of the board-reset state machine so Quartus can
// infer one synchronous M10K-backed memory.
always @(posedge clk) begin
    sound_ram_q <= sound_ram[z80_addr[12:0]];
    if (!reset && sound_ram_cs && !z80_wr_n)
        sound_ram[z80_addr[12:0]] <= z80_dout;
end

always @(posedge clk) begin
    old_syt_access <= syt_access;
    old_bank_access <= bank_access;
    old_z80_m1_n <= z80_m1_n;
    old_ym_write_active <= ym_write_active;
    old_sample_underrun_active <= sample_underrun_active;

    if (reset) begin
        audio_div <= 3'd0;
        rom_bank <= 2'd0;
        old_syt_access <= 1'b0;
        old_bank_access <= 1'b0;
        old_z80_m1_n <= 1'b1;
        old_ym_write_active <= 1'b0;
        old_sample_underrun_active <= 1'b0;
        sample_req <= 1'b0;
        sample_addr <= 24'd0;
        request_kind <= REQUEST_ROM;
        sound_rom_cache_valid <= 1'b0;
        debug_z80_m1 <= 32'd0;
        debug_ym_writes <= 32'd0;
        debug_sample_a_misses <= 16'd0;
        debug_sample_b_misses <= 16'd0;
        debug_sample_underruns <= 16'd0;
    end else begin
        audio_div <= audio_div + 1'd1;

        if (bank_access && !old_bank_access && !z80_wr_n)
            rom_bank <= z80_dout[1:0];

        if (old_z80_m1_n && !z80_m1_n)
            debug_z80_m1 <= debug_z80_m1 + 1'd1;
        if (!old_ym_write_active && ym_write_active)
            debug_ym_writes <= debug_ym_writes + 1'd1;

        // A pair of independent 64-bit line caches converts JT10's ROM-pin
        // interface into low-rate DDR requests.  Address outputs change well
        // before the decoder consumes a new byte, so request on a tag change
        // even while output enable is inactive.
        if (sample_req) begin
            if (sample_ack) begin
                sample_req <= 1'b0;
                case (request_kind)
                    REQUEST_ROM: begin
                        sound_rom_cache_tag <= sample_addr[23:3];
                        sound_rom_cache_data <= sample_data;
                        sound_rom_cache_valid <= 1'b1;
                    end
                    default: begin end
                endcase
            end
        end else if (sound_rom_required && !sound_rom_cache_hit) begin
            sample_addr <= {sound_rom_image_addr[23:3], 3'b000};
            sample_req <= 1'b1;
            request_kind <= REQUEST_ROM;
        end else if (!adpcma_cache_hit) begin
            sample_addr <= {adpcma_image_addr[23:3], 3'b000};
            sample_req <= 1'b1;
            request_kind <= REQUEST_A;
            debug_sample_a_misses <= debug_sample_a_misses + 1'd1;
        end else if (!adpcmb_cache_hit) begin
            sample_addr <= {adpcmb_image_addr[23:3], 3'b000};
            sample_req <= 1'b1;
            request_kind <= REQUEST_B;
            debug_sample_b_misses <= debug_sample_b_misses + 1'd1;
        end else if (!adpcma_lookahead_roe_n &&
                     !adpcma_lookahead_cache_hit) begin
            // JT10 supplies the address that will reach its multiplexed
            // ADPCM-A ROM pins two 666 kHz channel slots later. Warm that
            // line early enough to cover shared-DDR tail latency.
            sample_addr <= {adpcma_lookahead_image_addr[23:3], 3'b000};
            sample_req <= 1'b1;
            request_kind <= REQUEST_A;
        end else if (!adpcmb_next_cache_hit) begin
            // Unlike the multiplexed ADPCM-A bus, JT10 exposes only the
            // ADPCM-B byte being consumed. Keep its next sequential line in
            // the second cache slot so a line crossing does not become a
            // one-for-one demand miss and audible underrun on real DDR.
            sample_addr <= {adpcmb_next_tag, 3'b000};
            sample_req <= 1'b1;
            request_kind <= REQUEST_B;
        end

        if (!old_sample_underrun_active && sample_underrun_active)
            debug_sample_underruns <= debug_sample_underruns + 1'd1;
    end
end

endmodule
