// Taito Air TMS320C25 subsystem: CPU, internal data RAM and board-specific
// external data-space peripherals. Shared and line RAM are true dual-port
// memories owned by tas_main; this block drives their DSP-side ports.
module tas_dsp (
    input               clk,
    input               reset,
    input               hold,

    output     [11:0]   prog_addr,
    input      [15:0]   prog_data,

    output              line_cs,
    output              line_we,
    output     [13:0]   line_addr,
    output     [15:0]   line_wdata,
    input      [15:0]   line_rdata,

    output              shared_cs,
    output              shared_we,
    output     [14:0]   shared_addr,
    output     [15:0]   shared_wdata,
    input               shared_grant,
    input      [15:0]   shared_rdata,

    output     [15:0]   debug_pc,
    output     [15:0]   debug_ir,
    output     [31:0]   debug_instructions,
    output     [15:0]   debug_illegal,
    output reg [15:0]   debug_last_addr,
    output reg [15:0]   debug_last_data,
    output reg [2:0]    debug_flags,
    output reg [2:0]    flag_strobe
);

wire core_req;
wire core_we;
wire [15:0] core_addr;
wire [15:0] core_wdata;
reg core_ack;
reg [15:0] core_rdata;
wire core_debug_write;

tas_tms320c25 cpu (
    .clk(clk), .reset(reset), .hold(hold),
    .prog_addr(prog_addr), .prog_data(prog_data),
    .data_req(core_req), .data_we(core_we), .data_addr(core_addr),
    .data_wdata(core_wdata), .data_ack(core_ack), .data_rdata(core_rdata),
    .debug_pc(debug_pc), .debug_ir(debug_ir),
    .debug_instructions(debug_instructions), .debug_illegal(debug_illegal),
    .debug_write(core_debug_write)
);

localparam SEL_OTHER  = 3'd0;
localparam SEL_LOCAL  = 3'd1;
localparam SEL_LINE   = 3'd2;
localparam SEL_SHARED = 3'd3;

reg busy;
reg [2:0] pending_sel;
wire new_request = core_req && !busy;
wire local_select = core_addr <= 16'h03ff;
wire line_select = core_addr >= 16'h4000 && core_addr <= 16'h7fff;
wire shared_select = core_addr[15];
wire request_accepted = new_request && (!shared_select || shared_grant);

wire local_cs = new_request && local_select;
wire [15:0] local_rdata;
tas_ram #(.AW(10), .DISTRIBUTED(1)) internal_data_ram (
    .clk(clk), .cs(local_cs), .we(core_we), .uds_n(1'b0), .lds_n(1'b0),
    .addr(core_addr[9:0]), .din(core_wdata), .dout(local_rdata),
    .rd2_addr('0), .rd2_cs(1'b0), .rd2_we(1'b0), .rd2_din(16'd0),
    .rd2_dout()
);

assign line_cs = new_request && line_select;
assign line_we = core_we;
assign line_addr = core_addr[13:0];
assign line_wdata = core_wdata;
// Shared RAM is time-multiplexed with the 68000.  Keep the C25 request live
// until tas_main grants the single physical RAM port; only then start the
// normal one-cycle response sequence.
assign shared_cs = new_request && shared_select && shared_grant;
assign shared_we = core_we;
assign shared_addr = core_addr[14:0];
assign shared_wdata = core_wdata;

reg [15:0] mul_a1, mul_b1;
reg [15:0] mul_a2, mul_b2;
reg signed [15:0] clip_x, clip_y, clip_z;
reg [3:0] clip_or;
reg [3:0] clip_and;
reg [3:0] clip_point;
reg muldiv_start;
reg [15:0] muldiv_a;
reg [15:0] muldiv_b;
reg [15:0] muldiv_divisor;
wire [31:0] muldiv_result;
wire [15:0] muldiv_remainder;
wire muldiv_busy;
reg muldiv_zero;

// The board's custom block computes unsigned (A*B)/C. A sequential unit is
// preferable here: the C25 data bus naturally waits on the result read, while
// a combinational 32/16 divide cannot close the 20 MHz MiSTer system clock.
sys_umuldiv #(.NB_MUL1(16), .NB_MUL2(16), .NB_DIV(16)) math_unit (
    .clk(clk), .start(muldiv_start), .busy(muldiv_busy),
    .mul1(muldiv_a), .mul2(muldiv_b), .div(muldiv_divisor),
    .result(muldiv_result), .remainder(muldiv_remainder)
);

