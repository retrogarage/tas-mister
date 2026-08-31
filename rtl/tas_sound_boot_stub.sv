// Test-only sound-CPU life responder retained after board bring-up.
//
// It performs a legal TC0140SYT slave-side write after the main CPU releases
// the audio-board reset. Production instantiates the real Z80/YM2610 board;
// protocol and main-board tests use this deterministic responder to isolate
// the 68000/DSP/video path.
module tas_sound_boot_stub (
    input            clk,
    input            reset,
    input            sound_reset_n,
    input      [3:0] status,
    output reg       sound_cs,
    output reg       sound_wr,
    output reg       sound_port,
    output reg [3:0] sound_din
);

reg old_sound_reset_n;
reg [7:0] delay_count;
reg [4:0] state;

always @(posedge clk) begin
    sound_cs <= 1'b0;
    if (reset) begin
        old_sound_reset_n <= 1'b0;
        delay_count <= 8'd0;
        state <= 5'd0;
        sound_wr <= 1'b1;
        sound_port <= 1'b0;
        sound_din <= 4'd0;
    end else begin
        old_sound_reset_n <= sound_reset_n;
        if (!sound_reset_n) begin
            delay_count <= 8'd0;
            state <= 5'd0;
        end else if (!old_sound_reset_n) begin
            delay_count <= 8'hff;
            state <= 5'd1;
        end else if (state == 5'd1) begin
            if (delay_count != 0) delay_count <= delay_count - 1'd1;
            else state <= 5'd2;
        end else begin
            case (state)
                5'd2: begin
                    sound_cs <= 1'b1;
                    sound_wr <= 1'b1;
                    sound_port <= 1'b0;
                    sound_din <= 4'd0;
                    state <= 5'd3;
                end
                5'd3: state <= 5'd4;
                5'd4: begin
                    sound_cs <= 1'b1;
                    sound_wr <= 1'b1;
                    sound_port <= 1'b1;
                    sound_din <= 4'd0;
                    state <= 5'd5;
                end
                5'd5: state <= 5'd6;
                5'd6: begin
                    sound_cs <= 1'b1;
                    sound_wr <= 1'b1;
                    sound_port <= 1'b1;
                    sound_din <= 4'd0;
                    state <= 5'd7;
                end
                5'd7: if (status[1:0] != 0) state <= 5'd8;
                5'd8: begin
                    // Select command nibble zero on the sound side.
                    sound_cs <= 1'b1;
                    sound_wr <= 1'b1;
                    sound_port <= 1'b0;
                    sound_din <= 4'd0;
                    state <= 5'd9;
                end
                5'd9: state <= 5'd10;
                5'd10, 5'd12, 5'd14, 5'd16: begin
                    // Reading nibble one clears status bit 0; reading nibble
                    // three clears bit 1. Always consuming four nibbles also
                    // handles a new four-nibble message without a race.
                    sound_cs <= 1'b1;
                    sound_wr <= 1'b0;
                    sound_port <= 1'b1;
                    sound_din <= 4'd0;
                    state <= state + 1'd1;
                end
                5'd11, 5'd13, 5'd15: state <= state + 1'd1;
                5'd17: state <= 5'd7;
                default: state <= 5'd0;
            endcase
        end
    end
end

endmodule
