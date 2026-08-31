`timescale 1ns/1ps

module tb_tc0140syt;
reg clk = 0;
always #5 clk = ~clk;

reg reset = 1;
reg main_cs = 0;
reg main_wr = 0;
reg main_port = 0;
reg [3:0] main_din = 0;
wire [3:0] main_dout;
reg sound_cs = 0;
reg sound_wr = 0;
reg sound_port = 0;
reg [3:0] sound_din = 0;
wire [3:0] sound_dout;
wire sound_reset_n;
wire sound_nmi_n;
wire [3:0] status;

tas_tc0140syt dut (
    .clk(clk), .reset(reset),
    .main_cs(main_cs), .main_wr(main_wr), .main_port(main_port),
    .main_din(main_din), .main_dout(main_dout),
    .sound_cs(sound_cs), .sound_wr(sound_wr), .sound_port(sound_port),
    .sound_din(sound_din), .sound_dout(sound_dout),
    .sound_reset_n(sound_reset_n), .sound_nmi_n(sound_nmi_n),
    .status(status)
);

task main_write(input port, input [3:0] value);
begin
    @(negedge clk);
    main_port = port;
    main_din = value;
    main_wr = 1;
    main_cs = 1;
    @(negedge clk);
    main_cs = 0;
end
endtask

task sound_write(input port, input [3:0] value);
begin
    @(negedge clk);
    sound_port = port;
    sound_din = value;
    sound_wr = 1;
    sound_cs = 1;
    @(negedge clk);
    sound_cs = 0;
end
endtask

// TV80 samples read data at T2, several system clocks after the TC0140SYT
// access edge. The pre-increment nibble must remain stable until then.
task sound_read_delayed(input [3:0] expected);
begin
    @(negedge clk);
    sound_port = 1;
    sound_wr = 0;
    sound_cs = 1;
    @(negedge clk);
    sound_cs = 0;
    repeat (8) @(negedge clk);
    if (sound_dout !== expected)
        $fatal(1, "delayed sound read got %h expected %h", sound_dout,
               expected);
end
endtask

task main_read(input [3:0] expected);
begin
    @(negedge clk);
    main_port = 1;
    main_wr = 0;
    main_cs = 1;
    #1;
    if (main_dout !== expected)
        $fatal(1, "main read got %h expected %h", main_dout, expected);
    @(negedge clk);
    main_cs = 0;
end
endtask

initial begin
    repeat (4) @(negedge clk);
    reset = 0;

    main_write(0, 4);
    main_write(1, 1);
    if (sound_reset_n) $fatal(1, "sound reset was not asserted");
    main_write(0, 4);
    main_write(1, 0);
    if (!sound_reset_n) $fatal(1, "sound reset was not released");

    // Post byte EC in mailbox 0/1 and verify the optional NMI doorbell plus
    // the registered read data at TV80-realistic sampling latency.
    sound_write(0, 6);
    sound_write(1, 0);
    main_write(0, 0);
    main_write(1, 4'hc);
    main_write(1, 4'he);
    if (status[0] !== 1'b1 || sound_nmi_n !== 1'b0)
        $fatal(1, "posted command did not assert NMI, status=%h nmi_n=%b",
               status, sound_nmi_n);
    sound_write(0, 0);
    sound_read_delayed(4'hc);
    sound_read_delayed(4'he);
    if (status[0] !== 1'b0 || sound_nmi_n !== 1'b1)
        $fatal(1, "command consume did not clear NMI, status=%h nmi_n=%b",
               status, sound_nmi_n);

    // Mode 5 releases NMI without consuming a pending command.
    main_write(0, 0);
    main_write(1, 4'h5);
    main_write(1, 4'ha);
    if (sound_nmi_n !== 1'b0) $fatal(1, "second command missed NMI");
    sound_write(0, 5);
    sound_write(1, 0);
    if (sound_nmi_n !== 1'b1 || status[0] !== 1'b1)
        $fatal(1, "mode 5 did not disable NMI independently of status");
    sound_write(0, 0);
    sound_read_delayed(4'h5);
    sound_read_delayed(4'ha);

    // Check the reverse two-nibble mailbox and its main-side status clear.
    sound_write(0, 0);
    sound_write(1, 4'ha);
    sound_write(1, 4'hb);
    if (status[2] !== 1'b1)
        $fatal(1, "sound-to-main message was not posted");
    main_write(0, 0);
    main_read(4'ha);
    main_read(4'hb);
    if (status[2] !== 1'b0)
        $fatal(1, "main did not consume reverse mailbox, status=%h", status);

    $display("PASS tb_tc0140syt");
    $finish;
end
endmodule
