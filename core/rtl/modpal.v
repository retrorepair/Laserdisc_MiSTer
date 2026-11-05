// MOD. PAL (SYSTEM mode, NTSC discs): the CLD-1750's NTSC -> pseudo-PAL conversion for PAL TVs (docs/mod_pal.md).
//
// The player's PALB board (SM p.54) separates the NTSC chroma with a 3.58 MHz band-pass (F202) and a comb filter
// (F201), moves it to 4.43 MHz (IC208 TA7320P mixer, F101 4.43 MHz band-pass) and outputs it on the 525-line, 60 Hz
// picture as PAL-coded colour (OM p.46: colour on a PAL TV; "pseudo-PAL (PAL on 60 Hz)"), so the TV gets
// U sin + / - V cos on a 4.43361875 MHz carrier (crystal X202) with the swinging burst.
// Here, per 4fsc sample of the replayed composite (8-bit codes, n = index in the 910-sample line):
//   1H comb d = x - x(line before); band-pass c4 = 2d[n-2] - d[n] - d[n-4] (chroma(n-2) = c4/8, peak at fsc);
//   luma y8 = 8x[n-2] - c4. The 4fsc samples sit 90 deg apart on the subcarrier, so held samples of c4 give the
//   chroma's complex envelope; rotated by 33 deg (the TBC's sampling phase against the burst: ld-decode samples on
//   the I/Q axes, measured -33 / +147 deg on GGV1069) the burst lies on the real axis, and its sign over n = 80..107
//   gives the line's sign. U, V then modulate the PAL carrier (NCO), V inverted on alternate lines; in the burst
//   window the burst is turned to 135 / 225 deg at its own amplitude. PAL at 4.43 MHz is below the 4fsc Nyquist
//   frequency, so the composite goes on at 4fsc into the core's 4x reconstruction filter.
// Chroma advance (menu) delays the luma by 2 x adv samples here, as the core's split does for NTSC/PAL.
// Bit-exact model: tools/analysis/modpal_ref.py (testbench core/sim/tb_modpal.sv).
module modpal #(
	parameter SIN_HEX = "rtl/modpal_sin.hex"
) (
	input             clk,
	input             ce,          // 4fsc
	input       [7:0] x,           // replayed composite code (with the OSD)
	input      [10:0] n,           // x's index in the line (0 = line start)
	input       [2:0] adv,         // chroma advance setting
	output reg  [7:0] out          // PAL-coded composite code, two ce after x (stages s1-s5)
);

localparam [31:0] INC4 = 32'd1329934748;   // 4 x 4433618.75 / 57272727.27 x 2^32 (carrier per 4fsc sample)

reg  [7:0] mem [0:1023];                   // the line before
reg signed [11:0] sin_rom [0:1023];
integer mi;
initial begin
	$readmemh(SIN_HEX, sin_rom);
	for (mi = 0; mi < 1024; mi = mi + 1) mem[mi] = 8'd0;   // as the model: no line before at start
end

// stage 0 (ce): capture, read the line before
reg  [7:0] x0, prev;
reg [10:0] n0;
reg  [2:0] adv0, adv1;
reg        s1, s2, s3, s4, s5;
always @(posedge clk) begin
	s1 <= ce; s2 <= s1; s3 <= s2; s4 <= s3; s5 <= s4;
	if (ce) begin
		x0 <= x;
		n0 <= n;
		adv0 <= adv;
	end
	prev <= mem[n[9:0]];
end

// stage 1: comb, band-pass, luma, held quadrature samples
reg signed  [9:0] d1, d2, d3, d4;          // d[n-1..n-4]
reg         [7:0] xh1, xh2;                // x[n-1], x[n-2]
reg signed [13:0] yh [0:14];               // y8 history (chroma advance)
reg signed [11:0] zr, zi;
reg        [10:0] n1;
reg               vsw = 1'b1;            // toggles at each line start (the first line gets 0 = -V)
wire signed  [9:0] d  = $signed({2'b00, x0}) - $signed({2'b00, prev});
wire signed [11:0] c4 = 12'sd2 * d2 - d - d4;
wire signed [13:0] y8 = $signed({3'b000, xh2, 3'b000}) - c4;
integer k;
always @(posedge clk) if (s1) begin
	mem[n0[9:0]] <= x0;
	d1 <= d; d2 <= d1; d3 <= d2; d4 <= d3;
	xh1 <= x0; xh2 <= xh1;
	yh[0] <= y8;
	for (k = 1; k < 15; k = k + 1) yh[k] <= yh[k - 1];
	case (n0[1:0])
	2'd0: zr <= c4;
	2'd1: zi <= -c4;
	2'd2: zr <= -c4;
	2'd3: zi <= c4;
	endcase
	if (n0 == 11'd0) vsw <= ~vsw;
	n1 <= n0;
	adv1 <= adv0;
end

// stage 2: rotate by 33 deg
wire signed [26:0] qr_p = zr * 16'sd27482 - zi * 16'sd17847;
wire signed [26:0] qi_p = zr * 16'sd17847 + zi * 16'sd27482;
reg  signed [11:0] qr, qi;
reg         [10:0] n2;
reg         [13:0] y2;
reg                vsw2;
always @(posedge clk) if (s2) begin
	qr <= qr_p >>> 15;
	qi <= qi_p >>> 15;
	n2 <= n1;
	y2 <= yh[{adv1, 1'b0}];
	vsw2 <= vsw;
end

// stage 3: the line's burst sign, U and V (the burst turned to 135 / 225 deg); the carrier's sine and cosine
reg  [31:0] ph = 32'd0;
wire signed [11:0] qa = qr[11] ? -qr : qr;
wire signed [27:0] ba_p = qa * 17'sd23170;  // |qr| / sqrt2
wire signed [11:0] ba = ba_p >>> 15;
reg  signed [16:0] pacc;
reg                sneg;                   // the line's sign is - (burst on +real)
wire               sneg_now = (n2 == 11'd108) ? pacc[16] : sneg;
reg  signed [12:0] u3, v3;
reg  signed [11:0] sn3, cs3;
reg         [13:0] y3;
reg                vsw3;
always @(posedge clk) if (s3) begin
	if (n2 == 11'd0) pacc <= 17'sd0;
	else if (n2 >= 11'd80 && n2 < 11'd108) pacc <= pacc + qr;
	sneg <= sneg_now;
	if (n2 >= 11'd74 && n2 < 11'd114) begin
		u3 <= -ba;
		v3 <= ba;
	end else begin
		u3 <= sneg_now ? qr : -qr;
		v3 <= sneg_now ? qi : -qi;
	end
	sn3 <= sin_rom[ph[31:22]];
	cs3 <= sin_rom[ph[31:22] + 10'd256];
	y3 <= y2;
	vsw3 <= vsw2;
end

// stage 4: modulate (and advance the carrier one 4fsc sample)
reg  signed [25:0] cu4, cv4;
reg  signed [13:0] yd4;
reg                vsw4;
always @(posedge clk) if (s4) begin
	ph <= ph + INC4;
	cu4 <= u3 * sn3;
	cv4 <= v3 * cs3;
	yd4 <= ($signed(y3) + 14'sd4) >>> 3;
	vsw4 <= vsw3;
end

// stage 5 (the next sample's stage 1): sum, clamp
wire signed [26:0] csum = vsw4 ? cu4 + cv4 : cu4 - cv4;
wire signed [12:0] chroma = csum >>> 14;
wire signed [14:0] o = yd4 + chroma;
always @(posedge clk) if (s5) out <= o < 0 ? 8'd0 : o > 15'sd255 ? 8'd255 : o[7:0];

endmodule
