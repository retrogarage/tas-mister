`timescale 1ns/1ps

module tb_throttle_overlay;
reg enable = 1'b0;
reg [9:0] x = 10'd0;
reg [9:0] y = 10'd0;
reg [11:0] throttle_counter = 12'h000;
reg [11:0] stick_x_counter = 12'h000;
reg [11:0] stick_y_counter = 12'h000;
wire draw;
wire [7:0] red;
wire [7:0] green;
wire [7:0] blue;

tas_throttle_overlay dut (
    .enable(enable), .x(x), .y(y),
    .throttle_counter(throttle_counter),
    .stick_x_counter(stick_x_counter),
    .stick_y_counter(stick_y_counter),
    .draw(draw), .red(red), .green(green), .blue(blue)
);

task automatic expect_pixel(
    input [9:0] test_x,
    input [9:0] test_y,
    input expected_draw,
    input [23:0] expected_rgb
);
begin
    x = test_x;
    y = test_y;
    #1;
    if (draw !== expected_draw ||
        (expected_draw && {red, green, blue} !== expected_rgb))
        $fatal(1, "pixel %0d,%0d draw/rgb=%b/%06h expected %b/%06h",
               test_x, test_y, draw, {red, green, blue},
               expected_draw, expected_rgb);
end
endtask

initial begin
    // Hidden means fully transparent over both normally drawn markers.
    expect_pixel(10'd500, 10'd193, 1'b0, 24'h000000);
    expect_pixel(10'd454, 10'd195, 1'b0, 24'h000000);

    enable = 1'b1;
    // Center throttle marker is amber and the green fill extends down.
    expect_pixel(10'd500, 10'd193, 1'b1, 24'hffc000);
    expect_pixel(10'd500, 10'd194, 1'b1, 24'hffc000);
    expect_pixel(10'd500, 10'd200, 1'b1, 24'h20c040);

    // Full and idle use Top Landing's ROM-derived cabinet endpoints.
    throttle_counter = 12'hfd9; // -39, full/slot-up
    expect_pixel(10'd500, 10'd130, 1'b1, 24'hffc000);
    expect_pixel(10'd500, 10'd129, 1'b0, 24'h000000);
    throttle_counter = 12'h028; // +40, idle/slot-down
    expect_pixel(10'd500, 10'd257, 1'b1, 24'hffc000);
    expect_pixel(10'd500, 10'd256, 1'b0, 24'h000000);

    // Fixed throttle rail, center tick, label, and transparent exterior.
    expect_pixel(10'd492, 10'd180, 1'b1, 24'he0e0e0);
    expect_pixel(10'd490, 10'd194, 1'b1, 24'ha0a0a0);
    expect_pixel(10'd500, 10'd112, 1'b1, 24'h20d8ff);
    expect_pixel(10'd510, 10'd180, 1'b0, 24'h000000);

    // Centered yoke appears as an amber 3x3 marker in its compact box.
    throttle_counter = 12'h000;
    stick_x_counter = 12'h000;
    stick_y_counter = 12'h000;
    expect_pixel(10'd454, 10'd195, 1'b1, 24'hffc000);

    // Calibrated cabinet endpoints reach the four corners of the travel area.
    stick_x_counter = 12'hfd1; // -47, left
    stick_y_counter = 12'hfe0; // -32, up
    expect_pixel(10'd422, 10'd163, 1'b1, 24'hffc000);
    stick_x_counter = 12'h030; // +48, right
    stick_y_counter = 12'h020; // +32, down
    expect_pixel(10'd485, 10'd226, 1'b1, 24'hffc000);

    // Y label, border, center ticks, and transparent area outside the box.
    expect_pixel(10'd444, 10'd144, 1'b1, 24'h20d8ff);
    expect_pixel(10'd420, 10'd180, 1'b1, 24'he0e0e0);
    expect_pixel(10'd421, 10'd195, 1'b1, 24'ha0a0a0);
    expect_pixel(10'd419, 10'd180, 1'b0, 24'h000000);

    $display("PASS tb_throttle_overlay");
    $finish;
end

endmodule
