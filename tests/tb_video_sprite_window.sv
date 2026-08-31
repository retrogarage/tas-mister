`timescale 1ns/1ps

module tb_video_sprite_window;
reg clk = 1'b0;
always #5 clk = ~clk;

reg [14:0] chain_base = 15'd0;
reg [8:0] target_y = 9'd0;
wire visible;
reg [9:0] fill_x = 10'd0;
reg [8:0] fill_y = 9'd0;
reg cockpit_active = 1'b0;
reg title_active = 1'b0;
reg foreground_valid = 1'b0;
wire fill;
reg detector_reset = 1'b1;
reg detector_pixel_valid = 1'b0;
reg detector_frame_end = 1'b0;
reg [9:0] detector_x = 10'd0;
reg [8:0] detector_y = 9'd0;
reg [7:0] detector_red = 8'd0;
reg [7:0] detector_green = 8'd0;
reg [7:0] detector_blue = 8'd0;
wire detected_title;

tas_topland_sprite_window dut (
    .chain_base(chain_base),
    .target_y(target_y),
    .visible(visible)
);

tas_topland_left_edge_fill fill_dut (
    .x(fill_x),
    .y(fill_y),
    .cockpit_active(cockpit_active),
    .title_active(title_active),
    .foreground_valid(foreground_valid),
    .fill(fill)
);

tas_topland_title_detector title_dut (
    .clk(clk),
    .reset(detector_reset),
    .pixel_valid(detector_pixel_valid),
    .frame_end(detector_frame_end),
    .x(detector_x),
    .y(detector_y),
    .red(detector_red),
    .green(detector_green),
    .blue(detector_blue),
    .title_active(detected_title)
);

task check(input expected_visible);
begin
    #1;
    if (visible !== expected_visible)
        $fatal(1, "sprite window mismatch chain=%04h y=%0d visible=%0d",
            chain_base, target_y, visible);
end
endtask

task sample_title_marker(
    input [9:0] sample_x,
    input [8:0] sample_y,
    input [23:0] sample_rgb
);
begin
    detector_x = sample_x;
    detector_y = sample_y;
    {detector_red, detector_green, detector_blue} = sample_rgb;
    detector_pixel_valid = 1'b1;
    @(posedge clk);
    #1;
    detector_pixel_valid = 1'b0;
end
endtask

task publish_title_frame;
begin
    detector_frame_end = 1'b1;
    @(posedge clk);
    #1;
    detector_frame_end = 1'b0;
end
endtask

task check_fill(input expected_fill);
begin
    #1;
    if (fill !== expected_fill)
        $fatal(1,
            "left-edge fill mismatch x=%0d y=%0d cockpit=%0d foreground=%0d fill=%0d",
            fill_x, fill_y, cockpit_active, foreground_valid, fill);
end
endtask

initial begin
    // The identified cloud chain remains fully visible through the final
    // playfield line and is clipped at the first cockpit line.
    chain_base = {13'h08c4, 2'b00};
    target_y = 9'd272;
    check(1'b1);
    target_y = 9'd273;
    check(1'b0);
    target_y = 9'd399;
    check(1'b0);

    // Neighbouring world and cockpit chains are never clipped, including
    // below the boundary. This protects runway personnel and the legitimate
    // readout descriptors found in the same pause group as the clouds.
    chain_base = {13'h08c3, 2'b00};
    target_y = 9'd273;
    check(1'b1);
    chain_base = {13'h08b4, 2'b00};
    target_y = 9'd399;
    check(1'b1);
    chain_base = {13'h04a4, 2'b00};
    check(1'b1);

    // Non-flight empty x=1 and flight empty x=1..3 retain the accepted result.
    // Only a qualified title may additionally override valid artwork at x=3;
    // unqualified course-selector foreground remains visible.
    fill_x = 10'd1;
    fill_y = 9'd100;
    cockpit_active = 1'b0;
    foreground_valid = 1'b0;
    check_fill(1'b1);
    foreground_valid = 1'b1;
    check_fill(1'b0);
    foreground_valid = 1'b0;
    cockpit_active = 1'b1;
    check_fill(1'b1);
    fill_x = 10'd2;
    check_fill(1'b1);
    fill_x = 10'd0;
    check_fill(1'b0);
    fill_x = 10'd3;
    check_fill(1'b1);
    fill_x = 10'd4;
    check_fill(1'b0);
    fill_x = 10'd1;
    fill_y = 9'd273;
    check_fill(1'b0);
    fill_y = 9'd100;
    foreground_valid = 1'b1;
    check_fill(1'b0);
    cockpit_active = 1'b0;
    fill_x = 10'd3;
    check_fill(1'b0);
    title_active = 1'b1;
    check_fill(1'b1);
    fill_x = 10'd4;
    check_fill(1'b0);
    title_active = 1'b0;

    // All three bounded spatial/color markers are required and publish only
    // at the completed-frame boundary. Offset/tolerant samples model the
    // registered final-RGB pipeline; a partial level-select-like frame clears
    // title instead of authorizing an x=3 crop.
    repeat (2) @(posedge clk);
    detector_reset = 1'b0;
    sample_title_marker(10'd265, 9'd80, 24'hff0000);
    sample_title_marker(10'd255, 9'd120, 24'haaaaaa);
    sample_title_marker(10'd240, 9'd300, 24'h0000ff);
    if (detected_title !== 1'b0)
        $fatal(1, "title detector published before frame end");
    publish_title_frame();
    if (detected_title !== 1'b1)
        $fatal(1, "complete title signature was not detected");
    sample_title_marker(10'd288, 9'd106, 24'he02018);
    sample_title_marker(10'd144, 9'd166, 24'h909b88);
    sample_title_marker(10'd273, 9'd312, 24'h1830d8);
    publish_title_frame();
    if (detected_title !== 1'b1)
        $fatal(1, "bounded/tolerant title signature was not detected");
    sample_title_marker(10'd265, 9'd80, 24'hff0000);
    sample_title_marker(10'd255, 9'd120, 24'haaaaaa);
    publish_title_frame();
    if (detected_title !== 1'b0)
        $fatal(1, "partial title signature was accepted");

    // A centered publisher splash arms the complete intro sequence before the
    // runway frame appears. Edge content rejects a course-select-like screen
    // even when it contains similar blue and grey pixels.
    detector_reset = 1'b1;
    @(posedge clk);
    #1;
    detector_reset = 1'b0;
    sample_title_marker(10'd260, 9'd130, 24'h000011);
    sample_title_marker(10'd240, 9'd250, 24'h111111);
    publish_title_frame();
    if (detected_title !== 1'b1)
        $fatal(1, "publisher splash did not arm title intro");
    publish_title_frame();
    if (detected_title !== 1'b1)
        $fatal(1, "publisher-to-title bridge did not persist");
    sample_title_marker(10'd265, 9'd80, 24'hff0000);
    sample_title_marker(10'd255, 9'd120, 24'haaaaaa);
    sample_title_marker(10'd240, 9'd300, 24'h0000ff);
    publish_title_frame();
    if (detected_title !== 1'b1)
        $fatal(1, "bridged title signature was not accepted");
    publish_title_frame();
    if (detected_title !== 1'b0)
        $fatal(1, "title mask persisted into following scene");

    detector_reset = 1'b1;
    @(posedge clk);
    #1;
    detector_reset = 1'b0;
    sample_title_marker(10'd260, 9'd130, 24'h000066);
    sample_title_marker(10'd240, 9'd250, 24'h444444);
    sample_title_marker(10'd20, 9'd100, 24'hffffff);
    publish_title_frame();
    if (detected_title !== 1'b0)
        $fatal(1, "edge-populated selector falsely armed title intro");

    $display("PASS tb_video_sprite_window: cloud window and scene-qualified edge fill");
    $finish;
end

endmodule
