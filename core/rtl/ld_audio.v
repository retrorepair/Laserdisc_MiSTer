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
	input      [12:0] aud_waddr,     // {frame buffer, block (0 analogue, 1 digital), word}
	input      [63:0] aud_wdata,

	input             new_pic,
	input       [1:0] pic_buf,
	input             sound_on,
	input       [1:0] chan,          // AUDIO D/A: 0 stereo, 1 L channel on both outputs, 2 R channel on both
	input             src,           // AUDIO D/A: 0 the analogue soundtrack, 1 the digital (EFM) one
	input             ntsc,          // clk_sys is 57.272727 MHz (630 MHz / 11) instead of 70.9379 MHz
	input       [4:0] dlc,           // DIGITAL LEVEL CONTROL: the digital sound down by 0-25 dB (European OM p.12)

	output reg [15:0] l,
	output reg [15:0] r
);

// 44.1 kHz exactly from clk_sys: PAL 44100 / 70937900; NTSC 44100 x 11 / 630000000 (clk_sys = 630 MHz / 11)
wire [29:0] F_CLK = ntsc ? 30'd630000000 : 30'd70937900;
wire [29:0] F_AUD = ntsc ? 30'd485100 : 30'd44100;
localparam [11:0] CUSHION = 12'd64;

// DIGITAL LEVEL CONTROL gain, Q15, 1 dB steps (the step is EST: the OM gives the range 0 to -25 dB)
function [15:0] dlc_g(input [4:0] db);
	case (db)
		5'd0: dlc_g = 16'd32767;
		5'd1: dlc_g = 16'd29205;
		5'd2: dlc_g = 16'd26029;
		5'd3: dlc_g = 16'd23198;
		5'd4: dlc_g = 16'd20675;
		5'd5: dlc_g = 16'd18427;
		5'd6: dlc_g = 16'd16423;
		5'd7: dlc_g = 16'd14637;
		5'd8: dlc_g = 16'd13045;
		5'd9: dlc_g = 16'd11627;
		5'd10: dlc_g = 16'd10362;
		5'd11: dlc_g = 16'd9235;
		5'd12: dlc_g = 16'd8231;
		5'd13: dlc_g = 16'd7336;
		5'd14: dlc_g = 16'd6538;
		5'd15: dlc_g = 16'd5827;
		5'd16: dlc_g = 16'd5193;
		5'd17: dlc_g = 16'd4629;
		5'd18: dlc_g = 16'd4125;
		5'd19: dlc_g = 16'd3677;
		5'd20: dlc_g = 16'd3277;
		5'd21: dlc_g = 16'd2920;
		5'd22: dlc_g = 16'd2603;
		5'd23: dlc_g = 16'd2320;
		5'd24: dlc_g = 16'd2068;
		5'd25: dlc_g = 16'd1843;
		default: dlc_g = 16'd1842;
	endcase
endfunction

// ------------------------------------------------------------------ banks (3 frame buffers x 2 blocks x 1024 words)
reg [63:0] bank [0:6143];
reg [12:0] b_ra;
reg [63:0] b_q;
always @(posedge clk) begin
	if (aud_we && aud_waddr[12:11] != 2'd3) bank[aud_waddr] <= aud_wdata;
	b_q <= bank[b_ra];
end

// ------------------------------------------------------------------ sample queue (4096 x {R, L})
reg [31:0] q [0:4095];
reg [11:0] q_wp, q_rp;
reg [12:0] q_n;
reg        q_push, q_pop;
reg [31:0] q_din;
reg [31:0] q_dout;
wire signed [15:0] ch_l = (chan == 2'd2) ? q_dout[31:16] : q_dout[15:0];
wire signed [15:0] ch_r = (chan == 2'd1) ? q_dout[15:0]  : q_dout[31:16];
wire signed [31:0] dl_l = ch_l * $signed({1'b0, dlc_g(dlc)});
wire signed [31:0] dl_r = ch_r * $signed({1'b0, dlc_g(dlc)});
always @(posedge clk) begin
	if (q_push && q_n != 13'd4096) q[q_wp] <= q_din;
	q_dout <= q[q_rp];
end

// ------------------------------------------------------------------ block -> queue
localparam T_IDLE = 2'd0, T_CNT = 2'd1, T_WORD = 2'd2, T_HI = 2'd3;
reg  [1:0] ts;
reg  [1:0] tb;
reg        tsrc;           // the block being transferred
reg  [9:0] tw;             // word being read
reg [11:0] tn;             // samples left
reg        twait;          // the RAM read is in flight

// ------------------------------------------------------------------ 44.1 kHz
reg [29:0] acc;
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
		if (new_pic && sound_on) begin tb <= pic_buf; tsrc <= src; b_ra <= {pic_buf, src, 10'd0}; twait <= 1'b1; ts <= T_CNT; end
	T_CNT:
		if (!twait) begin
			tn <= b_q[11:0] > 12'd2046 ? 12'd2046 : b_q[11:0];
			tw <= 10'd1;
			b_ra <= {tb, tsrc, 10'd1};
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
		b_ra <= {tb, tsrc, tw + 10'd1};
		twait <= 1'b1;
		ts <= (tn == 12'd1) ? T_IDLE : T_WORD;
	end
	endcase

	// output: start once the cushion has built up, stop (silence) if the queue runs dry
	if (tick) begin
		if (playing && q_n != 13'd0) begin
			// q_dout holds q[q_rp] (read in the clocks since q_rp last moved); the digital sound at its level
			l <= (src && dlc != 5'd0) ? dl_l[30:15] : (chan == 2'd2) ? q_dout[31:16] : q_dout[15:0];
			r <= (src && dlc != 5'd0) ? dl_r[30:15] : (chan == 2'd1) ? q_dout[15:0]  : q_dout[31:16];
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
	ts = T_IDLE; acc = 30'd0; playing = 1'b0; cush = 12'd0; q_push = 1'b0; tick = 1'b0; twait = 1'b0;
	q_wp = 12'd0; q_rp = 12'd0; q_n = 13'd0; l = 16'd0; r = 16'd0;
end

endmodule
