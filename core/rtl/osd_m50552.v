// M50552-style on-screen display, mixed into the composite TBC stream (the real chip's CV IN -> CV OUT).
// cls gives the same per-dot decision for the RGB picture path (core/rtl/ld_scan.v colours it).
//
// Bit-exact implementation of tools/osd/osd_fx.py (docs/osd_dot_grid.md):
//   24x12 cells of 12x18 dots, 14-row glyphs, one dot row per field line, dot clock 7.03 MHz
//   (phase accumulator at 4fsc), white glyphs with a black shadow border, optional blue/black raster.
// Per line, during horizontal blanking, the four glyph rows a dot row needs (d-2..d+1) are fetched
// into rowbits and reduced to a 288-entry {lit, border} line buffer; the active line then reads it.
// The blue raster's chroma is formed from the line's own burst vector (from pal_decoder) because the
// TBC is line-locked: the player's M50552 runs from the reference 4fsc to which the disc burst is locked.
module osd_m50552 #(
	parameter FONT_HEX   = "rtl/osd_font.hex",
	parameter SCREEN_HEX = "rtl/osd_screens.hex"
) (
	input             clk,
	input             ce,

	input      [15:0] s_in,
	input      [10:0] x,
	input       [8:0] ln,
	input             fld,

	input       [2:0] screen,       // 0 = off (screen ids: tools/osd/gen_osd_rom.py)
	input       [1:0] bg,           // 0 = overlay, 1 = blue raster, 2 = black raster
	input             pic_off,      // no disc picture: the background fills the screen even with no screen up

	input signed [26:0] br,         // current line's burst vector and flags (pal_decoder)
	input signed [26:0] bi,
	input             col,
	input             inv,

	output reg [15:0] s_out,
	output reg  [1:0] cls,          // the same decision for the RGB path: 0 video, 1 glyph, 2 black, 3 blue raster
	output reg [10:0] xo,
	output reg  [8:0] lno,
	output reg        fo
);

localparam [15:0] BLANK = 16'd14442, WHITE = 16'd54016, YB = 16'd6073;
localparam [10:0] XS = 11'd283;
localparam [31:0] ACC0 = 32'd6927, STEP = 32'd25979;
localparam  [8:0] ROW0 = 9'd58;
localparam signed [17:0] QNR = -18'sd77891, QNI = -18'sd38650, QIR = -18'sd77891, QII = 18'sd38650;

// ------------------------------------------------------------------ ROMs
reg [11:0] font_rom [0:2047];
reg  [6:0] scr_rom  [0:4095];
initial begin
	$readmemh(FONT_HEX, font_rom);
	$readmemh(SCREEN_HEX, scr_rom);
end

// ------------------------------------------------------------------ per-line glyph fetch + reduce
reg signed [9:0]  d_line;          // dot row of the current line (ln - ROW0)
reg         [2:0] scr_l;           // screen latched for this line
reg      [287:0]  rowbits [0:3];   // rows d-2 .. d+1, index = dot column
reg               fa_run;          // phase A: fetch
reg         [1:0] fa_j;            // fetch row j (0 = d-2 .. 3 = d+1)
reg         [4:0] fa_cc;           // fetch cell column 0..23
reg               fb_run;          // phase B: reduce
reg         [8:0] fb_m;            // 0..289
reg      [287:0]  sh [0:3];
reg         [3:0] hist [0:3];      // {b(m-1), b(m-2), b(m-3), b(m-4)} after register

reg [1:0] obuf [0:287];            // {lit, border}
reg [1:0] obuf_q;

