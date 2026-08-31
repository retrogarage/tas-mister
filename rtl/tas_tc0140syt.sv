// Taito TC0140SYT CPU communication registers.
//
// The nibble protocol and status-bit behavior follow the FPGA-proven
// implementation in MiSTer-devel/Arcade-TaitoF2_MiSTer. This module keeps
// only the communication portion; ROM banking and the audio-board chip
// selects belong in the Top Landing sound-board module.
module tas_tc0140syt (
    input              clk,
    input              reset,

    input              main_cs,
    input              main_wr,
    input              main_port,
    input      [3:0]   main_din,
    output reg [3:0]   main_dout,

    input              sound_cs,
    input              sound_wr,
    input              sound_port,
    input      [3:0]   sound_din,
    output reg [3:0]   sound_dout,

    output             sound_reset_n,
    output             sound_nmi_n,
    output reg [3:0]   status
);

reg [3:0] main_index;
reg [3:0] sound_index;
reg [15:0] to_sound;
reg [15:0] to_main;
reg sound_reset;
reg nmi_enabled;

assign sound_reset_n = !reset && !sound_reset;
assign sound_nmi_n = !(nmi_enabled && (status[0] || status[1]));

always @* begin
    main_dout = 4'hf;
    if (main_port) begin
        case (main_index)
            4'd0: main_dout = to_main[3:0];
            4'd1: main_dout = to_main[7:4];
            4'd2: main_dout = to_main[11:8];
            4'd3: main_dout = to_main[15:12];
            4'd4: main_dout = status;
            default: main_dout = 4'hf;
        endcase
    end

end

always @(posedge clk) begin
    if (reset) begin
        main_index <= 4'd0;
        sound_index <= 4'd0;
        to_sound <= 16'd0;
        to_main <= 16'd0;
        sound_reset <= 1'b1;
        nmi_enabled <= 1'b0;
        sound_dout <= 4'hf;
        status <= 4'd0;
    end else begin
        if (main_cs) begin
            if (!main_port && main_wr) begin
                main_index <= main_din;
            end else if (main_port) begin
                if (main_wr) begin
                    case (main_index)
                        4'd0: begin
                            to_sound[3:0] <= main_din;
                            main_index <= 4'd1;
                        end
                        4'd1: begin
                            to_sound[7:4] <= main_din;
                            main_index <= 4'd2;
                            status[0] <= 1'b1;
                        end
                        4'd2: begin
                            to_sound[11:8] <= main_din;
                            main_index <= 4'd3;
                        end
                        4'd3: begin
                            to_sound[15:12] <= main_din;
                            main_index <= 4'd4;
                            status[1] <= 1'b1;
                        end
                        4'd4: sound_reset <= main_din[0];
                        default: begin end
                    endcase
                end else begin
                    case (main_index)
                        4'd0: main_index <= 4'd1;
                        4'd1: begin
                            main_index <= 4'd2;
                            status[2] <= 1'b0;
                        end
                        4'd2: main_index <= 4'd3;
                        4'd3: begin
                            main_index <= 4'd4;
                            status[3] <= 1'b0;
                        end
                        default: begin end
                    endcase
                end
            end
        end

        if (sound_cs) begin
            if (!sound_port && sound_wr) begin
                sound_index <= sound_din;
            end else if (sound_port) begin
                if (sound_wr) begin
                    case (sound_index)
                        4'd0: begin
                            to_main[3:0] <= sound_din;
                            sound_index <= 4'd1;
                        end
                        4'd1: begin
                            to_main[7:4] <= sound_din;
                            sound_index <= 4'd2;
                            status[2] <= 1'b1;
                        end
                        4'd2: begin
                            to_main[11:8] <= sound_din;
                            sound_index <= 4'd3;
                        end
                        4'd3: begin
                            to_main[15:12] <= sound_din;
                            sound_index <= 4'd4;
                            status[3] <= 1'b1;
                        end
                        4'd5: nmi_enabled <= 1'b0;
                        4'd6: nmi_enabled <= 1'b1;
                        default: begin end
                    endcase
                end else begin
                    // The Z80 samples its read data several system clocks
                    // after the access edge. Register the pre-increment
                    // nibble, matching the original TC0140SYT/F2 behavior,
                    // so it remains stable for the full bus cycle.
                    case (sound_index)
                        4'd0: begin
                            sound_dout <= to_sound[3:0];
                            sound_index <= 4'd1;
                        end
                        4'd1: begin
                            sound_dout <= to_sound[7:4];
                            sound_index <= 4'd2;
                            status[0] <= 1'b0;
                        end
                        4'd2: begin
                            sound_dout <= to_sound[11:8];
                            sound_index <= 4'd3;
                        end
                        4'd3: begin
                            sound_dout <= to_sound[15:12];
                            sound_index <= 4'd4;
                            status[1] <= 1'b0;
                        end
                        4'd4: sound_dout <= status;
                        default: sound_dout <= 4'hf;
                    endcase
                end
            end
        end
    end
end

endmodule
