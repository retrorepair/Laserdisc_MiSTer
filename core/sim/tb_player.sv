// tb_player (vectors: tools/analysis/player_vectors.py): the player's search, chapter skip and DISPLAY against GGV1069's real VBI codes (player_vbi.hex: per frame
// {f2 line 17, f2 line 16, f1 line 17, f1 line 16}, from the capture's .tbc.db). A model of ld_stream shows the
// requested frame two frame ticks after it is asked for, with its codes. Expected frames from the same table:
// chapter 1 at 0, chapter 15 at 7360, picture 12345 at 12504 (chapter 20, whose start is 11860), chapter 22 at 13660.
`timescale 1ns/1ps
module tb_player;
localparam N = 25361;
localparam CH5 = 3760, CH12 = 5860;     // chapter starts (tools/analysis/player_vectors.py)
reg clk = 0;
always #10 clk = ~clk;
reg [127:0] vbi [0:N-1];
initial $readmemh("player_vbi.hex", vbi);

reg [5:0] tc = 0;
wire frame_tick = (tc == 0);
always @(posedge clk) tc <= tc + 1'd1;

reg k_pgm = 0;
reg k_ms_f = 0, k_ms_r = 0, k_sp_up = 0, k_sp_dn = 0, k_rep_a = 0, k_rep_b = 0;
reg [15:0] stop_at = 16'hFFFF;
reg k_play = 0, k_pause = 0, k_stop = 0, k_digit = 0, k_clear = 0, k_chptm = 0, k_skip_f = 0, k_skip_r = 0, k_display = 0;
reg [3:0] digit = 0;
reg [12:0] load_id = 0;
reg reset = 1;
wire video_on, resync, hold, sys_mode_set;
wire [15:0] frame;
wire [2:0] osd_screen;
wire [1:0] osd_bg, want_side, audio_sel, sys_mode, txt_l0, txt_l1;
wire [3:0] txt_r0;
wire [3:0] state;
wire audio_src, txt_side_b, txt_chap_v;
wire [7:0] txt_chap;
wire [4:0] txt_msg;
wire [19:0] txt_n0, txt_n1;

// the stream: the frame asked for goes up two ticks later
reg [15:0] pend = 0, pic_frame = 16'hFFFF;
reg [127:0] pic_vbi = 0;
reg new_pic = 0;
reg [12:0] seen_load = 0;
always @(posedge clk) begin
	new_pic <= 0;
	seen_load <= load_id;
	if (load_id != seen_load) pic_frame <= 16'hFFFF;        // a new disc: nothing shown until its first picture
	else if (frame_tick) begin
		pend <= frame;
		if (pend != pic_frame || state == 4'd7) begin
			pic_frame <= pend; pic_vbi <= (pend == stop_at) ? {vbi[pend][127:24], 24'h82CFFF} : vbi[pend]; new_pic <= 1;
		end
	end
end

player dut (
	.clk(clk), .reset(reset), .frame_tick(frame_tick), .ntsc(1'b1),
	.k_play(k_play), .k_playpause(1'b0), .k_pause(k_pause), .k_stop(k_stop), .k_eject(1'b0),
	.k_step_f(1'b0), .k_step_r(1'b0), .k_system(1'b0), .k_audio(1'b0), .scan_f(1'b0), .scan_r(1'b0),
	.k_side_a(1'b0), .k_side_b(1'b0),
	.k_digit(k_digit), .digit(digit), .k_clear(k_clear), .k_chptm(k_chptm), .k_skip_f(k_skip_f), .k_skip_r(k_skip_r),
	.k_display(k_display), .k_ms_f(k_ms_f), .k_ms_r(k_ms_r), .k_sp_up(k_sp_up), .k_sp_dn(k_sp_dn),
	.k_rep_a(k_rep_a), .k_rep_b(k_rep_b), .k_pgm(k_pgm), .k_lang(1'b0), .lang_in(2'd0), .lang(), .lang_set(), .k_lvl_up(1'b0), .k_lvl_dn(1'b0), .dlc(),
	.txt_pg_show(), .txt_pg_n(), .txt_pg_list(), .txt_pg_pend_v(), .txt_pg_pend(),
	.new_pic(new_pic), .pic_frame(pic_frame), .pic_vbi(pic_vbi),
	.disc(1'b1), .frames(16'd25361), .two_sided(1'b0), .side_b(1'b0), .load_id(load_id), .has_digital(1'b0),
	.sys_mode_in(2'd0), .sys_mode(sys_mode), .sys_mode_set(sys_mode_set),
	.video_on(video_on), .frame(frame), .resync(resync), .osd_screen(osd_screen), .osd_bg(osd_bg),
	.txt_l0(txt_l0), .txt_l1(txt_l1), .txt_r0(txt_r0), .txt_side_b(txt_side_b), .txt_chap_v(txt_chap_v), .txt_chap(txt_chap), .txt_msg(txt_msg), .txt_n0(txt_n0), .txt_n1(txt_n1),
	.state(state), .hold(hold), .want_side(want_side), .audio_sel(audio_sel), .audio_src(audio_src)
);

integer errs = 0;
task press(input integer which, input [3:0] d);   // 0 play 1 pause 2 digit 3 chptm 4 skip_f 5 skip_r 6 display 7 clear
                                                  // 8 ms_f 9 sp_up 10 rep_a 11 rep_b 12 sp_dn
	begin
		@(posedge clk);
		case (which)
		0: k_play <= 1; 1: k_pause <= 1; 2: begin k_digit <= 1; digit <= d; end 3: k_chptm <= 1;
		4: k_skip_f <= 1; 5: k_skip_r <= 1; 6: k_display <= 1; 7: k_clear <= 1;
		13: k_pgm <= 1;
		8: k_ms_f <= 1; 9: k_sp_up <= 1; 10: k_rep_a <= 1; 11: k_rep_b <= 1; 12: k_sp_dn <= 1;
		endcase
		@(posedge clk);
		{k_play, k_pause, k_digit, k_chptm, k_skip_f, k_skip_r, k_display, k_clear} <= 0;
		{k_ms_f, k_sp_up, k_rep_a, k_rep_b, k_sp_dn, k_pgm} <= 0;
		repeat (3) @(posedge clk);
	end
endtask
task wait_state(input [3:0] s, input integer ticks);
	integer i;
	begin
		i = 0;
		while (state != s && i < ticks * 64) begin @(posedge clk); i = i + 1; end
		if (state != s) begin $display("timeout waiting for state %0d (in %0d)", s, state); errs = errs + 1; end
	end
endtask
task check(input [255:0] what, input integer got, input integer want);
	begin
		$display("%0s: %0d (expected %0d) %0s", what, got, want, got == want ? "ok" : "WRONG");
		if (got != want) errs = errs + 1;
	end
endtask

integer f0;
initial begin
	repeat (10) @(posedge clk);
	reset <= 0;
	repeat (10) @(posedge clk);
	load_id <= 1;                                           // Load disc: close, spin up, info, then search to chapter 1
	wait_state(4'd12, 1000);
	repeat (2) @(posedge clk);                              // the screen follows the state one clock later
	check("start: search screen", osd_screen, 7);
	check("start: chapter shown", txt_n1, 1);
	wait_state(4'd7, 500);
	f0 = frame;
	check("start: landed at chapter 1 (frame 0, +1 for the tick)", f0 <= 1, 1);
	check("start: picture on", video_on, 1);
	repeat (64 * 30) @(posedge clk);

	press(2, 1); press(2, 5); press(0, 0);                  // 1 5 PLAY: chapter 15
	wait_state(4'd12, 10);
	check("ch15: chapter shown", txt_n1, 'h15);
	wait_state(4'd7, 500);
	check("ch15: landed at 7360", frame <= 7361 && frame >= 7360, 1);

	press(3, 0); press(2, 1); press(2, 2); press(2, 3); press(2, 4); press(2, 5); press(1, 0);   // CHP/TM 12345 PAUSE
	wait_state(4'd12, 10);
	check("frame search: FRAME screen", txt_l1, 2);
	wait_state(4'd9, 500);
	check("frame search: still at 12504", frame, 12504);
	check("frame search: picture on", video_on, 1);

	press(0, 0);                                            // PLAY
	wait_state(4'd7, 10);
	repeat (64 * 10) @(posedge clk);
	press(6, 0);                                            // DISPLAY on: frame number at row 0
	repeat (64 * 3) @(posedge clk);
	check("display: screen 7", osd_screen, 7);
	check("display: number kind", txt_l0, 2);
	check("display: right block PLAY", txt_r0, 1);
	press(6, 0);

	press(4, 0); press(4, 0);                               // CHAPTER SKIP forward twice: chapter 22
	wait_state(4'd7, 500);
	check("skip x2: chapter 22 at 13660", frame <= 13661 && frame >= 13660, 1);
	repeat (64 * 10) @(posedge clk);
	press(5, 0);                                            // back: start of chapter 22
	wait_state(4'd12, 10);
	wait_state(4'd7, 500);
	check("skip back: start of chapter 22", frame <= 13661 && frame >= 13660, 1);

	press(2, 9); press(2, 9); press(0, 0);                  // chapter 99 does not exist: lands at the end
	wait_state(4'd12, 10);
	press(7, 0);                                            // CLEAR cancels the search: back to play where it was
	wait_state(4'd7, 10);
	check("clear: back in play near 13660", frame >= 13660 && frame < 13700, 1);


	// multi-speed: starts at 1/4 (one frame per 4 ticks), + twice gives x1
	f0 = frame;
	press(8, 0);
	wait_state(4'd13, 10);
	repeat (64 * 40) @(posedge clk);
	check("multi-speed 1/4: ~10 frames in 40 ticks", (frame - f0 >= 8) && (frame - f0 <= 12), 1);
	press(9, 0); press(9, 0);
	f0 = frame;
	repeat (64 * 20) @(posedge clk);
	check("multi-speed x1: ~20 frames in 20 ticks", (frame - f0 >= 18) && (frame - f0 <= 22), 1);
	// a picture stop code ahead stills the picture (x1 and slower)
	stop_at = frame + 16'd10;
	wait_state(4'd9, 40);
	check("stop code: still at the coded frame", (frame >= stop_at) && (frame <= stop_at + 2), 1);
	stop_at = 16'hFFFF;
	press(0, 0);                                            // PLAY
	wait_state(4'd7, 10);
	// A-B repeat: A here, B 50 frames on: back to A
	press(10, 0); f0 = frame;
	repeat (64 * 50) @(posedge clk);
	press(11, 0);
	wait_state(4'd12, 10);
	wait_state(4'd7, 100);
	check("A-B: back at A", (frame >= f0) && (frame <= f0 + 2), 1);
	repeat (64 * 60) @(posedge clk);
	check("A-B: still inside the section", (frame >= f0) && (frame <= f0 + 55), 1);
	press(7, 0);                                            // CLEAR ends the repeat
	// chapter repeat: B alone, then the chapter's end returns to its start
	press(11, 0);
	f0 = dut.cur_ch;
	wait_state(4'd12, 3000);
	wait_state(4'd7, 200);
	check("chapter repeat: back in the same chapter", dut.cur_ch == f0 || dut.cur_ch_v == 0, 1);

	// PGM: 5, 12, 3 (a digit is taken after about 1 s; two quick digits make 12)
	press(7, 0);                                            // CLEAR (any repeat)
	press(13, 0);
	press(2, 5); repeat (64 * 35) @(posedge clk);
	press(2, 1); press(2, 2); repeat (64 * 35) @(posedge clk);
	press(2, 3); repeat (64 * 35) @(posedge clk);
	check("pgm: three steps", dut.pg_n, 3);
	check("pgm: screen", osd_screen, 7);
	check("pgm: step 2 is chapter 12", dut.pg[15:8], 'h12);
	press(0, 0);                                            // PLAY: chapter 5 first
	wait_state(4'd12, 10);
	wait_state(4'd7, 500);
	check("pgm: at chapter 5's start", frame >= CH5 && frame <= CH5 + 1, 1);
	wait_state(4'd12, 600);                                 // chapter 5 ends: search to 12
	wait_state(4'd7, 500);
	check("pgm: then chapter 12's start", frame >= CH12 && frame <= CH12 + 1, 1);
	press(7, 0);                                            // CLEAR: programme play ends
	check("pgm: cleared", dut.pg_play, 0);
	$display("%0d errors", errs);
	if (errs) $display("FAIL"); else $display("PASS");
	$finish;
end
endmodule