// fetch pipeline (one item per clock): counters -> q0 (row maths registered) -> screen ROM -> font ROM
// -> rowbits write. Counters instead of a divide, and the registered q0 stage, keep every path short.
wire signed [9:0] fa_dr = d_line - 10'sd2 + {8'd0, fa_j};
wire              fa_in = (fa_dr >= 0) && (fa_dr < 10'sd216);
wire        [7:0] fa_dru = fa_dr[7:0];
wire       [23:0] fa_prod = fa_dru * 24'd3641;               // explicit width: a 16-bit product would overflow
wire        [3:0] fa_cr = fa_prod[19:16];                    // dr / 18 for dr < 256
wire        [7:0] fa_cr18 = fa_cr * 8'd18;
wire        [4:0] fa_gr = fa_dru - fa_cr18;
reg               q0_v, p1_v, p2_v;
reg         [1:0] q0_j, p1_j, p2_j;
reg         [4:0] q0_cc, p1_cc, p2_cc;
reg         [3:0] q0_cr;
reg         [4:0] q0_gr, p1_gr;
reg               q0_in, p1_in, p2_in;
reg         [6:0] code_q;
reg        [11:0] glyph_q;
reg         [4:0] p2_gr;                 // 5 bits: glyph rows 16-17 must not wrap to 0-1

wire        [8:0] q0_cell = q0_cr * 9'd24 + q0_cc;           // explicit width (a concat self-sizes)
always @(posedge clk) begin
	code_q  <= scr_rom[{scr_l, q0_cell}];
	glyph_q <= font_rom[{code_q, p1_gr[3:0]}];
end

integer j, k;
always @(posedge clk) begin
	// start of line: latch dot row, kick off phase A
	if (ce && x == 11'd0) begin
		d_line <= $signed({1'b0, ln}) - $signed({1'b0, ROW0});
		scr_l  <= screen;
		fa_run <= 1'b1;
		fa_j   <= 2'd0;
		fa_cc  <= 5'd0;
		for (j = 0; j < 4; j = j + 1) rowbits[j] <= 288'd0;
	end else if (fa_run) begin
		if (fa_cc == 5'd23) begin
			fa_cc <= 5'd0;
			fa_j  <= fa_j + 2'd1;
			if (fa_j == 2'd3) fa_run <= 1'b0;
		end else fa_cc <= fa_cc + 5'd1;
	end

	q0_v <= fa_run; q0_j <= fa_j; q0_cc <= fa_cc; q0_cr <= fa_cr; q0_gr <= fa_gr; q0_in <= fa_in;
	p1_v <= q0_v;   p1_j <= q0_j; p1_cc <= q0_cc; p1_gr <= q0_gr; p1_in <= q0_in;
	p2_v <= p1_v;   p2_j <= p1_j; p2_cc <= p1_cc; p2_gr <= p1_gr; p2_in <= p1_in;

	if (p2_v) begin
		for (k = 0; k < 12; k = k + 1)
			rowbits[p2_j][p2_cc * 12 + k] <= p2_in && (p2_gr < 5'd14) && glyph_q[11 - k];
		if (p2_j == 2'd3 && p2_cc == 5'd23) begin           // last item written next: start phase B
			fb_run <= 1'b1;
			fb_m   <= 9'd0;
		end
	end

	if (fb_run) begin
		if (fb_m == 9'd0) begin
			for (j = 0; j < 4; j = j + 1) begin sh[j] <= rowbits[j]; hist[j] <= 4'd0; end
		end else begin
			for (j = 0; j < 4; j = j + 1) begin
				hist[j] <= {sh[j][0], hist[j][3:1]};
				sh[j]   <= sh[j] >> 1;
			end
		end
		fb_m <= fb_m + 9'd1;
		if (fb_m == 9'd290) fb_run <= 1'b0;
	end
end

// reduce: at register state hist = {b(k+1), b(k), b(k-1), b(k-2)} for k = fb_m - 3
// (sh loaded at m=0; first shift at m=1 yields hist[3] = b(0)).  rows j: 0=d-2 .. 3=d+1
wire lit_k = hist[2][2];
wire nb    = hist[0][2] | hist[0][1] | hist[0][0] |
             hist[1][3] | hist[1][2] | hist[1][1] | hist[1][0] |
             hist[2][3] | hist[2][1] | hist[2][0] |
             hist[3][3] | hist[3][2] | hist[3][1];
// (j=0,h=3) and (j=3,h=0) excluded: (dy,dx) = (2,-1) and (-1,2)
wire [8:0] fb_k = fb_m - 9'd3;
always @(posedge clk) begin
	if (fb_run && fb_m >= 9'd3 && fb_m <= 9'd290)
		obuf[fb_k] <= {lit_k, !lit_k && nb};
end

// ------------------------------------------------------------------ per-line chroma coefficient
reg signed [44:0] m_rr, m_ii, m_ri, m_ir;
reg signed [20:0] kr, ki;
reg               col_l, inv_l;
reg         [1:0] kseq;
always @(posedge clk) begin
	if (ce && x == 11'd160) begin
		col_l <= col; inv_l <= inv; kseq <= 2'd1;
		m_rr <= br * (inv ? QIR : QNR); m_ii <= bi * (inv ? QII : QNI);
		m_ri <= bi * (inv ? QIR : QNR); m_ir <= br * (inv ? QII : QNI);
	end else if (kseq == 2'd1) begin
		kr <= (m_rr - m_ii) >>> 24;
		ki <= (m_ri + m_ir) >>> 24;
		kseq <= 2'd0;
	end
end

// ------------------------------------------------------------------ active mix (2 ce latency)
reg  [31:0] acc;
wire [31:0] acc_now = (x == XS) ? ACC0 : acc + STEP;
wire [15:0] dc_now  = acc_now[31:16];

reg  [15:0] s1;
reg  [10:0] x1;
reg   [8:0] ln1;
reg         f1, win1, dv1;
reg   [1:0] ob1;                                         // obuf_q captured for this sample
reg   [1:0] ph1;
always @(posedge clk) if (ce) begin
	acc  <= acc_now;
	s1   <= s_in; x1 <= x; ln1 <= ln; f1 <= fld; ph1 <= x[1:0];
	// The background colour is the screen whenever no disc picture is shown, from power-on: "In NTSC mode or
	// PAL mode, the colour of the background is blue"; MOD. PAL "black when the power is turned on" (OM p.46).
	win1 <= (scr_l != 3'd0 || pic_off) && (ln >= 9'd22) && (ln < 9'd310) && (x >= 11'd185) && (x < 11'd1107);
	dv1  <= (x >= XS) && (dc_now < 16'd288) && (d_line >= -10'sd2) && (d_line < 10'sd218);
	ob1  <= obuf_q;                                       // read during the clocks since x changed
end
always @(posedge clk) obuf_q <= obuf[dc_now[8:0]];        // address held for 4 clks

wire signed [21:0] chroma = !col_l ? 22'sd0 :
                            (ph1 == 2'd0) ?  kr : (ph1 == 2'd1) ? -ki : (ph1 == 2'd2) ? -kr : ki;
wire signed [22:0] bgs    = $signed({7'd0, BLANK}) + $signed({7'd0, YB}) + chroma;
wire        [15:0] bgs_c  = (bgs < 0) ? 16'd0 : (bgs > 65535) ? 16'hFFFF : bgs[15:0];

always @(posedge clk) if (ce) begin
	xo <= x1; lno <= ln1; fo <= f1;
	if (!win1) begin s_out <= s1; cls <= 2'd0; end
	else if (dv1 && ob1[1]) begin s_out <= WHITE; cls <= 2'd1; end
	else if (dv1 && ob1[0]) begin s_out <= BLANK; cls <= 2'd2; end
	else case (bg)
		2'd1:    begin s_out <= bgs_c; cls <= 2'd3; end
		2'd2:    begin s_out <= BLANK; cls <= 2'd2; end
		default: begin s_out <= s1;    cls <= 2'd0; end
	endcase
end

endmodule
