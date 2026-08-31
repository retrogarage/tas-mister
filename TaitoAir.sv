// Taito Air System for MiSTer -- bring-up build for Top Landing.
module emu
(
    `include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 3'b000;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE,
        SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS,
        SDRAM_nRAS, SDRAM_nCS} = 'Z;

// Leave scanline generation entirely to MiSTer's HDMI scaler/filter presets.
// VGA_SL controls the framework's native-line darkener; it is not required
// for a preset's adaptive vertical filter and would duplicate that effect.
assign VGA_SL = 2'b00;
assign VGA_F1 = 1'b0;
assign VGA_SCALER = 1'b0;
assign VGA_DISABLE = 1'b0;
assign HDMI_FREEZE = 1'b0;
assign HDMI_BLACKOUT = 1'b0;
assign HDMI_BOB_DEINT = 1'b0;

assign AUDIO_S = 1'b1;
assign AUDIO_MIX = 2'b00;

assign LED_DISK = 2'b00;
assign LED_POWER = 2'b00;
assign BUTTONS = 2'b00;
assign VIDEO_ARX = 13'd4;
assign VIDEO_ARY = 13'd3;

`include "build_id.v"
localparam CONF_STR = {
    "Taito Air System;;",
    "T[0],Reset;",
    "O1,Control indicators,Off,On;",
    "O23,Throttle input,Gamepad hold,HOTAS position,Buttons hold;",
    "DIP;",
    "J1,Start,Coin,Service,Throttle Up,Throttle Down;",
    "jn,Start,Select,-,-,-;",
    "V,v", `BUILD_DATE
};

wire [1:0] buttons;
wire [127:0] status;
wire [31:0] joystick_0;
wire [15:0] joystick_l_analog_0;
wire [15:0] joystick_r_analog_0;
wire ioctl_download;
wire [15:0] ioctl_index;
wire ioctl_wr;
wire [26:0] ioctl_addr;
wire [7:0] ioctl_dout;
wire ioctl_wait;

wire clk_sys;
wire pll_locked;
// Keep the conventional instance name: MiSTer's framework SDC uses it when
// separating the core clock from HDMI, audio and HPS clock domains.
pll pll (
    .refclk(CLK_50M),
    .rst(1'b0),
    .outclk_0(clk_sys),
    .locked(pll_locked)
);

hps_io #(.CONF_STR(CONF_STR), .WIDE(0)) hps_io_inst (
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .buttons(buttons),
    .joystick_0(joystick_0),
    .joystick_l_analog_0(joystick_l_analog_0),
    .joystick_r_analog_0(joystick_r_analog_0),
    .status(status),
    .status_menumask(16'd0),
    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait)
);

// MiSTer asserts status[0] while it initializes video and sends an arcade ROM.
// The raster and ROM transport therefore must remain alive during that reset;
// only the emulated board is held until the loader has completed.
wire reset_hw = RESET | !pll_locked;
wire reset_sys = reset_hw | status[0] | buttons[1];
wire rom_download;
wire rom_loaded;
wire board_reset;

tas_download_control download_control (
    .clk(clk_sys),
    .reset_hw(reset_hw),
    .reset_sys(reset_sys),
    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .rom_download(rom_download),
    .rom_loaded(rom_loaded),
    .board_reset(board_reset)
);

wire rom_cpu_req;
wire [23:0] rom_cpu_addr;
wire rom_cpu_ack;
wire [15:0] rom_cpu_data;
wire gfx_req;
wire [19:0] gfx_addr;
wire gfx_ack;
wire [63:0] gfx_data;
wire audio_sample_req;
wire [23:0] audio_sample_addr;
wire audio_sample_ack;
wire [63:0] audio_sample_data;
wire debug_wr_ack;
wire [31:0] debug_cpu_blocked_clocks;
wire [31:0] debug_cpu_unsafe_cache_hits;
reg debug_wr_req;
reg [27:0] debug_wr_addr;
reg [63:0] debug_wr_data;
wire video_ddr_background_safe;

assign DDRAM_CLK = clk_sys;
tas_ddr_rom rom_store (
    .clk(clk_sys),
    .reset(reset_hw),
    .background_safe(video_ddr_background_safe),
    .ioctl_wr(ioctl_wr && ioctl_download && ioctl_index == 16'd0),
    .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .cpu_req(rom_cpu_req),
    .cpu_addr(rom_cpu_addr),
    .cpu_ack(rom_cpu_ack),
    .cpu_data(rom_cpu_data),
    .gfx_req(gfx_req),
    .gfx_addr(gfx_addr),
    .gfx_ack(gfx_ack),
    .gfx_data(gfx_data),
    .audio_req(audio_sample_req),
    .audio_addr(audio_sample_addr),
    .audio_ack(audio_sample_ack),
    .audio_data(audio_sample_data),
    .debug_wr_req(debug_wr_req),
    .debug_wr_addr(debug_wr_addr),
    .debug_wr_data(debug_wr_data),
    .debug_wr_ack(debug_wr_ack),
    .debug_cpu_blocked_clocks(debug_cpu_blocked_clocks),
    .debug_cpu_unsafe_cache_hits(debug_cpu_unsafe_cache_hits),
    .DDRAM_BUSY(DDRAM_BUSY),
    .DDRAM_DOUT(DDRAM_DOUT),
    .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
    .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
    .DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_DIN(DDRAM_DIN),
    .DDRAM_BE(DDRAM_BE),
    .DDRAM_RD(DDRAM_RD),
    .DDRAM_WE(DDRAM_WE)
);

wire hblank;
wire vblank;
wire hsync;
wire vsync;
wire [7:0] video_r;
wire [7:0] video_g;
wire [7:0] video_b;
wire ce_pix;
wire [23:0] debug_addr;
wire [23:0] debug_fetch_addr;
wire [31:0] debug_cycles;
wire [7:0] debug_sysctrl;
wire debug_irq;
wire debug_halted;
wire debug_fault;
wire [23:0] debug_fault_addr;
wire [31:0] debug_fault_cycles;
wire [23:0] debug_hist0;
wire [23:0] debug_hist1;
wire [23:0] debug_hist2;
wire [23:0] debug_hist3;
wire [23:0] debug_hist4;
wire [23:0] debug_hist5;
wire [23:0] debug_hist6;
wire [23:0] debug_hist7;
wire sound_main_cs;
wire sound_main_wr;
wire sound_main_port;
wire [3:0] sound_main_din;
wire [3:0] sound_main_dout;
wire signed [15:0] sound_audio_left;
wire signed [15:0] sound_audio_right;
wire [15:0] debug_z80_addr;
wire [2:0] debug_sound_rom_bank;
wire debug_sound_reset_n;
wire debug_z80_halted;
wire [31:0] debug_z80_m1;
wire [31:0] debug_ym_writes;
wire [15:0] debug_sample_a_misses;
wire [15:0] debug_sample_b_misses;
wire [15:0] debug_sample_underruns;
wire [16:0] video_vco_addr;
wire [15:0] video_vco_data;
wire [11:0] video_palette_addr;
wire [15:0] video_palette_data;
wire [12:0] video_gradient_addr;
wire [15:0] video_gradient_low;
wire [15:0] video_gradient_high;
wire [127:0] video_grw_regs;
wire video_gradbank;
wire [9:0] video_bg0_scrollx;
wire [9:0] video_bg0_scrolly;
wire [15:0] video_bg0_zoom;
wire [9:0] video_bg1_scrollx;
wire [9:0] video_bg1_scrolly;
wire [15:0] video_bg1_zoom;
wire [63:0] debug_gradient;
wire [63:0] debug_timing;
wire [11:0] dsp_prog_addr;
wire [15:0] dsp_prog_data;
wire [15:0] debug_dsp_pc;
wire [15:0] debug_dsp_ir;
wire [31:0] debug_dsp_instructions;
wire [15:0] debug_dsp_illegal;
wire [15:0] debug_dsp_addr;
wire [15:0] debug_dsp_data;
wire [2:0] debug_dsp_flags;
wire [2:0] dsp_flag_strobe;
wire dma_fb_erase_strobe;
wire dma_fb_copy_strobe;
wire video_line_req;
wire [13:0] video_line_addr;
wire video_line_ack;
wire [15:0] video_line_data;
wire video_polygon_hold;
wire [11:0] flight_throttle_counter;
wire [11:0] flight_stick_x_counter;
wire [11:0] flight_stick_y_counter;
wire [7:0] dswa;
wire [7:0] dswb;

// Arcade MRAs stream their switch payload independently of the ROM download.
// Keep the documented all-open factory state until MiSTer supplies it.
tas_dip_switches dip_switches (
    .clk(clk_sys),
    .ioctl_wr(ioctl_wr),
    .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_dout),
    .dswa(dswa),
    .dswb(dswb)
);

tas_dsp_program dsp_program (
    .clk(clk_sys),
    // Index 0 is copied directly into DDR3 by MiSTer's MRA loader, so the
    // C25 program uses a separate streamed ROM entry.
    .ioctl_wr(ioctl_wr && ioctl_download && ioctl_index == 16'd1),
    .ioctl_addr(ioctl_addr[12:0]),
    .ioctl_data(ioctl_dout),
    .cpu_addr(dsp_prog_addr),
    .cpu_data(dsp_prog_data)
);

// Preserve the original eight trace words, then append four cadence words,
// four audio words and two arbitration words. Linux can read all eighteen
// from physical address 0x30300000 without JTAG or SignalTap. The counters are observational only
// and never feed back into board, video, or audio timing.
reg [19:0] debug_timer;
reg [2:0] debug_state;
reg [4:0] debug_word;
reg [63:0] debug_payload [0:17];
wire [31:0] telemetry_frame_count;
wire [31:0] telemetry_frame_cpu_cycles;
wire [31:0] telemetry_frame_dsp_instructions;
wire [31:0] telemetry_total_dsp_instructions;
wire [15:0] telemetry_flag_count_0;
wire [15:0] telemetry_flag_count_1;
wire [15:0] telemetry_flag_count_2;
wire [15:0] telemetry_dma_copy_count;
wire [15:0] telemetry_dma_erase_count;
wire [31:0] telemetry_polygon_hold_total;
wire [31:0] telemetry_polygon_hold_max;

tas_cadence_telemetry cadence_telemetry (
    .clk(clk_sys), .reset(board_reset), .vblank(vblank),
    .cpu_bus_cycles(debug_cycles),
    .dsp_reset(board_reset || !debug_sysctrl[0]),
    .dsp_instructions(debug_dsp_instructions),
    .dsp_flag_strobe(dsp_flag_strobe),
    .dma_copy_strobe(dma_fb_copy_strobe),
    .dma_erase_strobe(dma_fb_erase_strobe),
    .polygon_hold(video_polygon_hold),
    .frame_count(telemetry_frame_count),
    .frame_cpu_bus_cycles(telemetry_frame_cpu_cycles),
    .frame_dsp_instructions(telemetry_frame_dsp_instructions),
    .total_dsp_instructions(telemetry_total_dsp_instructions),
    .flag_count_0(telemetry_flag_count_0),
    .flag_count_1(telemetry_flag_count_1),
    .flag_count_2(telemetry_flag_count_2),
    .dma_copy_count(telemetry_dma_copy_count),
    .dma_erase_count(telemetry_dma_erase_count),
    .polygon_hold_total(telemetry_polygon_hold_total),
    .polygon_hold_max(telemetry_polygon_hold_max)
);

always @(posedge clk_sys) begin
    if (reset_hw) begin
        debug_timer <= 20'd0;
        debug_state <= 3'd0;
        debug_wr_req <= 1'b0;
        debug_wr_addr <= 28'd0;
        debug_wr_data <= 64'd0;
        debug_word <= 5'd0;
        debug_payload[0] <= 64'd0;
        debug_payload[1] <= 64'd0;
        debug_payload[2] <= 64'd0;
        debug_payload[3] <= 64'd0;
        debug_payload[4] <= 64'd0;
        debug_payload[5] <= 64'd0;
        debug_payload[6] <= 64'd0;
        debug_payload[7] <= 64'd0;
        debug_payload[8] <= 64'd0;
        debug_payload[9] <= 64'd0;
        debug_payload[10] <= 64'd0;
        debug_payload[11] <= 64'd0;
        debug_payload[12] <= 64'd0;
        debug_payload[13] <= 64'd0;
        debug_payload[14] <= 64'd0;
        debug_payload[15] <= 64'd0;
        debug_payload[16] <= 64'd0;
        debug_payload[17] <= 64'd0;
    end else begin
        case (debug_state)
            3'd0: begin
                debug_wr_req <= 1'b0;
                // Telemetry is diagnostic only. Start each eighteen-word
                // burst during vertical blank so it cannot steal the DDR
                // service window from a visible TC0080VCO scanline.  Hold a
                // saturated timer until blanking rather than wrapping and
                // accidentally postponing the sample by another interval.
                if (rom_loaded && &debug_timer && vblank) begin
                    debug_payload[0] <= {
                        debug_fetch_addr, debug_addr, debug_cycles[15:0]
                    };
                    debug_payload[1] <= {
                        debug_cycles, 20'd0, debug_sysctrl,
                        rom_loaded, ioctl_download, debug_halted, debug_irq
                    };
                    debug_payload[2] <= {
                        debug_fault_cycles, debug_fault_addr,
                        debug_fault, 7'd0
                    };
                    debug_payload[3] <= {
                        debug_dsp_pc, debug_dsp_ir, debug_dsp_illegal,
                        debug_dsp_flags, 13'd0
                    };
                    debug_payload[4] <= video_grw_regs[63:0];
                    debug_payload[5] <= video_grw_regs[127:64];
                    debug_payload[6] <= debug_gradient;
                    debug_payload[7] <= debug_timing;
                    debug_payload[8] <= {
                        telemetry_frame_count, telemetry_frame_cpu_cycles
                    };
                    debug_payload[9] <= {
                        telemetry_frame_dsp_instructions,
                        telemetry_total_dsp_instructions
                    };
                    debug_payload[10] <= {
                        telemetry_flag_count_0, telemetry_flag_count_1,
                        telemetry_flag_count_2, telemetry_dma_copy_count
                    };
                    // TAS1 identifies the append-only cadence layout.  The
                    // final half-word is the independent 68000 erase count.
                    debug_payload[11] <= {
                        32'h54415331, 16'd0, telemetry_dma_erase_count
                    };
                    debug_payload[12] <= {
                        debug_z80_m1, debug_z80_addr,
                        debug_sound_rom_bank, debug_sound_reset_n,
                        debug_z80_halted, 11'd0
                    };
                    debug_payload[13] <= {
                        debug_ym_writes, debug_sample_a_misses,
                        debug_sample_b_misses
                    };
                    debug_payload[14] <= {
                        debug_sample_underruns, 23'd0, audio_sample_req,
                        audio_sample_addr
                    };
                    debug_payload[15] <= {
                        32'h54415332, sound_audio_left, sound_audio_right
                    };
                    debug_payload[16] <= {
                        telemetry_polygon_hold_total,
                        telemetry_polygon_hold_max
                    };
                    debug_payload[17] <= {
                        debug_cpu_blocked_clocks,
                        debug_cpu_unsafe_cache_hits
                    };
                    debug_word <= 5'd0;
                    debug_state <= 3'd1;
                end else if (!(&debug_timer)) begin
                    debug_timer <= debug_timer + 1'd1;
                end
            end
            3'd1: begin
                // If a heavily loaded blanking interval ends mid-burst,
                // pause the remaining words until the next vertical blank.
                // No new diagnostic transaction is launched in visible time.
                debug_wr_req <= 1'b0;
                if (vblank) begin
                    debug_wr_addr <=
                        28'h0300000 + {20'd0, debug_word, 3'b000};
                    debug_wr_data <= debug_payload[debug_word];
                    debug_wr_req <= 1'b1;
                    debug_state <= 3'd2;
                end
            end
            3'd2: if (debug_wr_ack) begin
                debug_wr_req <= 1'b0;
                if (debug_word == 5'd17) begin
                    debug_timer <= 20'd0;
                    debug_state <= 3'd0;
                end else begin
                    debug_word <= debug_word + 1'd1;
                    debug_state <= 3'd1;
                end
            end
            default: begin
                debug_wr_req <= 1'b0;
                debug_state <= 3'd0;
            end
        endcase
    end
end

assign AUDIO_L = sound_audio_left;
assign AUDIO_R = sound_audio_right;

tas_sound sound_board (
    .clk(clk_sys),
    .reset(board_reset),
    .main_cs(sound_main_cs),
    .main_wr(sound_main_wr),
    .main_port(sound_main_port),
    .main_din(sound_main_din),
    .main_dout(sound_main_dout),
    .sample_req(audio_sample_req),
    .sample_addr(audio_sample_addr),
    .sample_ack(audio_sample_ack),
    .sample_data(audio_sample_data),
    .audio_left(sound_audio_left),
    .audio_right(sound_audio_right),
    .debug_z80_addr(debug_z80_addr),
    .debug_rom_bank(debug_sound_rom_bank),
    .debug_reset_n(debug_sound_reset_n),
    .debug_z80_halted(debug_z80_halted),
    .debug_z80_m1(debug_z80_m1),
    .debug_ym_writes(debug_ym_writes),
    .debug_sample_a_misses(debug_sample_a_misses),
    .debug_sample_b_misses(debug_sample_b_misses),
    .debug_sample_underruns(debug_sample_underruns)
);

tas_main main_board (
    .clk(clk_sys),
    .reset(board_reset),
    .vblank(vblank),
    .controls(joystick_0),
    .joystick_l_analog(joystick_l_analog_0),
    .joystick_r_analog(joystick_r_analog_0),
    .throttle_mode(status[3:2]),
    .dswa(dswa),
    .dswb(dswb),
    .flight_throttle_counter(flight_throttle_counter),
    .flight_stick_x_counter(flight_stick_x_counter),
    .flight_stick_y_counter(flight_stick_y_counter),
    .sound_main_cs(sound_main_cs),
    .sound_main_wr(sound_main_wr),
    .sound_main_port(sound_main_port),
    .sound_main_din(sound_main_din),
    .sound_main_dout(sound_main_dout),
    .video_vco_addr(video_vco_addr),
    .video_vco_data(video_vco_data),
    .video_palette_addr(video_palette_addr),
    .video_palette_data(video_palette_data),
    .video_gradient_addr(video_gradient_addr),
    .video_gradient_low(video_gradient_low),
    .video_gradient_high(video_gradient_high),
    .video_grw_regs(video_grw_regs),
    .video_gradbank(video_gradbank),
    .video_bg0_scrollx(video_bg0_scrollx),
    .video_bg0_scrolly(video_bg0_scrolly),
    .video_bg0_zoom(video_bg0_zoom),
    .video_bg1_scrollx(video_bg1_scrollx),
    .video_bg1_scrolly(video_bg1_scrolly),
    .video_bg1_zoom(video_bg1_zoom),
    .video_line_req(video_line_req),
    .video_line_addr(video_line_addr),
    .video_line_ack(video_line_ack),
    .video_line_data(video_line_data),
    .video_polygon_hold(video_polygon_hold),
    .dsp_prog_addr(dsp_prog_addr),
    .dsp_prog_data(dsp_prog_data),
    .rom_req(rom_cpu_req),
    .rom_addr(rom_cpu_addr),
    .rom_ack(rom_cpu_ack),
    .rom_data(rom_cpu_data),
    .debug_addr(debug_addr),
    .debug_fetch_addr(debug_fetch_addr),
    .debug_cycles(debug_cycles),
    .debug_sysctrl(debug_sysctrl),
    .debug_irq(debug_irq),
    .debug_halted(debug_halted),
    .debug_fault(debug_fault),
    .debug_fault_addr(debug_fault_addr),
    .debug_fault_cycles(debug_fault_cycles),
    .debug_hist0(debug_hist0),
    .debug_hist1(debug_hist1),
    .debug_hist2(debug_hist2),
    .debug_hist3(debug_hist3),
    .debug_hist4(debug_hist4),
    .debug_hist5(debug_hist5),
    .debug_hist6(debug_hist6),
    .debug_hist7(debug_hist7),
    .debug_dsp_pc(debug_dsp_pc),
    .debug_dsp_ir(debug_dsp_ir),
    .debug_dsp_instructions(debug_dsp_instructions),
    .debug_dsp_illegal(debug_dsp_illegal),
    .debug_dsp_addr(debug_dsp_addr),
    .debug_dsp_data(debug_dsp_data),
    .debug_dsp_flags(debug_dsp_flags),
    .dsp_flag_strobe(dsp_flag_strobe),
    .dma_fb_erase_strobe(dma_fb_erase_strobe),
    .dma_fb_copy_strobe(dma_fb_copy_strobe)
);

tas_video game_video (
    .clk(clk_sys),
    .reset(reset_hw),
    .rom_loaded(rom_loaded),
    .download_active(rom_download),
    .throttle_overlay_enable(status[1]),
    .throttle_counter(flight_throttle_counter),
    .stick_x_counter(flight_stick_x_counter),
    .stick_y_counter(flight_stick_y_counter),
    .vco_addr(video_vco_addr),
    .vco_data(video_vco_data),
    .palette_addr(video_palette_addr),
    .palette_data(video_palette_data),
    .gradient_addr(video_gradient_addr),
    .gradient_low(video_gradient_low),
    .gradient_high(video_gradient_high),
    .grw_regs(video_grw_regs),
    .gradbank(video_gradbank),
    .bg0_scrollx(video_bg0_scrollx),
    .bg0_scrolly(video_bg0_scrolly),
    .bg0_zoom(video_bg0_zoom),
    .bg1_scrollx(video_bg1_scrollx),
    .bg1_scrolly(video_bg1_scrolly),
    .bg1_zoom(video_bg1_zoom),
    .dsp_flag_strobe(dsp_flag_strobe),
    .dma_fb_erase_strobe(dma_fb_erase_strobe),
    .dma_fb_copy_strobe(dma_fb_copy_strobe),
    .line_req(video_line_req),
    .line_addr(video_line_addr),
    .line_ack(video_line_ack),
    .line_data(video_line_data),
    .gfx_req(gfx_req),
    .gfx_addr(gfx_addr),
    .gfx_ack(gfx_ack),
    .gfx_data(gfx_data),
    .ce_pix(ce_pix),
    .hblank(hblank),
    .vblank(vblank),
    .hsync(hsync),
    .vsync(vsync),
    .red(video_r),
    .green(video_g),
    .blue(video_b),
    .debug_gradient(debug_gradient),
    .debug_timing(debug_timing),
    .ddr_background_safe(video_ddr_background_safe),
    .polygon_hold(video_polygon_hold)
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL = ce_pix;
assign VGA_DE = ~(hblank | vblank);
assign VGA_HS = hsync;
assign VGA_VS = vsync;
assign VGA_R = video_r;
assign VGA_G = video_g;
assign VGA_B = video_b;

assign LED_USER = rom_loaded && (debug_cycles[18] ^ debug_cycles[15]);

endmodule
