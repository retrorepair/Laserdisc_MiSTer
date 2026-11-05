// tb_modpal: core/rtl/modpal.v against its bit-exact model (tools/analysis/modpal_ref.py) on GGV1069 NTSC lines.
// Vectors: tools/analysis/modpal_vectors.py (modpal_in.hex: x n adv per 4fsc sample; modpal_out.hex: expected out).
`timescale 1ns/1ps
module tb_modpal;
localparam N = 20020;
reg clk = 0;
always #8.73 clk = ~clk;                  // 57.27 MHz
reg  [23:0] vin  [0:N-1];
reg   [7:0] vexp [0:N-1];
reg  [7:0] x;
reg [10:0] n;
reg  [2:0] adv;
initial begin
	$readmemh("modpal_in.hex", vin);
	$readmemh("modpal_out.hex", vexp);
	{x, n, adv} = {vin[0][23:16], vin[0][14:4], vin[0][2:0]};   // the first ce takes vector 0
end
reg  [1:0] cnt = 0;
wire       ce = (cnt == 0);
always @(posedge clk) cnt <= cnt + 1'd1;
wire [7:0] out;
modpal #(.SIN_HEX("../rtl/modpal_sin.hex")) dut (.clk(clk), .ce(ce), .x(x), .n(n), .adv(adv), .out(out));
integer i = 0, errs = 0, checked = 0;
always @(posedge clk) if (ce) begin
	// the DUT takes vector i at ce i and has its result out just after ce i+1: out now holds sample i-2's
	if (i >= 912 && i - 2 < N) begin
		checked = checked + 1;
		if (out !== vexp[i - 2]) begin
			if (errs < 10) $display("sample %0d (n %0d): out %0d, expected %0d", i - 2, vin[i - 2][15:4], out, vexp[i - 2]);
			errs = errs + 1;
		end
	end
	if (i + 1 < N) {x, n, adv} <= {vin[i + 1][23:16], vin[i + 1][14:4], vin[i + 1][2:0]};
	if (i == N + 1) begin
		$display("%0d samples checked, %0d errors", checked, errs);
		if (errs) $display("FAIL"); else $display("PASS");
		$finish;
	end
	i = i + 1;
end
endmodule
