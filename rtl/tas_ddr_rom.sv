// MiSTer DDR3 adapter for a byte-stream ROM download and 68000 word reads.
// The logical image is placed at physical DDR3 byte address 0x30000000.
module tas_ddr_rom (
    input               clk,
    input               reset,
    input               background_safe,

    input               ioctl_wr,
    input      [26:0]   ioctl_addr,
    input      [7:0]    ioctl_data,
    output              ioctl_wait,

    input               cpu_req,
    input      [23:0]   cpu_addr,
    output reg          cpu_ack,
    output reg [15:0]   cpu_data,

    // TC0080VCO graphics reader. Addresses are relative to the 1 MiB
    // graphics region and each request returns one aligned 64-bit tile row.
    input               gfx_req,
    input      [19:0]   gfx_addr,
    output              gfx_ack,
    output     [63:0]   gfx_data,

    // Low-rate aligned lines for YM2610 ADPCM sample caches.
    input               audio_req,
    input      [23:0]   audio_addr,
    output reg          audio_ack,
    output reg [63:0]   audio_data,

    // Low-rate diagnostic writes into unused space above the ROM image.
    input               debug_wr_req,
    input      [27:0]   debug_wr_addr,
    input      [63:0]   debug_wr_data,
    output reg          debug_wr_ack,

    // Observational counters for the video-safe CPU arbitration gate. A CPU
    // cache hit uses no DDR bandwidth and is therefore allowed through even
    // when background_safe is low. True misses remain held until the video
    // client has declared a safe interval.
    output reg [31:0]   debug_cpu_blocked_clocks,
    output reg [31:0]   debug_cpu_unsafe_cache_hits,

    input               DDRAM_BUSY,
    input      [63:0]   DDRAM_DOUT,
    input               DDRAM_DOUT_READY,
    output     [7:0]    DDRAM_BURSTCNT,
    output     [28:0]   DDRAM_ADDR,
    output reg [63:0]   DDRAM_DIN,
    output reg [7:0]    DDRAM_BE,
    output reg          DDRAM_RD,
    output reg          DDRAM_WE
);

localparam IDLE          = 4'd0;
localparam WRITE_ISSUE   = 4'd1;
localparam WRITE_WAIT    = 4'd2;
localparam READ_ISSUE    = 4'd3;
localparam READ_WAIT     = 4'd4;
localparam READ_HOLD     = 4'd5;
localparam GFX_HOLD      = 4'd6;
localparam AUDIO_HOLD    = 4'd8;

reg [3:0]  state;
reg [27:0] memory_addr;
reg [63:0] cache_data;
reg [24:0] cache_tag;
reg        cache_valid;
// Graphics rows have strong immediate locality, so retain a small asynchronous
// L1 for the line builder's one-clock hit path. Rows displaced from L1 remain
// in a larger synchronous L2 backed by M10Ks. This avoids spending thousands
// of scarce LABs on a wide asynchronous cache while screening most misses from
// the variable-latency shared DDR interface.
reg [63:0] gfx_cache_data [0:31];
reg [24:0] gfx_cache_tag [0:31];
reg [31:0] gfx_cache_valid;
reg [511:0] gfx_l2_valid;
reg [8:0]  gfx_l2_lookup_index;
reg [24:0] gfx_l2_lookup_tag;
reg        gfx_l2_pending;
reg        gfx_l2_miss_pending;
reg        write_is_debug;
reg        read_is_gfx;
reg        read_is_audio;
reg        prefer_audio;
reg        gfx_hit_hold;
reg        gfx_ack_registered;
reg [63:0] gfx_data_registered;

wire [2:0] byte_lane = memory_addr[2:0];
wire [24:0] request_tag = {4'b0000, cpu_addr[23:3]};
wire [2:0] request_lane = cpu_addr[2:0];
wire cpu_cache_hit = cache_valid && cache_tag == request_tag;
wire [27:0] gfx_memory_addr = 28'h0100000 + {8'd0, gfx_addr};
wire [24:0] gfx_request_tag = gfx_memory_addr[27:3];
function automatic [4:0] gfx_cache_hash(input [24:0] tag);
begin
    gfx_cache_hash = tag[4:0] ^ tag[9:5] ^ tag[14:10] ^
        tag[19:15];
