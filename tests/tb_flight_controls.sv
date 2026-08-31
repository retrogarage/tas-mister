`timescale 1ns/1ps

module tb_flight_controls;

reg clk = 1'b0;
reg reset = 1'b1;
reg vblank = 1'b0;
reg [31:0] digital = 32'd0;
reg [15:0] analog_left = 16'd0;
reg [15:0] analog_right = 16'd0;
reg [1:0] throttle_mode = 2'd0;
reg [8:0] read_offset = 9'd0;
wire [15:0] read_data;
wire [5:0] limit_n;
wire [11:0] throttle_counter;
wire [11:0] stick_x_counter;
wire [11:0] stick_y_counter;

always #5 clk = ~clk;

tas_flight_controls dut (
    .clk(clk), .reset(reset), .vblank(vblank),
    .digital(digital),
    .analog_left(analog_left),
    .analog_right(analog_right),
    .throttle_mode(throttle_mode),
    .read_offset(read_offset),
    .read_data(read_data),
    .limit_n(limit_n),
    .throttle_counter(throttle_counter),
    .stick_x_counter(stick_x_counter),
    .stick_y_counter(stick_y_counter)
);

task automatic frame_tick;
begin
    @(negedge clk);
    vblank = 1'b1;
    @(posedge clk);
    #1;
    @(negedge clk);
    vblank = 1'b0;
    @(posedge clk);
    #1;
end
endtask

task automatic reset_controls;
begin
    reset = 1'b1;
    vblank = 1'b0;
    digital = 32'd0;
    analog_left = 16'd0;
    analog_right = 16'd0;
    throttle_mode = 2'd0;
    repeat (2) @(posedge clk);
    #1;
    reset = 1'b0;
    repeat (2) @(posedge clk);
    #1;
end
endtask

task automatic expect_read(input [8:0] offset, input [15:0] expected);
begin
    read_offset = offset;
    #1;
    if (read_data !== expected)
        $fatal(1, "offset %03h returned %04h, expected %04h",
               offset, read_data, expected);
end
endtask

function automatic signed [11:0] reference_mame_axis(input integer raw);
    integer magnitude;
    integer numerator;
    integer scaled;
begin
    magnitude = raw < 0 ? -raw : raw;
    if ((magnitude * 100) <= 1905)
        reference_mame_axis = 12'sd0;
    else if ((magnitude * 100) >= 10795)
        reference_mame_axis = raw < 0 ? 12'sh800 : 12'sh7ff;
    else begin
        numerator = magnitude * 100 - 1905;
        if (raw < 0) begin
            scaled = (numerator * 2048 + 4445) / 8890;
            reference_mame_axis = -scaled;
        end else begin
            scaled = (numerator * 2047 + 4445) / 8890;
            reference_mame_axis = scaled;
        end
    end
end
endfunction

function automatic signed [11:0] reference_calibrated_axis(
    input integer raw,
    input integer negative_end,
    input integer positive_end
);
    integer nominal;
    integer magnitude;
    integer result;
begin
    nominal = $signed(reference_mame_axis(raw));
    magnitude = nominal < 0 ? -nominal : nominal;
    if (nominal < 0)
        result = -((magnitude * negative_end + 1024) / 2048);
    else
        result = (magnitude * positive_end + 1023) / 2048;
    reference_calibrated_axis = result;
end
endfunction

function automatic integer normalized_throttle(input integer raw);
    integer normalized;
begin
    normalized = (raw * 409) >>> 8;
    if (normalized > 63)
        normalized = 63;
    else if (normalized < -63)
        normalized = -63;
    normalized_throttle = normalized;
end
endfunction

integer n;
initial begin
    reset_controls();
    // The original startup POST checks that the two throttle limit switches
    // agree inactive before accepting Start. A virtual lever must therefore
    // begin at raw center rather than either calibrated endpoint.
    if (throttle_counter !== 12'h000 || stick_x_counter !== 12'h000 ||
        stick_y_counter !== 12'h000 || limit_n !== 6'b111111)
        $fatal(1, "reset/POST-neutral state is wrong");

    // Exhaustively prove the MAME frontend transfer followed by each of Top
    // Landing's ROM-derived cabinet ranges for every signed MiSTer input byte.
    for (n = -128; n <= 127; n = n + 1) begin
        analog_left[7:0] = n[7:0];
        analog_left[15:8] = n[7:0];
        analog_right[15:8] = n[7:0];
        throttle_mode = 2'd1;
        frame_tick();
        if ($signed(stick_x_counter) !==
            reference_calibrated_axis(n, 47, 48))
            $fatal(1, "X axis %0d mapped to %0d, expected %0d", n,
                   $signed(stick_x_counter),
                   reference_calibrated_axis(n, 47, 48));
        if ($signed(stick_y_counter) !==
            reference_calibrated_axis(n, 32, 32))
            $fatal(1, "Y axis %0d mapped to %0d, expected %0d", n,
                   $signed(stick_y_counter),
                   reference_calibrated_axis(n, 32, 32));
        if ($signed(throttle_counter) !==
            reference_calibrated_axis(n, 39, 40))
            $fatal(1, "throttle axis %0d mapped to %0d, expected %0d", n,
                   $signed(throttle_counter),
                   reference_calibrated_axis(n, 39, 40));
    end
    reset_controls();

    // MAME's default 15% dead zone suppresses raw +/-19 completely.
    throttle_mode = 2'd1;
    analog_left = {8'hed, 8'h13}; // -19 Y, +19 X
    analog_right = {8'h13, 8'h00};
    frame_tick();
    if (throttle_counter !== 12'h000 || stick_x_counter !== 12'h000 ||
        stick_y_counter !== 12'h000)
        $fatal(1, "MAME dead zone is wrong");

    // The first value outside the dead zone follows the composed mapping. The
    // deliberately small cabinet range retains a one-count X result here.
    analog_left = {8'hec, 8'h14}; // -20 Y, +20 X
    analog_right = {8'h14, 8'h00};
    frame_tick();
    if (throttle_counter !== 12'h000 || stick_x_counter !== 12'h001 ||
        stick_y_counter !== 12'h000)
        $fatal(1, "calibrated dead-zone edge is wrong: %03h/%03h/%03h",
               throttle_counter, stick_x_counter, stick_y_counter);

    // MAME's 85% frontend saturation now reaches the exact cabinet endpoints.
    analog_left = {8'h94, 8'h6c}; // -108 Y, +108 X
    analog_right = {8'h94, 8'h00};
    frame_tick();
    if (throttle_counter !== 12'hfd9 || stick_x_counter !== 12'h030 ||
        stick_y_counter !== 12'hfe0)
        $fatal(1, "calibrated analog saturation mapping is wrong");
    if (limit_n !== 6'b010101)
        $fatal(1, "negative throttle/Y and positive X limits are wrong: %b",
               limit_n);
    expect_read(9'h000, 16'h00d9);
    expect_read(9'h002, 16'h0030);
    expect_read(9'h004, 16'h000f);
    expect_read(9'h006, 16'h0000);
    expect_read(9'h100, 16'h00e0);
    expect_read(9'h102, 16'h0000);
    expect_read(9'h104, 16'h000f);
    expect_read(9'h106, 16'h0000);

    // Limit switches change only at the ROM-derived physical endpoints.
    reset_controls();
    analog_left[7:0] = 8'h6b; // +107 maps to +47, below right limit
    frame_tick();
    if (limit_n[3] !== 1'b1) $fatal(1, "+107 asserted right limit");
    analog_left[7:0] = 8'h6c; // +108 maps to +48
    frame_tick();
    if (limit_n[3] !== 1'b0) $fatal(1, "+108 did not assert right limit");
    analog_left[7:0] = 8'h94; // -108 maps to -47
    frame_tick();
    if (limit_n[2] !== 1'b0) $fatal(1, "-108 did not assert left limit");
    analog_left[7:0] = 8'h95; // -107 maps to -46
    frame_tick();
    if (limit_n[2] !== 1'b1) $fatal(1, "-107 asserted left limit");

    // MAME keyboard yoke: KEYDELTA(20), CENTERDELTA(20), once per frame.
    reset_controls();
    digital[0] = 1'b1; // right
    digital[3] = 1'b1; // up
    @(negedge clk);
    vblank = 1'b1;
    @(posedge clk);
    #1;
    if (stick_x_counter !== 12'h014 || stick_y_counter !== 12'hfec)
        $fatal(1, "first digital yoke step is wrong");
    // vblank is an edge, not a per-clock enable. Holding it high must not
    // repeat keyboard dynamics hundreds of times during the blanking period.
    repeat (8) @(posedge clk);
    #1;
    if (stick_x_counter !== 12'h014 || stick_y_counter !== 12'hfec)
        $fatal(1, "held-high vblank repeated a control step");
    @(negedge clk);
    vblank = 1'b0;
    @(posedge clk);
    #1;
    frame_tick();
    if (stick_x_counter !== 12'h028 || stick_y_counter !== 12'hfe0)
        $fatal(1, "second digital yoke step is wrong");
    digital[1] = 1'b1; // opposing directions cancel and hold both axes
    digital[2] = 1'b1;
    frame_tick();
    if (stick_x_counter !== 12'h028)
        $fatal(1, "opposing digital yoke directions did not hold");
    digital = 32'd0;
    frame_tick();
    if (stick_x_counter !== 12'h014 || stick_y_counter !== 12'hff4)
        $fatal(1, "digital yoke did not recenter by 20");
    frame_tick();
    if (stick_x_counter !== 12'h000 || stick_y_counter !== 12'h000)
        $fatal(1, "digital yoke did not finish centering");

    // Absolute analog wins and returning into the dead zone centers at once.
    digital[1] = 1'b1;
    analog_left[7:0] = 8'h6c;
    frame_tick();
    if (stick_x_counter !== 12'h030)
        $fatal(1, "digital input overrode absolute analog X");
    digital = 32'd0;
    analog_left = 16'd0;
    frame_tick();
    if (stick_x_counter !== 12'h000)
        $fatal(1, "absolute analog X did not return directly to center");

    // MAME throttle buttons use an output KEYDELTA(40); CENTERDELTA(0) makes
    // adjustments hold. Either direction reaches the corresponding calibrated
    // endpoint in one step from the POST-neutral reset position.
    reset_controls();
    throttle_mode = 2'd2;
    digital[7] = 1'b1; // throttle up is negative
    frame_tick();
    if (throttle_counter !== 12'hfd9)
        $fatal(1, "first throttle-up step is wrong");
    digital = 32'd0;
    frame_tick();
    if (throttle_counter !== 12'hfd9)
        $fatal(1, "released digital throttle did not hold");
    reset_controls();
    throttle_mode = 2'd2;
    digital[8] = 1'b1;
    frame_tick();
    if (throttle_counter !== 12'h028)
        $fatal(1, "throttle-down step is wrong");
    digital[7] = 1'b1;
    frame_tick();
    if (throttle_counter !== 12'h028)
        $fatal(1, "opposing throttle buttons did not cancel and hold");

    // A physical throttle maps its full travel to the two cabinet endpoints.
    throttle_mode = 2'd1;
    analog_right[15:8] = 8'h6c;
    frame_tick();
    if (throttle_counter !== 12'h028 || limit_n[0] !== 1'b0)
        $fatal(1, "absolute throttle did not override the digital fallback");
    digital = 32'd0;
    analog_right = 16'd0;
    frame_tick();
    if (throttle_counter !== 12'h000)
        $fatal(1, "absolute throttle did not return to center");
    analog_right[15:8] = 8'h94;
    frame_tick();
    if (throttle_counter !== 12'hfd9 || limit_n[1] !== 1'b0)
        $fatal(1, "absolute throttle did not reach full/slot-up");

    // Digital throttle clamps at the calibrated full endpoint.
    reset_controls();
    throttle_mode = 2'd2;
    digital[7] = 1'b1;
    frame_tick();
    if (throttle_counter !== 12'hfd9 || limit_n[1] !== 1'b0)
        $fatal(1, "digital throttle did not clamp at slot-up");

    // Default gamepad mode turns right-stick Y into the cabinet lever's
    // graded rate control. A 31-count local dead zone rejects drift; rates
    // 1/2/3 retain fine adjustment and fast travel. Releasing the stick holds
    // every intermediate value. Endpoint button bits remain ignored here.
    reset_controls();
    analog_right[15:8] = 8'he1; // -31 is still inside the local dead zone
    digital[8:7] = 2'b01;
    frame_tick();
    if (throttle_counter !== 12'h000)
        $fatal(1, "gamepad throttle moved inside its local dead zone");
    analog_right[15:8] = 8'hd8; // -40: one count toward full per frame
    frame_tick();
    if (throttle_counter !== 12'hfff)
        $fatal(1, "fine gamepad throttle rate is wrong");
    analog_right = 16'd0;
    frame_tick();
    if (throttle_counter !== 12'hfff)
        $fatal(1, "centred gamepad throttle did not hold an intermediate value");
    digital[8:7] = 2'b10;
    frame_tick();
    if (throttle_counter !== 12'hfff)
        $fatal(1, "endpoint button bits leaked into gamepad throttle mode");
    digital = 32'd0;
    analog_right[15:8] = 8'h40; // +64: two counts toward idle
    frame_tick();
    if (throttle_counter !== 12'h001)
        $fatal(1, "medium gamepad throttle rate/clamp is wrong");
    analog_right[15:8] = 8'h81; // -127: three counts toward full
    repeat (30)
        frame_tick();
    if (throttle_counter !== 12'hfd9 || limit_n[1] !== 1'b0)
        $fatal(1, "fast gamepad throttle did not clamp at full");
    analog_right[15:8] = 8'h7f;
    repeat (30)
        frame_tick();
    if (throttle_counter !== 12'h028 || limit_n[0] !== 1'b0)
        $fatal(1, "fast gamepad throttle did not clamp at idle");

    // The unused fourth menu encoding deliberately aliases the safe default
    // gamepad rate-control behavior.
    reset_controls();
    throttle_mode = 2'd3;
    analog_right[15:8] = 8'hd8;
    frame_tick();
    if (throttle_counter !== 12'hfff)
        $fatal(1, "undefined throttle mode did not use safe gamepad behavior");

    // The two calibrated endpoints produce the game's exact 15-to-0 power
    // range after the original 0x199 multiply, clamp and bar-level transform.
    if (normalized_throttle(-39) !== -63 ||
        ((64 - normalized_throttle(-39)) >>> 3) !== 15)
        $fatal(1, "full endpoint does not produce all 15 game bars");
    if (normalized_throttle(40) !== 63 ||
        ((64 - normalized_throttle(40)) >>> 3) !== 0)
        $fatal(1, "idle endpoint does not produce zero game bars");

    $display("PASS tb_flight_controls");
    $finish;
end

endmodule
