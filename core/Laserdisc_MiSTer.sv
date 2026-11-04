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
	"O[5:4],SYSTEM mode,PAL,NTSC,MOD.PAL;",
	"O[6],Video output,RGB,Composite;",      // composite: the TBC samples on the VGA connector (docs/composite_output.md)
	"O[7],Composite DAC,Green (0.7V),R+G+B tied (1.0V);",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;",
	"V,v",`BUILD_DATE
};

// player <-> reader/OSD/menu (declared before use)
wire        video_on, resync, disc, sys_mode_set;
wire [15:0] play_frame, frames;
wire  [2:0] osd_screen;
wire  [1:0] osd_bg, sys_mode;
wire  [3:0] player_state;
wire  [1:0] audio_sel;

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
	.status_in({status[127:6], sys_mode, status[3:0]}),   // SYSTEM key writes the mode back to the menu
	.status_set(sys_mode_set),
	.status_menumask(1'b0),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// clk_sys = 4 x 4fsc(PAL) = 70.9379 MHz; ce_4fsc = clk_sys / 4
wire clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

wire reset = RESET | status[0] | buttons[1];

reg [1:0] ce_cnt;
always @(posedge clk_sys) ce_cnt <= ce_cnt + 2'd1;
wire ce_4fsc = (ce_cnt == 2'd0);

///////////////////////   TIMING   /////////////////////////////
// ld-decode PAL TBC timing. run holds the origin for one ce on resync: the player switching from its own
// raster to disc video restarts line/field timing at that instant (docs/player_logic.md, the picture-on jump).

wire [10:0] t_x;
wire  [8:0] t_ln;
wire        t_fld, t_line_start;
reg         run;

always @(posedge clk_sys) begin
	if (reset || resync) run <= 1'b0;
	else if (ce_4fsc) run <= 1'b1;
end

tbc_timing tbc_timing
(
	.clk(clk_sys),
	.ce(ce_4fsc),
	.run(run),
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
wire [11:0] aud_waddr;
wire [63:0] aud_wdata;
wire [127:0] pic_vbi;
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
	.cvbs(cvbs),
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
	.pic_vbi(pic_vbi),
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
	.l(aud_l),
	.r(aud_r)
);

assign AUDIO_S = 1'b1;
assign AUDIO_L = aud_l;
assign AUDIO_R = aud_r;

///////////////////////   PLAYER LOGIC   /////////////////////////
// Keyboard -> CLD-1750 controls (docs/player_logic.md):
//   Enter PLAY, Space >/II, P PAUSE, S STOP, E OPEN/CLOSE, Left/Right SCAN (hold), , . STEP, Y SYSTEM, A AUDIO D/A
reg        key_tg;
reg        k_play, k_playpause, k_pause, k_stop, k_eject, k_step_f, k_step_r, k_system, k_audio;
reg        scan_f, scan_r;
always @(posedge clk_sys) begin
	{k_play, k_playpause, k_pause, k_stop, k_eject, k_step_f, k_step_r, k_system, k_audio} <= 9'd0;
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
			9'h1_74: scan_f      <= ps2_key[9];
			9'h1_6B: scan_r      <= ps2_key[9];
			default: ;
		endcase
	end
end


player player
(
	.clk(clk_sys),
	.reset(reset),
	.frame_tick(frame_tick),
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
	.disc(disc),
	.frames(frames),
	.sys_mode_in(status[5:4]),
	.sys_mode(sys_mode),
	.sys_mode_set(sys_mode_set),
	.video_on(video_on),
	.frame(play_frame),
	.resync(resync),
	.osd_screen(osd_screen),
	.osd_bg(osd_bg),
	.state(player_state),
	.audio_sel(audio_sel)
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
	.bg(osd_bg),
	.pic_off(!(video_on && shown)),
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
function automatic [7:0] cv_dac(input [15:0] v);
	reg [27:0] q;
	begin
		q = v * 12'd1238 + 28'd131072;
		cv_dac = q[27:18] > 10'd255 ? 8'd255 : q[25:18];
	end
endfunction
reg  [7:0] cv_code1, cv_code2, cv_out;

// R+G+B tied (docs/composite_output.md): the three 0.7 V outputs in parallel into the TV's 75 ohm reach 1.05 V at
// full scale (as voltage sources with 75 ohm each, or as current DACs with their 75 ohm terminations). Code 255
// (white, 1.0 V above the sync tip) is then T = 729 of 765 units: T = round(code * 20 / 7), split exactly over the
// three channels.
wire [21:0] cv_t_p = cv_out * 14'd11703 + 22'd2048;          // code * 20/7 * 4096
wire  [9:0] cv_t   = cv_t_p[21:12];
wire [25:0] cv_t0  = cv_t * 16'd21846;                       // floor(T / 3) for T < 1000
wire [25:0] cv_t1  = (cv_t + 10'd1) * 16'd21846;
wire [25:0] cv_t2  = (cv_t + 10'd2) * 16'd21846;
always @(posedge clk_sys) if (ce_4fsc) begin
	cv_code1 <= cv_code;                    // the OSD's two-ce latency
	cv_code2 <= cv_code1;
	cv_out   <= (osd_cls == 2'd0) ? cv_code2 : cv_dac(osd_s);
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
	.cls(osd_cls),
	.show(video_on && shown),
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
//   Composite: VGA_DE is high for every sample of every line. Platform rule (MiSTer sys_top.v, VGA_scanlines
//            .din(de_emu ? rgb : 0)): the framework forces the analogue outputs to 0 wherever DE is low. On the
//            composite line 0 is sync-tip level, so a normal DE would wipe the colour burst (the TV then kills the
//            colour: a grey picture) and turn the whole blanking interval into one long sync pulse.
//   VSync  : the broad pulses, 2.5 lines: the first field's from its line 0; the second field's from the middle of
//            the first field's line 312 (PAL line 313), as on the disc (tbc_timing, cvbs_scan)

wire hsync = (p_x < 11'd83);
wire hact  = (p_x >= 11'd185) && (p_x < 11'd1107);
wire vact  = (p_ln >= 9'd22) && (p_ln < 9'd310);
wire vsync = !p_fld ? ((p_ln < 9'd2) || (p_ln == 9'd2 && p_x < 11'd567) || (p_ln == 9'd312 && p_x >= 11'd567))
                    : (p_ln < 9'd2);

reg  [7:0] vr, vg, vb;
reg        vhs, vvs, vde, vf1;
always @(posedge clk_sys) if (ce_4fsc) begin
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
			vg  <= cv_out;
			vb  <= 8'd0;
		end
	end else begin
		vr  <= hact ? pr : 8'd0;
		vg  <= hact ? pg : 8'd0;
		vb  <= hact ? pb : 8'd0;
	end
	vhs <= hsync;
	vvs <= vsync;
	vde <= status[6] ? 1'b1 : (hact && vact);   // composite: every sample passes the framework (see above)
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