end
endfunction
function automatic [8:0] gfx_l2_hash(input [24:0] tag);
begin
    gfx_l2_hash = tag[8:0] ^ tag[17:9] ^
        {2'd0, tag[24:18]};
end
endfunction
wire [4:0] gfx_cache_index = gfx_cache_hash(gfx_request_tag);
wire gfx_cache_hit = gfx_cache_valid[gfx_cache_index] &&
    gfx_cache_tag[gfx_cache_index] == gfx_request_tag;
wire [4:0] gfx_fill_index = gfx_cache_hash(memory_addr[27:3]);
wire [8:0] gfx_l2_request_index = gfx_l2_hash(gfx_request_tag);
wire [8:0] gfx_l2_fill_index = gfx_l2_hash(memory_addr[27:3]);
wire [4:0] gfx_l2_l1_fill_index = gfx_cache_hash(gfx_l2_lookup_tag);
wire [88:0] gfx_l2_read_data;
wire gfx_l2_read_enable = gfx_req && !gfx_cache_hit && !gfx_hit_hold &&
    !gfx_l2_pending && !gfx_l2_miss_pending &&
    !(read_is_gfx && state != IDLE);
wire gfx_l2_write_enable = state == READ_WAIT && DDRAM_DOUT_READY &&
    read_is_gfx;
wire gfx_l2_hit = gfx_req && gfx_l2_pending &&
    gfx_l2_valid[gfx_l2_lookup_index] &&
    gfx_l2_read_data[88:64] == gfx_l2_lookup_tag;
wire gfx_physical_pending = gfx_req && (gfx_l2_miss_pending ||
    (gfx_l2_pending && !gfx_l2_hit));
// Both cache levels are independent of DDR. A hit can therefore complete
// while an unrelated CPU/audio/debug transaction owns the physical port. The
// hold bit preserves the request/ack protocol without tying hits to the FSM.
wire gfx_cache_fast_ack = gfx_req && gfx_cache_hit && !gfx_hit_hold;
assign gfx_ack = gfx_ack_registered || gfx_cache_fast_ack || gfx_l2_hit;
assign gfx_data = gfx_cache_fast_ack
    ? gfx_cache_data[gfx_cache_index]
    : (gfx_l2_hit ? gfx_l2_read_data[63:0] : gfx_data_registered);

assign ioctl_wait = (state != IDLE);
assign DDRAM_BURSTCNT = 8'd1;
assign DDRAM_ADDR = {4'b0011, memory_addr[27:3]};

// Keep the victim data and tag in one simple synchronous memory. Isolating
// this pattern behind a wrapper prevents top-level cache-control muxes from
// turning the read into a large asynchronous LAB implementation.
tas_ddr_cache_ram #(.AW(9), .DW(89)) gfx_l2 (
    .clk(clk),
    .read_enable(gfx_l2_read_enable),
    .read_addr(gfx_l2_request_index),
    .read_data(gfx_l2_read_data),
    .write_enable(gfx_l2_write_enable),
    .write_addr(gfx_l2_fill_index),
    .write_data({memory_addr[27:3], DDRAM_DOUT})
);

always @(posedge clk) begin
    cpu_ack <= 1'b0;
    gfx_ack_registered <= 1'b0;
    audio_ack <= 1'b0;
    debug_wr_ack <= 1'b0;

    if (reset) begin
        state       <= IDLE;
        memory_addr <= 28'd0;
        cache_data  <= 64'd0;
        cache_tag   <= 25'd0;
        cache_valid <= 1'b0;
        gfx_cache_valid <= 32'd0;
        gfx_l2_valid <= 512'd0;
        gfx_l2_lookup_index <= 9'd0;
        gfx_l2_lookup_tag <= 25'd0;
        gfx_l2_pending <= 1'b0;
        gfx_l2_miss_pending <= 1'b0;
        write_is_debug <= 1'b0;
        read_is_gfx <= 1'b0;
        read_is_audio <= 1'b0;
        prefer_audio <= 1'b0;
        gfx_hit_hold <= 1'b0;
        DDRAM_DIN   <= 64'd0;
        DDRAM_BE    <= 8'd0;
        DDRAM_RD    <= 1'b0;
        DDRAM_WE    <= 1'b0;
        cpu_data    <= 16'hffff;
        gfx_data_registered <= 64'd0;
        audio_data <= 64'd0;
        debug_cpu_blocked_clocks <= 32'd0;
        debug_cpu_unsafe_cache_hits <= 32'd0;
    end else begin
        // Count only clocks where the background gate itself is the reason a
        // CPU miss cannot start. Higher-priority ROM-loader, audio and video
        // transactions are deliberately excluded from this measurement.
        if (state == IDLE && !ioctl_wr &&
            !(audio_req &&
              (!gfx_req || gfx_cache_hit || gfx_l2_hit ||
               (gfx_physical_pending && prefer_audio))) &&
            !gfx_physical_pending && cpu_req && !cpu_cache_hit &&
            !background_safe && !(&debug_cpu_blocked_clocks))
            debug_cpu_blocked_clocks <= debug_cpu_blocked_clocks + 1'd1;

        if (!gfx_req) begin
            gfx_hit_hold <= 1'b0;
            gfx_l2_pending <= 1'b0;
            gfx_l2_miss_pending <= 1'b0;
        end else if (gfx_cache_fast_ack || gfx_l2_hit) begin
            gfx_hit_hold <= 1'b1;
        end

        if (gfx_l2_read_enable) begin
            gfx_l2_lookup_index <= gfx_l2_request_index;
            gfx_l2_lookup_tag <= gfx_request_tag;
            gfx_l2_pending <= 1'b1;
        end else if (gfx_l2_pending && gfx_req) begin
            gfx_l2_pending <= 1'b0;
            if (gfx_l2_hit) begin
                // Promote an L2 hit so subsequent rows with immediate
                // locality retain the asynchronous one-clock path.
                gfx_cache_data[gfx_l2_l1_fill_index] <=
                    gfx_l2_read_data[63:0];
                gfx_cache_tag[gfx_l2_l1_fill_index] <= gfx_l2_lookup_tag;
                gfx_cache_valid[gfx_l2_l1_fill_index] <= 1'b1;
            end else begin
                gfx_l2_miss_pending <= 1'b1;
            end
        end

        case (state)
            IDLE: begin
                DDRAM_RD <= 1'b0;
                DDRAM_WE <= 1'b0;
                if (ioctl_wr) begin
                    memory_addr <= {1'b0, ioctl_addr};
                    DDRAM_DIN <= {8{ioctl_data}};
                    DDRAM_BE <= 8'b00000001 << ioctl_addr[2:0];
                    write_is_debug <= 1'b0;
                    if (cache_valid && cache_tag == {1'b0, ioctl_addr[26:3]})
                        cache_valid <= 1'b0;
                    // ROM loading happens before execution and invalidates
                    // both graphics-row cache levels as a unit.
                    gfx_cache_valid <= 32'd0;
                    gfx_l2_valid <= 512'd0;
                    state <= WRITE_ISSUE;
                end else if (audio_req &&
                             (!gfx_req || gfx_cache_hit || gfx_l2_hit ||
                              (gfx_physical_pending && prefer_audio))) begin
                    memory_addr <= {4'b0000, audio_addr[23:3], 3'b000};
                    read_is_gfx <= 1'b0;
                    read_is_audio <= 1'b1;
                    prefer_audio <= 1'b0;
                    state <= READ_ISSUE;
                end else if (gfx_physical_pending) begin
                    // Bound audio latency without allowing a broken or cold
                    // sample cache to monopolize DDR ahead of the video
                    // builder. When both clients remain active, alternate.
                    prefer_audio <= 1'b1;
                    memory_addr <= {gfx_l2_lookup_tag, 3'b000};
                    read_is_gfx <= 1'b1;
                    read_is_audio <= 1'b0;
                    gfx_l2_miss_pending <= 1'b0;
                    if (!DDRAM_BUSY) begin
                        DDRAM_RD <= 1'b1;
                        state <= READ_WAIT;
                    end else begin
                        state <= READ_ISSUE;
                    end
                end else if (cpu_req && cpu_cache_hit) begin
                    cpu_data <= {
                        cache_data[{request_lane, 3'b000} +: 8],
                        cache_data[{request_lane + 3'd1, 3'b000} +: 8]
                    };
                    cpu_ack <= 1'b1;
                    state <= READ_HOLD;
                    if (!background_safe &&
                        !(&debug_cpu_unsafe_cache_hits))
                        debug_cpu_unsafe_cache_hits <=
                            debug_cpu_unsafe_cache_hits + 1'd1;
                end else if (background_safe && cpu_req) begin
                    memory_addr <= {4'b0000, cpu_addr};
                    read_is_gfx <= 1'b0;
                    read_is_audio <= 1'b0;
                    state <= READ_ISSUE;
                end else if (background_safe && debug_wr_req) begin
                    // Debug telemetry must never pre-empt an emulated-board
                    // client.  The top level schedules these writes in
                    // vertical blank; retaining lowest priority here also
                    // makes the invariant explicit if that scheduler changes.
                    memory_addr <= debug_wr_addr;
                    DDRAM_DIN <= debug_wr_data;
                    DDRAM_BE <= 8'hff;
                    write_is_debug <= 1'b1;
                    if (cache_valid && cache_tag == debug_wr_addr[27:3])
                        cache_valid <= 1'b0;
                    state <= WRITE_ISSUE;
                end
            end

            WRITE_ISSUE: begin
                if (!DDRAM_BUSY) begin
                    DDRAM_WE <= 1'b1;
                    state <= WRITE_WAIT;
                end
            end

            WRITE_WAIT: begin
                if (!DDRAM_BUSY) begin
                    DDRAM_WE <= 1'b0;
                    if (write_is_debug) debug_wr_ack <= 1'b1;
                    state <= IDLE;
                end
            end

            READ_ISSUE: begin
                if (!DDRAM_BUSY) begin
                    DDRAM_RD <= 1'b1;
                    state <= READ_WAIT;
                end
            end

            READ_WAIT: begin
                // Avalon-MM accepts the read on a clock where RD is asserted
                // and waitrequest (DDRAM_BUSY) is low. Drop RD immediately
                // after that acceptance; keeping it asserted until the return
                // data arrives can enqueue the same line more than once.
                if (!DDRAM_BUSY)
                    DDRAM_RD <= 1'b0;
                if (DDRAM_DOUT_READY) begin
                    DDRAM_RD <= 1'b0;
                    if (read_is_gfx) begin
                        gfx_cache_data[gfx_fill_index] <= DDRAM_DOUT;
                        gfx_cache_tag[gfx_fill_index] <= memory_addr[27:3];
                        gfx_cache_valid[gfx_fill_index] <= 1'b1;
                        gfx_l2_valid[gfx_l2_fill_index] <= 1'b1;
                        gfx_data_registered <= DDRAM_DOUT;
                        gfx_ack_registered <= 1'b1;
                        state <= GFX_HOLD;
                    end else if (read_is_audio) begin
                        audio_data <= DDRAM_DOUT;
                        audio_ack <= 1'b1;
                        state <= AUDIO_HOLD;
                    end else begin
                        cache_data <= DDRAM_DOUT;
                        cache_tag <= memory_addr[27:3];
                        cache_valid <= 1'b1;
                        cpu_data <= {
                            DDRAM_DOUT[{byte_lane, 3'b000} +: 8],
                            DDRAM_DOUT[{byte_lane + 3'd1, 3'b000} +: 8]
                        };
                        cpu_ack <= 1'b1;
                        state <= READ_HOLD;
                    end
                end
            end

            // cpu_req is level-based. Do not interpret the tail of the
            // completed request as a second cache hit while the requester is
            // consuming cpu_ack on the following clock.
            READ_HOLD: begin
                DDRAM_RD <= 1'b0;
                if (!cpu_req) state <= IDLE;
            end

            GFX_HOLD: begin
                DDRAM_RD <= 1'b0;
                if (!gfx_req) state <= IDLE;
            end

            AUDIO_HOLD: begin
                DDRAM_RD <= 1'b0;
                if (!audio_req) state <= IDLE;
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule

module tas_ddr_cache_ram #(
    parameter AW = 9,
    parameter DW = 89
) (
    input                 clk,
    input                 read_enable,
    input        [AW-1:0] read_addr,
    output reg   [DW-1:0] read_data,
    input                 write_enable,
    input        [AW-1:0] write_addr,
    input        [DW-1:0] write_data
);
(* ramstyle = "M10K, no_rw_check" *) reg [DW-1:0] memory [0:(1<<AW)-1];
always @(posedge clk) begin
    if (read_enable) read_data <= memory[read_addr];
    if (write_enable) memory[write_addr] <= write_data;
end
endmodule
