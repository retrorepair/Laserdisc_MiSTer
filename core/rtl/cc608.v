// Closed-caption decoder box (menu option): a model of an external line-21 caption decoder between the player and
// the TV, not a player feature (the CLD-1750 has none). The user's reference is a UK deaf-institute decoder of about
// 1995 showing white text on black boxes; NCI/Sanyo TeleCaption decoders are the period US equivalents.
//
// Standards: EIA-608 line 21 caption data (field 1, data channel 1 = CC1) and the decoder rules of 47 CFR 15.119
// (which were written from NCI's TeleCaption II Decoder Module Performance Specification, 1985):
//   - line 21 of field 1: 7 cycles of clock run-in, two 0 bits, a start bit, then 16 data bits LSB first at 32 x fH
//     (503 kHz, 28.44 samples at 4fsc), two 7-bit characters with odd parity;
//   - caption modes pop-on (RCL ... EOC), roll-up (RU2/RU3/RU4, CR) and paint-on (RDC); EDM / ENM erase the displayed /
//     non-displayed memory; BS, DER; preamble address codes set row (1-15), indent (multiples of 4) and underline;
//     mid-row codes insert a space and set underline; tab offsets; the 16 special characters; control codes are sent
//     twice and the repeat is ignored; a character with a parity error shows as a solid block;
//   - 15 rows of 32 columns inside the safe title area, each row 13 field lines (26 frame lines).
// The 608 extended characters (two-byte, 608-B) post-date a 1995 decoder: their fallback character stays, as on such
// a decoder. Text mode (TR/RTD) is not shown. All text is white (the user's reference box); colour and italics
// attributes are not drawn, underline is. The 5x7 font is an approximation (tools/cc/gen_cc_font.py, user-approved).
module cc608 #(
	parameter FONT_HEX = "rtl/cc_font.hex"
) (
	input             clk,
	input             ce,          // 4fsc
	input             enable,      // menu: the decoder box is connected
	input             ntsc,        // line 21 captions are an NTSC (525-line) signal

	input      [15:0] s,           // replayed composite (16-bit TBC levels), with its position
	input      [10:0] x,
	input       [8:0] ln,
	input             fld,

	output reg  [1:0] cls          // two ce after (x, ln, fld), as osd_m50552: 0 none, 1 caption text, 2 black box
);

