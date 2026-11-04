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

// ------------------------------------------------------------------ player raster
// The player's sync generator makes standard PAL from its 4fsc crystal, where fsc = 283.75 fH + 25 Hz: the burst
// phase advances 283.75 + 1/625 cycles per line (the 25 Hz offset, which PAL chose to make the subcarrier dot
// pattern least visible), swinging 135/225 deg line by line. Lines are 1135 samples (line-locked, as the TBC is), so
// the 1/625 cycle per line is a phase step: rth counts the line's phase in 1/5000 cycle (+3758 per line), and the
// sample at x is A cos(90 deg * x + phi), phi = rth + swing, A = 21.4 IRE (300 mV p-p burst). The disc's TBC carries
// the same relationship, so the raster's dot pattern now matches the disc's (user, 2026-11-04: "the osd blue screens
// have it but the disc doesn't").
reg  [12:0] rth;           // burst phase of the current line, 1/5000 cycle
reg         rpar;          // line parity (PAL V-switch): 0 = 135 deg, 1 = 225 deg
wire [12:0] rphi = rth + (rpar ? 13'd3125 : 13'd1875);
wire [12:0] rphw = (rphi >= 13'd5000) ? rphi - 13'd5000 : rphi;
wire [29:0] rphm = rphw * 17'd3355;
wire [7:0]  ridx = rphm[23:16];                      // phi in 1/256 cycle (256/5000 = 3355/65536)
function automatic signed [14:0] rcos(input [7:0] i);
	begin
		case (i)
		8'd0: rcos = 15'sd8481;
		8'd1: rcos = 15'sd8478;
		8'd2: rcos = 15'sd8471;
		8'd3: rcos = 15'sd8458;
		8'd4: rcos = 15'sd8440;
		8'd5: rcos = 15'sd8417;
		8'd6: rcos = 15'sd8389;
		8'd7: rcos = 15'sd8356;
		8'd8: rcos = 15'sd8318;
		8'd9: rcos = 15'sd8275;
		8'd10: rcos = 15'sd8227;
		8'd11: rcos = 15'sd8174;
		8'd12: rcos = 15'sd8116;
		8'd13: rcos = 15'sd8053;
		8'd14: rcos = 15'sd7985;
		8'd15: rcos = 15'sd7913;
		8'd16: rcos = 15'sd7835;
		8'd17: rcos = 15'sd7753;
		8'd18: rcos = 15'sd7667;
		8'd19: rcos = 15'sd7575;
		8'd20: rcos = 15'sd7480;
		8'd21: rcos = 15'sd7379;
		8'd22: rcos = 15'sd7274;
		8'd23: rcos = 15'sd7165;
		8'd24: rcos = 15'sd7052;
		8'd25: rcos = 15'sd6934;
		8'd26: rcos = 15'sd6812;
		8'd27: rcos = 15'sd6686;
		8'd28: rcos = 15'sd6556;
		8'd29: rcos = 15'sd6422;
		8'd30: rcos = 15'sd6284;
		8'd31: rcos = 15'sd6142;
		8'd32: rcos = 15'sd5997;
		8'd33: rcos = 15'sd5848;
		8'd34: rcos = 15'sd5695;
		8'd35: rcos = 15'sd5540;
		8'd36: rcos = 15'sd5380;
		8'd37: rcos = 15'sd5218;
		8'd38: rcos = 15'sd5052;
		8'd39: rcos = 15'sd4883;
		8'd40: rcos = 15'sd4712;
		8'd41: rcos = 15'sd4537;
		8'd42: rcos = 15'sd4360;
		8'd43: rcos = 15'sd4180;
		8'd44: rcos = 15'sd3998;
		8'd45: rcos = 15'sd3813;
		8'd46: rcos = 15'sd3626;
		8'd47: rcos = 15'sd3437;
		8'd48: rcos = 15'sd3246;
		8'd49: rcos = 15'sd3052;
		8'd50: rcos = 15'sd2857;
		8'd51: rcos = 15'sd2660;
		8'd52: rcos = 15'sd2462;
		8'd53: rcos = 15'sd2262;
		8'd54: rcos = 15'sd2061;
		8'd55: rcos = 15'sd1858;
		8'd56: rcos = 15'sd1655;
		8'd57: rcos = 15'sd1450;
		8'd58: rcos = 15'sd1244;
		8'd59: rcos = 15'sd1038;
		8'd60: rcos = 15'sd831;
		8'd61: rcos = 15'sd624;
		8'd62: rcos = 15'sd416;
		8'd63: rcos = 15'sd208;
		8'd64: rcos = 15'sd0;
		8'd65: rcos = -15'sd208;
		8'd66: rcos = -15'sd416;
		8'd67: rcos = -15'sd624;
		8'd68: rcos = -15'sd831;
		8'd69: rcos = -15'sd1038;
		8'd70: rcos = -15'sd1244;
		8'd71: rcos = -15'sd1450;
		8'd72: rcos = -15'sd1655;
		8'd73: rcos = -15'sd1858;
		8'd74: rcos = -15'sd2061;
		8'd75: rcos = -15'sd2262;
		8'd76: rcos = -15'sd2462;
		8'd77: rcos = -15'sd2660;
		8'd78: rcos = -15'sd2857;
		8'd79: rcos = -15'sd3052;
		8'd80: rcos = -15'sd3246;
		8'd81: rcos = -15'sd3437;
		8'd82: rcos = -15'sd3626;
		8'd83: rcos = -15'sd3813;
		8'd84: rcos = -15'sd3998;
		8'd85: rcos = -15'sd4180;
		8'd86: rcos = -15'sd4360;
		8'd87: rcos = -15'sd4537;
		8'd88: rcos = -15'sd4712;
		8'd89: rcos = -15'sd4883;
		8'd90: rcos = -15'sd5052;
		8'd91: rcos = -15'sd5218;
		8'd92: rcos = -15'sd5380;
		8'd93: rcos = -15'sd5540;
		8'd94: rcos = -15'sd5695;
		8'd95: rcos = -15'sd5848;
		8'd96: rcos = -15'sd5997;
		8'd97: rcos = -15'sd6142;
		8'd98: rcos = -15'sd6284;
		8'd99: rcos = -15'sd6422;
		8'd100: rcos = -15'sd6556;
		8'd101: rcos = -15'sd6686;
		8'd102: rcos = -15'sd6812;
		8'd103: rcos = -15'sd6934;
		8'd104: rcos = -15'sd7052;
		8'd105: rcos = -15'sd7165;
		8'd106: rcos = -15'sd7274;
		8'd107: rcos = -15'sd7379;
		8'd108: rcos = -15'sd7480;
		8'd109: rcos = -15'sd7575;
		8'd110: rcos = -15'sd7667;
		8'd111: rcos = -15'sd7753;
		8'd112: rcos = -15'sd7835;
		8'd113: rcos = -15'sd7913;
		8'd114: rcos = -15'sd7985;
		8'd115: rcos = -15'sd8053;
		8'd116: rcos = -15'sd8116;
		8'd117: rcos = -15'sd8174;
		8'd118: rcos = -15'sd8227;
		8'd119: rcos = -15'sd8275;
		8'd120: rcos = -15'sd8318;
		8'd121: rcos = -15'sd8356;
		8'd122: rcos = -15'sd8389;
		8'd123: rcos = -15'sd8417;
		8'd124: rcos = -15'sd8440;
		8'd125: rcos = -15'sd8458;
		8'd126: rcos = -15'sd8471;
		8'd127: rcos = -15'sd8478;
		8'd128: rcos = -15'sd8481;
		8'd129: rcos = -15'sd8478;
		8'd130: rcos = -15'sd8471;
		8'd131: rcos = -15'sd8458;
		8'd132: rcos = -15'sd8440;
		8'd133: rcos = -15'sd8417;
		8'd134: rcos = -15'sd8389;
		8'd135: rcos = -15'sd8356;
		8'd136: rcos = -15'sd8318;
		8'd137: rcos = -15'sd8275;
		8'd138: rcos = -15'sd8227;
		8'd139: rcos = -15'sd8174;
		8'd140: rcos = -15'sd8116;
		8'd141: rcos = -15'sd8053;
		8'd142: rcos = -15'sd7985;
		8'd143: rcos = -15'sd7913;
		8'd144: rcos = -15'sd7835;
		8'd145: rcos = -15'sd7753;
		8'd146: rcos = -15'sd7667;
		8'd147: rcos = -15'sd7575;
		8'd148: rcos = -15'sd7480;
		8'd149: rcos = -15'sd7379;
		8'd150: rcos = -15'sd7274;
		8'd151: rcos = -15'sd7165;
		8'd152: rcos = -15'sd7052;
		8'd153: rcos = -15'sd6934;
		8'd154: rcos = -15'sd6812;
		8'd155: rcos = -15'sd6686;
		8'd156: rcos = -15'sd6556;
		8'd157: rcos = -15'sd6422;
		8'd158: rcos = -15'sd6284;
		8'd159: rcos = -15'sd6142;
		8'd160: rcos = -15'sd5997;
		8'd161: rcos = -15'sd5848;
		8'd162: rcos = -15'sd5695;
		8'd163: rcos = -15'sd5540;
		8'd164: rcos = -15'sd5380;
		8'd165: rcos = -15'sd5218;
		8'd166: rcos = -15'sd5052;
		8'd167: rcos = -15'sd4883;
		8'd168: rcos = -15'sd4712;
		8'd169: rcos = -15'sd4537;
		8'd170: rcos = -15'sd4360;
		8'd171: rcos = -15'sd4180;
		8'd172: rcos = -15'sd3998;
		8'd173: rcos = -15'sd3813;
		8'd174: rcos = -15'sd3626;
		8'd175: rcos = -15'sd3437;
		8'd176: rcos = -15'sd3246;
		8'd177: rcos = -15'sd3052;
		8'd178: rcos = -15'sd2857;
		8'd179: rcos = -15'sd2660;
		8'd180: rcos = -15'sd2462;
		8'd181: rcos = -15'sd2262;
		8'd182: rcos = -15'sd2061;
		8'd183: rcos = -15'sd1858;
		8'd184: rcos = -15'sd1655;
		8'd185: rcos = -15'sd1450;
		8'd186: rcos = -15'sd1244;
		8'd187: rcos = -15'sd1038;
		8'd188: rcos = -15'sd831;
		8'd189: rcos = -15'sd624;
		8'd190: rcos = -15'sd416;
		8'd191: rcos = -15'sd208;
		8'd192: rcos = 15'sd0;
		8'd193: rcos = 15'sd208;
		8'd194: rcos = 15'sd416;
		8'd195: rcos = 15'sd624;
		8'd196: rcos = 15'sd831;
		8'd197: rcos = 15'sd1038;
		8'd198: rcos = 15'sd1244;
		8'd199: rcos = 15'sd1450;
		8'd200: rcos = 15'sd1655;
		8'd201: rcos = 15'sd1858;
		8'd202: rcos = 15'sd2061;
		8'd203: rcos = 15'sd2262;
		8'd204: rcos = 15'sd2462;
		8'd205: rcos = 15'sd2660;
		8'd206: rcos = 15'sd2857;
		8'd207: rcos = 15'sd3052;
		8'd208: rcos = 15'sd3246;
		8'd209: rcos = 15'sd3437;
		8'd210: rcos = 15'sd3626;
		8'd211: rcos = 15'sd3813;
		8'd212: rcos = 15'sd3998;
		8'd213: rcos = 15'sd4180;
		8'd214: rcos = 15'sd4360;
		8'd215: rcos = 15'sd4537;
		8'd216: rcos = 15'sd4712;
		8'd217: rcos = 15'sd4883;
		8'd218: rcos = 15'sd5052;
		8'd219: rcos = 15'sd5218;
		8'd220: rcos = 15'sd5380;
		8'd221: rcos = 15'sd5540;
		8'd222: rcos = 15'sd5695;
		8'd223: rcos = 15'sd5848;
		8'd224: rcos = 15'sd5997;
		8'd225: rcos = 15'sd6142;
		8'd226: rcos = 15'sd6284;
		8'd227: rcos = 15'sd6422;
		8'd228: rcos = 15'sd6556;
		8'd229: rcos = 15'sd6686;
		8'd230: rcos = 15'sd6812;
		8'd231: rcos = 15'sd6934;
		8'd232: rcos = 15'sd7052;
		8'd233: rcos = 15'sd7165;
		8'd234: rcos = 15'sd7274;
		8'd235: rcos = 15'sd7379;
		8'd236: rcos = 15'sd7480;
		8'd237: rcos = 15'sd7575;
		8'd238: rcos = 15'sd7667;
		8'd239: rcos = 15'sd7753;
		8'd240: rcos = 15'sd7835;
		8'd241: rcos = 15'sd7913;
		8'd242: rcos = 15'sd7985;
		8'd243: rcos = 15'sd8053;
		8'd244: rcos = 15'sd8116;
		8'd245: rcos = 15'sd8174;
		8'd246: rcos = 15'sd8227;
		8'd247: rcos = 15'sd8275;
		8'd248: rcos = 15'sd8318;
		8'd249: rcos = 15'sd8356;
		8'd250: rcos = 15'sd8389;
		8'd251: rcos = 15'sd8417;
		8'd252: rcos = 15'sd8440;
		8'd253: rcos = 15'sd8458;
		8'd254: rcos = 15'sd8471;
		8'd255: rcos = 15'sd8478;
		endcase
	end
endfunction
reg signed [14:0] rc, rs;  // A cos(phi), A sin(phi) for the current line
always @(posedge clk) if (ce && x == 11'd10) begin rc <= rcos(ridx); rs <= rcos(ridx - 8'd64); end
wire signed [16:0] rbv = (x[1:0] == 2'd0) ? rc : (x[1:0] == 2'd1) ? -rs : (x[1:0] == 2'd2) ? -rc : rs;
wire signed [17:0] rbs = 18'sd14442 + rbv;            // blanking + burst
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
// line (rpar 0): the PAL burst-blanking sequence. The disc shows the same 4-field cycle (bursts from line 5 or 6,
// to 307/308/309, the first and last at 135 degrees in every field).
wire [8:0] blast = fld ? 9'd308 : 9'd309;
wire rburst = (ptype == P_N) && (x >= 11'd98) && (x < 11'd138) &&
              (ln >= 9'd6 || (ln == 9'd5 && !rpar)) && (ln < blast || (ln == blast && !rpar));
wire [15:0] raster = rlow ? 16'd0 : rburst ? rbs[15:0] : 16'd14442;
wire [13:0] rth_n = {1'b0, rth} + 14'd3758;
always @(posedge clk) if (ce && run && x == 11'd1134) begin
	rth  <= (rth_n >= 14'd5000) ? rth_n - 14'd5000 : rth_n;
	rpar <= ~rpar;
end

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

initial begin rd_bank = 1'b0; bank_w = 1'b1; rth = 13'd0; rpar = 1'b0; lf_req = 1'b0; end

endmodule
