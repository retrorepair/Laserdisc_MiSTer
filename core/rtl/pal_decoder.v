// PAL composite -> RGB decoder for line-locked 4fsc TBC samples.
//
// Bit-exact implementation of tools/model/pal_decode_fx.py (see docs/core_architecture.md).
// This stands in for the TV's decoder while the core outputs RGB; it is not CLD-1750 logic.
//
// Input: one sample per ce with its line position x (0..1134), field line ln and field flag.
// The filters are centred 3 samples back, so every output carries the (x, ln, fld) of the
// sample it describes (xo/lno/fo), LAT ce-cycles after that sample entered.
module pal_decoder (
	input             clk,
	input             ce,
	input             ntsc,         // NTSC line: burst window 78-109 (burst 74-110), blanking 15360
	input      [15:0] s,
	input      [10:0] x,
	input       [8:0] ln,
	input             fld,

	output reg  [7:0] r,
	output reg  [7:0] g,
	output reg  [7:0] b,
	output reg [10:0] xo,
	output reg  [8:0] lno,
	output reg        fo,

	// current line's burst vector and flags, valid from x ~ 140 (for the composite-domain OSD)
	output signed [26:0] burst_r,
	output signed [26:0] burst_i,
	output               line_col,
	output               line_inv
);

wire [15:0] BLANK  = ntsc ? 16'd15360 : 16'd14442;
localparam [58:0] N_DIV  = 59'h4d46d3d29df4380;   // round(K_UV * 2^48)
localparam [50:0] KILL2  = 51'd294554922506;       // colour-killer |B|^2 threshold
wire [10:0] BURST0 = ntsc ? 11'd78 : 11'd102, BURST1 = ntsc ? 11'd109 : 11'd133;

// ---------------------------------------------------------------- stage A: d = s - BLANK
reg signed [17:0] d_a;
reg        [10:0] x_a;
reg         [8:0] ln_a;
reg               f_a;
always @(posedge clk) if (ce) begin
	d_a  <= $signed({2'b00, s}) - $signed({2'b00, BLANK});
	x_a  <= x;
	ln_a <= ln;
	f_a  <= fld;
end

// fs/4 mix by line phase: d * e^{-j x pi/2} = (d,0) (0,-d) (-d,0) (0,d)
wire signed [17:0] zr_a = (x_a[1:0] == 2'd0) ?  d_a : (x_a[1:0] == 2'd2) ? -d_a : 18'sd0;
wire signed [17:0] zi_a = (x_a[1:0] == 2'd1) ? -d_a : (x_a[1:0] == 2'd3) ?  d_a : 18'sd0;

// ---------------------------------------------------------------- tap delay lines
reg signed [17:0] dh  [0:6];
reg signed [17:0] zrh [0:6];
reg signed [17:0] zih [0:6];
reg        [10:0] xh  [0:6];
reg         [8:0] lnh [0:6];
reg               fh  [0:6];
integer i;
always @(posedge clk) if (ce) begin
	dh[0] <= d_a; zrh[0] <= zr_a; zih[0] <= zi_a; xh[0] <= x_a; lnh[0] <= ln_a; fh[0] <= f_a;
	for (i = 1; i < 7; i = i + 1) begin
		dh[i] <= dh[i-1]; zrh[i] <= zrh[i-1]; zih[i] <= zih[i-1];
		xh[i] <= xh[i-1]; lnh[i] <= lnh[i-1]; fh[i] <= fh[i-1];
	end
end

// ---------------------------------------------------------------- stage C: LPF, luma notch (centre = tap 3)
// L = 1*z0 + 2*z1 + 3*z2 + 4*z3 + 3*z4 + 2*z5 + 1*z6   (|L| < 2^20)
wire signed [21:0] lr_w = zrh[0] + (zrh[1] <<< 1) + 3*zrh[2] + (zrh[3] <<< 2) + 3*zrh[4] + (zrh[5] <<< 1) + zrh[6];
wire signed [21:0] li_w = zih[0] + (zih[1] <<< 1) + 3*zih[2] + (zih[3] <<< 2) + 3*zih[4] + (zih[5] <<< 1) + zih[6];
// yn = (d[c-2] + 2 d[c] + d[c+2]) >>> 2, centre c = tap 3
wire signed [19:0] yn_w = (dh[1] + (dh[3] <<< 1) + dh[5]) >>> 2;

