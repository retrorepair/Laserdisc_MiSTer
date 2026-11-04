// TBC replay timing: one sample per ce, 1135 samples per line, fields of 313 then 312 lines; fld = 0 is the first field.
// Measured on the Community North TBC (isFirstField fields): the first field's 313 stored lines are PAL lines 1-313,
// its last line carrying line 313's equalising pulse and the start of the second field's broad pulses; the second
// field's lines 0-311 are PAL 314-625 and its stored line 312 is padding (a copy of the next frame's line 1).
module tbc_timing (
	input             clk,
	input             ce,
	input             run,          // hold at origin while 0 (reader prefill)

	output reg [10:0] x,
	output reg  [8:0] ln,
	output reg        fld,
	output reg        line_start    // one ce-cycle pulse when x == 0 (any line)
);

localparam [10:0] W = 11'd1135;

always @(posedge clk) if (ce) begin
	line_start <= 1'b0;
	if (!run) begin
		x <= 11'd0; ln <= 9'd0; fld <= 1'b0;
	end else if (x == W - 11'd1) begin
		x <= 11'd0;
		line_start <= 1'b1;
		if (ln == (fld ? 9'd311 : 9'd312)) begin
			ln <= 9'd0;
			fld <= ~fld;
		end else begin
			ln <= ln + 9'd1;
		end
	end else begin
		x <= x + 11'd1;
	end
end

endmodule
