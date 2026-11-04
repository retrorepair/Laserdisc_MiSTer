// Composite (CVBS) replay of the frame on screen, straight from its DDR3 slot, at the TBC replay timing.
//
// The slot holds the frame's composite region (tools/convert/dscv/add_cvbs.py): both fields, 313 lines of 1136
// bytes each (the second field's line 313 is padding), as 8-bit DAC codes (code 255 = 100 IRE white = 54016 on
// the TBC scale; sync tip about 0, blanking code 68). Field line ln of field fld (0 = first) is slot row
// fld * 313 + ln. Each line is fetched, while the line before it is shown, into the other half of a two-line
// buffer through ld_stream's line fetch.
//
// Outputs, one ce after the position:
//   code   the sample's DAC code, unchanged, so the replay is bit-exact wherever nothing is drawn over it
//   s      the same sample on the TBC's 16-bit scale (code * 54016 / 255), for the composite OSD mix and the burst
//          measurement that colours the OSD's blue raster (osd_m50552, pal_decoder)
// With no disc video (show = 0) it is the player's own raster, as tbc_reader generated it (docs/player_logic.md):
// line sync, burst and blanking, with the 625-line vertical interval and burst blanking (below).
module cvbs_scan (
	input             clk,
	input             ce,
	input      [10:0] x,
	input       [8:0] ln,
	input             fld,
	input             run,
	input             show,

	output reg        lf_req,
	output reg  [9:0] lf_row,
	input             lf_we,
	input       [8:0] lf_addr,
	input      [63:0] lf_data,

	output reg  [7:0] code,
	output reg [15:0] s,
	output reg [10:0] xs,
	output reg  [8:0] lns,
	output reg        flds
);

// ------------------------------------------------------------------ two-line buffer (2 x 256 words)
// The bank toggles at every line start (not by line parity: field lines 312 and 0 are both even), so the line
// being fetched never lands in the half being shown.
reg [63:0] lb [0:511];
reg        rd_bank, bank_w;
reg [63:0] lb_q;
always @(posedge clk) begin
	if (lf_we) lb[{bank_w, lf_addr[7:0]}] <= lf_data;
	lb_q <= lb[{rd_bank, x[10:3]}];
end

wire       last_ln = ln == (fld ? 9'd311 : 9'd312);   // tbc_timing
wire [8:0] nln     = last_ln ? 9'd0 : ln + 9'd1;
wire       nfld    = last_ln ? ~fld : fld;
always @(posedge clk) begin
	lf_req <= 1'b0;
	// the bank changes on the last sample of a line, so the read for sample 0 already uses the new line's half
	if (ce && x == 11'd1134) begin
		rd_bank <= ~rd_bank;               // the next line: the half filled during this one
		bank_w <= rd_bank;                 // the line after it: the other half
	end
	if (ce && x == 11'd0) begin
		lf_req <= 1'b1;
		lf_row <= (nfld ? 10'd313 : 10'd0) + {1'b0, nln};
	end
end

// ------------------------------------------------------------------ player raster (from tbc_reader)
// Subcarrier-locked at 1135 samples/line: the burst phase advances 270 deg per line and swings 135/225 deg:
// phi(L)/45 = 6L + (L odd ? 5 : 3), sample = cos(45 deg * (2x + phi/45)). Levels on the TBC scale.
reg  [1:0] rline;
wire [2:0] rk = {x[1:0], 1'b0} + (rline * 3'd6) + (rline[0] ? 3'd5 : 3'd3);
wire       rpos = (rk == 3'd1) || (rk == 3'd7);
// Vertical interval, line by line as on the disc's own TBC (measured on Community North, both field types) and in
// the 625-line standard: B = broad pulse (27.3 us = 484 samples), E = equalising pulse (2.35 us = 42), N = line
// sync (4.7 us = 83); half lines start at x = 0 and x = 567. (The service manual gives no pulse widths for the
// player's sync generator, so the widths are the standard's.)
//   first field  (313 lines, PAL 1-313):   0-1 BB, 2 BE, 3-4 EE, 310-311 EE, 312 EB
//   second field (312 lines, PAL 314-625): 0-1 BB, 2-3 EE, 4 E-, 309 NE, 310-311 EE
localparam [1:0] P_NONE = 2'd0, P_N = 2'd1, P_E = 2'd2, P_B = 2'd3;
wire        h2 = (x >= 11'd567);
wire [10:0] xh = h2 ? x - 11'd567 : x;
reg   [1:0] ptype;
always @* begin
	if (!fld) case (ln)
		9'd0, 9'd1:                   ptype = P_B;
		9'd2:                         ptype = h2 ? P_E : P_B;
		9'd3, 9'd4, 9'd310, 9'd311:   ptype = P_E;
		9'd312:                       ptype = h2 ? P_B : P_E;
		default:                      ptype = h2 ? P_NONE : P_N;
	endcase else case (ln)
		9'd0, 9'd1:                   ptype = P_B;
		9'd2, 9'd3, 9'd310, 9'd311:   ptype = P_E;
		9'd4:                         ptype = h2 ? P_NONE : P_E;
		9'd309:                       ptype = h2 ? P_E : P_N;
		default:                      ptype = h2 ? P_NONE : P_N;
	endcase
end
wire rlow = (ptype == P_N && xh < 11'd83) || (ptype == P_E && xh < 11'd42) || (ptype == P_B && xh < 11'd484);
// Burst on lines 5-309 (first field) or 5-308 (second), the first and last burst of each field on a 135-degree
// line (rline even): the PAL burst-blanking sequence. The disc shows the same 4-field cycle (bursts from line 5 or 6,
// to 307/308/309, the first and last at 135 degrees in every field).
wire [8:0] blast = fld ? 9'd308 : 9'd309;
wire rburst = (ptype == P_N) && (x >= 11'd98) && (x < 11'd138) &&
              (ln >= 9'd6 || (ln == 9'd5 && !rline[0])) && (ln < blast || (ln == blast && !rline[0]));
wire [15:0] raster = rlow ? 16'd0 : rburst ? (rpos ? 16'd20439 : 16'd8445) : 16'd14442;
always @(posedge clk) if (ce && run && x == 11'd1134) rline <= rline + 2'd1;

// DAC code of a TBC-scale level: round(v * 255 / 54016)
function automatic [7:0] dac(input [15:0] v);
	reg [27:0] p;
	begin
		p = v * 12'd1238 + 28'd131072;
		dac = p[27:18] > 10'd255 ? 8'd255 : p[25:18];
	end
endfunction

// lb_q holds the word for the current x (read in the clocks after x changed)
wire  [7:0] smp = lb_q[{x[2:0], 3'b000} +: 8];
wire [21:0] smp_s = smp * 22'd13557;     // code * 54016 / 255 = code * 13557 / 64
always @(posedge clk) if (ce) begin
	xs <= x; lns <= ln; flds <= fld;
	if (show) begin
		code <= smp;
		s    <= smp_s[21:6];
	end else begin
		code <= dac(raster);
		s    <= raster;
	end
end

initial begin rd_bank = 1'b0; bank_w = 1'b1; rline = 2'd0; lf_req = 1'b0; end

endmodule
