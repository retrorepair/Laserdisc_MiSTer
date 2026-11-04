`timescale 1ns/1ps
// Composite reconstruction filter (Laserdisc_MiSTer.sv cv_interp) on its own: a step and a 4.43 MHz burst through it.
module tb_interp;
reg clk = 0; always #7.048 clk = ~clk;
reg [1:0] div = 0; always @(posedge clk) div <= div + 2'd1;
wire ce_4fsc = div == 2'd0;
reg [7:0] cv_out = 68;
`include "interp_inc.sv"
integer n = 0, f;
initial f = $fopen("interp.txt", "w");
always @(posedge clk) begin
	if (ce_4fsc) begin
		n <= n + 1;
		// 40 samples blank, 40 white, then a burst-like 4fsc/4 sine of amplitude 20 around 100
		cv_out <= (n < 40) ? 8'd68 : (n < 80) ? 8'd255 : (n[1:0] == 0) ? 8'd120 : (n[1:0] == 2) ? 8'd80 : 8'd100;
	end
	$fwrite(f, "%0d %0d\n", cv_out, cv_hi);
	if (n == 140) begin $fclose(f); $finish; end
end
endmodule
