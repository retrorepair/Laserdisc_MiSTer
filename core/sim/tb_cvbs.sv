`timescale 1ns/1ps
// Composite replay: ld_stream (composite stream) + cvbs_scan + tbc_timing against a DDR3 model holding one real
// composite frame in slot 0 (gen_cvbs.py). After the frame goes up, every sample cvbs_scan plays on chosen lines
// of both fields must equal the slot's byte for that field line and sample; with the picture off, the raster.
module tb_cvbs;
reg clk = 0;
always #7.04842 clk = ~clk;
reg [1:0] div = 0; always @(posedge clk) div <= div + 2'd1;
wire ce = div == 2'd0;
reg reset = 1;
localparam [28:0] HDR_W = 29'h6000000, RING_W = 29'h6020000;
localparam SLOTW = 89918;
localparam [15:0] FRAME = 16'd5;

logic [63:0] mem [int unsigned];
reg [63:0] tmp [0:SLOTW-1];
reg busy; wire [7:0] bc; wire [28:0] addr; reg [63:0] dout; reg dready; wire rd, we; wire [63:0] din; wire [7:0] be;
int unsigned rq_addr [$], rq_len [$], rq_time [$];
int unsigned cyc = 0, r_addr, r_left, w_addr, w_left = 0;
always @(posedge clk) begin
	cyc <= cyc + 1;
	busy <= ($urandom % 8) == 0;
	if (rd && !busy) begin rq_addr.push_back(addr); rq_len.push_back(bc); rq_time.push_back(cyc + 20); end
	if (we && !busy) begin
		if (w_left == 0) begin w_addr = addr; w_left = bc; end
		mem[w_addr] = din; w_addr++; w_left--;
	end
	dready <= 1'b0;
	if (r_left == 0 && rq_addr.size() != 0 && rq_time[0] <= cyc) begin
		r_addr = rq_addr.pop_front(); r_left = rq_len.pop_front(); void'(rq_time.pop_front());
	end
	if (r_left != 0) begin
		dout <= mem.exists(r_addr) ? mem[r_addr] : 64'hDEAD_BEEF_DEAD_BEEF; dready <= 1'b1; r_addr++; r_left--;
	end
end

wire [10:0] t_x; wire [8:0] t_ln; wire t_fld, t_ls;
reg run = 0;
always @(posedge clk) if (!reset && ce) run <= 1'b1;
tbc_timing tim (.clk(clk), .ce(ce), .ntsc(1'b0), .run(run), .vjump(1'b0), .x(t_x), .ln(t_ln), .fld(t_fld), .line_start(t_ls));
wire flip = ce && run && t_x == 0 && t_ln == 0 && !t_fld;

wire disc, shown, lf_we, cvbs, cv_req; wire [9:0] lf_row;
wire lf_req = cvbs && cv_req;              // as the top level routes it
wire [8:0] lf_addr; wire [63:0] lf_data;
wire [15:0] frames; wire [10:0] crop_x, pic_cols, pic_rows; wire [9:0] crop_y;
reg video_on = 1;                          // disc video wanted from the start; checks run once the picture is up
ld_stream dut (
	.clk(clk), .reset(reset), .want(FRAME), .flip(flip), .pstate(4'd7), .video_on(video_on), .want_cvbs(1'b1), .hold(1'b0), .want_side(2'd0), .two_sided(), .side_b(), .load_id(), .ntsc(),
	.cvbs(cvbs), .disc(disc), .frames(frames), .crop_x(crop_x), .crop_y(crop_y), .pic_cols(pic_cols),
	.pic_rows(pic_rows), .shown(shown), .new_pic(), .pic_buf(), .has_audio(), .has_digital(), .pic_vbi(), .aud_we(), .aud_waddr(),
	.aud_wdata(), .lf_req(lf_req), .lf_row(lf_row), .lf_we(lf_we), .lf_addr(lf_addr), .lf_data(lf_data),
	.DDRAM_BUSY(busy), .DDRAM_BURSTCNT(bc), .DDRAM_ADDR(addr), .DDRAM_DOUT(dout), .DDRAM_DOUT_READY(dready),
	.DDRAM_RD(rd), .DDRAM_DIN(din), .DDRAM_BE(be), .DDRAM_WE(we)
);
wire [7:0] code; wire [15:0] s; wire [10:0] xs; wire [8:0] lns; wire flds;
cvbs_scan scan (.ntsc(1'b0),
	.clk(clk), .ce(ce), .x(t_x), .ln(t_ln), .fld(t_fld), .run(run), .show(cvbs && video_on && shown),
	.lf_req(cv_req), .lf_row(lf_row), .lf_we(lf_we), .lf_addr(lf_addr), .lf_data(lf_data),
	.code(code), .s(s), .xs(xs), .lns(lns), .flds(flds)
);

function automatic [7:0] slot_byte(input int f, input int l, input int x);
	int b; b = (f * 313 + l) * 1136 + x;
	slot_byte = mem[RING_W + b / 8][(b % 8) * 8 +: 8];
endfunction

int errors = 0, checked = 0, raster_checked = 0;
// a sample counts once the picture was already up when it was produced (the boundary sample is the switch)
reg shown_d = 0; always @(posedge clk) if (ce) shown_d <= shown;
always @(posedge clk) if (ce && video_on && shown && shown_d && run) begin
	// lines checked: field 0 lines 0, 23, 160, 312 (its last: PAL line 313); field 1 lines 0, 160, 311 (its last)
	if ((!flds && (lns == 0 || lns == 23 || lns == 160 || lns == 312)) || (flds && (lns == 0 || lns == 160 || lns == 311))) begin
		checked++;
		if (code !== slot_byte(flds, lns, xs)) begin
			if (errors < 10) $display("field %0d line %0d x %0d: %0d, want %0d", flds, lns, xs, code, slot_byte(flds, lns, xs));
			errors++;
		end
	end
end
// the player's raster: vertical-interval pulses (B broad, E equalising, N line sync) at chosen samples
function automatic int rwant(input f, input int l, input int x);
	rwant = -1;
	case ({f, 9'(l), 11'(x)})
		{1'b0, 9'd100, 11'd50}:  rwant = 0;    // N
		{1'b0, 9'd0,   11'd300}: rwant = 0;    // B
		{1'b0, 9'd0,   11'd500}: rwant = 68;   // serration
		{1'b0, 9'd2,   11'd600}: rwant = 0;    // second half E
		{1'b0, 9'd2,   11'd620}: rwant = 68;
		{1'b0, 9'd312, 11'd30}:  rwant = 0;    // E
		{1'b0, 9'd312, 11'd50}:  rwant = 68;
		{1'b0, 9'd312, 11'd700}: rwant = 0;    // second field's broad pulses start mid-line
		{1'b1, 9'd4,   11'd20}:  rwant = 0;    // E
		{1'b1, 9'd4,   11'd600}: rwant = 68;   // no pulse in the second half
		{1'b1, 9'd309, 11'd50}:  rwant = 0;    // N
		{1'b1, 9'd309, 11'd110}: rwant = 68;   // no burst after line 308
		{1'b1, 9'd309, 11'd590}: rwant = 0;    // second half E
		{1'b1, 9'd311, 11'd600}: rwant = 0;    // E
	endcase
endfunction
int bfirst [2], blast [2], bpar_first [2], bpar_last [2];
initial begin bfirst = '{999, 999}; blast = '{-1, -1}; end
always @(posedge clk) if (ce && !video_on && run) begin
	if (rwant(flds, lns, xs) >= 0) begin
		raster_checked++;
		if (code !== rwant(flds, lns, xs)) begin
			$display("raster field %0d line %0d x %0d: %0d, want %0d", flds, lns, xs, code, rwant(flds, lns, xs)); errors++;
		end
	end
end
// first and last burst line of each raster field, and the burst phase there (rline even = 135 degrees)
always @(posedge clk) if (ce && !video_on && run && t_x == 11'd110 && scan.rburst) begin
	if (int'(t_ln) < bfirst[t_fld]) begin bfirst[t_fld] = t_ln; bpar_first[t_fld] = scan.rpar; end
	if (int'(t_ln) > blast[t_fld])   begin blast[t_fld]  = t_ln; bpar_last[t_fld]  = scan.rpar; end
end

initial begin
	$readmemh("dscv/cv_hdr.hex", tmp, 0, 27);
	for (int i = 0; i < 28; i++) mem[HDR_W + i] = tmp[i];
	$readmemh("dscv/cv_slot.hex", tmp, 0, SLOTW - 1);
	for (int i = 0; i < SLOTW; i++) mem[RING_W + i] = tmp[i];
	repeat (20) @(posedge clk); reset <= 0;
	fork begin repeat (20000000) @(posedge clk); $display("TIMEOUT at clock %0d: disc %0d cvbs %0d fresh %0d shown %0d fstate %0d cstate %0d", cyc, disc, cvbs, dut.fresh, shown, dut.fstate, dut.cstate); $finish; end join_none
	wait (disc && cvbs);
	$display("disc: composite stream, %0d frames", frames);
	wait (dut.fresh);
	$display("frame ready (slot %0d) at clock %0d", dut.buf_slot[dut.ready_buf], cyc);
	wait (shown);                                 // up at the next boundary
	$display("picture up at clock %0d", cyc);
	repeat (2) begin wait (flip); repeat (3) @(posedge clk); end   // two whole frames played from the slot
	$display("two frames played at clock %0d, %0d samples checked", cyc, checked);
	video_on = 0;
	repeat (3000) @(posedge clk);
	repeat (2) begin wait (flip); @(posedge clk); end
	for (int f = 0; f < 2; f++) begin
		$display("raster field %0d: bursts on lines %0d-%0d, phase odd %0d/%0d", f, bfirst[f], blast[f], bpar_first[f], bpar_last[f]);
		if (bpar_first[f] || bpar_last[f] || bfirst[f] < 5 || bfirst[f] > 6 || blast[f] < (f ? 307 : 308) || blast[f] > (f ? 308 : 309)) errors++;
	end
	$display("%0d samples checked against the slot, %0d raster samples, %0d errors", checked, raster_checked, errors);
	// every checked line of both fields, twice, less the switch sample
	if (errors == 0 && raster_checked >= 14 && checked >= 2 * 7 * 1135 - 1) $display("PASS"); else $display("FAIL");
	$finish;
end
endmodule
