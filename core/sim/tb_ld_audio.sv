`timescale 1ns/1ps
// ld_audio over 30 real frames of ld-decode PCM (gen: Community North frames 1660-1689, the fade into a quiet
// stretch), new_pic every 40 ms exactly as at 25 Hz: every sample must come out once, in order, with no gap.
module tb_ld_audio;
reg clk = 0;
always #7.04842 clk = ~clk;                  // 70.9379 MHz
localparam NF = 30, FRAME_CLK = 2837516;     // 70937900 / 25
reg [63:0] blk [0:NF*1024-1];
reg we = 0; reg [11:0] wa; reg [63:0] wd;
reg new_pic = 0; reg [1:0] pb = 0;
wire [15:0] l, r;
ld_audio dut (.clk(clk), .reset(1'b0), .aud_we(we), .aud_waddr(wa), .aud_wdata(wd),
              .new_pic(new_pic), .pic_buf(pb), .sound_on(1'b1), .chan(2'd0), .l(l), .r(r));
reg [31:0] got [0:NF*1764+100];
int n = 0, gaps = 0, errors = 0;
reg tick_d = 0, play_d = 0, started = 0;
always @(posedge clk) begin
	tick_d <= dut.tick;
	if (dut.tick) play_d <= dut.playing && dut.q_n != 0;
	if (tick_d) begin
		if (play_d) begin got[n] = {r, l}; n++; started = 1; end
		else if (started && n < NF * 1764) gaps++;
	end
end
initial begin
	$readmemh("dscv/aud_frames.hex", blk);
	for (int f = 0; f < NF; f++) begin
		// the frame's block goes into bank f % 3 during the frame before, as ld_stream does
		for (int i = 0; i < 1024; i++) begin
			@(posedge clk) begin we <= 1; wa <= {f % 3 == 0 ? 2'd0 : f % 3 == 1 ? 2'd1 : 2'd2, i[9:0]}; wd <= blk[f * 1024 + i]; end
		end
		@(posedge clk) we <= 0;
		repeat (FRAME_CLK - 1026) @(posedge clk);
		@(posedge clk) begin new_pic <= 1; pb <= f % 3; end
		@(posedge clk) new_pic <= 0;
	end
	repeat (FRAME_CLK + 200000) @(posedge clk);   // the last frame, the 64-sample cushion, then silence
	for (int i = 0; i < NF * 1764 && i < n; i++)
		if (got[i] !== (i[0] ? blk[(i / 1764) * 1024 + 1 + (i % 1764) / 2][63:32] : blk[(i / 1764) * 1024 + 1 + (i % 1764) / 2][31:0])) begin
			if (errors < 5) $display("sample %0d: %h", i, got[i]);
			errors++;
		end
	$display("%0d samples out of %0d, %0d gaps after the start, %0d wrong; queue left %0d, output now %h %h, playing %0d",
	         n, NF * 1764, gaps, errors, dut.q_n, l, r, dut.playing);
	if (n == NF * 1764 && gaps == 0 && errors == 0 && l == 0 && r == 0 && !dut.playing) $display("PASS"); else $display("FAIL");
	$finish;
end
endmodule
