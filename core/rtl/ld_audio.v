// Disc audio for the RGB path: each frame's ld-decode PCM block, played while its picture is on screen.
//
// ld_stream writes a frame's audio block (word 0 = sample count, then two 16-bit stereo samples per word,
// tbc2dscv.c) into the bank of the frame buffer it decoded into. When that picture goes up (new_pic) with sound
// on, the block's samples are queued. The queue is played at 44.1 kHz, made exactly from clk_sys
// (4 x 4fsc = 70.9379 MHz; 44100 / 70937900 by a remainder accumulator). That gives exactly 1764 samples per
// 25 Hz frame, which is what ld-decode records for every PAL frame of the capture (881 + 883 per field).
//
// Output starts after a cushion of CUSHION samples, so a frame's samples are queued before the previous
// frame's run out. Pushes land at the frame boundary while output runs continuously; this is the
// display-timing bridge between per-frame blocks and a constant-rate DAC.
//
// Sound is muted outside normal play: PAUSE "the sound and/or video image disappears" (OM p.50), SCAN on LD
// "Others: Sound is muted" (p.56), still frame / frame advance "sound is muted" (p.68). sound_on comes from the
// player state; when it drops the queue is emptied at once and the output is silent.
module ld_audio (
	input             clk,
	input             reset,

	input             aud_we,
	input      [11:0] aud_waddr,
	input      [63:0] aud_wdata,

	input             new_pic,
	input       [1:0] pic_buf,
	input             sound_on,
	input       [1:0] chan,          // AUDIO D/A: 0 stereo, 1 L channel on both outputs, 2 R channel on both

	output reg [15:0] l,
	output reg [15:0] r
);

localparam [26:0] F_CLK = 27'd70937900, F_AUD = 27'd44100;
localparam [11:0] CUSHION = 12'd64;

// ------------------------------------------------------------------ banks (3 x 1024 words)
reg [63:0] bank [0:3071];
reg [11:0] b_ra;
reg [63:0] b_q;
always @(posedge clk) begin
	if (aud_we && aud_waddr[11:10] != 2'd3) bank[aud_waddr] <= aud_wdata;
	b_q <= bank[b_ra];
end

// ------------------------------------------------------------------ sample queue (4096 x {R, L})
reg [31:0] q [0:4095];
reg [11:0] q_wp, q_rp;
reg [12:0] q_n;
reg        q_push, q_pop;
reg [31:0] q_din;
reg [31:0] q_dout;
always @(posedge clk) begin
	if (q_push && q_n != 13'd4096) q[q_wp] <= q_din;
	q_dout <= q[q_rp];
end

// ------------------------------------------------------------------ block -> queue
localparam T_IDLE = 2'd0, T_CNT = 2'd1, T_WORD = 2'd2, T_HI = 2'd3;
reg  [1:0] ts;
reg  [1:0] tb;
reg  [9:0] tw;             // word being read
reg [11:0] tn;             // samples left
reg        twait;          // the RAM read is in flight

// ------------------------------------------------------------------ 44.1 kHz
reg [26:0] acc;
reg        tick;
reg        playing;
reg [11:0] cush;

always @(posedge clk) begin
	q_push <= 1'b0;
	tick <= 1'b0;
	if (acc + F_AUD >= F_CLK) begin acc <= acc + F_AUD - F_CLK; tick <= 1'b1; end
	else acc <= acc + F_AUD;

	// queue bookkeeping (push from the transfer, pop at the tick)
	q_pop = tick && playing && q_n != 13'd0;
	if (q_push && q_n != 13'd4096) q_wp <= q_wp + 12'd1;
	if (q_pop) q_rp <= q_rp + 12'd1;
	q_n <= q_n + ((q_push && q_n != 13'd4096) ? 13'd1 : 13'd0) - (q_pop ? 13'd1 : 13'd0);

	// transfer: count word, then each word's low sample and high sample
	twait <= 1'b0;
	case (ts)
	T_IDLE:
		if (new_pic && sound_on) begin tb <= pic_buf; b_ra <= {pic_buf, 10'd0}; twait <= 1'b1; ts <= T_CNT; end
	T_CNT:
		if (!twait) begin
			tn <= b_q[11:0] > 12'd2046 ? 12'd2046 : b_q[11:0];
			tw <= 10'd1;
			b_ra <= {tb, 10'd1};
			twait <= 1'b1;
			ts <= (b_q[11:0] == 12'd0) ? T_IDLE : T_WORD;
		end
	T_WORD:
		if (!twait) begin
			q_push <= 1'b1; q_din <= b_q[31:0];
			tn <= tn - 12'd1;
			ts <= (tn == 12'd1) ? T_IDLE : T_HI;
		end
	T_HI: begin
		q_push <= 1'b1; q_din <= b_q[63:32];
		tn <= tn - 12'd1;
		tw <= tw + 10'd1;
		b_ra <= {tb, tw + 10'd1};
		twait <= 1'b1;
		ts <= (tn == 12'd1) ? T_IDLE : T_WORD;
	end
	endcase

	// output: start once the cushion has built up, stop (silence) if the queue runs dry
	if (tick) begin
		if (playing && q_n != 13'd0) begin
			// q_dout holds q[q_rp] (read in the clocks since q_rp last moved)
			l <= (chan == 2'd2) ? q_dout[31:16] : q_dout[15:0];
			r <= (chan == 2'd1) ? q_dout[15:0]  : q_dout[31:16];
		end else begin
			l <= 16'd0; r <= 16'd0;
			if (playing) playing <= 1'b0;
		end
		if (!playing && q_n != 13'd0) begin
			if (cush == CUSHION) playing <= 1'b1;
			else cush <= cush + 12'd1;
		end
		if (q_n == 13'd0) cush <= 12'd0;
	end

	if (!sound_on || reset) begin
		// muted: silence now, queue emptied
		playing <= 1'b0; cush <= 12'd0;
		l <= 16'd0; r <= 16'd0;
		q_rp <= q_wp; q_n <= 13'd0;
		if (ts != T_IDLE && !(new_pic && sound_on)) ts <= T_IDLE;
	end
end

initial begin
	ts = T_IDLE; acc = 27'd0; playing = 1'b0; cush = 12'd0; q_push = 1'b0; tick = 1'b0; twait = 1'b0;
	q_wp = 12'd0; q_rp = 12'd0; q_n = 13'd0; l = 16'd0; r = 16'd0;
end

endmodule
