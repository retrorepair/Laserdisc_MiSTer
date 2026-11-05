//============================================================================
//
//  Laserdisc: LaserDisc player core for MiSTer.
//
//  Plays reference-decoded (Decode-Orc Transform PAL 3D) DSCV streams from DDR3 at the ld-decode TBC
//  timing (4fsc, 1135 x 312/313), with the CLD-1750's OSD and player logic (docs/streaming_design.md,
//  docs/player_logic.md); output RGB.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_SL = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Laserdisc;;",   // core name: games/Laserdisc, the MiSTer.ini section, Main's is_laserdisc()
	"S0,DS*,Load disc;",                      // the Laserdisc Main reads it into DDR3 (support/laserdisc)
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"O[5:4],SYSTEM mode,MOD.PAL,NTSC;",
	"O[6],Video output,RGB,Composite;",      // composite: the TBC samples on the VGA connector (docs/composite_output.md)
	"O[7],Composite DAC,Green (0.7V),R+G+B tied (1.0V);",
	"O[10:8],Chroma advance,Off,0.11us,0.23us,0.34us,0.45us,0.56us,0.68us,0.79us;",
	"O[11],CC decoder box,Off,On;",
	"O[13:12],OSD language,English,Francais,Deutsch,Italiano;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;",
	"V,v",`BUILD_DATE
};

// player <-> reader/OSD/menu (declared before use)
wire        video_on, resync, disc, sys_mode_set, lang_set;
wire  [1:0] osd_lang;
wire [15:0] play_frame, frames;
wire  [2:0] osd_screen;
wire  [1:0] osd_bg, sys_mode;
wire  [3:0] player_state;
wire  [1:0] audio_sel;
wire        audio_src, has_digital;   // AUDIO D/A source; the disc's digital audio
wire        turn_hold, two_sided, side_b;   // two-side play
wire [12:0] load_id;                // counts discs loaded (header)
wire  [1:0] want_side;

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_in({status[127:14], osd_lang, status[11:6], sys_mode, status[3:0]}),   // SYSTEM / LANGUAGE keys write back
	.status_set(sys_mode_set | lang_set),
	.status_menumask(1'b0),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// clk_sys = 4 x 4fsc of the disc's system: 70.9379 MHz for PAL (4fsc 17.734475 MHz), 57.272727 MHz for NTSC
// (4fsc 14.318182 MHz); ce_4fsc = clk_sys / 4, the TBC sample rate. One fractional PLL, reconfigured through
// pll_cfg (as MiSTer console cores switch PAL/NTSC): M = 8 for both, so only the fraction K and the output divider
// C change. PAL: 50 MHz x 8.512548 / 6; NTSC: 50 MHz x (8 + 78090314 / 2^32) / 7 (within 0.01 ppb).
wire clk_sys, pll_locked;
wire [63:0] reconfig_to_pll, reconfig_from_pll;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

wire        cfg_waitrequest;
reg         cfg_write;
reg   [5:0] cfg_address;
reg  [31:0] cfg_data;
pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(1'b0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(1'b0),
	.mgmt_readdata(),
	.mgmt_write(cfg_write),
	.mgmt_address(cfg_address),
	.mgmt_writedata(cfg_data),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

// The system to clock for: a disc's, once its header is parsed (disc). Kept in the CLK_50M domain, outside the core
// reset that a switch causes, so the choice holds while the core restarts on the new clock.
wire ld_ntsc;
reg  clk_ntsc = 1'b0;      // the system the PLL is set for
reg  pll_busy = 1'b0;
always @(posedge CLK_50M) begin
	reg [1:0] dsc_s, ntsc_s;
	reg [2:0] st;
	dsc_s  <= {dsc_s[0], disc};
	ntsc_s <= {ntsc_s[0], ld_ntsc};
	cfg_write <= 1'b0;
	if (st == 3'd0 && dsc_s[1] && ntsc_s[1] != clk_ntsc) begin
		clk_ntsc <= ntsc_s[1];
		pll_busy <= 1'b1;
		st <= 3'd1;
	end
	if (!cfg_waitrequest && st != 3'd0) begin
		st <= st + 3'd1;
		case (st)
			3'd1: begin cfg_address <= 6'd0; cfg_data <= 32'd0; cfg_write <= 1'b1; end               // waitrequest mode
			3'd2: begin cfg_address <= 6'd7; cfg_write <= 1'b1;                                       // M fraction K
			            cfg_data <= clk_ntsc ? 32'd78090314 : 32'd2201376898; end
			3'd3: begin cfg_address <= 6'd5; cfg_write <= 1'b1;                                       // C0: 7 (4+3, odd) / 6 (3+3)
			            cfg_data <= clk_ntsc ? 32'h0002_0403 : 32'h0000_0303; end
			3'd4: begin cfg_address <= 6'd2; cfg_data <= 32'd0; cfg_write <= 1'b1; end               // start
			3'd6: begin pll_busy <= 1'b0; st <= 3'd0; end
			default: ;
		endcase
	end
end

// the core restarts on the new clock: held in reset while the PLL is reconfigured and until it locks again
reg [1:0] lock_s, ntsc_s;
always @(posedge clk_sys) begin
	lock_s <= {lock_s[0], pll_locked && !pll_busy};
	ntsc_s <= {ntsc_s[0], clk_ntsc};
end
wire ntsc = ntsc_s[1];     // 525-line timing throughout the core (constant outside the reset of a switch)
wire reset = RESET | status[0] | buttons[1] | !lock_s[1];

reg [1:0] ce_cnt;
always @(posedge clk_sys) ce_cnt <= ce_cnt + 2'd1;
wire ce_4fsc = (ce_cnt == 2'd0);

///////////////////////   TIMING   /////////////////////////////
// ld-decode PAL TBC timing. On resync (picture on) the vertical phase jumps with H continuous, as the player's TBC
// output does (tbc_timing vjump, docs/player_logic.md: the picture-on roll).

wire [10:0] t_x;
wire  [8:0] t_ln;
wire        t_fld, t_line_start;
reg         run;

always @(posedge clk_sys) begin
	if (reset) run <= 1'b0;
	else if (ce_4fsc) run <= 1'b1;
end

tbc_timing tbc_timing
(
	.clk(clk_sys),
	.ce(ce_4fsc),
	.ntsc(ntsc),
	.run(run),
	.vjump(resync),
	.x(t_x),
	.ln(t_ln),
	.fld(t_fld),
	.line_start(t_line_start)
);

// one pulse per output frame, at the start of the first field: the player's frame clock and ld_stream's flip
wire        frame_tick = ce_4fsc && run && (t_x == 11'd0) && (t_ln == 9'd0) && !t_fld;

///////////////////////   DSCV STREAM   //////////////////////////
// Frames arrive in DDR3 slots from the HPS; ld_stream decodes the one the player wants into a frame buffer.

wire        lf_req, lf_we, shown, new_pic, has_audio, aud_we, cvbs;
wire        ls_lf_req, cv_lf_req;
wire  [9:0] ls_lf_row, cv_lf_row;
wire  [1:0] pic_buf;
wire [12:0] aud_waddr;
wire [63:0] aud_wdata;
wire [127:0] pic_vbi;
wire  [15:0] pic_frame;
wire  [9:0] lf_row;
wire  [8:0] lf_addr;
wire [63:0] lf_data;
wire [10:0] crop_x, pic_cols, pic_rows;
wire  [9:0] crop_y;

assign DDRAM_CLK = clk_sys;

// the scan-out in use asks for lines: composite plays from the slot, RGB from the frame buffer
assign lf_req = cvbs ? cv_lf_req : ls_lf_req;
assign lf_row = cvbs ? cv_lf_row : ls_lf_row;

ld_stream ld_stream
(
	.clk(clk_sys),
	.reset(reset),
	.want(play_frame),
	.flip(frame_tick),
	.pstate(player_state),
	.video_on(video_on),
	.want_cvbs(status[6]),
	.hold(turn_hold),
	.want_side(want_side),
	.cvbs(cvbs),
	.two_sided(two_sided),
	.side_b(side_b),
	.load_id(load_id),
	.ntsc(ld_ntsc),
	.disc(disc),
	.frames(frames),
	.crop_x(crop_x),
	.crop_y(crop_y),
	.pic_cols(pic_cols),
	.pic_rows(pic_rows),
	.shown(shown),
	.new_pic(new_pic),
	.pic_buf(pic_buf),
	.has_audio(has_audio),
	.has_digital(has_digital),
	.pic_vbi(pic_vbi),
	.pic_frame(pic_frame),
	.aud_we(aud_we),
	.aud_waddr(aud_waddr),
	.aud_wdata(aud_wdata),
	.lf_req(lf_req),
	.lf_row(lf_row),
	.lf_we(lf_we),
	.lf_addr(lf_addr),
	.lf_data(lf_data),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE)
);

///////////////////////   AUDIO   //////////////////////////////
// The disc's sound (ld-decode PCM, 44.1 kHz stereo) with its picture, in normal play only (ld_audio.v), squelched
// where the disc's programme status code says there is no sound programme (ld_status.v).

wire [15:0] aud_l, aud_r;
wire        squelch, cx_on;

// the control MCU's reading of the disc's programme status code (squelch, CX), from the picture on screen
ld_status ld_status
(
	.clk(clk_sys),
	.reset(reset | !disc),
	.new_pic(new_pic),
	.vbi(pic_vbi),
	.squelch(squelch),
	.cx(cx_on)
);

ld_audio ld_audio
(
	.clk(clk_sys),
	.reset(reset),
	.aud_we(aud_we),
	.aud_waddr(aud_waddr),
	.aud_wdata(aud_wdata),
	.new_pic(new_pic),
	.pic_buf(pic_buf),
	.sound_on(player_state == 4'd7 && video_on && has_audio && !squelch),
	.chan(audio_sel),
	.src(audio_src),
	.ntsc(ntsc),
	.dlc(dlc),
	.l(aud_l),
	.r(aud_r)
);

assign AUDIO_S = 1'b1;
assign AUDIO_L = aud_l;
assign AUDIO_R = aud_r;

///////////////////////   PLAYER LOGIC   /////////////////////////
// Keyboard -> CLD-1750 controls (docs/player_logic.md):
//   Enter PLAY, Space >/II, P PAUSE, S STOP, E OPEN/CLOSE, Left/Right SCAN (hold), , . STEP, Y SYSTEM, A AUDIO D/A,
//   F1 DISC SIDE A, F2 DISC SIDE B; 0-9 (and the keypad) DIRECT SEARCH digits, Backspace CLEAR, C CHP/TM,
//   [ ] CHAPTER SKIP back / forward, D DISPLAY, R / T REPEAT A / B, M / N MULTI-SPEED forward / reverse,
//   = / - (and keypad + -) MULTI-SPEED + / -, G PGM, L LANGUAGE, PgUp / PgDn digital LEVEL
reg        key_tg;
reg        k_play, k_playpause, k_pause, k_stop, k_eject, k_step_f, k_step_r, k_system, k_audio, k_side_a, k_side_b;
reg        k_digit, k_clear, k_chptm, k_skip_f, k_skip_r, k_display, k_ms_f, k_ms_r, k_sp_up, k_sp_dn, k_rep_a, k_rep_b, k_pgm, k_lang;
reg        k_lvl_up, k_lvl_dn;
reg  [3:0] k_dval;
reg        scan_f, scan_r;
always @(posedge clk_sys) begin
	{k_play, k_playpause, k_pause, k_stop, k_eject, k_step_f, k_step_r, k_system, k_audio, k_side_a, k_side_b} <= 11'd0;
	{k_digit, k_clear, k_chptm, k_skip_f, k_skip_r, k_display, k_ms_f, k_ms_r, k_sp_up, k_sp_dn, k_rep_a, k_rep_b, k_pgm, k_lang} <= 14'd0;
	{k_lvl_up, k_lvl_dn} <= 2'd0;
	key_tg <= ps2_key[10];
	if (key_tg != ps2_key[10]) begin
		casez ({ps2_key[8], ps2_key[7:0]})
			9'h0_5A: k_play      <= ps2_key[9];
			9'h0_29: k_playpause <= ps2_key[9];
			9'h0_4D: k_pause     <= ps2_key[9];
			9'h0_1B: k_stop      <= ps2_key[9];
			9'h0_24: k_eject     <= ps2_key[9];
			9'h0_49: k_step_f    <= ps2_key[9];
			9'h0_41: k_step_r    <= ps2_key[9];
			9'h0_35: k_system    <= ps2_key[9];
			9'h0_1C: k_audio     <= ps2_key[9];   // A: AUDIO D/A
			9'h0_05: k_side_a    <= ps2_key[9];   // F1: DISC SIDE A
			9'h0_06: k_side_b    <= ps2_key[9];   // F2: DISC SIDE B
			9'h0_66: k_clear     <= ps2_key[9];   // Backspace: CLEAR
			9'h0_21: k_chptm     <= ps2_key[9];   // C: CHP/TM
			9'h0_54: k_skip_r    <= ps2_key[9];   // [: CHAPTER SKIP back
			9'h0_5B: k_skip_f    <= ps2_key[9];   // ]: CHAPTER SKIP forward
			9'h0_23: k_display   <= ps2_key[9];   // D: DISPLAY
			9'h0_2D: k_rep_a     <= ps2_key[9];   // R: REPEAT A
			9'h0_2C: k_rep_b     <= ps2_key[9];   // T: REPEAT B
			9'h0_34: k_pgm       <= ps2_key[9];   // G: PGM
			9'h0_4B: k_lang      <= ps2_key[9];   // L: LANGUAGE
			9'h1_7D: k_lvl_up    <= ps2_key[9];   // Page Up: digital LEVEL up
			9'h1_7A: k_lvl_dn    <= ps2_key[9];   // Page Down: digital LEVEL down
			9'h0_3A: k_ms_f      <= ps2_key[9];   // M: MULTI-SPEED forward
			9'h0_31: k_ms_r      <= ps2_key[9];   // N: MULTI-SPEED reverse
			9'h0_55, 9'h0_79: k_sp_up <= ps2_key[9];   // = or keypad +: faster
			9'h0_4E, 9'h0_7B: k_sp_dn <= ps2_key[9];   // - or keypad -: slower
			9'h0_45, 9'h0_70: begin k_digit <= ps2_key[9]; k_dval <= 4'd0; end
			9'h0_16, 9'h0_69: begin k_digit <= ps2_key[9]; k_dval <= 4'd1; end
			9'h0_1E, 9'h0_72: begin k_digit <= ps2_key[9]; k_dval <= 4'd2; end
			9'h0_26, 9'h0_7A: begin k_digit <= ps2_key[9]; k_dval <= 4'd3; end
			9'h0_25, 9'h0_6B: begin k_digit <= ps2_key[9]; k_dval <= 4'd4; end
			9'h0_2E, 9'h0_73: begin k_digit <= ps2_key[9]; k_dval <= 4'd5; end
			9'h0_36, 9'h0_74: begin k_digit <= ps2_key[9]; k_dval <= 4'd6; end
			9'h0_3D, 9'h0_6C: begin k_digit <= ps2_key[9]; k_dval <= 4'd7; end
			9'h0_3E, 9'h0_75: begin k_digit <= ps2_key[9]; k_dval <= 4'd8; end
			9'h0_46, 9'h0_7D: begin k_digit <= ps2_key[9]; k_dval <= 4'd9; end
			9'h1_74: scan_f      <= ps2_key[9];
			9'h1_6B: scan_r      <= ps2_key[9];
			default: ;
		endcase
	end
end

// the player's variable OSD text (search, DISPLAY, side change: screen 7)
wire  [1:0] txt_l0, txt_l1;
wire  [3:0] txt_r0;
wire        txt_side_b, txt_we, txt_chap_v;
wire  [7:0] txt_chap;
wire  [4:0] txt_msg;
wire  [4:0] dlc;
wire        txt_pg_show, txt_pg_pend_v;
wire  [4:0] txt_pg_n;
wire [191:0] txt_pg_list;
wire  [7:0] txt_pg_pend;
wire [19:0] txt_n0, txt_n1;
wire  [8:0] txt_addr;
wire  [6:0] txt_data;
osd_text osd_text
(
	.clk(clk_sys),
	.l0_kind(txt_l0),
	.l1_kind(txt_l1),
	.r0_kind(txt_r0),
	.side_b(txt_side_b),
	.chap_v(txt_chap_v),
	.chap(txt_chap),
	.lang(osd_lang),
	.pg_show(txt_pg_show),
	.pg_n(txt_pg_n),
	.pg_list(txt_pg_list),
	.pg_pend_v(txt_pg_pend_v),
	.pg_pend(txt_pg_pend),
	.msg(txt_msg),
	.n0(txt_n0),
	.n1(txt_n1),
	.we(txt_we),
	.addr(txt_addr),
	.data(txt_data)
);

player player
(
	.clk(clk_sys),
	.reset(reset),
	.frame_tick(frame_tick),
	.ntsc(ntsc),
	.k_play(k_play),
	.k_playpause(k_playpause),
	.k_pause(k_pause),
	.k_stop(k_stop),
	.k_eject(k_eject),
	.k_step_f(k_step_f),
	.k_step_r(k_step_r),
	.k_system(k_system),
	.k_audio(k_audio),
	.scan_f(scan_f),
	.scan_r(scan_r),
	.k_side_a(k_side_a),
	.k_side_b(k_side_b),
	.k_digit(k_digit),
	.digit(k_dval),
	.k_clear(k_clear),
	.k_chptm(k_chptm),
	.k_skip_f(k_skip_f),
	.k_skip_r(k_skip_r),
	.k_display(k_display),
	.k_ms_f(k_ms_f),
	.k_ms_r(k_ms_r),
	.k_sp_up(k_sp_up),
	.k_sp_dn(k_sp_dn),
	.k_rep_a(k_rep_a),
	.k_rep_b(k_rep_b),
	.k_pgm(k_pgm),
	.k_lang(k_lang),
	.k_lvl_up(k_lvl_up),
	.k_lvl_dn(k_lvl_dn),
	.dlc(dlc),
	.lang_in(status[13:12]),
	.lang(osd_lang),
	.lang_set(lang_set),
	.new_pic(new_pic),
	.pic_frame(pic_frame),
	.pic_vbi(pic_vbi),
	.disc(disc),
	.frames(frames),
	.two_sided(two_sided),
	.side_b(side_b),
	.load_id(load_id),
	.has_digital(has_digital),
	.sys_mode_in(status[5:4]),
	.sys_mode(sys_mode),
	.sys_mode_set(sys_mode_set),
	.video_on(video_on),
	.frame(play_frame),
	.resync(resync),
	.osd_screen(osd_screen),
	.txt_l0(txt_l0),
	.txt_l1(txt_l1),
	.txt_r0(txt_r0),
	.txt_side_b(txt_side_b),
	.txt_chap_v(txt_chap_v),
	.txt_chap(txt_chap),
	.txt_msg(txt_msg),
	.txt_pg_show(txt_pg_show),
	.txt_pg_n(txt_pg_n),
	.txt_pg_list(txt_pg_list),
	.txt_pg_pend_v(txt_pg_pend_v),
	.txt_pg_pend(txt_pg_pend),
	.txt_n0(txt_n0),
	.txt_n1(txt_n1),
	.osd_bg(osd_bg),
	.state(player_state),
	.hold(turn_hold),
	.want_side(want_side),
	.audio_sel(audio_sel),
	.audio_src(audio_src)
);

// Composite source: the frame's TBC samples from its slot (or the player's raster), one ce after the timing.
wire  [7:0] cv_code;
wire [15:0] cv_s;
wire [10:0] cv_x;
wire  [8:0] cv_ln;
wire        cv_fld;

cvbs_scan cvbs_scan
(
	.clk(clk_sys),
	.ce(ce_4fsc),
	.x(t_x),
	.ln(t_ln),
	.fld(t_fld),
	.run(run),
	.show(cvbs && video_on && shown),
	.ntsc(ntsc),
	.lf_req(cv_lf_req),
	.lf_row(cv_lf_row),
	.lf_we(lf_we),
	.lf_addr(lf_addr),
	.lf_data(lf_data),
	.code(cv_code),
	.s(cv_s),
	.xs(cv_x),
	.lns(cv_ln),
	.flds(cv_fld)
);

// M50552-style OSD, mixed into the composite stream as the real chip does (CV IN -> CV OUT). Its per-dot decision
// (cls) also colours the RGB path (ld_scan). The blue raster's chroma comes from the line's own burst, measured by
// pal_decoder (only its burst measurement is used: the TBC is line-locked, osd_m50552.v).
wire [15:0] osd_s;
wire [10:0] osd_x;
wire  [8:0] osd_ln;
wire        osd_fld;
wire  [1:0] osd_cls;
wire signed [26:0] burst_r, burst_i;

// The closed-caption decoder box (menu option; rtl/cc608.v): an external line-21 decoder between player and TV,
// reading the replayed composite (with its timing) and drawing white text in black boxes over the picture.
wire [1:0] cc_cls;
cc608 cc608
(
	.clk(clk_sys),
	.ce(ce_4fsc),
	.enable(status[11]),
	.ntsc(ntsc),
	.s(cv_s),
	.x(cv_x),
	.ln(cv_ln),
	.fld(cv_fld),
	.cls(cc_cls)
);
wire        line_col, line_inv;

osd_m50552 osd_m50552
(
	.clk(clk_sys),
	.ce(ce_4fsc),
	.s_in(cv_s),
	.x(cv_x),
	.ln(cv_ln),
	.fld(cv_fld),
	.screen(osd_screen),
	.lang(osd_lang),
	.txt_we(txt_we),
	.txt_addr(txt_addr),
	.txt_data(txt_data),
	.bg((video_on && shown) ? 2'd0 : osd_bg),     // over the picture when it is on (DISPLAY, side change)
	.pic_off(!(video_on && shown)),
	.ntsc(ntsc),
	.br(burst_r),
	.bi(burst_i),
	.col(line_col),
	.inv(line_inv),
	.s_out(osd_s),
	.cls(osd_cls),
	.xo(osd_x),
	.lno(osd_ln),
	.fo(osd_fld)
);

pal_decoder pal_decoder
(
	.clk(clk_sys),
	.ce(ce_4fsc),
	.ntsc(ntsc),
	.s(osd_s),
	.x(osd_x),
	.ln(osd_ln),
	.fld(osd_fld),
	.r(),
	.g(),
	.b(),
	.xo(),
	.lno(),
	.fo(),
	.burst_r(burst_r),
	.burst_i(burst_i),
	.line_col(line_col),
	.line_inv(line_inv)
);

// Composite DAC code, aligned with ld_scan's output (one ce after the OSD): the replayed sample where the OSD
// passes the video, the OSD's composite level where it draws. Code = level * 255 / 54016 (add_cvbs.py).
function automatic [7:0] cv_dac(input [15:0] v, input n);   // white 54016 (PAL) / 51200 (NTSC) = code 255
	reg [27:0] q;
	begin
		q = (n ? v * 12'd1306 : v * 12'd1238) + 28'd131072;
		cv_dac = q[27:18] > 10'd255 ? 8'd255 : q[25:18];
	end
endfunction
reg  [7:0] cv_code1, cv_code2, cv_out;

// Chroma advance (menu, Off by default), a platform bridge: the MiSTer analogue output path delays the chroma band
// against luma, so colour trails to the right of edges on the TV (user, 2026-11-04: MiSTer's own composite output shows
// the same on this board, which is why its author uses an external filter; the disc's TBC has chroma and luma aligned
// within 0.1 us at the bar edges, and real players' output stages are built for composite). The composite is split into
// chroma (a 17-tap band-pass at fsc, about +-1.4 MHz) and its exact complement (luma and sync), and the luma is delayed
// by 2 x setting samples, so chroma reaches the TV that much earlier. Off: chroma + luma is the input, bit for bit.
// MOD. PAL (SYSTEM mode, NTSC discs on a PAL TV, OM p.46): the PALB board's NTSC -> pseudo-PAL conversion
// (rtl/modpal.v, docs/mod_pal.md). It does its own chroma advance (on its PAL chroma), so the split below runs Off.
reg [10:0] mp_n;                       // cv_out's index in its line
wire [7:0] mp_out;
wire       mp_en = ntsc && (sys_mode == 2'd0);
modpal modpal
(
	.clk(clk_sys),
	.ce(ce_4fsc),
	.x(cv_out),
	.n(mp_n),
	.adv(status[10:8]),
	.out(mp_out)
);
wire [2:0] cv_adv = mp_en ? 3'd0 : status[10:8];

reg  [7:0] yh [0:16];                  // input history, yh[0] newest
reg signed [10:0] ydl [0:14];          // luma history
reg signed [9:0]  c_d;
reg  [7:0] cv_yc;
integer yk;
function automatic signed [9:0] sx(input [7:0] v); sx = $signed({2'b00, v}); endfunction
wire signed [21:0] cbp = -22'sd5   * (sx(yh[0])  + sx(yh[16])) - 22'sd6 * (sx(yh[2]) + sx(yh[14]))
                       +  22'sd95  * (sx(yh[4])  + sx(yh[12])) - 22'sd245 * (sx(yh[6]) + sx(yh[10]))
                       +  22'sd323 *  sx(yh[8]);
wire signed [11:0] c_now = (cbp + 22'sd512) >>> 10;
wire signed [11:0] y_now = sx(yh[8]) - c_now;
wire signed [11:0] yc_sum = ydl[{cv_adv, 1'b0}] + c_d;
always @(posedge clk_sys) if (ce_4fsc) begin
	yh[0] <= mp_en ? mp_out : cv_out;
	for (yk = 1; yk < 17; yk = yk + 1) yh[yk] <= yh[yk - 1];
	ydl[0] <= y_now[10:0];
	for (yk = 1; yk < 15; yk = yk + 1) ydl[yk] <= ydl[yk - 1];
	c_d <= c_now[9:0];
	cv_yc <= (yc_sum < 0) ? 8'd0 : (yc_sum > 12'sd255) ? 8'd255 : yc_sum[7:0];
end

// Composite reconstruction, a platform bridge: the MiSTer VGA DAC is a zero-order hold at the rate the core updates
// it, with no reconstruction filter, while the player's CCD TBC output is a band-limited analogue signal (SM VDTB,
// docs/sm_video_audio.md). Held at 4fsc, the TBC samples carry full-strength images at 13.3 MHz and above, which a TV
// with a sampled (comb-filter) input folds back into the picture. So the samples are interpolated 4x to clk_sys
// (16fsc) before the DAC: a 48-tap Kaiser windowed-sinc low-pass (fc 7.4 MHz, beta 7.5), flat to 5 MHz within 0.3 dB
// (-0.6 dB at 5.5 MHz), images 68 dB or more down. Each phase sums to 1024, so levels are unchanged
// (docs/composite_output.md). cx[0] is the newest sample; phase p = 0..3 is the output clock within its period.
function automatic signed [11:0] cv_cf(input [1:0] ph, input [3:0] k);
	begin
		case ({ph, k})
		{2'd0, 4'd0}: cv_cf = 12'sd0;
		{2'd0, 4'd1}: cv_cf = 12'sd1;
		{2'd0, 4'd2}: cv_cf = -12'sd10;
		{2'd0, 4'd3}: cv_cf = 12'sd44;
		{2'd0, 4'd4}: cv_cf = -12'sd118;
		{2'd0, 4'd5}: cv_cf = 12'sd258;
		{2'd0, 4'd6}: cv_cf = 12'sd838;
		{2'd0, 4'd7}: cv_cf = 12'sd49;
		{2'd0, 4'd8}: cv_cf = -12'sd63;
		{2'd0, 4'd9}: cv_cf = 12'sd34;
		{2'd0, 4'd10}: cv_cf = -12'sd11;
		{2'd0, 4'd11}: cv_cf = 12'sd2;
		{2'd1, 4'd0}: cv_cf = 12'sd0;
		{2'd1, 4'd1}: cv_cf = -12'sd2;
		{2'd1, 4'd2}: cv_cf = -12'sd2;
		{2'd1, 4'd3}: cv_cf = 12'sd34;
		{2'd1, 4'd4}: cv_cf = -12'sd137;
		{2'd1, 4'd5}: cv_cf = 12'sd500;
		{2'd1, 4'd6}: cv_cf = 12'sd713;
		{2'd1, 4'd7}: cv_cf = -12'sd87;
		{2'd1, 4'd8}: cv_cf = -12'sd4;
		{2'd1, 4'd9}: cv_cf = 12'sd15;
		{2'd1, 4'd10}: cv_cf = -12'sd7;
		{2'd1, 4'd11}: cv_cf = 12'sd1;
		{2'd2, 4'd0}: cv_cf = 12'sd1;
		{2'd2, 4'd1}: cv_cf = -12'sd7;
		{2'd2, 4'd2}: cv_cf = 12'sd15;
		{2'd2, 4'd3}: cv_cf = -12'sd4;
		{2'd2, 4'd4}: cv_cf = -12'sd87;
		{2'd2, 4'd5}: cv_cf = 12'sd713;
		{2'd2, 4'd6}: cv_cf = 12'sd500;
		{2'd2, 4'd7}: cv_cf = -12'sd137;
		{2'd2, 4'd8}: cv_cf = 12'sd34;
		{2'd2, 4'd9}: cv_cf = -12'sd2;
		{2'd2, 4'd10}: cv_cf = -12'sd2;
		{2'd2, 4'd11}: cv_cf = 12'sd0;
		{2'd3, 4'd0}: cv_cf = 12'sd2;
		{2'd3, 4'd1}: cv_cf = -12'sd11;
		{2'd3, 4'd2}: cv_cf = 12'sd34;
		{2'd3, 4'd3}: cv_cf = -12'sd63;
		{2'd3, 4'd4}: cv_cf = 12'sd49;
		{2'd3, 4'd5}: cv_cf = 12'sd838;
		{2'd3, 4'd6}: cv_cf = 12'sd258;
		{2'd3, 4'd7}: cv_cf = -12'sd118;
		{2'd3, 4'd8}: cv_cf = 12'sd44;
		{2'd3, 4'd9}: cv_cf = -12'sd10;
		{2'd3, 4'd10}: cv_cf = 12'sd1;
		{2'd3, 4'd11}: cv_cf = 12'sd0;
		default: cv_cf = 12'sd0;
		endcase
	end
endfunction
reg  [7:0] cx [0:11];
reg  [1:0] cph;
reg signed [20:0] cprod [0:11];
reg  [7:0] cv_hi;
integer ck;
always @(posedge clk_sys) begin : cv_interp
	reg signed [24:0] acc;
	if (ce_4fsc) begin
		cx[0] <= cv_yc;
		for (ck = 1; ck < 12; ck = ck + 1) cx[ck] <= cx[ck - 1];
		cph <= 2'd0;
	end else cph <= cph + 2'd1;
	for (ck = 0; ck < 12; ck = ck + 1) cprod[ck] <= $signed({1'b0, cx[ck]}) * cv_cf(cph, ck[3:0]);
	acc = 25'sd512;
	for (ck = 0; ck < 12; ck = ck + 1) acc = acc + cprod[ck];
	cv_hi <= (acc < 0) ? 8'd0 : (acc[24:10] > 15'd255) ? 8'd255 : acc[17:10];
end

// R+G+B tied (docs/composite_output.md): the three 0.7 V outputs in parallel into the TV's 75 ohm reach 1.05 V at
// full scale (as voltage sources with 75 ohm each, or as current DACs with their 75 ohm terminations). Code 255
// (white, 1.0 V above the sync tip) is then T = 729 of 765 units: T = round(code * 20 / 7), split exactly over the
// three channels.
wire [21:0] cv_t_p = cv_hi * 14'd11703 + 22'd2048;           // code * 20/7 * 4096
wire  [9:0] cv_t   = cv_t_p[21:12];
wire [25:0] cv_t0  = cv_t * 16'd21846;                       // floor(T / 3) for T < 1000
wire [25:0] cv_t1  = (cv_t + 10'd1) * 16'd21846;
wire [25:0] cv_t2  = (cv_t + 10'd2) * 16'd21846;
always @(posedge clk_sys) if (ce_4fsc) begin
	cv_code1 <= cv_code;                    // the OSD's two-ce latency
	cv_code2 <= cv_code1;
	// the player's OSD, else the caption decoder box (white text; its black box at the 7.5 IRE setup, code 90), else
	// the replayed signal
	cv_out   <= (osd_cls != 2'd0) ? cv_dac(osd_s, ntsc) : (cc_cls == 2'd1) ? 8'd255 : (cc_cls == 2'd2) ? 8'd90 : cv_code2;
	mp_n     <= osd_x;                       // the sample cv_out now holds
end

wire  [7:0] pr, pg, pb;
wire [10:0] p_x;
wire  [8:0] p_ln;
wire        p_fld;

ld_scan ld_scan
(
	.clk(clk_sys),
	.ce(ce_4fsc),
	.x(osd_x),
	.ln(osd_ln),
	.fld(osd_fld),
	.cls((osd_cls != 2'd0) ? osd_cls : cc_cls),      // the caption box under the player's OSD
	.show(video_on && shown),
	.ntsc(ntsc),
	.crop_x(crop_x),
	.crop_y(crop_y),
	.pic_cols(pic_cols),
	.pic_rows(pic_rows),
	.lf_req(ls_lf_req),
	.lf_row(ls_lf_row),
	.lf_we(lf_we),
	.lf_addr(lf_addr),
	.lf_data(lf_data[47:0]),
	.r(pr),
	.g(pg),
	.b(pb),
	.xo(p_x),
	.lno(p_ln),
	.fo(p_fld)
);

///////////////////////   VIDEO OUT   ////////////////////////////
// Sync generated from the pixel's TBC position (p_x/p_ln/p_fld).
// TODO(M1 verification): align VSync/active-line range with the sync pulses embedded
// in the TBC lines; current values are the nominal PAL field structure.
//   HSync  : x in [0, 83)                    (4.7 us at 4fsc)
//   active : x in [185, 1107), field line in [22, 310) (VGA_DE: what the scaler shows)
//   RGB    : every line of the picture, VBI lines included (the frame buffer keeps field lines 12-311), as the
//            player's video signal carries them. The scaler (HDMI) shows DE only.
//   Composite: every sample goes to the DAC. Platform rule: stock MiSTer sys_top.v zeroes the analogue outputs
//            wherever DE is low (VGA_scanlines .din(de_emu ? rgb : 0)); on the composite line 0 is sync-tip level,
//            so that would wipe the colour burst (the TV then kills the colour: a grey picture) and turn the blanking
//            into one long sync pulse. The core builds with MISTER_VGA_RAW (qsf), which leaves the outputs as the
//            core drives them. DE stays the active picture in both modes: the framework's menu (sys/osd.v) needs
//            real line and frame blanking in DE to place itself, and the HDMI scaler shows DE only.
//   VSync  : the broad pulses, 2.5 lines: the first field's from its line 0; the second field's from the middle of
//            the first field's line 312 (PAL line 313), as on the disc (tbc_timing, cvbs_scan)

// NTSC (910 x 263/262): HSync 0-66 (4.7 us), active samples 134-893 and field lines 20-261, VSync on the broad
// pulses: first field lines 3-5, second field from the middle of line 2 to the middle of line 5 (cvbs_scan)
wire hsync = ntsc ? (p_x < 11'd67) : (p_x < 11'd83);
wire hact  = ntsc ? ((p_x >= 11'd134) && (p_x < 11'd894)) : ((p_x >= 11'd185) && (p_x < 11'd1107));
wire vact  = ntsc ? ((p_ln >= 9'd20) && (p_ln < 9'd262)) : ((p_ln >= 9'd22) && (p_ln < 9'd310));
wire vsync = ntsc ? (!p_fld ? ((p_ln >= 9'd3) && (p_ln <= 9'd5))
                            : ((p_ln == 9'd2 && p_x >= 11'd455) || p_ln == 9'd3 || p_ln == 9'd4 || (p_ln == 9'd5 && p_x < 11'd455)))
                  : (!p_fld ? ((p_ln < 9'd2) || (p_ln == 9'd2 && p_x < 11'd567) || (p_ln == 9'd312 && p_x >= 11'd567))
                            : (p_ln < 9'd2));

reg  [7:0] vr, vg, vb;
reg        vhs, vvs, vde, vf1;
// composite: every clk_sys (the interpolated samples); RGB: once per 4fsc sample
always @(posedge clk_sys) if (status[6] || ce_4fsc) begin
	if (status[6]) begin
		// the menu's choice decides the output, so the player's raster and OSD go out as composite even with no
		// disc; the disc's own samples take over once the Laserdisc Main has switched to the composite stream
		// composite on green, red and blue at 0, as MiSTer's CVBS output (sys yc_out) but the waveform is the
		// disc's own: every sample of the line, its sync and burst included
		if (status[7]) begin
			vr  <= cv_t0[23:16];
			vg  <= cv_t1[23:16];
			vb  <= cv_t2[23:16];
		end else begin
			vr  <= 8'd0;
			vg  <= cv_hi;
			vb  <= 8'd0;
		end
	end else begin
		vr  <= hact ? pr : 8'd0;
		vg  <= hact ? pg : 8'd0;
		vb  <= hact ? pb : 8'd0;
	end
end
always @(posedge clk_sys) if (ce_4fsc) begin
	vhs <= hsync;
	vvs <= vsync;
	vde <= hact && vact;
	vf1 <= p_fld;
end

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_4fsc;
assign VGA_R  = vr;
assign VGA_G  = vg;
assign VGA_B  = vb;
assign VGA_HS = vhs;
assign VGA_VS = vvs;
assign VGA_DE = vde;
assign VGA_F1 = vf1;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = run & act_cnt[24];

endmodule
