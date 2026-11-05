// tb_osd_text: render osd_text.v's layouts into text (rows 0-1)
`timescale 1ns/1ps
module tb_osd_text;
reg clk = 0; always #5 clk = ~clk;
reg [1:0] l0, l1; reg [3:0] r0; reg sb; reg [4:0] msg = 0; reg pgs = 0; reg [19:0] n0, n1;
wire we; wire [8:0] a; wire [6:0] d;
osd_text u (.clk(clk), .lang(2'd0), .l0_kind(l0), .l1_kind(l1), .r0_kind(r0), .side_b(sb), .chap_v(1'b1), .chap(8'h03), .msg(msg), .pg_show(pgs), .pg_n(5'd3), .pg_list({168'd0, 8'h03, 8'h12, 8'h05}), .pg_pend_v(1'b1), .pg_pend(8'h07), .n0(n0), .n1(n1), .we(we), .addr(a), .data(d));
reg [7:0] scr [0:287];

always @(posedge clk) if (we && a < 288) scr[a] <= {1'b0, d};
task show(input [127:0] name);
	integer r, c; reg [8*24-1:0] s;
	begin
		repeat (600) @(posedge clk);
		for (r = 0; r < 12; r = r + ((r == 6) ? 5 : 1)) begin
			s = "";
			for (c = 0; c < 24; c = c + 1) s = {s, scr[r * 24 + c]};
			$display("%0s row %0d: |%s|", name, r, s);
		end
	end
endtask
initial begin
	l0 = 1; l1 = 1; r0 = 0; sb = 0; n0 = 0; n1 = 20'h00001; show("chapter 1");
	n1 = 20'h00015; show("chapter 15");
	l1 = 2; n1 = 20'h12345; show("frame");
	l1 = 3; n1 = 20'h01234; show("time");
	l0 = 2; l1 = 0; r0 = 1; n0 = 20'h01841; show("display CAV");
	l0 = 3; n0 = 20'h00134; sb = 1; show("display CLV");
	l0 = 0; r0 = 2; sb = 0; show("turn A>B");
	l0 = 3; r0 = 3; msg = 4; n0 = 20'h01249; show("display+msg");
	l0 = 0; r0 = 1; msg = 0; l1 = 0; pgs = 1; show("program");
	$finish;
end
endmodule
