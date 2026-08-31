`timescale 1ns/1ps

module tb_audio_line_cache;
reg clk = 0;
always #5 clk = ~clk;
reg reset = 1;
reg [20:0] lookup_tag = 0;
wire lookup_hit;
wire [63:0] lookup_data;
reg [20:0] probe_tag = 0;
wire probe_hit;
reg fill = 0;
reg [20:0] fill_tag = 0;
reg [63:0] fill_data = 0;
integer i;

tas_audio_line_cache #(.LINES(8)) dut (
    .clk(clk), .reset(reset),
    .lookup_tag(lookup_tag), .lookup_hit(lookup_hit),
    .lookup_data(lookup_data),
    .probe_tag(probe_tag), .probe_hit(probe_hit),
    .fill(fill), .fill_tag(fill_tag), .fill_data(fill_data)
);

task fill_line(input [20:0] tag, input [63:0] value);
begin
    @(negedge clk);
    fill_tag = tag;
    fill_data = value;
    fill = 1;
    @(negedge clk);
    fill = 0;
end
endtask

task expect_line(input [20:0] tag, input [63:0] value);
begin
    lookup_tag = tag;
    #1;
    if (!lookup_hit || lookup_data !== value)
        $fatal(1, "cache tag=%h hit=%b data=%h expected=%h", tag,
               lookup_hit, lookup_data, value);
end
endtask

initial begin
    repeat (3) @(negedge clk);
    reset = 0;

    if ($test$plusargs("DUPLICATE_FILL")) begin
        fill_line(21'h042, 64'h1111222233334444);
        fill_line(21'h042, 64'h5555666677778888);
        $fatal(1, "duplicate audio-cache fill was accepted");
    end

    // Six concurrent ADPCM-A streams plus two crossing-line lookaheads fit
    // without the one-line thrash diagnosed by the review.
    for (i = 0; i < 8; i = i + 1)
        fill_line(21'h100 + i, 64'h1000000000000000 + i);
    for (i = 0; i < 8; i = i + 1)
        expect_line(21'h100 + i, 64'h1000000000000000 + i);
    probe_tag = 21'h106;
    #1;
    if (!probe_hit) $fatal(1, "resident prefetch probe missed");
    probe_tag = 21'h200;
    #1;
    if (probe_hit) $fatal(1, "absent prefetch probe hit");

    // A ninth distinct line replaces only the round-robin victim.
    fill_line(21'h200, 64'h0123456789abcdef);
    expect_line(21'h200, 64'h0123456789abcdef);
    lookup_tag = 21'h100;
    #1;
    if (lookup_hit) $fatal(1, "round-robin victim was not replaced");
    for (i = 1; i < 8; i = i + 1)
        expect_line(21'h100 + i, 64'h1000000000000000 + i);

    $display("PASS tb_audio_line_cache");
    $finish;
end
endmodule
