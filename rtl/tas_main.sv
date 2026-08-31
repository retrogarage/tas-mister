// First-pass Taito Air main board: cycle-exact 68000 plus the documented
// Top Landing address map. Custom video, DSP and sound devices are represented
// by their writable memory/register windows while those devices are developed.
module tas_main (
    input               clk,
    input               reset,
    input               vblank,
    input      [31:0]   controls,
    input      [15:0]   joystick_l_analog,
    input      [15:0]   joystick_r_analog,
    input      [1:0]    throttle_mode,
    input      [7:0]    dswa,
    input      [7:0]    dswb,
    output     [11:0]   flight_throttle_counter,
    output     [11:0]   flight_stick_x_counter,
    output     [11:0]   flight_stick_y_counter,

    output              sound_main_cs,
    output              sound_main_wr,
    output              sound_main_port,
    output     [3:0]    sound_main_din,
    input      [3:0]    sound_main_dout,

    input      [16:0]   video_vco_addr,
    output     [15:0]   video_vco_data,
    input      [11:0]   video_palette_addr,
    output     [15:0]   video_palette_data,
    input      [12:0]   video_gradient_addr,
    output     [15:0]   video_gradient_low,
    output     [15:0]   video_gradient_high,
    output reg [127:0]  video_grw_regs,
    output              video_gradbank,
    output reg [9:0]    video_bg0_scrollx,
    output reg [9:0]    video_bg0_scrolly,
    output reg [15:0]   video_bg0_zoom,
    output reg [9:0]    video_bg1_scrollx,
    output reg [9:0]    video_bg1_scrolly,
    output reg [15:0]   video_bg1_zoom,

    input               video_line_req,
    input      [13:0]   video_line_addr,
    output reg          video_line_ack,
    output     [15:0]   video_line_data,
    input               video_polygon_hold,

    output     [11:0]   dsp_prog_addr,
    input      [15:0]   dsp_prog_data,

    output reg          rom_req,
    output reg [23:0]   rom_addr,
    input               rom_ack,
    input      [15:0]   rom_data,

    output reg [23:0]   debug_addr,
    output reg [23:0]   debug_fetch_addr,
    output reg [31:0]   debug_cycles,
    output reg [7:0]    debug_sysctrl,
    output              debug_irq,
    output              debug_halted,
    output reg          debug_fault,
    output reg [23:0]   debug_fault_addr,
    output reg [31:0]   debug_fault_cycles,
    output reg [23:0]   debug_hist0,
    output reg [23:0]   debug_hist1,
    output reg [23:0]   debug_hist2,
    output reg [23:0]   debug_hist3,
    output reg [23:0]   debug_hist4,
    output reg [23:0]   debug_hist5,
    output reg [23:0]   debug_hist6,
    output reg [23:0]   debug_hist7,
    output     [15:0]   debug_dsp_pc,
    output     [15:0]   debug_dsp_ir,
    output     [31:0]   debug_dsp_instructions,
    output     [15:0]   debug_dsp_illegal,
    output     [15:0]   debug_dsp_addr,
    output     [15:0]   debug_dsp_data,
    output     [2:0]    debug_dsp_flags,
    output     [2:0]    dsp_flag_strobe,
    output reg          dma_fb_erase_strobe,
    output reg          dma_fb_copy_strobe
);

