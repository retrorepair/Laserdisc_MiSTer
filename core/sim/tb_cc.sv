// tb_cc: the caption decoder box (cc608.v) on EIA-608 line 21 waveforms built to the standard: 7 cycles of 503 kHz
// clock run-in from 10.5 us after sync, two 0 bits, a start bit, two 7-bit+odd-parity bytes LSB first at 32 x fH,
// 50 IRE high (NTSC TBC levels: blanking 15360, 358.4 per IRE). Checks the caption memory and prints a rendered row.
`timescale 1ns/1ps
module tb_cc;
reg clk = 0; always #8.73 clk = ~clk;
reg [1:0] cnt = 0; wire ce = cnt == 0; always @(posedge clk) cnt <= cnt + 1'd1;
reg [10:0] x = 0; reg [8:0] ln = 0; reg fld = 0;
reg [15:0] s = 15360;
reg [15:0] pair = 0;                   // {byte2, byte1} with parity, sent on the next line 21 of field 1
wire [1:0] cls;
cc608 #(.FONT_HEX("../rtl/cc_font.hex")) dut (.clk(clk), .ce(ce), .enable(1'b1), .ntsc(1'b1), .s(s), .x(x), .ln(ln), .fld(fld), .cls(cls));

function [7:0] par(input [6:0] c); par = {~^c, c}; endfunction   // odd parity in bit 7
// the line 21 waveform at sample x
function [15:0] l21(input [10:0] xx, input [15:0] p);
	real t, ph; integer bit_i; reg b;
	begin
		t = xx;
		if (t >= 150.0 && t < 349.1) begin                               // run-in: 7 cycles
			ph = (t - 150.0) / 28.444 * 3.14159265 * 2.0;
			l21 = 15360 + 8960 - $rtoi(8960.0 * $cos(ph));
		end else if (t >= 349.1 && t < 349.1 + 19.0 * 28.444) begin
			bit_i = $rtoi((t - 349.1) / 28.444);
			if (bit_i < 2) b = 0; else if (bit_i == 2) b = 1; else b = p[bit_i - 3];
			l21 = b ? 16'd33280 : 16'd15360;
		end else l21 = 15360;
	end
endfunction
// NTSC timing: 910 samples, fields of 263 / 262 lines
always @(posedge clk) if (ce) begin
	if (x == 909) begin
		x <= 0;
		if (ln == (fld ? 261 : 262)) begin ln <= 0; fld <= !fld; end else ln <= ln + 1;
	end else x <= x + 1;
	s <= (!fld && ln == 20) ? l21(x, pair) : 16'd15360;
end

// send pairs one frame each (after field 1's line 21 has passed)
task send(input [6:0] a, input [6:0] b);
	begin
		@(posedge clk iff (ce && !fld && ln == 19 && x == 0));
		pair = {par(b), par(a)};
		@(posedge clk iff (ce && !fld && ln == 22 && x == 0));
	end
endtask
task ctl(input [6:0] a, input [6:0] b); begin send(a, b); send(a, b); end endtask   // controls are sent twice
task null_pair; send(7'h00, 7'h00); endtask

function [8*32-1:0] rowtext(input pg, input [3:0] r);
	integer c; reg [8:0] v;
	begin
		rowtext = "";
		for (c = 0; c < 32; c = c + 1) begin
			v = dut.mem[{pg, r, c[4:0]}];
			rowtext = {rowtext, (v[7:0] == 0) ? "." : v[7:0]};
		end
	end
endfunction

integer errs = 0;
task expect_row(input [8*32-1:0] want, input [3:0] r);
	reg [8*32-1:0] got;
	begin
		got = rowtext(dut.dpage, r);
		$display("row %0d: |%s| %s", r + 1, got, got == want ? "ok" : "WRONG");
		if (got != want) errs = errs + 1;
	end
endtask

integer i, k, line;
reg [8*192-1:0] art;
reg cap = 0;
reg [1:0] img [0:262][0:909];
reg [10:0] x1, x2; reg [8:0] l1, l2; reg f1, f2;
always @(posedge clk) if (ce) begin
	x1 <= x; x2 <= x1; l1 <= ln; l2 <= l1; f1 <= fld; f2 <= f1;
	if (cap && !f2) img[l2][x2] <= cls;           // cls is 2 ce after its position
end
initial begin
	repeat (4 * 910 * 600) @(posedge clk);       // the memory clears when enabled
	// pop-on: RCL, ENM, PAC row 15 (0x14 0x60: white, column 0), HELLO!, EOC
	ctl(7'h14, 7'h20); ctl(7'h14, 7'h2E); ctl(7'h14, 7'h60);
	send("H", "E"); send("L", "L"); send("O", "!");
	null_pair;
	expect_row("................................", 4'd14);   // not shown before EOC
	ctl(7'h14, 7'h2F);
	null_pair;
	expect_row("HELLO!..........................", 4'd14);
	// roll-up, 2 rows: RU2, PAC row 15 indent 8 (0x14 0x74), AB, CR, CD
	ctl(7'h14, 7'h25); ctl(7'h14, 7'h74);
	send("A", "B"); ctl(7'h14, 7'h2D); send("C", "D");
	null_pair; null_pair;
	expect_row("........AB......................", 4'd13);
	expect_row("CD..............................", 4'd14);
	// the rendered rows 14-15 (field 1 lines 212-237), columns 0-7: one character per 3 samples, # text, - box
	cap = 1;
	@(posedge clk iff (ce && !fld && ln == 240 && x == 0));
	cap = 0;
	for (line = 212; line < 238; line = line + 1) begin
		art = "";
		for (k = 0; k < 48; k = k + 1) art = {art, (img[line][226 + 3 * k] == 2'd1) ? "#" : (img[line][226 + 3 * k] == 2'd2) ? "-" : " "};
		$display("%3d %s", line, art[8*48-1:0]);
	end
	$display("%0d errors", errs);
	if (errs) $display("FAIL"); else $display("PASS");
	$finish;
end
endmodule
