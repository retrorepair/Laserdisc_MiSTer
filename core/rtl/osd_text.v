// The player's variable OSD text (screen 7 of osd_m50552): search, DISPLAY and side-change screens.
// It sweeps the 288 cells continuously, writing each cell's character into the screen RAM.
//
// Layouts (docs/player_logic.md, SEARCH / CHAPTER):
//   row 0, from column 1: "SEARCH" (F1: CLD-1750 304.67-305.44 s; F2 CLD-3080; CLD-D925 tour 1557-1575 s), or the
//          DISPLAY line in the CLD-1750's own form (European OM p.44 figure: "3 12.49 ... PLAY"): the chapter in
//          columns 1-2, then a CAV frame number or a CLV elapsed time as M.SS.
//   row 1, from column 1: "CHAPTER nn" (F1 "CHAPTER  1": two places, right-aligned), "FRAME nnnnn" or "TIME M.SS"
//          (the frame and time search screens: EST, in the chapter screen's form; the OM gives the front-panel
//          "Frame 0" and "0.00").
//   row 0, from column 17 (the CLD-1750's right-hand block): the state word with DISPLAY on (OM p.44: PLAY, STILL),
//          or "A > B" while the disc turns (CLD-D925 tour, e.g. 772 s "B > A": the D925's side change indicator).
//   PROGRAM (OM p.74 figure, "Display with a CD or CDV"): rows 1-2 "TOTAL" and the step count at the left, "PROGRAM"
//          and "STEP- n" at the right; rows 3-6 the 24 steps, 6 per row in 3-cell slots ("--" empty), the step being
//          entered marked with the arrow. The figure's total time needs a TOC, which these discs lack: not shown.
//   row 11, ending at column 22: a setting message (OM p.44 words): DIGITAL / ANALOG with STEREO / 1/L / 2/R after
//          AUDIO D/A, PAL / NTSC 3.58 after SYSTEM (placement on the bottom row as the CLD-D925 shows its sound
//          mode: EST for the CLD-1750).
// Numbers are BCD; leading zeros are blank.
module osd_text (
	input             clk,
	input       [1:0] l0_kind,     // 0 none, 1 SEARCH, 2 number (n0, 5 digits), 3 time (n0 = {min 3, sec 2})
	input       [1:0] l1_kind,     // 0 none, 1 CHAPTER n1[7:0], 2 FRAME n1, 3 TIME n1 = {min 3, sec 2}
	input       [1:0] lang,        // LANGUAGE: English, French, German, Italian (OM p.44-45 words)
	input       [3:0] r0_kind,     // 0 none, 1 PLAY, 2 "<from> > <to>", 3 STILL, 4-12 speeds x3 x2 x1 1/2 1/4 1/8
	                               // 1/16 1/30 1/90 (OM p.44, p.68), 13 CLV (the CLV warning, OM p.68)
	input             side_b,      // the side turned from
	input             chap_v,      // DISPLAY: the chapter number, if the disc has them
	input       [7:0] chap,
	input             pg_show,     // the programme screen
	input       [4:0] pg_n,        // steps programmed (0-24)
	input     [191:0] pg_list,     // step k's chapter (BCD) at [8k+7:8k]
	input             pg_pend_v,   // a chapter being keyed in (shown in the next slot)
	input       [7:0] pg_pend,
	input       [4:0] msg,         // row 11: 0 none, 1-6 {DIGITAL, ANALOG} x {STEREO, 1/L, 2/R}, 7 PAL, 8 NTSC 3.58,
	                               // 9 REPEAT MEMORY, 10 REPEAT A-B, 11 REPEAT CHAPTER, 12 REPEAT SIDE -A, 13 -B, 14 REPEAT PROGRAM,
	                               // 15 LAST MEMORY, 16 OUTPUT LEVEL (OM p.44)
	input      [19:0] n0,
	input      [19:0] n1,
	output reg        we,
	output reg  [8:0] addr,
	output reg  [6:0] data
);

reg [4:0] c = 5'd0;               // column 0..23
reg [3:0] r = 4'd0;               // row 0..11

function [6:0] dg(input [3:0] d); dg = 7'h30 + {3'd0, d}; endfunction
function [6:0] ch(input [55:0] s, input [3:0] i);      // character i of an up-to-7-character string
	ch = s[54 - 8 * i -: 7];                            // the low 7 bits of byte i (byte 0 = leftmost)