wire [23:1] cpu_eab;
wire [23:0] cpu_addr = {cpu_eab, 1'b0};
wire [15:0] cpu_dout;
reg  [15:0] cpu_din;
wire        cpu_rnw;
wire        as_n;
wire        uds_n;
wire        lds_n;
wire [2:0]  fc;
wire        cpu_halted_n;
reg         dtack_n;

// The board's MC68000 runs at 12 MHz.  clk is 32 MHz so emit the two
// non-overlapping fx68k phase enables on three of every four clocks.  The
// alternating enable type makes that exactly twelve complete cycles per
// second without introducing a derived fabric clock.
reg [1:0] cpu_enable_div;
reg cpu_phase;
reg en_phi1;
reg en_phi2;
always @(posedge clk) begin
    if (reset) begin
        cpu_enable_div <= 2'd0;
        cpu_phase <= 1'b0;
        en_phi1 <= 1'b0;
        en_phi2 <= 1'b0;
    end else begin
        en_phi1 <= 1'b0;
        en_phi2 <= 1'b0;
        if (cpu_enable_div == 2'd3) begin
            cpu_enable_div <= 2'd0;
        end else begin
            cpu_enable_div <= cpu_enable_div + 1'd1;
            if (cpu_phase) en_phi2 <= 1'b1;
            else en_phi1 <= 1'b1;
            cpu_phase <= ~cpu_phase;
        end
    end
end

reg old_vblank;
reg irq5;
reg [23:0] debug_last_data_addr;
wire iack = !as_n && (fc == 3'b111);
always @(posedge clk) begin
    if (reset) begin
        old_vblank <= 1'b0;
        irq5 <= 1'b0;
    end else begin
        old_vblank <= vblank;
        if (vblank && !old_vblank) irq5 <= 1'b1;
        if (iack) irq5 <= 1'b0;
    end
end

assign debug_irq = irq5;
assign debug_halted = !cpu_halted_n;

fx68k cpu (
    .clk      (clk),
    .extReset (reset),
    .pwrUp    (reset),
    .enPhi1   (en_phi1),
    .enPhi2   (en_phi2),

    .eab      (cpu_eab),
    .iEdb     (cpu_din),
    .oEdb     (cpu_dout),
    .eRWn     (cpu_rnw),
    .ASn      (as_n),
    .UDSn     (uds_n),
    .LDSn     (lds_n),
    .FC0      (fc[0]),
    .FC1      (fc[1]),
    .FC2      (fc[2]),

    .DTACKn   (dtack_n),
    .VPAn     (~iack),
    .BERRn    (1'b1),
    .HALTn    (1'b1),
    .BRn      (1'b1),
    .BGACKn   (1'b1),
    .IPL0n    (irq5 ? 1'b0 : 1'b1),
    .IPL1n    (1'b1),
    .IPL2n    (irq5 ? 1'b0 : 1'b1),

    .BGn      (),
    .E        (),
    .VMAn     (),
    .oRESETn  (),
    .oHALTEDn (cpu_halted_n)
);

localparam P_NONE  = 4'd0;
localparam P_MAIN  = 4'd1;
localparam P_GRAD  = 4'd2;
localparam P_PAL   = 4'd3;
localparam P_VCO   = 4'd4;
localparam P_DMA   = 4'd5;
localparam P_LINE  = 4'd6;
localparam P_DSP   = 4'd7;
localparam P_GRW   = 4'd8;
localparam P_POWER = 4'd9;

reg main_cs, grad_cs, pal_cs, vco_cs, dma_cs, line_cs, dsp_cs, grw_cs, power_cs;
wire [15:0] main_q, grad_low_q, grad_high_q, pal_q, vco_q, dma_q;
wire [15:0] line_q, dsp_q, grw_q, power_q;
wire [15:0] grad_q = cpu_addr[14] ? grad_high_q : grad_low_q;
wire dsp_line_cs;
wire dsp_line_we;
wire [13:0] dsp_line_addr;
wire [15:0] dsp_line_wdata;
wire [15:0] dsp_line_q;
wire line_port_dsp = dsp_line_cs;
wire line_port_video = video_line_req && !line_port_dsp;
wire dsp_shared_cs;
wire dsp_shared_we;
wire [14:0] dsp_shared_addr;
wire [15:0] dsp_shared_wdata;
wire [15:0] dsp_shared_q;
wire dsp_shared_grant = !dsp_cs;
reg dsp_bootstrap_active;
wire shared_ram_dsp_cs = dsp_shared_cs && dsp_shared_grant;
wire shared_ram_cs = dsp_cs || shared_ram_dsp_cs;
wire shared_ram_we = dsp_cs ? !cpu_rnw : dsp_shared_we;
wire [14:0] shared_ram_addr = dsp_cs ? cpu_addr[15:1] : dsp_shared_addr;
wire [15:0] shared_ram_wdata = dsp_cs ? cpu_dout : dsp_shared_wdata;
wire shared_ram_uds_n = dsp_cs ? uds_n : 1'b0;
wire shared_ram_lds_n = dsp_cs ? lds_n : 1'b0;

tas_ram #(.AW(15)) main_ram (
    .clk(clk), .cs(main_cs), .we(!cpu_rnw), .uds_n(uds_n), .lds_n(lds_n),
    .addr(cpu_addr[15:1]), .din(cpu_dout), .dout(main_q),
    .rd2_addr('0), .rd2_cs(1'b0), .rd2_we(1'b0), .rd2_din(16'd0), .rd2_dout()
);
// Gradient colors use two 8K-word planes.  Splitting them here preserves the
// original 16K-word capacity while exposing both halves of one 24-bit color
// to video in a single lookup.
tas_ram #(.AW(13), .SECOND_PORT(1)) gradient_low_ram (
    .clk(clk), .cs(grad_cs && !cpu_addr[14]),
    .we(!cpu_rnw), .uds_n(uds_n), .lds_n(lds_n),
    .addr(cpu_addr[13:1]), .din(cpu_dout), .dout(grad_low_q),
    .rd2_addr(video_gradient_addr), .rd2_cs(1'b1), .rd2_we(1'b0),
    .rd2_din(16'd0), .rd2_dout(video_gradient_low)
);
tas_ram #(.AW(13), .SECOND_PORT(1)) gradient_high_ram (
    .clk(clk), .cs(grad_cs && cpu_addr[14]),
    .we(!cpu_rnw), .uds_n(uds_n), .lds_n(lds_n),
    .addr(cpu_addr[13:1]), .din(cpu_dout), .dout(grad_high_q),
    .rd2_addr(video_gradient_addr), .rd2_cs(1'b1), .rd2_we(1'b0),
    .rd2_din(16'd0), .rd2_dout(video_gradient_high)
);
tas_ram #(.AW(12), .SECOND_PORT(1)) palette_ram (
    // The board exposes 0x188000-0x189fff (4K words) mirrored at
    // 0x18a000-0x18bfff.  cpu_addr[12:1] deliberately implements that mirror.
    .clk(clk), .cs(pal_cs), .we(!cpu_rnw), .uds_n(uds_n), .lds_n(lds_n),
    .addr(cpu_addr[12:1]), .din(cpu_dout), .dout(pal_q),
    .rd2_addr(video_palette_addr), .rd2_cs(1'b1), .rd2_we(1'b0),
    .rd2_din(16'd0), .rd2_dout(video_palette_data)
);
tas_vco_ram tc0080vco_ram (
    .clk(clk), .cpu_cs(vco_cs), .cpu_we(!cpu_rnw),
    .cpu_uds_n(uds_n), .cpu_lds_n(lds_n),
    .cpu_addr(cpu_addr[17:1]), .cpu_din(cpu_dout), .cpu_dout(vco_q),
    .video_addr(video_vco_addr), .video_dout(video_vco_data)
);
tas_ram #(.AW(2)) dma_regs (
    .clk(clk), .cs(dma_cs), .we(!cpu_rnw), .uds_n(uds_n), .lds_n(lds_n),
    .addr(cpu_addr[2:1]), .din(cpu_dout), .dout(dma_q),
    .rd2_addr('0), .rd2_cs(1'b0), .rd2_we(1'b0), .rd2_din(16'd0), .rd2_dout()
);
tas_ram #(.AW(14), .SECOND_PORT(1)) line_ram (
    .clk(clk), .cs(line_cs), .we(!cpu_rnw), .uds_n(uds_n), .lds_n(lds_n),
    .addr(cpu_addr[14:1]), .din(cpu_dout), .dout(line_q),
    .rd2_addr(line_port_dsp ? dsp_line_addr : video_line_addr),
    .rd2_cs(line_port_dsp || line_port_video),
    .rd2_we(line_port_dsp && dsp_line_we),
    .rd2_din(dsp_line_wdata), .rd2_dout(dsp_line_q)
);
assign video_line_data = dsp_line_q;

// The DSP has priority for the one clock in which it launches a line-RAM
// access.  The renderer holds its request until this registered grant; q_b is
// then stable for the parser on the following edge.
always @(posedge clk) begin
    if (reset) video_line_ack <= 1'b0;
    else video_line_ack <= line_port_video;
end
// The 68000 and C25 share one synchronous RAM port.  The verified pre-DSP
// core passes the board's exhaustive RAM POST with this exact single-port
// shape; explicit arbitration also avoids Cyclone V true-dual-port read-mode
// differences.  A registered 68000 access has priority for one clock and the
// C25 simply keeps its request asserted until granted.
tas_ram #(.AW(15)) dsp_shared_ram (
    .clk(clk), .cs(shared_ram_cs), .we(shared_ram_we),
    .uds_n(shared_ram_uds_n), .lds_n(shared_ram_lds_n),
    .addr(shared_ram_addr), .din(shared_ram_wdata), .dout(dsp_q),
    .rd2_addr('0), .rd2_cs(1'b0), .rd2_we(1'b0),
    .rd2_din(16'd0), .rd2_dout()
);
assign dsp_shared_q = dsp_q;

// The verified pre-DSP core returned zero for the first shared-word poll after
// reset.  Retain that bootstrap only until the real C25 publishes its own zero
// at shared word 0; all subsequent response/command values then come from RAM.
always @(posedge clk) begin
    if (reset) dsp_bootstrap_active <= 1'b1;
    else if (dsp_shared_cs && dsp_shared_grant && dsp_shared_we &&
             dsp_shared_addr == 15'd0 && dsp_shared_wdata == 16'h0000)
        dsp_bootstrap_active <= 1'b0;
end

tas_dsp dsp_subsystem (
    .clk(clk),
    .reset(reset | !debug_sysctrl[0]),
    // The board exposes C25 HOLD/HOLDA for external bus ownership. Freeze the
    // producer after it publishes a line-RAM list so span conversion cannot
    // race the next high-to-low DSP write pass.
    .hold(!debug_sysctrl[2] || video_polygon_hold),
    .prog_addr(dsp_prog_addr), .prog_data(dsp_prog_data),
    .line_cs(dsp_line_cs), .line_we(dsp_line_we),
    .line_addr(dsp_line_addr), .line_wdata(dsp_line_wdata),
    .line_rdata(dsp_line_q),
    .shared_cs(dsp_shared_cs), .shared_we(dsp_shared_we),
    .shared_addr(dsp_shared_addr), .shared_wdata(dsp_shared_wdata),
    .shared_grant(dsp_shared_grant),
    .shared_rdata(dsp_shared_q),
    .debug_pc(debug_dsp_pc), .debug_ir(debug_dsp_ir),
    .debug_instructions(debug_dsp_instructions),
    .debug_illegal(debug_dsp_illegal),
    .debug_last_addr(debug_dsp_addr), .debug_last_data(debug_dsp_data),
    .debug_flags(debug_dsp_flags),
    .flag_strobe(dsp_flag_strobe)
);
// The TC0430GRW exposes only eight words. video_grw_regs is already the
// byte-writeable register file used by the renderer, so read it directly
// instead of spending two whole M10Ks on eight inferred byte lanes.
assign grw_q = video_grw_regs[{cpu_addr[3:1], 4'b0000} +: 16];
// The 1Kx16 power-on/self-test RAM is small enough for MLABs. Keeping its
// two byte lanes out of M10Ks balances the 3,072-entry polygon span store.
tas_ram #(.AW(10), .DISTRIBUTED(1)) power_ram (
    .clk(clk), .cs(power_cs), .we(!cpu_rnw), .uds_n(uds_n), .lds_n(lds_n),
    .addr(cpu_addr[10:1]), .din(cpu_dout), .dout(power_q),
    .rd2_addr('0), .rd2_cs(1'b0), .rd2_we(1'b0), .rd2_din(16'd0), .rd2_dout()
);

wire bus_cycle = !as_n && (!uds_n || !lds_n) && !iack;
reg bus_active;
reg [3:0] pending;
reg pending_delay;
reg [7:0] ioc_reg4;
// The 68000 exposes odd-byte accesses as an even address plus LDS. Top
// Landing's TC0140SYT registers are at 0xa80001/03, so reject upper-byte and
// word-only aliases while using A1 to select port/data.
wire sound_access = bus_cycle && !bus_active && !lds_n &&
                    cpu_addr >= 24'ha80000 && cpu_addr <= 24'ha80003;
assign sound_main_cs = sound_access;
assign sound_main_wr = !cpu_rnw;
assign sound_main_port = cpu_addr[1];
// Top Landing maps the TC0140SYT at the odd-byte addresses 0xa80001 and
// 0xa80003, so the chip sees the low nibble of the 68000 lower data byte.
assign sound_main_din = cpu_dout[3:0];

// TC0220IOC input register 2. The two unknown lines and cabinet inputs are
// inactive-high, while the coin inputs are active-high. MiSTer's first three
// named buttons are Start, Coin and Service at controls[4], [5] and [6].
wire [7:0] ioc_in0 = {
    1'b1, ~controls[4], 1'b1, ~controls[6],
    1'b0, controls[5], 2'b11
};

wire [15:0] flight_counter_read;
wire [5:0] flight_limit_n;
tas_flight_controls flight_controls (
    .clk(clk),
    .reset(reset),
    .vblank(vblank),
    .digital(controls),
    .analog_left(joystick_l_analog),
    .analog_right(joystick_r_analog),
    .throttle_mode(throttle_mode),
    .read_offset(cpu_addr[8:0]),
    .read_data(flight_counter_read),
    .limit_n(flight_limit_n),
    .throttle_counter(flight_throttle_counter),
    .stick_x_counter(flight_stick_x_counter),
    .stick_y_counter(flight_stick_y_counter)
);
wire [7:0] ioc_in1 = {1'b1, 1'b0, flight_limit_n};

assign video_gradbank = debug_sysctrl[6];

function automatic [15:0] peripheral_read(input [23:0] address);
begin
    case (address)
        // Three signed 12-bit yoke/throttle counters, low byte then high
        // nibble, matching the original counter port ordering.
        24'ha00000, 24'ha00002, 24'ha00004, 24'ha00006,
        24'ha00100, 24'ha00102, 24'ha00104, 24'ha00106:
            peripheral_read = flight_counter_read;
        // TC0220IOC lower-byte registers. The MRA receiver supplies the Top
        // Landing service manual's factory defaults and selected DIP states.
        24'ha00200: peripheral_read = {8'h00, dswa};
        24'ha00202: peripheral_read = {8'h00, dswb};
        24'ha00204: peripheral_read = {8'h00, ioc_in0};
        24'ha00206: peripheral_read = {8'h00, ioc_in1};
        24'ha00208: peripheral_read = {8'h00, ioc_reg4};
        24'ha0020e: peripheral_read = 16'h00ff; // unused input bank
        default:     peripheral_read = 16'hffff;
    endcase
end
endfunction

always @(posedge clk) begin
    main_cs  <= 1'b0;
    grad_cs  <= 1'b0;
    pal_cs   <= 1'b0;
    vco_cs   <= 1'b0;
    dma_cs   <= 1'b0;
    line_cs  <= 1'b0;
    dsp_cs   <= 1'b0;
    grw_cs   <= 1'b0;
    power_cs <= 1'b0;
    dma_fb_erase_strobe <= 1'b0;
    dma_fb_copy_strobe <= 1'b0;

    if (reset) begin
        cpu_din          <= 16'hffff;
        dtack_n          <= 1'b1;
        bus_active       <= 1'b0;
        pending          <= P_NONE;
        pending_delay    <= 1'b0;
        rom_addr         <= 24'd0;
        debug_addr       <= 24'd0;
        debug_fetch_addr <= 24'd0;
        debug_cycles     <= 32'd0;
        debug_sysctrl    <= 8'd0;
        debug_fault      <= 1'b0;
        debug_fault_addr <= 24'd0;
        debug_fault_cycles <= 32'd0;
        debug_hist0      <= 24'd0;
        debug_hist1      <= 24'd0;
        debug_hist2      <= 24'd0;
        debug_hist3      <= 24'd0;
        debug_hist4      <= 24'd0;
        debug_hist5      <= 24'd0;
        debug_hist6      <= 24'd0;
        debug_hist7      <= 24'd0;
        debug_last_data_addr <= 24'd0;
        ioc_reg4         <= 8'd0;
        video_bg0_scrollx <= 10'd0;
        video_bg0_scrolly <= 10'd0;
        video_bg0_zoom    <= 16'h3f7f;
        video_bg1_scrollx <= 10'd0;
        video_bg1_scrolly <= 10'd0;
        video_bg1_zoom    <= 16'h3f7f;
        video_grw_regs    <= 128'd0;
        dma_fb_erase_strobe <= 1'b0;
        dma_fb_copy_strobe <= 1'b0;
    end else begin
        if (!bus_cycle) begin
            rom_req       <= 1'b0;
            bus_active    <= 1'b0;
            pending       <= P_NONE;
            pending_delay <= 1'b0;
            dtack_n       <= 1'b1;
        end

        if (bus_cycle && !bus_active) begin
            bus_active   <= 1'b1;
            debug_addr   <= cpu_addr;
            debug_cycles <= debug_cycles + 1'd1;

            if (!fc[1])
                debug_last_data_addr <= cpu_addr;

            if (cpu_rnw && fc[1]) begin
                debug_fetch_addr <= cpu_addr;
                debug_hist7 <= debug_hist6;
                debug_hist6 <= debug_hist5;
                debug_hist5 <= debug_hist4;
                debug_hist4 <= debug_hist3;
                debug_hist3 <= debug_hist2;
                debug_hist2 <= debug_hist1;
                debug_hist1 <= debug_hist0;
                debug_hist0 <= cpu_addr;
                // Top Landing enters 001b62 after a POST comparison fails.
                // Preserve the last data-space address so hardware telemetry
                // identifies the exact RAM/peripheral that disagreed.
                if (!debug_fault && cpu_addr == 24'h001b62) begin
                    debug_fault <= 1'b1;
                    debug_fault_addr <= debug_last_data_addr;
                    debug_fault_cycles <= debug_cycles + 1'd1;
                end else if (!debug_fault && cpu_addr >= 24'h0c0000) begin
                    debug_fault <= 1'b1;
                    debug_fault_addr <= cpu_addr;
                    debug_fault_cycles <= debug_cycles + 1'd1;
                end
            end

            if (cpu_addr < 24'h0c0000 && cpu_rnw) begin
                rom_addr <= cpu_addr;
                rom_req  <= 1'b1;
            end else if (cpu_addr >= 24'h0c0000 && cpu_addr <= 24'h0cffff) begin
                main_cs <= 1'b1;
                pending <= P_MAIN;
            end else if (cpu_addr >= 24'h180000 && cpu_addr <= 24'h187fff) begin
                grad_cs <= 1'b1;
                pending <= P_GRAD;
            end else if (cpu_addr >= 24'h188000 && cpu_addr <= 24'h18bfff) begin
                pal_cs <= 1'b1;
                pending <= P_PAL;
            end else if (cpu_addr >= 24'h800000 && cpu_addr <= 24'h820fff) begin
                vco_cs <= 1'b1;
                pending <= P_VCO;
                if (!cpu_rnw) begin
                    if (cpu_addr == 24'h820802)
                        video_bg0_scrollx <= cpu_dout[9:0];
                    if (cpu_addr == 24'h820804)
                        video_bg1_scrollx <= cpu_dout[9:0];
                    if (cpu_addr == 24'h820806)
                        video_bg0_scrolly <= cpu_dout[9:0];
                    if (cpu_addr == 24'h820808)
                        video_bg1_scrolly <= cpu_dout[9:0];
                    if (cpu_addr == 24'h82080c)
                        video_bg0_zoom <= cpu_dout;
                    if (cpu_addr == 24'h82080e)
                        video_bg1_zoom <= cpu_dout;
                end
            end else if (cpu_addr >= 24'h906000 && cpu_addr <= 24'h906007) begin
                dma_cs <= 1'b1;
                pending <= P_DMA;
                if (!cpu_rnw && cpu_addr == 24'h906000 && !uds_n) begin
                    if (!lds_n && cpu_dout == 16'h1fff)
                        dma_fb_erase_strobe <= 1'b1;
                    else if (cpu_dout[15])
                        dma_fb_copy_strobe <= 1'b1;
                end
            end else if (cpu_addr >= 24'h908000 && cpu_addr <= 24'h90ffff) begin
                line_cs <= 1'b1;
                pending <= P_LINE;
            end else if (cpu_addr >= 24'h910000 && cpu_addr <= 24'h91ffff) begin
                dsp_cs <= 1'b1;
                pending <= P_DSP;
            end else if (cpu_addr >= 24'h980000 && cpu_addr <= 24'h98000f) begin
                grw_cs <= 1'b1;
                pending <= P_GRW;
                if (!cpu_rnw) begin
                    case (cpu_addr[3:1])
                        3'd0: begin
                            if (!uds_n) video_grw_regs[15:8] <= cpu_dout[15:8];
                            if (!lds_n) video_grw_regs[7:0] <= cpu_dout[7:0];
                        end
                        3'd1: begin
                            if (!uds_n) video_grw_regs[31:24] <= cpu_dout[15:8];
                            if (!lds_n) video_grw_regs[23:16] <= cpu_dout[7:0];
                        end
                        3'd2: begin
                            if (!uds_n) video_grw_regs[47:40] <= cpu_dout[15:8];
                            if (!lds_n) video_grw_regs[39:32] <= cpu_dout[7:0];
                        end
                        3'd3: begin
                            if (!uds_n) video_grw_regs[63:56] <= cpu_dout[15:8];
                            if (!lds_n) video_grw_regs[55:48] <= cpu_dout[7:0];
                        end
                        3'd4: begin
                            if (!uds_n) video_grw_regs[79:72] <= cpu_dout[15:8];
                            if (!lds_n) video_grw_regs[71:64] <= cpu_dout[7:0];
                        end
                        3'd5: begin
                            if (!uds_n) video_grw_regs[95:88] <= cpu_dout[15:8];
                            if (!lds_n) video_grw_regs[87:80] <= cpu_dout[7:0];
                        end
                        3'd6: begin
                            if (!uds_n) video_grw_regs[111:104] <= cpu_dout[15:8];
                            if (!lds_n) video_grw_regs[103:96] <= cpu_dout[7:0];
                        end
                        default: begin
                            if (!uds_n) video_grw_regs[127:120] <= cpu_dout[15:8];
                            if (!lds_n) video_grw_regs[119:112] <= cpu_dout[7:0];
                        end
                    endcase
                end
            end else if (cpu_addr >= 24'hb00000 && cpu_addr <= 24'hb007ff) begin
                power_cs <= 1'b1;
                pending <= P_POWER;
            end else if (cpu_addr >= 24'ha80000 && cpu_addr <= 24'ha80003) begin
                cpu_din <= {8'h00, 4'h0, sound_main_dout};
                dtack_n <= 1'b0;
            end else begin
                if (!cpu_rnw && cpu_addr == 24'h140000)
                    debug_sysctrl <= cpu_dout[7:0];
                if (!cpu_rnw && cpu_addr == 24'ha00208 && !lds_n)
                    ioc_reg4 <= cpu_dout[7:0];
                cpu_din <= peripheral_read(cpu_addr);
                dtack_n <= 1'b0;
            end
        end

        if (bus_active && pending != P_NONE) begin
            if (!pending_delay) begin
                pending_delay <= 1'b1;
            end else begin
                case (pending)
                    P_MAIN:  cpu_din <= main_q;
                    P_GRAD:  cpu_din <= grad_q;
                    P_PAL:   cpu_din <= pal_q;
                    P_VCO:   cpu_din <= vco_q;
                    P_DMA:   cpu_din <= dma_q;
                    P_LINE:  cpu_din <= line_q;
                    // Preserve the verified bring-up response only until the
                    // C25 has initialized the real shared handshake word.
                    P_DSP:   cpu_din <=
                        (cpu_addr == 24'h910000 && debug_sysctrl[0] &&
                         dsp_bootstrap_active)
                            ? 16'h0000 : dsp_q;
                    P_GRW:   cpu_din <= grw_q;
                    P_POWER: cpu_din <= power_q;
                    default: cpu_din <= 16'hffff;
                endcase
                pending <= P_NONE;
                dtack_n <= 1'b0;
            end
        end

        if (bus_active && rom_ack) begin
            rom_req <= 1'b0;
            cpu_din <= rom_data;
            dtack_n <= 1'b0;
        end
    end
end

endmodule