// ------------------------------------------------------------------ line 21 data slicer (field 1)
localparam [8:0] LN21 = 9'd20;     // stored line index of line 21 (index 0 = line 1)
wire        l21 = enable && ntsc && !fld && ln == LN21;
reg  [15:0] mx, mn, th;
reg  [10:0] e;                     // the start bit's leading edge
reg         got_e, low_run;
reg   [5:0] low_n;
reg  [15:0] sh;                    // data bits, LSB first
reg   [4:0] nb;
reg  [15:0] pos;                   // next bit centre, 1/16 sample
reg         pair_v;                // a pair is ready (one per frame)
reg  [15:0] pair;
always @(posedge clk) begin
	pair_v <= 1'b0;
	if (ce) begin
		if (l21) begin
			if (x == 11'd150) begin mx <= s; mn <= s; got_e <= 1'b0; low_n <= 6'd0; nb <= 5'd0; end
			else if (x > 11'd150 && x < 11'd330) begin
				if (s > mx) mx <= s;
				if (s < mn) mn <= s;
			end
			if (x == 11'd330) th <= mn + ((mx - mn) >> 1);
			if (x > 11'd330 && !got_e) begin
				if (s < th) begin if (low_n != 6'd63) low_n <= low_n + 6'd1; end
				else if (low_n >= 6'd40 && (mx - mn) > 16'd5000) begin    // after the two 0 bits; a real run-in
					got_e <= 1'b1; e <= x; pos <= {x, 4'd0} + 16'd683;     // first data bit: 1.5 bits on
				end else low_n <= 6'd0;
			end
			if (got_e && nb != 5'd16 && {x, 4'd0} >= pos) begin
				sh <= {s >= th, sh[15:1]};
				nb <= nb + 5'd1;
				pos <= pos + 16'd455;                                      // 28.44 samples
			end
		end else if (ln == LN21 + 9'd1 && x == 11'd0 && !fld && got_e && nb == 5'd16) begin
			pair_v <= 1'b1; pair <= sh; got_e <= 1'b0;
		end
	end
end

// ------------------------------------------------------------------ caption memory: 2 pages x 15 rows x 32 columns
// cell: {underline, character}; character 0 = empty (no box), 0x89 = transparent space (no box)
reg  [8:0] mem [0:1023];
reg  [9:0] wa, ra2;
reg  [8:0] wd, rq2;
reg        we;
always @(posedge clk) begin
	if (we) mem[wa] <= wd;
	rq2 <= mem[ra2];
end

// ------------------------------------------------------------------ EIA-608 decoder
wire [7:0] b1 = pair[7:0], b2 = pair[15:8];
wire       p1 = ^b1, p2 = ^b2;                                    // odd parity: 1 when good
wire [6:0] c1 = b1[6:0], c2 = b2[6:0];
localparam M_NONE = 2'd0, M_POP = 2'd1, M_ROLL = 2'd2, M_PAINT = 2'd3;
reg  [1:0] mode;
reg        dpage;                     // page on screen
reg        ch2;                       // data channel 2 selected: its characters are not ours
reg        textm;                     // text mode (TR/RTD): characters not shown
reg [13:0] last_ctl;
reg  [3:0] row;                       // 0..14
reg  [4:0] col;
reg  [2:0] depth;                     // roll-up rows
reg        ul;
// work queue: up to two characters, then sequencer operations
reg  [6:0] q_c [0:1];
reg  [1:0] q_n;
reg  [2:0] op;                        // sequencer: 0 idle, 1 clear page, 2 scroll window, 3 clear to end of row
reg        op_pg;
reg  [8:0] op_i;
reg  [4:0] op_c;
reg  [3:0] op_r;
reg  [1:0] op_ph;
wire       tgt_pg = (mode == M_POP) ? !dpage : dpage;
// PAC rows (608): b1 & 7, b2 bit 5
function [3:0] pac_row(input [2:0] a, input hi);
	case (a)
	3'd1: pac_row = hi ? 4'd1 : 4'd0;
	3'd2: pac_row = hi ? 4'd3 : 4'd2;
	3'd5: pac_row = hi ? 4'd5 : 4'd4;
	3'd6: pac_row = hi ? 4'd7 : 4'd6;
	3'd7: pac_row = hi ? 4'd9 : 4'd8;
	3'd0: pac_row = 4'd10;
	3'd3: pac_row = hi ? 4'd12 : 4'd11;
	default: pac_row = hi ? 4'd14 : 4'd13;
	endcase
endfunction

reg pend_v;
reg en_d = 1'b0;
always @(posedge clk) begin
	we <= 1'b0;
	en_d <= enable;
	if (pair_v) pend_v <= 1'b1;
	if (!enable || !en_d) begin                         // off, or just switched on: start clean
		mode <= M_NONE; dpage <= 1'b0; op <= 3'd1; op_pg <= 1'b0; op_i <= 9'd0; op_c <= 5'd1; q_n <= 2'd0; pend_v <= 1'b0;
		ch2 <= 1'b0; textm <= 1'b0; last_ctl <= 14'd0; row <= 4'd14; col <= 5'd0; depth <= 3'd2; ul <= 1'b0;
	end else if (op != 3'd0) begin
		case (op)
		3'd1: begin                                    // clear a page (480 cells)
			we <= 1'b1; wa <= {op_pg, op_i}; wd <= 9'd0;
			if (op_i == 9'd479) begin
				if (op_pg == 1'b0 && op_c == 5'd1) begin op_pg <= 1'b1; op_i <= 9'd0; op_c <= 5'd0; end   // both
				else op <= 3'd0;
			end else op_i <= op_i + 9'd1;
		end
		3'd2: begin                                    // roll-up CR: rows base-depth+1 .. base-1 <- next row
			if (op_ph == 2'd0) begin ra2 <= {dpage, op_r + 4'd1, op_c}; op_ph <= 2'd1; end
			else if (op_ph == 2'd1) op_ph <= 2'd2;                  // rq2 is valid from the next clock
			else begin
				we <= 1'b1; wa <= {dpage, op_r, op_c}; wd <= rq2; op_ph <= 2'd0;
				if (op_c == 5'd31) begin
					op_c <= 5'd0;
					if (op_r + 4'd1 == row) begin op <= 3'd3; op_c <= 5'd0; op_pg <= dpage; end   // then clear base
					else op_r <= op_r + 4'd1;
				end else op_c <= op_c + 5'd1;
			end
		end
		3'd3: begin                                    // clear the current row from op_c on
			we <= 1'b1; wa <= {op_pg, row, op_c}; wd <= 9'd0;
			if (op_c == 5'd31) op <= 3'd0; else op_c <= op_c + 5'd1;
		end
		default: op <= 3'd0;
		endcase
	end else if (q_n != 2'd0) begin                      // write the queued characters
		if (!textm && !ch2 && mode != M_NONE) begin
			we <= 1'b1; wa <= {tgt_pg, row, col}; wd <= {ul, 1'b0, q_c[0]};
			if (col != 5'd31) col <= col + 5'd1;
		end
		q_c[0] <= q_c[1]; q_n <= q_n - 2'd1;
	end else if (pend_v) begin
		pend_v <= 1'b0;
		if (c1 >= 7'h10 && c1 <= 7'h1F && p1 && p2) begin
			// control codes come twice: the repeat is ignored
			if ({c1, c2} == last_ctl) last_ctl <= 14'd0;
			else begin
				last_ctl <= {c1, c2};
				ch2 <= c1[3];
				if (!c1[3]) begin
					if (c2 >= 7'h40) begin                                   // preamble address code
						row <= pac_row(c1[2:0], c2[5]);
						col <= c2[4] ? {c2[3:1], 2'b00} : 5'd0;
						ul <= c2[0];
						textm <= 1'b0;
					end else if (c1[2:0] == 3'd4 && c2[6:4] == 3'd2) begin   // miscellaneous control (0x14 0x2x)
						case (c2[3:0])
						4'h0: begin mode <= M_POP; textm <= 1'b0; end         // RCL
						4'h1: if (col != 5'd0) begin                          // BS
							col <= col - 5'd1;
							we <= 1'b1; wa <= {tgt_pg, row, col - 5'd1}; wd <= 9'd0;
						end
						4'h4: begin op <= 3'd3; op_c <= col; op_pg <= tgt_pg; end   // DER
						4'h5, 4'h6, 4'h7: begin                                // RU2 / RU3 / RU4
							if (mode != M_ROLL) begin op <= 3'd1; op_pg <= 1'b0; op_i <= 9'd0; op_c <= 5'd1; end
							mode <= M_ROLL; depth <= c2[2:0] - 3'd3; col <= 5'd0; textm <= 1'b0;
						end
						4'h9: begin mode <= M_PAINT; textm <= 1'b0; end        // RDC
						4'hA, 4'hB: textm <= 1'b1;                              // TR, RTD: text service
						4'hC: begin op <= 3'd1; op_pg <= dpage; op_i <= 9'd0; op_c <= 5'd0; end    // EDM
						4'hD: if (mode == M_ROLL) begin                         // CR
							col <= 5'd0;
							if (depth > 3'd1 && row >= {1'b0, depth} - 4'd1) begin
								op <= 3'd2; op_r <= row - {1'b0, depth} + 4'd1; op_c <= 5'd0; op_ph <= 2'd0;
							end else begin op <= 3'd3; op_c <= 5'd0; op_pg <= dpage; end
						end
						4'hE: begin op <= 3'd1; op_pg <= !dpage; op_i <= 9'd0; op_c <= 5'd0; end  // ENM
						4'hF: begin dpage <= !dpage; mode <= M_POP; end       // EOC
						default: ;                                              // AOF, AON, FON
						endcase
					end else if (c1[2:0] == 3'd7 && c2 >= 7'h21 && c2 <= 7'h23) begin   // tab offset
						col <= (col + c2[1:0] > 5'd31) ? 5'd31 : col + c2[1:0];
					end else if (c1[2:0] == 3'd1 && c2[6:4] == 3'd2) begin   // mid-row code: a space, underline
						ul <= c2[0]; q_c[0] <= 7'h20; q_n <= 2'd1;
					end else if (c1[2:0] == 3'd1 && c2[6:4] == 3'd3) begin   // special character
						if (!textm && mode != M_NONE) begin
							we <= 1'b1; wa <= {tgt_pg, row, col}; wd <= {ul, 4'h8, c2[3:0]};
							if (col != 5'd31) col <= col + 5'd1;
						end
					end
				end
			end
		end else if (c1 >= 7'h20 || c2 >= 7'h20) begin                   // characters
			last_ctl <= 14'd0;
			if (c1 >= 7'h20) begin
				q_c[0] <= p1 ? c1 : 7'h7F;                                  // parity error: solid block
				if (c2 >= 7'h20) begin q_c[1] <= p2 ? c2 : 7'h7F; q_n <= 2'd2; end
				else q_n <= 2'd1;
			end else begin q_c[0] <= p2 ? c2 : 7'h7F; q_n <= 2'd1; end
		end
	end
end

// ------------------------------------------------------------------ renderer
// rows from field line 43 (15 x 13 = 195 lines centred in 20-261), columns 18 samples from 226 (32 x 18 centred in
// 134-893); in a cell: glyph dots 3 samples wide from x 1, glyph rows 1 field line each from line 1, 10 rows; an
// underline on line 11; the black box is the whole cell. Stages from the sample's ce (k): k+1 cell, k+2 memory
// address, k+3 memory read, k+4 character, k+5 font read, k+6 decision; cls at ce k+8 (as osd_m50552's 2 ce).
reg  [8:0] font_rom [0:4095];
initial $readmemh(FONT_HEX, font_rom);
reg  [5:0] st;                                // st[i]: stage i+1
reg [10:0] rx;
reg  [8:0] rl;
reg        in_v, in_v2, in_v3;
reg  [3:0] rr, cl, cl2, cl3, gl;
reg  [4:0] rc, cx;
reg  [2:0] dot, dot3;
reg  [9:0] ra_r;
reg  [8:0] r_q;
reg  [7:0] ch_q;
reg        ul_q, box_q;
reg  [4:0] f_q;
reg  [1:0] c1r;
wire [8:0]  v  = rl - 9'd43;
wire [21:0] vq = v * 13'd5042;                // v / 13 for v < 195
wire [10:0] h  = rx - 11'd226;
wire [22:0] hq = h * 12'd3641;                // h / 18 for h < 576
always @(posedge clk) begin
	st <= {st[4:0], ce};
	if (ce) begin rx <= x; rl <= ln; cls <= c1r; end
	if (st[0]) begin                          // k+1: the cell and the position in it
		in_v <= enable && ntsc && rl >= 9'd43 && rl < 9'd238 && rx >= 11'd226 && rx < 11'd802;
		rr <= vq[19:16]; rc <= hq[20:16];
		cl <= v[3:0] - vq[19:16] * 4'd13;     // low bits suffice: the remainder is < 13
		cx <= h[4:0] - hq[20:16] * 5'd18;     // < 18
	end
	if (st[1]) begin                          // k+2: the memory address, the dot
		ra_r <= {dpage, rr, rc};
		dot <= (cx >= 5'd1 && cx < 5'd16) ? (cx - 5'd1) / 5'd3 : 3'd7;
		in_v2 <= in_v; cl2 <= cl;
	end
	r_q <= mem[ra_r];                         // k+3
	if (st[3]) begin                          // k+4: the character
		ch_q <= r_q[7:0]; ul_q <= r_q[8];
		box_q <= r_q[7:0] != 8'd0 && r_q[7:0] != 8'h89;
		gl <= cl2 - 4'd1; cl3 <= cl2; dot3 <= dot; in_v3 <= in_v2;
	end
	f_q <= font_rom[{ch_q, gl}][4:0];         // k+5
	if (st[5]) begin                          // k+6: the decision
		if (!in_v3 || !box_q) c1r <= 2'd0;
		else if (cl3 >= 4'd1 && cl3 <= 4'd10 && dot3 != 3'd7 && f_q[3'd4 - dot3]) c1r <= 2'd1;
		else if (cl3 == 4'd11 && ul_q && dot3 != 3'd7) c1r <= 2'd1;              // underline
		else c1r <= 2'd2;
	end
end

endmodule
