// Top Landing's yoke interface exposes three signed 12-bit position counters
// as separate low/high bytes, plus active-low end-limit signals. This module
// follows MAME's taitoio_yoke device for the counter format and digital
// dynamics, but calibrates physical travel from Top Landing's original 68000
// program.  The game scales/clamps throttle, X and Y at raw counter endpoints
// -39/+40, -47/+48 and -32/+32 respectively; feeding the nominal 12-bit ends
// makes all three controls saturate around centre.  A spring-centred gamepad
// stick is a graded set-and-hold throttle rate control, while a menu option
// retains absolute positional HOTAS operation over the calibrated endpoints.
module tas_flight_controls (
    input             clk,
    input             reset,
    input             vblank,
    input      [31:0] digital,
    input      [15:0] analog_left,
    input      [15:0] analog_right,
    input      [1:0]  throttle_mode,
    input      [8:0]  read_offset,
    output reg [15:0] read_data,
    output     [5:0]  limit_n,
    output     [11:0] throttle_counter,
    output     [11:0] stick_x_counter,
    output     [11:0] stick_y_counter
);

// MAME's default frontend normalizes the physical axis after a 0.15 dead zone
// and reaches full output at 0.85 travel. MiSTer supplies signed -127..+127;
// the table below is the same piecewise-linear transfer into the yoke device's
// signed 0x800..0x7ff counter range.
// This exact finite transfer is deliberately a constant table. Expressing the
// same ratios with SystemVerilog division makes Quartus instantiate two
// 32-bit dividers, adding six DSPs and a 32 ns setup failure. The upper value
// is the rounded magnitude for the 2048-count negative half; the lower value
// is for the 2047-count positive half.
function automatic [22:0] mame_axis_levels(input [7:0] magnitude);
begin
    if (magnitude <= 8'd19)
        mame_axis_levels = {12'd0, 11'd0};
    else if (magnitude >= 8'd108)
        mame_axis_levels = {12'd2048, 11'd2047};
    else begin
        case (magnitude)
            8'd20: mame_axis_levels = {12'd22, 11'd22};
            8'd21: mame_axis_levels = {12'd45, 11'd45};
            8'd22: mame_axis_levels = {12'd68, 11'd68};
            8'd23: mame_axis_levels = {12'd91, 11'd91};
            8'd24: mame_axis_levels = {12'd114, 11'd114};
            8'd25: mame_axis_levels = {12'd137, 11'd137};
            8'd26: mame_axis_levels = {12'd160, 11'd160};
            8'd27: mame_axis_levels = {12'd183, 11'd183};
            8'd28: mame_axis_levels = {12'd206, 11'd206};
            8'd29: mame_axis_levels = {12'd229, 11'd229};
            8'd30: mame_axis_levels = {12'd252, 11'd252};
            8'd31: mame_axis_levels = {12'd275, 11'd275};
            8'd32: mame_axis_levels = {12'd298, 11'd298};
            8'd33: mame_axis_levels = {12'd321, 11'd321};
            8'd34: mame_axis_levels = {12'd344, 11'd344};
            8'd35: mame_axis_levels = {12'd367, 11'd367};
            8'd36: mame_axis_levels = {12'd390, 11'd390};
            8'd37: mame_axis_levels = {12'd414, 11'd413};
            8'd38: mame_axis_levels = {12'd437, 11'd436};
            8'd39: mame_axis_levels = {12'd460, 11'd459};
            8'd40: mame_axis_levels = {12'd483, 11'd482};
            8'd41: mame_axis_levels = {12'd506, 11'd505};
            8'd42: mame_axis_levels = {12'd529, 11'd528};
            8'd43: mame_axis_levels = {12'd552, 11'd551};
            8'd44: mame_axis_levels = {12'd575, 11'd574};
            8'd45: mame_axis_levels = {12'd598, 11'd598};
            8'd46: mame_axis_levels = {12'd621, 11'd621};
            8'd47: mame_axis_levels = {12'd644, 11'd644};
            8'd48: mame_axis_levels = {12'd667, 11'd667};
            8'd49: mame_axis_levels = {12'd690, 11'd690};
            8'd50: mame_axis_levels = {12'd713, 11'd713};
            8'd51: mame_axis_levels = {12'd736, 11'd736};
            8'd52: mame_axis_levels = {12'd759, 11'd759};
            8'd53: mame_axis_levels = {12'd782, 11'd782};
            8'd54: mame_axis_levels = {12'd805, 11'd805};
            8'd55: mame_axis_levels = {12'd828, 11'd828};
            8'd56: mame_axis_levels = {12'd851, 11'd851};
            8'd57: mame_axis_levels = {12'd874, 11'd874};
            8'd58: mame_axis_levels = {12'd897, 11'd897};
            8'd59: mame_axis_levels = {12'd920, 11'd920};
            8'd60: mame_axis_levels = {12'd943, 11'd943};
            8'd61: mame_axis_levels = {12'd966, 11'd966};
            8'd62: mame_axis_levels = {12'd989, 11'd989};
            8'd63: mame_axis_levels = {12'd1012, 11'd1012};
            8'd64: mame_axis_levels = {12'd1036, 11'd1035};
            8'd65: mame_axis_levels = {12'd1059, 11'd1058};
            8'd66: mame_axis_levels = {12'd1082, 11'd1081};
            8'd67: mame_axis_levels = {12'd1105, 11'd1104};
            8'd68: mame_axis_levels = {12'd1128, 11'd1127};
            8'd69: mame_axis_levels = {12'd1151, 11'd1150};
            8'd70: mame_axis_levels = {12'd1174, 11'd1173};
            8'd71: mame_axis_levels = {12'd1197, 11'd1196};
            8'd72: mame_axis_levels = {12'd1220, 11'd1219};
            8'd73: mame_axis_levels = {12'd1243, 11'd1242};
            8'd74: mame_axis_levels = {12'd1266, 11'd1265};
            8'd75: mame_axis_levels = {12'd1289, 11'd1288};
            8'd76: mame_axis_levels = {12'd1312, 11'd1311};
            8'd77: mame_axis_levels = {12'd1335, 11'd1334};
            8'd78: mame_axis_levels = {12'd1358, 11'd1357};
            8'd79: mame_axis_levels = {12'd1381, 11'd1380};
            8'd80: mame_axis_levels = {12'd1404, 11'd1403};
            8'd81: mame_axis_levels = {12'd1427, 11'd1426};
            8'd82: mame_axis_levels = {12'd1450, 11'd1449};
            8'd83: mame_axis_levels = {12'd1473, 11'd1473};
            8'd84: mame_axis_levels = {12'd1496, 11'd1496};
            8'd85: mame_axis_levels = {12'd1519, 11'd1519};
            8'd86: mame_axis_levels = {12'd1542, 11'd1542};
            8'd87: mame_axis_levels = {12'd1565, 11'd1565};
            8'd88: mame_axis_levels = {12'd1588, 11'd1588};
            8'd89: mame_axis_levels = {12'd1611, 11'd1611};
            8'd90: mame_axis_levels = {12'd1634, 11'd1634};
            8'd91: mame_axis_levels = {12'd1658, 11'd1657};
            8'd92: mame_axis_levels = {12'd1681, 11'd1680};
            8'd93: mame_axis_levels = {12'd1704, 11'd1703};
            8'd94: mame_axis_levels = {12'd1727, 11'd1726};
            8'd95: mame_axis_levels = {12'd1750, 11'd1749};
            8'd96: mame_axis_levels = {12'd1773, 11'd1772};
            8'd97: mame_axis_levels = {12'd1796, 11'd1795};
            8'd98: mame_axis_levels = {12'd1819, 11'd1818};
            8'd99: mame_axis_levels = {12'd1842, 11'd1841};
            8'd100: mame_axis_levels = {12'd1865, 11'd1864};
            8'd101: mame_axis_levels = {12'd1888, 11'd1887};
            8'd102: mame_axis_levels = {12'd1911, 11'd1910};
            8'd103: mame_axis_levels = {12'd1934, 11'd1933};
            8'd104: mame_axis_levels = {12'd1957, 11'd1956};
            8'd105: mame_axis_levels = {12'd1980, 11'd1979};
            8'd106: mame_axis_levels = {12'd2003, 11'd2002};
            8'd107: mame_axis_levels = {12'd2026, 11'd2025};
            default: mame_axis_levels = {12'd0, 11'd0};
        endcase
    end
end
endfunction

function automatic signed [11:0] mame_axis(input signed [7:0] axis);
    reg [7:0] magnitude;
    reg [22:0] levels;
    reg signed [12:0] negative_level;
begin
    magnitude = axis[7] ? (8'd0 - axis) : axis;
    levels = mame_axis_levels(magnitude);
    if (axis[7]) begin
        negative_level = -$signed({1'b0, levels[22:11]});
        mame_axis = negative_level[11:0];
    end else begin
        mame_axis = $signed({1'b0, levels[10:0]});
    end
end
endfunction

function automatic signed [11:0] center_step(
    input signed [11:0] value
);
begin
    if (value > 12'sd20)
        center_step = value - 12'sd20;
    else if (value < -12'sd20)
        center_step = value + 12'sd20;
    else
        center_step = 12'sd0;
end
endfunction

// Top Landing's own input normalizer at 0x005c92 is the available board-side
// calibration evidence.  It multiplies throttle by 0x199/256, yoke X by
// 0x155/256, and inverted yoke Y by 0x200/256 before clamping each result to
// signed +/-63.  These asymmetric raw endpoints are the smallest values that
// reach both exact normalized limits.
localparam signed [11:0] THROTTLE_FULL = -12'sd39;
localparam signed [11:0] THROTTLE_IDLE =  12'sd40;
localparam signed [11:0] YOKE_X_LEFT   = -12'sd47;
localparam signed [11:0] YOKE_X_RIGHT  =  12'sd48;
localparam signed [11:0] YOKE_Y_UP     = -12'sd32;
localparam signed [11:0] YOKE_Y_DOWN   =  12'sd32;

function automatic signed [11:0] calibrated_yoke_x(
    input signed [11:0] value
);
    reg [11:0] magnitude;
    reg [18:0] extended_magnitude;
    reg [18:0] product;
    reg signed [12:0] result;
begin
    magnitude = value[11] ? (12'd0 - value) : value;
    extended_magnitude = {7'd0, magnitude};
    if (value[11]) begin
        product = (extended_magnitude << 5) +
                  (extended_magnitude << 4) - extended_magnitude + 12'd1024;
        result = -$signed({1'b0, product[18:11]});
    end else begin
        product = (extended_magnitude << 5) +
                  (extended_magnitude << 4) + 12'd1023;
        result = $signed({1'b0, product[18:11]});
    end
    calibrated_yoke_x = result[11:0];
end
endfunction

function automatic signed [11:0] calibrated_yoke_y(
    input signed [11:0] value
);
    reg [11:0] magnitude;
    reg [18:0] extended_magnitude;
    reg [18:0] product;
    reg signed [12:0] result;
begin
    magnitude = value[11] ? (12'd0 - value) : value;
    extended_magnitude = {7'd0, magnitude};
    product = (extended_magnitude << 5) +
              (value[11] ? 12'd1024 : 12'd1023);
    result = $signed({1'b0, product[18:11]});
    calibrated_yoke_y = value[11]
        ? (12'd0 - result[11:0]) : result[11:0];
end
endfunction

function automatic signed [11:0] calibrated_throttle(
    input signed [11:0] value
);
    reg [11:0] magnitude;
    reg [18:0] extended_magnitude;
    reg [18:0] product;
    reg signed [12:0] result;
begin
    magnitude = value[11] ? (12'd0 - value) : value;
    extended_magnitude = {7'd0, magnitude};
    if (value[11]) begin
        product = (extended_magnitude << 5) +
                  (extended_magnitude << 3) - extended_magnitude + 12'd1024;
        result = -$signed({1'b0, product[18:11]});
    end else begin
        product = (extended_magnitude << 5) +
                  (extended_magnitude << 3) + 12'd1023;
        result = $signed({1'b0, product[18:11]});
    end
    calibrated_throttle = result[11:0];
end
endfunction

function automatic signed [11:0] add_yoke_x_clamped(
    input signed [11:0] value,
    input signed [12:0] delta
);
    reg signed [12:0] sum;
begin
    sum = value + delta;
    if (sum > 13'sd48)
        add_yoke_x_clamped = YOKE_X_RIGHT;
    else if (sum < -13'sd47)
        add_yoke_x_clamped = YOKE_X_LEFT;
    else
        add_yoke_x_clamped = sum[11:0];
end
endfunction

function automatic signed [11:0] add_yoke_y_clamped(
    input signed [11:0] value,
    input signed [12:0] delta
);
    reg signed [12:0] sum;
begin
    sum = value + delta;
    if (sum > 13'sd32)
        add_yoke_y_clamped = YOKE_Y_DOWN;
    else if (sum < -13'sd32)
        add_yoke_y_clamped = YOKE_Y_UP;
    else
        add_yoke_y_clamped = sum[11:0];
end
endfunction

function automatic signed [11:0] add_throttle_clamped(
    input signed [11:0] value,
    input signed [12:0] delta
);
    reg signed [12:0] sum;
begin
    sum = value + delta;
    if (sum > 13'sd40)
        add_throttle_clamped = THROTTLE_IDLE;
    else if (sum < -13'sd39)
        add_throttle_clamped = THROTTLE_FULL;
    else
        add_throttle_clamped = sum[11:0];
end
endfunction

// MiSTer has already removed the controller's tiny device dead zone.  A
// wider core-local neutral region prevents spring-stick drift; the three
// rates retain single-counter precision near centre and quick full travel.
function automatic signed [12:0] gamepad_throttle_delta(
    input signed [7:0] axis
);
    reg [7:0] magnitude;
    reg signed [12:0] rate;
begin
    magnitude = axis[7] ? (8'd0 - axis) : axis;
    if (magnitude <= 8'd31)
        rate = 13'sd0;
    else if (magnitude <= 8'd63)
        rate = 13'sd1;
    else if (magnitude <= 8'd95)
        rate = 13'sd2;
    else
        rate = 13'sd3;
    gamepad_throttle_delta = axis[7] ? -rate : rate;
end
endfunction

wire signed [7:0] analog_x_raw = analog_left[7:0];
wire signed [7:0] analog_y_raw = analog_left[15:8];
wire signed [7:0] analog_throttle_raw = analog_right[15:8];
wire analog_x_active = analog_x_raw > 8'sd19 || analog_x_raw < -8'sd19;
wire analog_y_active = analog_y_raw > 8'sd19 || analog_y_raw < -8'sd19;
wire gamepad_throttle_active = analog_throttle_raw > 8'sd31 ||
                               analog_throttle_raw < -8'sd31;
wire signed [11:0] analog_x_value = calibrated_yoke_x(mame_axis(analog_x_raw));
wire signed [11:0] analog_y_value = calibrated_yoke_y(mame_axis(analog_y_raw));
wire signed [11:0] analog_throttle_value =
    calibrated_throttle(mame_axis(analog_throttle_raw));

reg old_vblank;
reg signed [11:0] stick_x_value;
reg signed [11:0] stick_y_value;
reg signed [11:0] throttle_value;
reg stick_x_digital_mode;
reg stick_y_digital_mode;

always @(posedge clk) begin
    old_vblank <= vblank;
    if (reset) begin
        old_vblank <= 1'b0;
        stick_x_value <= 12'sd0;
        stick_y_value <= 12'sd0;
        // Top Landing's startup control POST requires both throttle end
        // switches inactive before it prints THROTTLE OK and enables Start.
        // A physical lever retains its position, but the virtual gamepad
        // lever has no persistent position, so initialize it at raw center.
        // The calibrated -39/+40 full/idle endpoints remain reachable once
        // the player moves the right stick.
        throttle_value <= 12'sd0;
        stick_x_digital_mode <= 1'b0;
        stick_y_digital_mode <= 1'b0;
    end else if (vblank && !old_vblank) begin
        // MAME absolute analog values override the keyboard-style fallback.
        // Otherwise the yoke changes by 20 counts per frame and recenters at
        // the same rate. Opposing directions cancel and hold their position.
        if (analog_x_active) begin
            stick_x_value <= analog_x_value;
            stick_x_digital_mode <= 1'b0;
        end else if (digital[0] && !digital[1]) begin
            stick_x_value <= add_yoke_x_clamped(
                stick_x_digital_mode ? stick_x_value : 12'sd0, 13'sd20
            );
            stick_x_digital_mode <= 1'b1;
        end else if (digital[1] && !digital[0]) begin
            stick_x_value <= add_yoke_x_clamped(
                stick_x_digital_mode ? stick_x_value : 12'sd0, -13'sd20
            );
            stick_x_digital_mode <= 1'b1;
        end else if (!(digital[0] && digital[1])) begin
            stick_x_value <= stick_x_digital_mode
                ? center_step(stick_x_value) : 12'sd0;
        end else if (!stick_x_digital_mode) begin
            stick_x_value <= 12'sd0;
        end

        if (analog_y_active) begin
            stick_y_value <= analog_y_value;
            stick_y_digital_mode <= 1'b0;
        end else if (digital[2] && !digital[3]) begin
            stick_y_value <= add_yoke_y_clamped(
                stick_y_digital_mode ? stick_y_value : 12'sd0, 13'sd20
            );
            stick_y_digital_mode <= 1'b1;
        end else if (digital[3] && !digital[2]) begin
            stick_y_value <= add_yoke_y_clamped(
                stick_y_digital_mode ? stick_y_value : 12'sd0, -13'sd20
            );
            stick_y_digital_mode <= 1'b1;
        end else if (!(digital[2] && digital[3])) begin
            stick_y_value <= stick_y_digital_mode
                ? center_step(stick_y_value) : 12'sd0;
        end else if (!stick_y_digital_mode) begin
            stick_y_value <= 12'sd0;
        end

        // The cabinet throttle stays wherever the pilot leaves it. MiSTer
        // cannot forward a normal gamepad trigger's continuous magnitude to
        // arcade cores: a mapped trigger arrives only as its two endpoint
        // button bits. Default mode therefore treats right-stick Y as a
        // spring-centred rate control. Deflecting it changes the virtual lever
        // at a graded 1/2/3-count rate; releasing it holds the resulting
        // position, including every intermediate calibrated counter value.
        // HOTAS mode maps absolute travel to the ROM-derived endpoints. MAME's
        // KEYDELTA(40) is an output-port delta (sensitivity is inverse-applied
        // before the final read), so Buttons mode deliberately uses 40.
        case (throttle_mode)
            2'd1: throttle_value <= analog_throttle_value;
            2'd2: begin
                if (digital[7] && !digital[8])
                    throttle_value <= add_throttle_clamped(
                        throttle_value, -13'sd40
                    );
                else if (digital[8] && !digital[7])
                    throttle_value <= add_throttle_clamped(
                        throttle_value, 13'sd40
                    );
            end
            default: begin
                if (gamepad_throttle_active)
                    throttle_value <= add_throttle_clamped(
                        throttle_value,
                        gamepad_throttle_delta(analog_throttle_raw)
                    );
            end
        endcase
    end
end

assign throttle_counter = throttle_value;
assign stick_x_counter = stick_x_value;
assign stick_y_counter = stick_y_value;

// Active-low end switches follow the useful calibrated travel rather than
// unreachable nominal 12-bit windows. Bit order matches TC0220IOC IN1:
// slot down/up, handle left/right/down/up.
assign limit_n[0] = throttle_value >= THROTTLE_IDLE ? 1'b0 : 1'b1;
assign limit_n[1] = throttle_value <= THROTTLE_FULL ? 1'b0 : 1'b1;
assign limit_n[2] = stick_x_value <= YOKE_X_LEFT ? 1'b0 : 1'b1;
assign limit_n[3] = stick_x_value >= YOKE_X_RIGHT ? 1'b0 : 1'b1;
assign limit_n[4] = stick_y_value >= YOKE_Y_DOWN ? 1'b0 : 1'b1;
assign limit_n[5] = stick_y_value <= YOKE_Y_UP ? 1'b0 : 1'b1;

always @* begin
    case (read_offset)
        9'h000: read_data = {8'h00, throttle_counter[7:0]};
        9'h002: read_data = {8'h00, stick_x_counter[7:0]};
        9'h004: read_data = {12'h000, throttle_counter[11:8]};
        9'h006: read_data = {12'h000, stick_x_counter[11:8]};
        9'h100: read_data = {8'h00, stick_y_counter[7:0]};
        9'h104: read_data = {12'h000, stick_y_counter[11:8]};
        default: read_data = 16'h0000;
    endcase
end

endmodule
