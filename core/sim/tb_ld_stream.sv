`timescale 1ns/1ps
// ld_stream (with LaserActive's dsc_decoder) against a behavioural DDR3: random BUSY, 20-clock read latency.
// The DDR3 holds the header block and one real DSCV frame in slot 0 (gen_ld_stream.py). Checks:
//   1. the frame buffer ld_stream writes equals the C decoder's picture (tbc2dscv -dump), fields woven;
//   2. after the frame boundary, the line fetch returns those rows;
//   3. the status block the core writes.
module tb_ld_stream;

reg clk = 0;
always #7.048 clk = ~clk;
reg reset = 1;

localparam [28:0] HDR_W  = 29'h6000000, STAT_W = 29'h6000080, RING_W = 29'h6020000;
localparam [28:0] FB_W0  = 29'h6240000, FB_W1 = 29'h62C0000, FB_W2 = 29'h6340000;
localparam WORDS = 73026, VBIW = 73024, FBW = 288000, ROWW = 480, AUDW = 72000;
localparam [15:0] FRAME = 16'd5;

// ------------------------------------------------------------------ DDR3 model
logic [63:0] mem [int unsigned];
reg  [63:0] tmp [0:FBW-1];
reg  [63:0] expw [0:FBW-1];

reg         busy;
wire  [7:0] bc;
wire [28:0] addr;
reg  [63:0] dout;
reg         dready;
wire        rd, we;
wire [63:0] din;
wire  [7:0] be;

int unsigned rq_addr [$];
int unsigned rq_len  [$];
int unsigned rq_time [$];
int unsigned cyc = 0;
int unsigned r_addr, r_left;
int unsigned w_addr, w_left = 0;

always @(posedge clk) begin
	cyc <= cyc + 1;
	busy <= ($urandom % 8) == 0;
	if (rd && !busy) begin rq_addr.push_back(addr); rq_len.push_back(bc); rq_time.push_back(cyc + 20); end
	if (we && !busy) begin
		if (w_left == 0) begin w_addr = addr; w_left = bc; end
		mem[w_addr] = din;
		w_addr++; w_left--;
	end
	dready <= 1'b0;
	if (r_left == 0 && rq_addr.size() != 0 && rq_time[0] <= cyc) begin
		r_addr = rq_addr.pop_front(); r_left = rq_len.pop_front(); void'(rq_time.pop_front());
	end
	if (r_left != 0) begin
		dout <= mem.exists(r_addr) ? mem[r_addr] : 64'hDEAD_BEEF_DEAD_BEEF;
		dready <= 1'b1;
		r_addr++; r_left--;
	end
end

// ------------------------------------------------------------------ DUT
reg  [15:0] want = FRAME;
reg         flip = 0;
wire        disc, shown, lf_we;
wire [15:0] frames;
wire [10:0] crop_x, pic_cols, pic_rows;
wire  [9:0] crop_y;
reg         lf_req = 0;
reg   [9:0] lf_row = 0;
wire  [8:0] lf_addr;
wire [47:0] lf_data;
wire        new_pic, has_audio, aud_we;
wire  [1:0] pic_buf;
wire [11:0] aud_waddr;
wire [63:0] aud_wdata;
wire [15:0] al, ar;
wire [127:0] pic_vbi;

ld_stream dut (
	.clk(clk), .reset(reset), .want(want), .flip(flip), .pstate(4'd7), .video_on(1'b1), .want_cvbs(1'b0), .cvbs(),
	.disc(disc), .frames(frames), .crop_x(crop_x), .crop_y(crop_y), .pic_cols(pic_cols), .pic_rows(pic_rows),
	.shown(shown), .new_pic(new_pic), .pic_buf(pic_buf), .has_audio(has_audio), .pic_vbi(pic_vbi),
	.aud_we(aud_we), .aud_waddr(aud_waddr), .aud_wdata(aud_wdata), .lf_req(lf_req), .lf_row(lf_row), .lf_we(lf_we), .lf_addr(lf_addr), .lf_data(lf_data),
	.DDRAM_BUSY(busy), .DDRAM_BURSTCNT(bc), .DDRAM_ADDR(addr), .DDRAM_DOUT(dout), .DDRAM_DOUT_READY(dready),
	.DDRAM_RD(rd), .DDRAM_DIN(din), .DDRAM_BE(be), .DDRAM_WE(we)
);

ld_audio aud (
	.clk(clk), .reset(reset), .aud_we(aud_we), .aud_waddr(aud_waddr), .aud_wdata(aud_wdata),
	.new_pic(new_pic), .pic_buf(pic_buf), .sound_on(has_audio), .chan(2'd0), .l(al), .r(ar)
);

// audio out: the sample presented at each 44.1 kHz tick while playing
reg  [31:0] a_got [0:4095];
int         a_n = 0;
int unsigned a_first = 0, a_last = 0;
reg         tick_d = 0, play_d = 0;
always @(posedge clk) begin
	tick_d <= aud.tick;
	if (aud.tick) play_d <= aud.playing && aud.q_n != 0;
	if (tick_d && play_d) begin
		if (a_n == 0) a_first = cyc;
		a_last = cyc;
		a_got[a_n] = {ar, al}; a_n++;
	end
end

// ------------------------------------------------------------------ line fetch capture
reg  [47:0] lf_got [0:511];
int         lf_n = 0;
always @(posedge clk) if (lf_we) begin lf_got[lf_addr] = lf_data; lf_n++; end

function automatic [28:0] fbw(input [1:0] n);
	fbw = n == 2'd0 ? FB_W0 : n == 2'd1 ? FB_W1 : FB_W2;
endfunction

int errors = 0;
int t0;
task automatic check_line(input int row);
	lf_n = 0;
	@(posedge clk) begin lf_req <= 1'b1; lf_row <= row[9:0]; end
	@(posedge clk) lf_req <= 1'b0;
	wait (lf_n == ROWW);
	repeat (2) @(posedge clk);
	for (int i = 0; i < ROWW; i++)
		if (lf_got[i] !== {expw[row * ROWW + i][55:32], expw[row * ROWW + i][23:0]}) begin
			if (errors < 10) $display("line fetch row %0d word %0d: %h, want %h", row, i, lf_got[i], expw[row * ROWW + i]);
			errors++;
		end
endtask

initial begin
	$readmemh("dscv/hdr.hex", tmp, 0, 27);
	for (int i = 0; i < 28; i++) mem[HDR_W + i] = tmp[i];
	$readmemh("dscv/slot.hex", tmp, 0, WORDS - 1);
	for (int i = 0; i < WORDS; i++) mem[RING_W + i] = tmp[i];
	$readmemh("dscv/exp.hex", expw);

	repeat (20) @(posedge clk);
	reset <= 0;
	repeat (100) @(posedge clk);
	@(posedge clk) flip <= 1;              // frame boundary: status out, header in, PPS, then the decode
	@(posedge clk) flip <= 0;
	wait (disc);
	$display("disc: %0d frames, crop %0d,%0d, %0dx%0d", frames, crop_x, crop_y, pic_cols, pic_rows);
	t0 = cyc;
	fork
		wait (dut.fresh);
		begin repeat (4000000) @(posedge clk); $display("TIMEOUT"); $finish; end
	join_any
	disable fork;
	$display("decoded in %0d clocks (%.2f ms at 70.94 MHz), decoder error %0d", cyc - t0, (cyc - t0) / 70937.9,
	         dut.error_count);

	// 1. frame buffer contents
	for (int i = 0; i < FBW; i++) begin
		logic [63:0] v;
		v = mem.exists(fbw(dut.ready_buf) + i) ? mem[fbw(dut.ready_buf) + i] : 64'hX;
		if (v !== expw[i]) begin
			if (errors < 10) $display("fb row %0d word %0d: %h, want %h", i / ROWW, i % ROWW, v, expw[i]);
			errors++;
		end
	end
	$display("frame buffer: %0d mismatching words of %0d", errors, FBW);

	// 2. flip, then fetch lines through the display path
	@(posedge clk) flip <= 1;
	@(posedge clk) flip <= 0;
	repeat (2000) @(posedge clk);
	if (!shown || dut.disp_f != FRAME) begin $display("picture not up after the boundary"); errors++; end
	check_line(0); check_line(1); check_line(301); check_line(599);
	$display("VBI on screen: %h", pic_vbi);
	if (pic_vbi !== {mem[RING_W + VBIW + 1], mem[RING_W + VBIW]}) begin $display("VBI of the picture wrong"); errors++; end
	repeat (2000) @(posedge clk);

	// 4. audio: the block in the bank, then every sample played at 44.1 kHz
	for (int i = 0; i < 1024; i++)
		if (aud.bank[{dut.disp_buf, i[9:0]}] !== mem[RING_W + AUDW + i]) begin
			if (errors < 10) $display("audio bank word %0d: %h, want %h", i, aud.bank[{dut.disp_buf, i[9:0]}], mem[RING_W + AUDW + i]);
			errors++;
		end
	repeat (3000000) @(posedge clk);
	begin
		int n;
		n = mem[RING_W + AUDW][31:0];
		$display("audio: %0d samples in the block, %0d played, %.3f us apart", n, a_n,
		         (a_last - a_first) * 14.096 / 1000.0 / (a_n - 1));
		if (a_n != n) begin $display("audio sample count wrong"); errors++; end
		for (int i = 0; i < n && i < a_n; i++)
			if (a_got[i] !== (i[0] ? mem[RING_W + AUDW + 1 + i / 2][63:32] : mem[RING_W + AUDW + 1 + i / 2][31:0])) begin
				if (errors < 10) $display("audio sample %0d: %h", i, a_got[i]);
				errors++;
			end
	end

	// 3. status block (written at the second boundary)
	$display("status: %h %h %h %h", mem[STAT_W], mem[STAT_W + 1], mem[STAT_W + 2], mem[STAT_W + 3]);
	if (mem[STAT_W][31:0] != 32'h3153444C || mem[STAT_W + 1][15:0] != FRAME || mem[STAT_W + 2][47:32] != FRAME) begin
		$display("status block wrong"); errors++;
	end
	if (errors) $display("FAIL: %0d errors", errors); else $display("PASS");
	$finish;
end

endmodule
