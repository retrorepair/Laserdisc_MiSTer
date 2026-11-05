// TBC replay timing: one sample per ce. PAL: 1135 samples per line, fields of 313 then 312 lines. NTSC: 910 samples,
// fields of 263 then 262 (the GGV1069 TBC has the same layout: the first field's stored line 262 is a half line, the
// second field's is padding). fld = 0 is the first field.
// Measured on the Community North TBC (isFirstField fields): the first field's 313 stored lines are PAL lines 1-313,
// its last line carrying line 313's equalising pulse and the start of the second field's broad pulses; the second
// field's lines 0-311 are PAL 314-625 and its stored line 312 is padding (a copy of the next frame's line 1).
//
// Picture-on (vjump): the player's TBC keeps horizontal timing continuous when its output switches from its own raster
// to the disc, since both are locked to the reference H; only the vertical phase changes, by however far the disc's
// field start is from the raster's. A TV's vertical oscillator then misses the new field start (outside its sync
// window), free-runs at its own slightly longer period and rolls the picture up until it re-locks. Measured on F1
// (CLD-1750, 305.44-305.57 s): the disc's VBI lines first appear at about 85% of the screen height, then roll up about
// 14% per field and lock in about 6 fields. So on vjump the field-line counter jumps at the end of the current line to
// JUMP_LN, making that field JUMP_SHORT lines short: the next field start (the disc's) comes about 265 lines after the
// last, at 85% of the TV's scan. x runs on unchanged. (One measurement: the real offset depends on where the disc's
// field start happens to fall.)
module tbc_timing #(
	parameter [8:0] JUMP_LN   = 9'd48,  // PAL: 313 - 48 = 265 lines from this field's start to the next (85%)
	parameter [8:0] JUMP_LN_N = 9'd40   // NTSC: 263 - 40 = 223 lines (85% of 262.5)
) (
	input             clk,
	input             ce,
	input             ntsc,         // 525-line timing (constant while running: a change restarts the core)
	input             run,          // hold at origin while 0 (reader prefill)
	input             vjump,        // pulse: picture on (see above)

	output reg [10:0] x,
	output reg  [8:0] ln,
	output reg        fld,
	output reg        line_start    // one ce-cycle pulse when x == 0 (any line)
);

wire [10:0] W = ntsc ? 11'd910 : 11'd1135;

reg jump_armed;
always @(posedge clk) begin
	if (vjump) jump_armed <= 1'b1;
	if (ce) begin
	line_start <= 1'b0;
	if (!run) begin
		x <= 11'd0; ln <= 9'd0; fld <= 1'b0;
	end else if (x == W - 11'd1) begin
		x <= 11'd0;
		line_start <= 1'b1;
		if (jump_armed && !vjump) begin
			ln <= ntsc ? JUMP_LN_N : JUMP_LN;
			jump_armed <= 1'b0;
		end else if (ln == (ntsc ? (fld ? 9'd261 : 9'd262) : (fld ? 9'd311 : 9'd312))) begin
			ln <= 9'd0;
			fld <= ~fld;
		end else begin
			ln <= ln + 9'd1;
		end
	end else begin
		x <= x + 11'd1;
	end
	end
end

initial jump_armed = 1'b0;

endmodule