function automatic [3:0] classify_point(
    input signed [15:0] x,
    input signed [15:0] y,
    input signed [15:0] z
);
begin
    classify_point[0] = x < -z;
    classify_point[1] = x >  z;
    classify_point[2] = y < -z;
    classify_point[3] = y >  z;
end
endfunction

function automatic [15:0] peripheral_value(input [15:0] address);
begin
    case (address)
        16'h2003: peripheral_value = 16'h0000;
        16'h3407,16'h340b:
            peripheral_value = muldiv_zero ? 16'hffff : muldiv_result[15:0];
        16'h341b: peripheral_value = {12'd0, clip_point};
        16'h341c: peripheral_value = {12'd0, clip_and};
        16'h341d: peripheral_value = {12'd0, clip_or};
        default: peripheral_value = 16'hffff;
    endcase
end
endfunction

always @(posedge clk) begin
    core_ack <= 1'b0;

    if (reset) begin
        busy <= 1'b0;
        pending_sel <= SEL_OTHER;
        core_rdata <= 16'hffff;
        mul_a1 <= 16'd0;
        mul_b1 <= 16'd0;
        mul_a2 <= 16'd0;
        mul_b2 <= 16'd0;
        muldiv_start <= 1'b0;
        muldiv_a <= 16'd0;
        muldiv_b <= 16'd0;
        muldiv_divisor <= 16'd1;
        clip_x <= 16'sd0;
        clip_y <= 16'sd0;
        clip_z <= 16'sd0;
        clip_or <= 4'd0;
        clip_and <= 4'hf;
        clip_point <= 4'd0;
        muldiv_zero <= 1'b0;
        debug_last_addr <= 16'd0;
        debug_last_data <= 16'd0;
        debug_flags <= 3'd0;
        flag_strobe <= 3'd0;
    end else begin
        muldiv_start <= 1'b0;
        flag_strobe <= 3'd0;
        if (!core_req) busy <= 1'b0;

        if (request_accepted) begin
            busy <= 1'b1;
            if (local_select) pending_sel <= SEL_LOCAL;
            else if (line_select) pending_sel <= SEL_LINE;
            else if (shared_select) pending_sel <= SEL_SHARED;
            else pending_sel <= SEL_OTHER;

            debug_last_addr <= core_addr;
            if (core_we) debug_last_data <= core_wdata;

            if (core_we) begin
                case (core_addr)
                    16'h3000: begin
                        debug_flags[0] <= ~debug_flags[0];
                        flag_strobe[0] <= 1'b1;
                    end
                    16'h3001: begin
                        debug_flags[1] <= ~debug_flags[1];
                        flag_strobe[1] <= 1'b1;
                    end
                    16'h3002: begin
                        debug_flags[2] <= ~debug_flags[2];
                        flag_strobe[2] <= 1'b1;
                    end
                    16'h3404: mul_a1 <= core_wdata;
                    16'h3405: mul_b1 <= core_wdata;
                    16'h3408: mul_a2 <= core_wdata;
                    16'h3409: mul_b2 <= core_wdata;
                    16'h3418: clip_x <= core_wdata;
                    16'h3419: clip_y <= core_wdata;
                    16'h341a: clip_z <= core_wdata;
                    16'h341b: begin
                        clip_or <= 4'd0;
                        clip_and <= 4'hf;
                    end
                    default: begin end
                endcase
                if (core_addr == 16'h3406 || core_addr == 16'h340a)
                begin
                    muldiv_zero <= core_wdata == 0;
                    muldiv_a <= core_addr == 16'h340a ? mul_a2 : mul_a1;
                    muldiv_b <= core_addr == 16'h340a ? mul_b2 : mul_b1;
                    muldiv_divisor <= core_wdata;
                    muldiv_start <= core_wdata != 0;
                end
            end else if (core_addr == 16'h341b) begin
                clip_point <= classify_point(clip_x, clip_y, clip_z);
                clip_or <= clip_or | classify_point(clip_x, clip_y, clip_z);
                clip_and <= clip_and & classify_point(clip_x, clip_y, clip_z);
            end
        end

        if (busy && core_req &&
            !((core_addr == 16'h3407 || core_addr == 16'h340b) &&
              !muldiv_zero && muldiv_busy)) begin
            core_ack <= 1'b1;
            case (pending_sel)
                SEL_LOCAL: core_rdata <= local_rdata;
                SEL_LINE: core_rdata <= line_rdata;
                SEL_SHARED: core_rdata <= shared_rdata;
                default: core_rdata <= peripheral_value(core_addr);
            endcase
        end
    end
end

endmodule
