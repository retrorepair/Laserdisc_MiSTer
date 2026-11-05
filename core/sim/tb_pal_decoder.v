`timescale 1ns/1ps
// Streams one TBC field (field.hex: 313*1135 hex samples) through pal_decoder and dumps
// every active output pixel as "ln x r g b" to rgb_rtl.txt for comparison with
// tools/model/pal_decode_fx.py (core/sim/compare_pal.py).
module tb_pal_decoder;

localparam W = 1135, H = 313;

reg clk = 0;
always #7.048 clk = ~clk;          // ~70.94 MHz

reg  [1:0]  div4 = 0;
wire        ce = (div4 == 2'd0);
always @(posedge clk) div4 <= div4 + 2'd1;

reg  [15:0] mem [0:W*H-1];
reg  [15:0] s;
reg  [10:0] x;
reg   [8:0] ln;
reg         fld;

wire  [7:0] r, g, b;
wire [10:0] xo;
wire  [8:0] lno;
wire        fo;

pal_decoder dut (.clk(clk), .ce(ce), .ntsc(1'b0), .s(s), .x(x), .ln(ln), .fld(fld),
                 .r(r), .g(g), .b(b), .xo(xo), .lno(lno), .fo(fo));

integer fout, idx, flush;
initial begin
	$readmemh("field.hex", mem);
	fout = $fopen("rgb_rtl.txt", "w");
	s = 0; x = 0; ln = 0; fld = 0; idx = 0; flush = 0;
end

// drive one sample per ce; after the field, keep clocking a line of blanking-level samples (field 1)
always @(posedge clk) if (ce) begin
	if (idx < W*H) begin
		s   <= mem[idx];
		x   <= idx % W;
		ln  <= idx / W;
		fld <= 1'b0;
		idx <= idx + 1;
	end else begin
		s   <= 16'd14442;
		x   <= flush % W;
		ln  <= 9'd0;
		fld <= 1'b1;
		flush <= flush + 1;
		if (flush == 50) begin $fclose(fout); $finish; end
	end
end

always @(posedge clk) if (ce) begin
	if (fo == 1'b0 && xo >= 185 && xo < 1107 && idx > 20)
		$fwrite(fout, "%0d %0d %0d %0d %0d\n", lno, xo, r, g, b);
end

endmodule
