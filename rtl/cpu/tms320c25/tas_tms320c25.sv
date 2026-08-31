// Instruction-level TMS320C25 implementation for the Taito Air System DSP.
//
// This is deliberately an architectural core rather than a pin/cycle replica:
// each program or data transfer may consume several clk cycles, but instruction
// results, addressing side effects and repeat sequencing follow the C2x user
// guide.  The interface is kept small so instruction semantics can be tested
// independently of the arcade-board memory map.
module tas_tms320c25 (
    input               clk,
    input               reset,
    input               hold,

    output     [11:0]   prog_addr,
    input      [15:0]   prog_data,

    output reg          data_req,
    output reg          data_we,
    output reg [15:0]   data_addr,
    output reg [15:0]   data_wdata,
    input               data_ack,
    input      [15:0]   data_rdata,

    output reg [15:0]   debug_pc,
    output reg [15:0]   debug_ir,
    output reg [31:0]   debug_instructions,
    output reg [15:0]   debug_illegal,
    output reg          debug_write
);

localparam ST_FETCH_REQ  = 4'd0;
localparam ST_FETCH      = 4'd1;
localparam ST_DECODE     = 4'd2;
localparam ST_IMM_REQ    = 4'd3;
localparam ST_IMM        = 4'd4;
localparam ST_DATA       = 4'd5;
localparam ST_BLKD_GAP   = 4'd6;
localparam ST_BLKD_WRITE = 4'd7;
localparam ST_LTD_WRITE  = 4'd8;

localparam IK_NONE       = 4'd0;
localparam IK_LRLK       = 4'd1;
localparam IK_LALK       = 4'd2;
localparam IK_ADLK       = 4'd3;
localparam IK_SBLK       = 4'd4;
localparam IK_ANDK       = 4'd5;
localparam IK_ORK        = 4'd6;
localparam IK_XORK       = 4'd7;
localparam IK_BRANCH     = 4'd8;
localparam IK_CALL       = 4'd9;
localparam IK_BLKD       = 4'd10;

reg [3:0] state;
reg [3:0] imm_kind;
reg [15:0] pc;
reg [15:0] ir;
reg [15:0] ir_pc;
reg [31:0] acc;
reg [31:0] preg;
reg [15:0] treg;
reg [15:0] ar [0:7];
reg [15:0] stack [0:7];
reg [2:0] arp;
reg [2:0] arb;
reg [8:0] dp;
reg ov;
reg ovm;
reg intm;
reg sxm;
reg carry;
reg tc;
reg [1:0] pm;
reg [7:0] rptc;
reg repeat_active;
reg [15:0] repeat_addr;
reg [15:0] pfc;
reg blkd_pfc_valid;
reg [15:0] blkd_data;
integer i;

assign prog_addr = pc[11:0];

function automatic [15:0] effective_address(input [7:0] low);
begin
    effective_address = low[7] ? ar[arp] : {dp, low[6:0]};
end
endfunction

