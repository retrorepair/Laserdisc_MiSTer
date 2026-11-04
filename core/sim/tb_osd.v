`timescale 1ns/1ps
// field.hex -> osd_m50552 -> pal_decoder (as in the core); dumps the OSD's mixed samples
// "ln x s" over the active window to osd_rtl.txt for comparison with tools/osd/osd_fx.py.
module tb_osd;
localparam W = 1135, H = 313;
reg clk = 0; always #7.048 clk = ~clk;
reg [1:0] div4 = 0; always @(posedge clk) div4 <= div4 + 2'd1;
wire ce = (div4 == 2'd0);
reg [15:0] mem [0:W*H-1];
reg [15:0] s; reg [10:0] x; reg [8:0] ln; reg fld;
wire [15:0] os; wire [10:0] ox; wire [8:0] oln; wire of;
wire signed [26:0] br, bi; wire col, inv;
wire [7:0] r, g, b; wire [10:0] xo; wire [8:0] lno; wire fo;
osd_m50552 #(.FONT_HEX("../rtl/osd_font.hex"), .SCREEN_HEX("../rtl/osd_screens.hex")) osd (
	.clk(clk), .ce(ce), .s_in(s), .x(x), .ln(ln), .fld(fld), .screen(3'd3), .bg(2'd1), .pic_off(1'b0),
	.br(br), .bi(bi), .col(col), .inv(inv), .s_out(os), .xo(ox), .lno(oln), .fo(of));
pal_decoder dec (.clk(clk), .ce(ce), .s(os), .x(ox), .ln(oln), .fld(of), .r(r), .g(g), .b(b),
	.xo(xo), .lno(lno), .fo(fo), .burst_r(br), .burst_i(bi), .line_col(col), .line_inv(inv));
integer fout, idx;
initial begin $readmemh("field.hex", mem); fout = $fopen("osd_rtl.txt", "w"); idx = 0; s = 0; x = 0; ln = 0; fld = 0; end
always @(posedge clk) if (ce) begin
	if (idx < W*H) begin s <= mem[idx]; x <= idx % W; ln <= idx / W; fld <= 0; idx <= idx + 1; end
	else begin $fclose(fout); $finish; end
end
always @(posedge clk) if (ce && idx > 4 && oln >= 22 && oln < 310 && ox >= 185 && ox < 1107)
	$fwrite(fout, "%0d %0d %0d\n", oln, ox, os);
endmodule