endfunction

// a 5-digit number right-aligned in 5 cells (k = 0..4), leading zeros blank
function [6:0] num5(input [19:0] v, input [2:0] k);
	reg [3:0] d;
	reg       lead;
	begin
		d = v[19 - 4 * k -: 4];
		lead = (k == 0) ? (v[19:16] == 4'd0) : (k == 1) ? (v[19:12] == 8'd0) : (k == 2) ? (v[19:8] == 12'd0) :
		       (k == 3) ? (v[19:4] == 16'd0) : 1'b0;
		num5 = lead ? 7'h20 : dg(d);
	end
endfunction

// M.SS in 6 cells (k = 0..5): minutes in 3 places (leading zeros blank, the units always shown), '.', seconds
function [6:0] tim(input [19:0] v, input [2:0] k);
	begin
		case (k)
		3'd0: tim = (v[19:16] == 4'd0) ? 7'h20 : dg(v[19:16]);
		3'd1: tim = (v[19:12] == 8'd0) ? 7'h20 : dg(v[15:12]);
		3'd2: tim = dg(v[11:8]);
		3'd3: tim = 7'h2E;
		3'd4: tim = dg(v[7:4]);
		default: tim = dg(v[3:0]);
		endcase
	end
endfunction

// row 11 messages, 16 cells (columns 7-22), right-aligned; the words of OM p.44-45 per language (1/L is 1/G in French
// and 1/S in Italian, 2/R is 2/D in French and Italian)
function [6:0] msgc(input [1:0] lg, input [4:0] m, input [4:0] i);
	reg [127:0] s;
	begin
		case ({lg, m})
		{2'd0, 5'd16}: s = "    OUTPUT LEVEL";
		{2'd1, 5'd16}: s = "NIVEAU DE SORTIE";
		{2'd2, 5'd16}: s = "   AUSGANGSPEGEL";
		{2'd3, 5'd16}: s = "  LIVELLO USCITA";
		{2'd0, 4'd1}, {2'd1, 4'd1}, {2'd2, 4'd1}, {2'd3, 4'd1}: s = "  DIGITAL STEREO";
		{2'd0, 4'd2}, {2'd2, 4'd2}: s = "     DIGITAL 1/L";
		{2'd1, 4'd2}: s = "     DIGITAL 1/G";
		{2'd3, 4'd2}: s = "     DIGITAL 1/S";
		{2'd0, 4'd3}, {2'd2, 4'd3}: s = "     DIGITAL 2/R";
		{2'd1, 4'd3}, {2'd3, 4'd3}: s = "     DIGITAL 2/D";
		{2'd0, 4'd4}, {2'd1, 4'd4}, {2'd2, 4'd4}, {2'd3, 4'd4}: s = "   ANALOG STEREO";
		{2'd0, 4'd5}, {2'd2, 4'd5}: s = "      ANALOG 1/L";
		{2'd1, 4'd5}: s = "      ANALOG 1/G";
		{2'd3, 4'd5}: s = "      ANALOG 1/S";
		{2'd0, 4'd6}, {2'd2, 4'd6}: s = "      ANALOG 2/R";
		{2'd1, 4'd6}, {2'd3, 4'd6}: s = "      ANALOG 2/D";
		{2'd0, 4'd7}, {2'd1, 4'd7}, {2'd2, 4'd7}, {2'd3, 4'd7}: s = "             PAL";
		{2'd0, 4'd8}, {2'd1, 4'd8}, {2'd2, 4'd8}, {2'd3, 4'd8}: s = "       NTSC 3.58";
		{2'd0, 4'd9}: s = "   REPEAT MEMORY";
		{2'd1, 4'd9}: s = "  REPET. MEMOIRE";
		{2'd2, 4'd9}: s = "  WIEDERH SPEICH";
		{2'd3, 4'd9}: s = "  RIPET. MEMORIA";
		{2'd0, 4'd10}: s = "      REPEAT A-B";
		{2'd1, 4'd10}: s = "      REPET. A-B";
		{2'd2, 4'd10}: s = "     WIEDERH A-B";
		{2'd3, 4'd10}: s = "      RIPET. A-B";
		{2'd0, 4'd11}: s = "  REPEAT CHAPTER";
		{2'd1, 4'd11}: s = "    REPET. CHAP.";
		{2'd2, 4'd11}: s = " WIEDERH KAPITEL";
		{2'd3, 4'd11}: s = "      RIPET. CAP";
		{2'd0, 4'd12}: s = "  REPEAT SIDE -A";
		{2'd1, 4'd12}: s = "  REPET. FACE -A";
		{2'd2, 4'd12}: s = "WIEDERH SEITE -A";
		{2'd3, 4'd12}: s = "  RIPET. LATO -A";
		{2'd0, 4'd13}: s = "  REPEAT SIDE -B";
		{2'd1, 4'd13}: s = "  REPET. FACE -B";
		{2'd2, 4'd13}: s = "WIEDERH SEITE -B";
		{2'd3, 4'd13}: s = "  RIPET. LATO -B";
		{2'd0, 4'd14}: s = "  REPEAT PROGRAM";
		{2'd1, 4'd14}: s = "    REPET. PROG.";
		{2'd2, 4'd14}: s = "   WIEDERH PROG.";
		{2'd3, 4'd14}: s = "    RIPET. PROG.";
		{2'd0, 4'd15}: s = "     LAST MEMORY";
		{2'd1, 4'd15}: s = "DERNIERE MEMOIRE";
		{2'd2, 4'd15}: s = "   LETZTE SPEICH";
		{2'd3, 4'd15}: s = "  ULTIMA MEMORIA";
		default: s = "                ";
		endcase
		msgc = s[126 - 8 * i -: 7];
	end
