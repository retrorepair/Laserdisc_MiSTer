`timescale 1ns/1ps
// tbc_timing + tbc_reader against a behavioural DDRAM model holding a synthetic pattern:
// sample value = (field*7 + line*3 + x) & 0xFFFF. Checks every served sample for
// two fields of a 4-field image, with random busy and a 20-cycle read latency.
module tb_tbc_reader;

reg clk = 0;
always #7.048 clk = ~clk;
reg [1:0] div4 = 0;
always @(posedge clk) div4 <= div4 + 2'd1;
wire ce = (div4 == 2'd0);
reg reset = 1;

wire [10:0] t_x; wire [8:0] t_ln; wire t_fld, t_ls, run;
tbc_timing tim (.clk(clk), .ce(ce), .run(run), .x(t_x), .ln(t_ln), .fld(t_fld), .line_start(t_ls));

wire [15:0] s; wire [10:0] xs; wire [8:0] lns; wire flds;
reg busy; wire [7:0] bc; wire [28:0] addr; reg [63:0] dout; reg dready; wire rd;
reg [15:0] fr = 16'd1;           // transport as the player drives it: next frame = current + 1 (mod 2 frames)
reg        vid = 1'b1;
wire [15:0] nfr; wire dsc;
tbc_reader rdr (.clk(clk), .ce(ce), .reset(reset), .x(t_x), .ln(t_ln), .fld(t_fld), .line_start(t_ls),
                .run(run), .video_on(vid), .frame(fr), .resync(1'b0), .frames(nfr), .disc(dsc),
                .s(s), .xs(xs), .lns(lns), .flds(flds),
                .ddr_busy(busy), .ddr_burstcnt(bc), .ddr_addr(addr), .ddr_dout(dout),
                .ddr_dout_ready(dready), .ddr_rd(rd));

localparam FIELDS = 4;
function [15:0] pat(input integer f, input integer l, input integer xx);
	pat = (f * 7 + l * 3 + xx) & 16'hFFFF;
endfunction

// word address -> 64-bit data
function [63:0] word_at(input [28:0] a);
	integer off, f, l, w, k, xx;
	begin
		if (a == 29'h6000000) word_at = {32'd4, 32'h31434254};
		else begin
			off = a - 29'h6000200;
			f = off / 88892; l = (off % 88892) / 284; w = off % 284;
			for (k = 0; k < 4; k = k + 1) begin
				xx = w * 4 + k;
				word_at[k*16 +: 16] = (xx < 1135) ? pat(f, l, xx) : 16'd14442;
			end
		end
	end
endfunction

// DDRAM model: accept on rd && !busy; return burst words after 20 cycles, one per cycle
reg [28:0] q_addr; reg [7:0] q_left; integer q_wait;
initial begin busy = 0; dready = 0; q_left = 0; end
always @(posedge clk) begin
	busy   <= ($random & 3) == 0;
	dready <= 1'b0;
	if (rd && !busy && q_left == 0) begin q_addr <= addr; q_left <= bc; q_wait <= 20; end
	else if (q_left != 0) begin
		if (q_wait != 0) q_wait <= q_wait - 1;
		else begin dout <= word_at(q_addr); dready <= 1'b1; q_addr <= q_addr + 1; q_left <= q_left - 1; end
	end
end

integer errors = 0, checked = 0, field_no = 0, fk = 0;
reg prev_fld = 0;
always @(posedge clk) if (ce && run) begin
	if (flds != prev_fld) begin prev_fld <= flds; field_no <= field_no + 1; end
	if (t_fld == 1'b0 && t_ln == 0 && t_x == 0) begin fk = fk + 1; fr <= fk % 2; end   // frame fk-1 starts: next = fk
	// skip the first few samples after run (pipeline fill)
	if (checked > 8 || (lns == 0 && xs > 4)) begin
		if (s !== pat((field_no + (flds != prev_fld)) % FIELDS, lns, xs)) begin
			errors = errors + 1;
			if (errors < 10) $display("MISMATCH f%0d ln%0d x%0d got %h want %h", field_no, lns, xs, s, pat((field_no + (flds != prev_fld)) % FIELDS, lns, xs));
		end
		checked = checked + 1;
	end
	if (field_no == 2 && lns == 3) begin
		$display("checked %0d samples, %0d errors", checked, errors);
		$finish;
	end
end

initial begin #200 reset = 0; end
endmodule
