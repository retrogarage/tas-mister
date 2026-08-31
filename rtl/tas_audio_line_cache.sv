// Small fully-associative cache for multiplexed YM2610 sample-ROM addresses.
// ADPCM-A rotates one external address bus across six independent channels;
// retaining one line per active stream prevents the live address mux from
// evicting a different channel on every slot.
module tas_audio_line_cache #(
    parameter TAG_WIDTH = 21,
    parameter LINES = 8,
    parameter INDEX_WIDTH = $clog2(LINES)
) (
    input                         clk,
    input                         reset,
    input      [TAG_WIDTH-1:0]    lookup_tag,
    output reg                    lookup_hit,
    output reg [63:0]             lookup_data,
    input      [TAG_WIDTH-1:0]    probe_tag,
    output reg                    probe_hit,
    input                         fill,
    input      [TAG_WIDTH-1:0]    fill_tag,
    input      [63:0]             fill_data
);

reg [TAG_WIDTH-1:0] tags [0:LINES-1];
reg [63:0] data [0:LINES-1];
reg [LINES-1:0] valid;
reg [INDEX_WIDTH-1:0] replace_index;
integer i;

// The area-saving replacement policy depends on the owner never returning a
// line that became resident while its one outstanding request was in flight.
// Make that interface contract executable in simulation without adding a
// second comparator bank to the FPGA implementation.
`ifndef SYNTHESIS
integer duplicate_index;
always @(posedge clk) begin
    if (!reset && fill) begin
        for (duplicate_index = 0; duplicate_index < LINES;
             duplicate_index = duplicate_index + 1) begin
            if (valid[duplicate_index] &&
                tags[duplicate_index] == fill_tag)
                $fatal(1, "duplicate audio-cache fill tag=%h", fill_tag);
        end
    end
end
`endif

always @* begin
    lookup_hit = 1'b0;
    lookup_data = 64'hffffffffffffffff;
    probe_hit = 1'b0;
    for (i = 0; i < LINES; i = i + 1) begin
        if (valid[i] && tags[i] == lookup_tag) begin
            lookup_hit = 1'b1;
            lookup_data = data[i];
        end
        if (valid[i] && tags[i] == probe_tag)
            probe_hit = 1'b1;
    end
end

always @(posedge clk) begin
    if (reset) begin
        valid <= {LINES{1'b0}};
        replace_index <= {INDEX_WIDTH{1'b0}};
    end else if (fill) begin
        // The owner permits one outstanding request and starts it only on a
        // lookup miss.  Consequently a returned fill cannot already be
        // resident; avoiding a second LINES-wide tag search saves a duplicate
        // comparator bank in this dense design.
        tags[replace_index] <= fill_tag;
        data[replace_index] <= fill_data;
        valid[replace_index] <= 1'b1;
        replace_index <= replace_index + 1'd1;
    end
end

endmodule