endfunction

// the programme grid: slot = 6 x (row - 3) + column / 3, slot_c = column mod 3 (0 the arrow, 1-2 the chapter)
wire [5:0] slot   = (r - 4'd3) * 6'd6 + c / 5'd3;
wire [1:0] slot_c = c % 5'd3;
wire [7:0] slot_v = pg_list[{slot[4:0], 3'b000} +: 8];
wire [7:0] pg_nb  = (pg_n >= 5'd20) ? {4'd2, pg_n[3:0] - 4'd4} : (pg_n >= 5'd10) ? {4'd1, pg_n[3:0] - 4'd10} : {4'd0, pg_n[3:0]};
wire [4:0] pg_s   = (pg_n == 5'd24) ? 5'd24 : pg_n + 5'd1;          // the step being entered
wire [7:0] pg_sb  = (pg_s >= 5'd20) ? {4'd2, pg_s[3:0] - 4'd4} : (pg_s >= 5'd10) ? {4'd1, pg_s[3:0] - 4'd10} : {4'd0, pg_s[3:0]};

reg [6:0] cc;
always @(*) begin
	cc = 7'h20;
	if (r == 4'd0 && c >= 5'd1 && c <= 5'd9) begin
		if (l0_kind == 2'd1) begin if (c <= 5'd6) cc = ch("SEARCH ", c[3:0] - 4'd1); end
		else if (l0_kind != 2'd0) begin
			if (c == 5'd1) cc = (!chap_v || chap[7:4] == 4'd0) ? 7'h20 : dg(chap[7:4]);
			else if (c == 5'd2) cc = chap_v ? dg(chap[3:0]) : 7'h20;
			else if (c >= 5'd4) cc = (l0_kind == 2'd2) ? ((c <= 5'd8) ? num5(n0, c[2:0] - 3'd4) : 7'h20)
			                                          : tim(n0, c[2:0] - 3'd4);
		end
	end else if (r == 4'd0 && c >= 5'd17 && c <= 5'd23) begin
		case (r0_kind)
		4'd1: cc = ch((lang == 2'd1) ? "LECTURE" : (lang == 2'd2) ? "WIEDERG" : (lang == 2'd3) ? "RIPROD " : "PLAY   ", c[3:0] - 4'd1);
		4'd2: case (c)
		      5'd17: cc = side_b ? "B" : "A";
		      5'd19: cc = ">";                                    // the arrow glyph (font code 0x3E)
		      5'd21: cc = side_b ? "A" : "B";
		      default: ;
		      endcase
		4'd3: cc = ch((lang == 2'd1) ? "IMAGE  " : (lang == 2'd2) ? "STANDB " : (lang == 2'd3) ? "FER-IMM" : "STILL  ", c[3:0] - 4'd1);
		4'd4: cc = ch("x3     ", c[3:0] - 4'd1);
		4'd5: cc = ch("x2     ", c[3:0] - 4'd1);
		4'd6: cc = ch("x1     ", c[3:0] - 4'd1);
		4'd7: cc = ch("1/2    ", c[3:0] - 4'd1);
		4'd8: cc = ch("1/4    ", c[3:0] - 4'd1);
		4'd9: cc = ch("1/8    ", c[3:0] - 4'd1);
		4'd10: cc = ch("1/16   ", c[3:0] - 4'd1);
		4'd11: cc = ch("1/30   ", c[3:0] - 4'd1);
		4'd12: cc = ch("1/90   ", c[3:0] - 4'd1);
		4'd13: cc = ch("CLV    ", c[3:0] - 4'd1);
		default: ;
		endcase
	end else if (r == 4'd1 && c >= 5'd1 && c <= 5'd11) begin
		case (l1_kind)
		2'd1: if (c <= 5'd7) cc = ch("CHAPTER", c[3:0] - 4'd1);
		      else if (c == 5'd9) cc = (n1[7:4] == 4'd0) ? 7'h20 : dg(n1[7:4]);
		      else if (c == 5'd10) cc = dg(n1[3:0]);
		2'd2: if (c <= 5'd5) cc = ch("FRAME  ", c[3:0] - 4'd1);
		      else if (c >= 5'd7) cc = num5(n1, c[2:0] - 3'd7 + 3'd0);
		2'd3: if (c <= 5'd4) cc = ch("TIME   ", c[3:0] - 4'd1);
		      else if (c >= 5'd6) cc = tim(n1, c[2:0] - 3'd6);
		default: ;
		endcase
	end
	if (pg_show) begin
		if (r == 4'd1 && c >= 5'd1 && c <= 5'd5) cc = ch("TOTAL  ", c[3:0] - 4'd1);
		if (r == 4'd2 && c == 5'd1) cc = (pg_nb[7:4] == 4'd0) ? 7'h20 : dg(pg_nb[7:4]);
		if (r == 4'd2 && c == 5'd2) cc = dg(pg_nb[3:0]);
		if (r == 4'd1 && c >= 5'd17 && c <= 5'd23) cc = ch((lang == 2'd0) ? "PROGRAM" : "PROG.  ", c[3:0] - 4'd1);
		if (r == 4'd2 && c >= 5'd17 && c <= 5'd21)
			cc = ch((lang == 2'd1) ? "PAS-   " : (lang == 2'd2) ? "SCHR-  " : (lang == 2'd3) ? "FASE-  " : "STEP-  ", c[3:0] - 4'd1);
		if (r == 4'd2 && c == 5'd22) cc = (pg_sb[7:4] == 4'd0) ? 7'h20 : dg(pg_sb[7:4]);
		if (r == 4'd2 && c == 5'd23) cc = dg(pg_sb[3:0]);
		if (r >= 4'd3 && r <= 4'd6 && c < 5'd18) begin
			if (slot_c == 2'd0) cc = (slot == {1'b0, pg_n} && pg_n != 5'd24) ? ">" : 7'h20;
			else if (slot < {1'b0, pg_n}) cc = (slot_c == 2'd1) ? ((slot_v[7:4] == 4'd0) ? 7'h20 : dg(slot_v[7:4])) : dg(slot_v[3:0]);
			else if (slot == {1'b0, pg_n} && pg_pend_v) cc = (slot_c == 2'd1) ? ((pg_pend[7:4] == 4'd0) ? 7'h20 : dg(pg_pend[7:4])) : dg(pg_pend[3:0]);
			else cc = "-";
		end
	end
	if (r == 4'd11 && msg != 5'd0 && c >= 5'd7 && c <= 5'd22) cc = msgc(lang, msg, c - 5'd7);
	if (cc == 7'h00) cc = 7'h20;
end

always @(posedge clk) begin
	we   <= 1'b1;
	addr <= r * 9'd24 + {4'd0, c};
	data <= cc;
	if (c == 5'd23) begin
		c <= 5'd0;
		r <= (r == 4'd11) ? 4'd0 : r + 4'd1;
	end else c <= c + 5'd1;
end

endmodule