function automatic [31:0] memory_operand(
    input [15:0] word,
    input [3:0] shift
);
reg [31:0] extended;
begin
    extended = sxm ? {{16{word[15]}}, word} : {16'd0, word};
    memory_operand = extended << shift;
end
endfunction

function automatic [31:0] shifted_product;
begin
    case (pm)
        2'd0: shifted_product = preg;
        2'd1: shifted_product = preg << 1;
        2'd2: shifted_product = preg << 4;
        default: shifted_product = $signed(preg) >>> 6;
    endcase
end
endfunction

function automatic [15:0] reverse_carry_add(
    input [15:0] left,
    input [15:0] right
);
reg carry_bit;
reg [1:0] bit_sum;
integer bit_index;
begin
    reverse_carry_add = 16'd0;
    carry_bit = 1'b0;
    for (bit_index = 15; bit_index >= 0; bit_index = bit_index - 1) begin
        bit_sum = left[bit_index] + right[bit_index] + carry_bit;
        reverse_carry_add[bit_index] = bit_sum[0];
        carry_bit = bit_sum[1];
    end
end
endfunction

task automatic push_stack(input [15:0] value);
integer s;
begin
    for (s = 0; s < 7; s = s + 1)
        stack[s] <= stack[s + 1];
    stack[7] <= value;
end
endtask

task automatic pop_stack;
integer s;
begin
    pc <= stack[7];
    for (s = 7; s > 0; s = s - 1)
        stack[s] <= stack[s - 1];
end
endtask

task automatic modify_indirect(input [7:0] low);
reg [15:0] next_ar;
begin
    next_ar = ar[arp];
    case (low[6:4])
        3'b001: next_ar = ar[arp] - 1'd1;
        3'b010: next_ar = ar[arp] + 1'd1;
        3'b100: begin
            next_ar = reverse_carry_add(ar[arp], -ar[0]);
        end
        3'b101: next_ar = ar[arp] - ar[0];
        3'b110: next_ar = ar[arp] + ar[0];
        3'b111: begin
            // Reverse-carry addition propagates from MSB toward LSB.
            next_ar = reverse_carry_add(ar[arp], ar[0]);
        end
        default: begin end
    endcase
    ar[arp] <= next_ar;
    if (low[3]) begin
        arb <= arp;
        arp <= low[2:0];
    end
end
endtask

task automatic finish_instruction;
begin
    data_req <= 1'b0;
    debug_instructions <= debug_instructions + 1'd1;
    if (repeat_active && ir_pc == repeat_addr) begin
        if (rptc != 0) begin
            rptc <= rptc - 1'd1;
            pc <= repeat_addr;
        end else begin
            repeat_active <= 1'b0;
            blkd_pfc_valid <= 1'b0;
        end
    end
    state <= ST_FETCH_REQ;
end
endtask

task automatic add_to_acc(input [31:0] value);
reg [31:0] old_value;
reg [31:0] result;
begin
    old_value = acc;
    result = old_value + value;
    carry <= (old_value > result);
    if ((~(old_value[31] ^ value[31])) && (result[31] ^ old_value[31])) begin
        ov <= 1'b1;
        if (ovm) result = old_value[31] ? 32'h80000000 : 32'h7fffffff;
    end
    acc <= result;
end
endtask

task automatic sub_from_acc(input [31:0] value);
reg [31:0] old_value;
reg [31:0] result;
begin
    old_value = acc;
    result = old_value - value;
    carry <= (old_value >= value);
    if ((old_value[31] ^ value[31]) && (result[31] ^ old_value[31])) begin
        ov <= 1'b1;
        if (ovm) result = old_value[31] ? 32'h80000000 : 32'h7fffffff;
    end
    acc <= result;
end
endtask

task automatic start_read;
begin
    data_addr <= effective_address(ir[7:0]);
    data_we <= 1'b0;
    data_req <= 1'b1;
    state <= ST_DATA;
end
endtask

task automatic start_write(input [15:0] value);
begin
    data_addr <= effective_address(ir[7:0]);
    data_wdata <= value;
    data_we <= 1'b1;
    data_req <= 1'b1;
    debug_write <= 1'b1;
    state <= ST_DATA;
end
endtask

task automatic request_immediate(input [3:0] kind);
begin
    imm_kind <= kind;
    state <= ST_IMM_REQ;
end
endtask

always @(posedge clk) begin
    debug_write <= 1'b0;

    if (reset) begin
        state <= ST_FETCH_REQ;
        imm_kind <= IK_NONE;
        pc <= 16'd0;
        ir <= 16'd0;
        ir_pc <= 16'd0;
        acc <= 32'd0;
        preg <= 32'd0;
        treg <= 16'd0;
        arp <= 3'd0;
        arb <= 3'd0;
        dp <= 9'd0;
        ov <= 1'b0;
        ovm <= 1'b0;
        intm <= 1'b1;
        sxm <= 1'b1;
        carry <= 1'b1;
        tc <= 1'b0;
        pm <= 2'd0;
        rptc <= 8'd0;
        repeat_active <= 1'b0;
        repeat_addr <= 16'd0;
        pfc <= 16'd0;
        blkd_pfc_valid <= 1'b0;
        blkd_data <= 16'd0;
        data_req <= 1'b0;
        data_we <= 1'b0;
        data_addr <= 16'd0;
        data_wdata <= 16'd0;
        debug_pc <= 16'd0;
        debug_ir <= 16'd0;
        debug_instructions <= 32'd0;
        debug_illegal <= 16'd0;
        for (i = 0; i < 8; i = i + 1) begin
            ar[i] <= 16'd0;
            stack[i] <= 16'd0;
        end
    end else if (!hold || data_req) begin
        case (state)
            ST_FETCH_REQ: state <= ST_FETCH;

            ST_FETCH: begin
                ir <= prog_data;
                ir_pc <= pc;
                debug_pc <= pc;
                debug_ir <= prog_data;
                pc <= pc + 1'd1;
                state <= ST_DECODE;
            end

            ST_DECODE: begin
                casez (ir[15:8])
                    8'h0?: start_read(); // ADD
                    8'h1?: start_read(); // SUB
                    8'h2?: start_read(); // LAC
                    8'h30,8'h31,8'h32,8'h33,
                    8'h34,8'h35,8'h36,8'h37: start_read(); // LAR
                    8'h38,8'h39,8'h3c,8'h3d,8'h3e,8'h3f: start_read();
                    8'h40,8'h44,8'h45,8'h47,8'h48,
                    8'h4c,8'h4d,8'h4e: start_read();

                    8'h55: begin // MAR, including LARP and NOP
                        if (ir[7]) modify_indirect(ir[7:0]);
                        finish_instruction();
                    end

                    8'h5b: start_read(); // LTS

                    8'h60,8'h61,8'h62,8'h63,
                    8'h64,8'h65,8'h66,8'h67:
                        start_write(acc << ir[10:8]);
                    8'h68,8'h69,8'h6a,8'h6b,
                    8'h6c,8'h6d,8'h6e,8'h6f:
                        start_write((acc << ir[10:8]) >> 16);
                    8'h70,8'h71,8'h72,8'h73,
                    8'h74,8'h75,8'h76,8'h77:
                        start_write(ar[ir[10:8]]);

                    8'h90,8'h91,8'h92,8'h93,
                    8'h94,8'h95,8'h96,8'h97,
                    8'h98,8'h99,8'h9a,8'h9b,
                    8'h9c,8'h9d,8'h9e,8'h9f: start_read();

                    8'hc0,8'hc1,8'hc2,8'hc3,
                    8'hc4,8'hc5,8'hc6,8'hc7: begin
                        ar[ir[10:8]] <= {8'd0, ir[7:0]};
                        finish_instruction();
                    end
                    8'hc8,8'hc9: begin
                        dp <= ir[8:0];
                        finish_instruction();
                    end
                    8'hca: begin
                        acc <= {24'd0, ir[7:0]};
                        finish_instruction();
                    end
                    8'hcb: begin
                        rptc <= ir[7:0];
                        repeat_addr <= pc;
                        repeat_active <= 1'b1;
                        blkd_pfc_valid <= 1'b0;
                        finish_instruction();
                    end

                    8'hce: begin
                        case (ir[7:0])
                            8'h01: begin intm <= 1'b1; finish_instruction(); end
                            8'h02: begin ovm <= 1'b0; finish_instruction(); end
                            8'h03: begin ovm <= 1'b1; finish_instruction(); end
                            8'h04: finish_instruction(); // CNFD: B0 is data RAM
                            8'h06: begin sxm <= 1'b0; finish_instruction(); end
                            8'h07: begin sxm <= 1'b1; finish_instruction(); end
                            8'h08,8'h09,8'h0a,8'h0b: begin
                                pm <= ir[1:0]; finish_instruction();
                            end
                            8'h14: begin acc <= shifted_product(); finish_instruction(); end
                            8'h15: begin add_to_acc(shifted_product()); finish_instruction(); end
                            8'h16: begin sub_from_acc(shifted_product()); finish_instruction(); end
                            8'h18: begin carry <= acc[31]; acc <= acc << 1; finish_instruction(); end
                            8'h1b: begin
                                if (acc[31]) begin
                                    if (acc == 32'h80000000) begin
                                        ov <= 1'b1;
                                        acc <= ovm ? 32'h7fffffff : acc;
                                    end else acc <= -$signed(acc);
                                end
                                carry <= 1'b0;
                                finish_instruction();
                            end
                            8'h1d: begin // POP into low accumulator
                                acc <= {16'd0, stack[7]};
                                for (i = 7; i > 0; i = i - 1) stack[i] <= stack[i-1];
                                finish_instruction();
                            end
                            8'h1e: begin push_stack(pc); pc <= 16'h001e; finish_instruction(); end
                            8'h23: begin
                                if (acc == 32'h80000000) begin
                                    ov <= 1'b1;
                                    acc <= ovm ? 32'h7fffffff : acc;
                                end else acc <= -$signed(acc);
                                carry <= (acc == 0);
                                finish_instruction();
                            end
                            8'h25: begin pc <= acc[15:0]; finish_instruction(); end
                            8'h26: begin pop_stack(); finish_instruction(); end
                            8'h27: begin acc <= ~acc; finish_instruction(); end
                            8'h50,8'h51,8'h52,8'h53: begin
                                case (ir[1:0])
                                    2'd0: tc <= (ar[arp] == ar[0]);
                                    2'd1: tc <= (ar[arp] < ar[0]);
                                    2'd2: tc <= (ar[arp] > ar[0]);
                                    default: tc <= (ar[arp] != ar[0]);
                                endcase
                                finish_instruction();
                            end
                            default: begin
                                debug_illegal <= debug_illegal + 1'd1;
                                finish_instruction();
                            end
                        endcase
                    end

                    // Long-immediate operations share Dxxx. Bits 2:0 select
                    // the operation; bits 10:8 select AR or the shift count.
                    8'hd?: begin
                        case (ir[2:0])
                            3'd0: request_immediate(IK_LRLK);
                            3'd1: request_immediate(IK_LALK);
                            3'd2: request_immediate(IK_ADLK);
                            3'd3: request_immediate(IK_SBLK);
                            3'd4: request_immediate(IK_ANDK);
                            3'd5: request_immediate(IK_ORK);
                            3'd6: request_immediate(IK_XORK);
                            default: begin
                                debug_illegal <= debug_illegal + 1'd1;
                                finish_instruction();
                            end
                        endcase
                    end

                    8'hf0,8'hf1,8'hf2,8'hf3,
                    8'hf4,8'hf5,8'hf6,8'hf7,
                    8'hf8,8'hf9,8'hfa,8'hfb,
                    8'hff: request_immediate(IK_BRANCH);
                    8'hfd: begin
                        if (repeat_active && ir_pc == repeat_addr && blkd_pfc_valid) begin
                            pc <= pc + 1'd1; // repeated BLKD skips its operand word
                            data_addr <= pfc;
                            data_we <= 1'b0;
                            data_req <= 1'b1;
                            state <= ST_DATA;
                        end else request_immediate(IK_BLKD);
                    end
                    8'hfe: request_immediate(IK_CALL);

                    default: begin
                        debug_illegal <= debug_illegal + 1'd1;
                        finish_instruction();
                    end
                endcase
            end

            ST_IMM_REQ: state <= ST_IMM;

            ST_IMM: begin
                pc <= pc + 1'd1;
                case (imm_kind)
                    IK_LRLK: begin
                        ar[ir[10:8]] <= prog_data;
                        finish_instruction();
                    end
                    IK_LALK: begin
                        acc <= (sxm ? {{16{prog_data[15]}}, prog_data} :
                                      {16'd0, prog_data}) << ir[11:8];
                        finish_instruction();
                    end
                    IK_ADLK: begin
                        add_to_acc((sxm ? {{16{prog_data[15]}}, prog_data} :
                                          {16'd0, prog_data}) << ir[11:8]);
                        finish_instruction();
                    end
                    IK_SBLK: begin
                        sub_from_acc((sxm ? {{16{prog_data[15]}}, prog_data} :
                                            {16'd0, prog_data}) << ir[11:8]);
                        finish_instruction();
                    end
                    IK_ANDK: begin acc <= acc & ({16'd0,prog_data} << ir[11:8]); finish_instruction(); end
                    IK_ORK:  begin acc <= acc | ({16'd0,prog_data} << ir[11:8]); finish_instruction(); end
                    IK_XORK: begin acc <= acc ^ ({16'd0,prog_data} << ir[11:8]); finish_instruction(); end
                    IK_CALL: begin
                        push_stack(pc + 1'd1);
                        pc <= prog_data;
                        if (ir[7]) modify_indirect(ir[7:0]);
                        finish_instruction();
                    end
                    IK_BRANCH: begin
                        case (ir[15:8])
                            8'hf0: if (ov) begin pc <= prog_data; ov <= 1'b0; end
                            8'hf1: if ($signed(acc) > 0) pc <= prog_data;
                            8'hf2: if ($signed(acc) <= 0) pc <= prog_data;
                            8'hf3: if ($signed(acc) < 0) pc <= prog_data;
                            8'hf4: if ($signed(acc) >= 0) pc <= prog_data;
                            8'hf5: if (acc != 0) pc <= prog_data;
                            8'hf6: if (acc == 0) pc <= prog_data;
                            8'hf7: if (!ov) pc <= prog_data; else ov <= 1'b0;
                            8'hf8: if (!tc) pc <= prog_data;
                            8'hf9: if (tc) pc <= prog_data;
                            // BIO is not connected by the Taito Air wrapper
                            // and is held inactive-high. BIOZ branches only
                            // when the active-low pin is asserted, so it
                            // falls through here after consuming its operand.
                            8'hfa: begin end
                            8'hfb: if (ar[arp] != 0) pc <= prog_data;
                            8'hff: pc <= prog_data;
                            default: begin end
                        endcase
                        if (ir[7]) modify_indirect(ir[7:0]);
                        finish_instruction();
                    end
                    IK_BLKD: begin
                        pfc <= prog_data;
                        blkd_pfc_valid <= 1'b1;
                        data_addr <= prog_data;
                        data_we <= 1'b0;
                        data_req <= 1'b1;
                        state <= ST_DATA;
                    end
                    default: finish_instruction();
                endcase
            end

            ST_DATA: if (data_ack) begin
                data_req <= 1'b0;
                if (ir[15:8] == 8'hfd) begin
                    // BLKD is a read followed by a write to the instruction's
                    // direct/indirect destination. Preserve PFC across RPT.
                    if (!data_we) begin
                        blkd_data <= data_rdata;
                        state <= ST_BLKD_GAP;
                    end else begin
                        pfc <= pfc + 1'd1;
                        if (ir[7]) modify_indirect(ir[7:0]);
                        finish_instruction();
                    end
                end else if (data_we) begin
                    if (ir[7]) modify_indirect(ir[7:0]);
                    finish_instruction();
                end else begin
                    casez (ir[15:8])
                        8'h0?: add_to_acc(memory_operand(data_rdata, ir[11:8]));
                        8'h1?: sub_from_acc(memory_operand(data_rdata, ir[11:8]));
                        8'h2?: acc <= memory_operand(data_rdata, ir[11:8]);
                        8'h30,8'h31,8'h32,8'h33,
                        8'h34,8'h35,8'h36,8'h37: ar[ir[10:8]] <= data_rdata;
                        8'h38: preg <= $signed(data_rdata) * $signed(treg);
                        8'h39: begin
                            add_to_acc(shifted_product());
                            treg <= data_rdata;
                            preg <= $signed(data_rdata) * $signed(data_rdata);
                        end
                        8'h3c: treg <= data_rdata;
                        8'h3d: begin treg <= data_rdata; add_to_acc(shifted_product()); end
                        8'h3e: begin treg <= data_rdata; acc <= shifted_product(); end
                        8'h3f: begin
                            // LTD combines LTA with DMOV: copy the source
                            // word to the following address only when the
                            // source is in on-chip RAM. The wrapper models
                            // its local C25 RAM at 0000-03ff; board RAM starts
                            // at 0400 and must not receive DMOV writes.
                            treg <= data_rdata;
                            add_to_acc(shifted_product());
                            if (data_addr < 16'h0400) begin
                                data_addr <= data_addr + 1'd1;
                                data_wdata <= data_rdata;
                                data_we <= 1'b1;
                                data_req <= 1'b1;
                                debug_write <= 1'b1;
                                state <= ST_LTD_WRITE;
                            end else begin
                                if (ir[7]) modify_indirect(ir[7:0]);
                                finish_instruction();
                            end
                        end
                        8'h40: acc <= {data_rdata,16'd0};
                        8'h44: begin
                            acc[31:16] <= acc[31:16] - data_rdata;
                            if (acc[31:16] < data_rdata) carry <= 1'b0;
                        end
                        8'h45: sub_from_acc({16'd0,data_rdata});
                        8'h47: begin
                            if (acc >= memory_operand(data_rdata,4'd15))
                                acc <= ((acc - memory_operand(data_rdata,4'd15)) << 1) | 1'd1;
                            else acc <= acc << 1;
                            carry <= (acc >= memory_operand(data_rdata,4'd15));
                        end
                        8'h48: begin
                            acc[31:16] <= acc[31:16] + data_rdata;
                            if ((acc[31:16] + data_rdata) < acc[31:16]) carry <= 1'b1;
                        end
                        8'h4c: acc[15:0] <= acc[15:0] ^ data_rdata;
                        8'h4d: acc[15:0] <= acc[15:0] | data_rdata;
                        8'h4e: acc <= acc & {16'd0,data_rdata};
                        8'h5b: begin treg <= data_rdata; sub_from_acc(shifted_product()); end
                        8'h90,8'h91,8'h92,8'h93,
                        8'h94,8'h95,8'h96,8'h97,
                        8'h98,8'h99,8'h9a,8'h9b,
                        8'h9c,8'h9d,8'h9e,8'h9f:
                            tc <= |(data_rdata & (16'h8000 >> ir[11:8]));
                        default: begin end
                    endcase
                    if (ir[15:8] != 8'h3f) begin
                        if (ir[7]) modify_indirect(ir[7:0]);
                        finish_instruction();
                    end
                end
            end

            ST_LTD_WRITE: if (data_ack) begin
                data_req <= 1'b0;
                if (ir[7]) modify_indirect(ir[7:0]);
                finish_instruction();
            end

            ST_BLKD_GAP: begin
                data_addr <= effective_address(ir[7:0]);
                data_wdata <= blkd_data;
                data_we <= 1'b1;
                data_req <= 1'b1;
                debug_write <= 1'b1;
                state <= ST_BLKD_WRITE;
            end

            ST_BLKD_WRITE: if (data_ack) begin
                data_req <= 1'b0;
                pfc <= pfc + 1'd1;
                if (ir[7]) modify_indirect(ir[7:0]);
                finish_instruction();
            end

            default: state <= ST_FETCH_REQ;
        endcase
    end
end

endmodule