reg signed [21:0] lr_c, li_c;
reg signed [19:0] yn_c;
reg        [10:0] x_c;
reg         [8:0] ln_c;
reg               f_c;
always @(posedge clk) if (ce) begin
	lr_c <= lr_w; li_c <= li_w; yn_c <= yn_w;
	x_c <= xh[3]; ln_c <= lnh[3]; f_c <= fh[3];
end

// ---------------------------------------------------------------- per-line burst, ident, coefficient
reg signed [26:0] br, bi;           // burst accumulators
reg signed [26:0] pbr, pbi;         // previous colour line's burst
reg               col;              // current line has colour (valid from x_c == 134)
reg               pcol;             // previous line had colour (delay RAM valid)
reg               inv;              // current line V inverted
reg signed [27:0] c0r, c0i;         // conj(B) * (-1 +/- j)
reg        [50:0] mag2;
reg signed [25:0] cr, ci;           // per-line demod coefficient

assign burst_r = br, burst_i = bi, line_col = col, line_inv = inv;

// sequential divider q = N_DIV / mag2 (restoring, 59 iterations at clk rate)
reg               div_run;
reg         [5:0] div_i;
reg        [51:0] div_rem;
reg        [58:0] div_q;
reg               div_done;

// Once-per-line arithmetic runs as a short clk-rate sequence (each step one DSP level), started
// at the ce after the burst window; it completes long before active video (x >= 185).
reg         [2:0] seq;            // 0 idle, 1 products, 2 sums, 3 decide
reg signed [53:0] p_bb_r, p_bb_i, p_dot_r, p_dot_i;
reg               dot_pos;
// q * c0 split as q*c0_hi*2^14 + q*c0_lo so every product fits a 27x27 DSP (exact)
wire signed [21:0] q_s    = $signed({1'b0, div_q[20:0]});
wire signed [13:0] c0r_hi = c0r[27:14];
wire signed [13:0] c0i_hi = c0i[27:14];
wire signed [14:0] c0r_lo = $signed({1'b0, c0r[13:0]});
wire signed [14:0] c0i_lo = $signed({1'b0, c0i[13:0]});
reg  signed [35:0] m_rh, m_ih;
reg  signed [36:0] m_rl, m_il;
reg  signed [49:0] qc_r, qc_i;
reg         [1:0]  qseq;
wire        [51:0] rem_sh = {div_rem[50:0], N_DIV[div_i]};
initial begin seq = 3'd0; qseq = 2'd0; div_run = 1'b0; end

always @(posedge clk) begin
	div_done <= 1'b0;

	case (seq)
	3'd1: begin
		p_bb_r <= br * br;  p_bb_i <= bi * bi;
		p_dot_r <= br * pbr; p_dot_i <= bi * pbi;
		seq <= 3'd2;
	end
	3'd2: begin
		mag2    <= p_bb_r + p_bb_i;
		dot_pos <= (p_dot_r + p_dot_i) > 0;
		seq <= 3'd3;
	end
	3'd3: begin
		seq  <= 3'd0;
		pcol <= col;
		if (mag2 < KILL2) begin
			col <= 1'b0;
			inv <= 1'b0;
		end else begin
			col <= 1'b1;
			inv <= col && dot_pos;
			if (col && dot_pos) begin c0r <= -br - bi; c0i <= bi - br; end    // burst at 225 deg
			else                begin c0r <= -br + bi; c0i <= br + bi; end    // burst at 135 deg
			pbr <= br; pbi <= bi;
			div_run <= 1'b1; div_i <= 6'd58; div_rem <= 52'd0;
		end
	end
	default: ;
	endcase

	if (div_run) begin
		if (rem_sh >= {1'b0, mag2}) begin
			div_rem <= rem_sh - {1'b0, mag2};
			div_q[div_i] <= 1'b1;
		end else begin
			div_rem <= rem_sh;
			div_q[div_i] <= 1'b0;
		end
		if (div_i == 6'd0) begin div_run <= 1'b0; div_done <= 1'b1; end
		else div_i <= div_i - 6'd1;
	end

	// coefficient: cr = (q * c0) >>> 24, three registered steps
	case (qseq)
	2'd1: begin
		m_rh <= q_s * c0r_hi; m_rl <= q_s * c0r_lo;
		m_ih <= q_s * c0i_hi; m_il <= q_s * c0i_lo;
		qseq <= 2'd2;
	end
	2'd2: begin
		qc_r <= (m_rh <<< 14) + m_rl;
		qc_i <= (m_ih <<< 14) + m_il;
		qseq <= 2'd3;
	end
	2'd3: begin
		cr <= qc_r >>> 24;
		ci <= qc_i >>> 24;
		qseq <= 2'd0;
	end
	default: if (div_done) qseq <= 2'd1;
	endcase

	if (ce) begin
		if (x_c == BURST0) begin br <= lr_c; bi <= li_c; end
		else if (x_c > BURST0 && x_c <= BURST1) begin br <= br + lr_c; bi <= bi + li_c; end

		if (ln_c == 9'd0 && x_c == 11'd0) begin col <= 1'b0; pcol <= 1'b0; end   // field start: model resets per field

		if (x_c == BURST1 + 11'd1) seq <= 3'd1;
	end
end

// ---------------------------------------------------------------- stage D: demodulate
reg signed [47:0] p_rr, p_ii, p_ri, p_ir;
reg signed [19:0] yn_d;
reg        [10:0] x_d;
reg         [8:0] ln_d;
reg               f_d, col_d, pcol_d, inv_d;
always @(posedge clk) if (ce) begin
	p_rr <= lr_c * cr; p_ii <= li_c * ci; p_ri <= lr_c * ci; p_ir <= li_c * cr;
	yn_d <= yn_c; x_d <= x_c; ln_d <= ln_c; f_d <= f_c; col_d <= col; pcol_d <= pcol; inv_d <= inv;
end

wire signed [48:0] u_sum = p_rr - p_ii;
wire signed [48:0] v_sum = p_ri + p_ir;
wire signed [24:0] ur_w  = u_sum >>> 24;
wire signed [24:0] vi_w0 = v_sum >>> 24;
wire signed [24:0] vi_w  = inv_d ? -vi_w0 : vi_w0;

// previous-line (ur, vi) delay RAM, addressed by x
reg [49:0] dl_ram [0:2047];
reg [49:0] dl_q;
always @(posedge clk) if (ce) begin
	dl_q <= dl_ram[x_d];
	dl_ram[x_d] <= {ur_w, vi_w};
end

// ---------------------------------------------------------------- stage E: PAL delay-line average
reg signed [24:0] ur_e, vi_e;
reg signed [19:0] yn_e;
reg        [10:0] x_e;
reg         [8:0] ln_e;
reg               f_e, col_e, pcol_e;
always @(posedge clk) if (ce) begin
	ur_e <= ur_w; vi_e <= vi_w; yn_e <= yn_d; x_e <= x_d; ln_e <= ln_d; f_e <= f_d; col_e <= col_d; pcol_e <= pcol_d;
end
wire signed [24:0] pur = dl_q[49:25];
wire signed [24:0] pvi = dl_q[24:0];
wire signed [25:0] u_w = !col_e ? 26'sd0 : pcol_e ? ((ur_e + pur) >>> 1) : ur_e;
wire signed [25:0] v_w = !col_e ? 26'sd0 : pcol_e ? ((vi_e + pvi) >>> 1) : vi_e;
wire signed [33:0] y8_w = (yn_e * 14'sd6757) >>> 20;

// ---------------------------------------------------------------- stage F: matrix
reg signed [39:0] m_rv, m_bu, m_g;
reg signed [33:0] y8_f;
reg        [10:0] x_f;
reg         [8:0] ln_f;
reg               f_f;
always @(posedge clk) if (ce) begin
	m_rv <= v_w * 14'sd4671;
	m_bu <= u_w * 15'sd8308;
	m_g  <= u_w * 12'sd1617 + v_w * 13'sd2378;
	y8_f <= y8_w; x_f <= x_e; ln_f <= ln_e; f_f <= f_e;
end
wire signed [39:0] r_w = y8_f + (m_rv >>> 12);
wire signed [39:0] b_w = y8_f + (m_bu >>> 12);
wire signed [39:0] g_w = y8_f - (m_g  >>> 12);

function [7:0] clamp8(input signed [39:0] v);
	clamp8 = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0];
endfunction

always @(posedge clk) if (ce) begin
	r <= clamp8(r_w); g <= clamp8(g_w); b <= clamp8(b_w);
	xo <= x_f; lno <= ln_f; fo <= f_f;
end

endmodule
