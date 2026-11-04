`timescale 1ns/1ps
// ld_status on Community North's two programme status codes, a code with bad parity, and frames with none.
module tb_ld_status;
reg clk = 0; always #5 clk = ~clk;
reg reset = 1, new_pic = 0; reg [127:0] vbi = 0;
wire squelch, cx;
ld_status dut (.clk(clk), .reset(reset), .new_pic(new_pic), .vbi(vbi), .squelch(squelch), .cx(cx));
integer errors = 0;
task show(input [23:0] l16, input [23:0] l329, input exp_sq, input [8*24-1:0] what);
	begin
		@(posedge clk) begin vbi <= {32'd0, 8'd0, l329, 32'h00F00180, 8'd0, l16}; new_pic <= 1; end
		@(posedge clk) new_pic <= 0;
		@(posedge clk);
		$display("%0s: squelch %0d cx %0d", what, squelch, cx);
		if (squelch !== exp_sq) errors = errors + 1;
	end
endtask
initial begin
	repeat (3) @(posedge clk); reset = 0;
	show(24'h000000, 24'h000000, 0, "no code yet");
	show(24'h8BA41F, 24'h8BA41F, 0, "8BA41F mono");
	show(24'h8BA426, 24'h8BA426, 1, "8BA426 status 2");
	show(24'h000000, 24'h000000, 1, "no code: held");
	show(24'h8BA427, 24'h000000, 1, "bad parity: held");
	show(24'h000000, 24'h8BA41F, 0, "field 2 only, mono");
	if (errors == 0) $display("PASS"); else $display("FAIL: %0d", errors);
	$finish;
end
endmodule
