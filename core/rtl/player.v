// CLD-1750 player logic, slice 1 (docs/player_logic.md): transport states, timings and OSD screens.
//
// Behaviour per the CLD-1750 operating instructions (OM) and footage F1 (durations measured at 25 frames/s):
//   CLOSE 7.5 s, spin-up "PLAY" 5.5 s, disc info 3.6 s, then picture with a timing switch (resync).
//   PAUSE blanks picture and sound (OM p.50); STOP returns to the start for the next PLAY (OM p.50);
//   STEP freezes and steps frames (CAV, OM p.68); SCAN is ~x10 for ~2 s then ~x30 (OM p.56).
//   Spin-down before the tray opens: 2 s (EST, unmeasured). OPEN screen text: EST.
//   AUDIO D/A (D/A/CX): LD with analog audio carrying CX auto-switching signals cycles stereo -> L channel ->
//   R channel (CLD1750K OM p.20 figure; European OM p.54 D/A/CX). The digital-audio cycle and the six-step CX cycle
//   of discs without the signals are not implemented (no digital audio source, no CX expander yet).
//   Two-side play (docs/player_logic.md): PLAY on a two-sided disc plays side A, then turns and plays side B;
//   DISC SIDE A instead of PLAY plays side A only, then stops (CLD1750K/2750K OM p.14). The turn holds the last
//   picture, with no sound, for 11.6 s, then side B's first frame cuts in and plays (CLD-D925 footage 26dn8tT74Io,
//   DISC SIDE B pressed at 76.0 s, side-B picture at 87.6 s; user: "hold the last frame from side 1 until side 2
//   comes up and then just starts playing side 2"). The auto turn at the end of a side is taken to be the same.
//   During the turn the OSD shows "A > B" (CLD-D925 tour kT6GRXhZ4, 772 s "B > A"; user: D925 for side switching).
//   SEARCH / CHAPTER (docs/player_logic.md; European OM pp.58-62):
//     Chapter Search: digits, then PLAY or PAUSE. CHP/TM switches the entry to Frame Number (CAV) or Time Number
//     (CLV, M.SS) and back; CLEAR clears the entry, or cancels a search under way. Chapter Skip: back to the start of
//     the chapter playing, or forward one chapter; presses before the picture returns accumulate.
//     The search jumps and reads the disc's own codes where it lands (picture number, chapter number, CLV time code,
//     IEC 60857 10.1.3/10.1.5/10.1.6/10.1.10), bisecting the frame index, with the picture off and SEARCH /
//     CHAPTER nn on the background (F1 CLD-1750; F2 CLD-3080), then picture-on as at the start of play. It takes at
//     least 0.77 s (F1 304.67-305.44 s). Results: PLAY plays; CAV with PAUSE, CAV via CHP/TM ("normal search") and
//     Frame Number Search give a still frame (OM p.58, p.62); CLV with PAUSE pauses.
//     At the start of play a disc with chapter numbers is first searched to chapter 1 (F1: SEARCH / CHAPTER  1).
//   DISPLAY (LD without TOC, OM p.75): CAV frame number <-> off; CLV elapsed time <-> off, in the CLD-1750's form
//     (European OM p.44 figure "3 12.49 ... PLAY": chapter, frame or time, the state word at the right).
//   MULTI-SPEED (CAV, OM p.68): forward / reverse starts at 1/4; + / - step x3 x2 x1 1/2 1/4 1/8 1/16 1/30 1/90;
//     sound muted; DISPLAY shows the speed. CLV discs: STEP or MULTI-SPEED shows "CLV" for about 2 s. Picture stop
//     codes (IEC 60857 10.1.4) still the picture at x1 and slower, normal play included.
//   REPEAT (OM p.70-72): REPEAT A marks a point (PLAY returns to it); A then B repeats the section; B alone repeats
//     the chapter, twice the side (a disc without chapters: the side); CLEAR ends it. The words of OM p.44 show for
//     3 s. A repeat's jump is a search without the SEARCH text: picture off, then picture-on (EST).
//   PROGRAM (OM p.74): PGM opens the programme (up to 24 chapters); a chapter keyed in is taken after about 1 s (the
//     figure's "After approx. 1 second"), so two digits make 10 and over; CLEAR takes back the last; PLAY searches to
//     the first step and plays, each chapter's end searches to the next, and after the last the player stops.
//     CLEAR during programme play ends it (play continues); opening the tray clears the programme.
//     RANDOM PLAY is for LDs with a TOC (OM p.66), which these captures lack: not available.
//   LAST MEMORY (European OM p.12): switching off during LD play stores the position; at the next power-on play
//     starts from it. A core reset (MiSTer menu Reset) stands for the power switch: the position survives it, and
//     when the same disc comes up again, play resumes there with "LAST MEMORY" (OM p.44 words) shown for 3 s.
//   DIGITAL LEVEL CONTROL (European OM p.12): the digital sound 0 to -25 dB (1 dB steps: EST), "OUTPUT LEVEL" shown
//     for 3 s (OM p.44 words). A new disc starts at 0 dB (EST).
//   LANGUAGE (European OM p.40): ENGLISH -> FRANCAIS -> DEUTSCH -> ITALIANO, kept through power-off (the MiSTer
//     menu option holds it); the OSD words in each language from OM p.44-45.
//   AUDIO D/A and SYSTEM show the OM p.44 words for the new setting (DIGITAL / ANALOG + STEREO / 1/L / 2/R; PAL /
//     NTSC 3.58) on the bottom row for 3 s (EST: placement and time), and DISPLAY keeps the sound mode there (as the
//     CLD-D925 does).
module player (
	input             clk,
	input             reset,
	input             frame_tick,   // one pulse per output frame (25 Hz PAL, 29.97 Hz NTSC)
	input             ntsc,         // the timings below are seconds: counted in NTSC frames they are x 1.1988

	// key events (pulses) and held keys, already mapped from the keyboard
	input             k_play,       // PLAY >
	input             k_playpause,  // >/II (front panel)
	input             k_pause,      // PAUSE II
	input             k_stop,       // STOP
	input             k_eject,      // OPEN/CLOSE
	input             k_step_f,
	input             k_step_r,
	input             k_system,
	input             k_audio,      // AUDIO D/A (D/A/CX on the remote)
	input             scan_f,       // held
	input             scan_r,       // held
	input             k_side_a,     // DISC SIDE A
	input             k_side_b,     // DISC SIDE B
	input             k_digit,      // a digit key (DIRECT SEARCH 0-9)
	input       [3:0] digit,
	input             k_clear,      // CLEAR
	input             k_chptm,      // CHP/TM
	input             k_skip_f,     // CHAPTER SKIP forward
	input             k_skip_r,     // CHAPTER SKIP back
	input             k_display,    // DISPLAY
	input             k_ms_f,       // MULTI-SPEED forward / reverse (OM p.68)
	input             k_ms_r,
	input             k_sp_up,      // MULTI-SPEED + / -
	input             k_sp_dn,
	input             k_rep_a,      // REPEAT A / B (OM p.70-72)
	input             k_rep_b,
	input             k_pgm,        // PGM (OM p.74)
	input             k_lang,       // LANGUAGE (front panel, European OM p.40)
	input             k_lvl_up,     // the SCAN/LEVEL control as LEVEL: digital level up / down (OM p.12)
	input             k_lvl_dn,
	output reg  [4:0] dlc,          // DIGITAL LEVEL CONTROL, dB down (0-25)
	input       [1:0] lang_in,      // the OSD language from the MiSTer menu
	output reg  [1:0] lang,         // 0 English, 1 French, 2 German, 3 Italian
	output reg        lang_set,     // pulse: LANGUAGE changed it (write back to the menu)

	input             new_pic,      // ld_stream: a decoded picture went up ...
	input      [15:0] pic_frame,    // ... this frame index
	input     [127:0] pic_vbi,      // ... with these VBI codes: {f2 line 17, f2 line 16, f1 line 17, f1 line 16}

	input             disc,         // a TBC image is loaded
	input      [15:0] frames,
	input             two_sided,    // the disc's other side is available
	input             side_b,       // the side loaded is B
	input      [12:0] load_id,      // changes when a disc is loaded from the MiSTer menu or an MGL
	input             has_digital,  // the disc carries digital (EFM) audio

	input       [1:0] sys_mode_in,  // SYSTEM mode from the MiSTer menu (0 MOD. PAL, 1 NTSC: OM p.46)
	output reg  [1:0] sys_mode,
	output reg        sys_mode_set, // pulse: player changed SYSTEM mode (write back to the menu)

	output reg        video_on,
	output reg [15:0] frame,
	output reg        resync,       // pulse: switch output timing to the disc (picture on)
	output reg  [2:0] osd_screen,   // ids: tools/osd/gen_osd_rom.py; 7 = the variable text (osd_text.v)
	output reg  [1:0] txt_l0,       // osd_text.v: row 0 left, row 1 left, row 0 right, their numbers
	output reg  [1:0] txt_l1,
	output reg  [3:0] txt_r0,
	output reg        txt_side_b,
	output reg        txt_chap_v,
	output reg  [7:0] txt_chap,
	output reg  [4:0] txt_msg,
	output reg        txt_pg_show,
	output reg  [4:0] txt_pg_n,
	output reg [191:0] txt_pg_list,
	output reg        txt_pg_pend_v,
	output reg  [7:0] txt_pg_pend,
	output reg [19:0] txt_n0,
	output reg [19:0] txt_n1,
	output      [1:0] osd_bg,       // 1 blue, 2 black (OM p.46)
	output reg  [3:0] state,
	output reg        hold,         // side change: the picture on screen stays up
	output reg  [1:0] want_side,    // during a turn: 1 A, 2 B (else 0); the HPS changes files when it changes
	output reg  [1:0] audio_sel,    // 0 stereo, 1 L channel, 2 R channel
	output reg        audio_src     // 0 analogue soundtrack, 1 digital
);

// 7.5 s, 5.5 s, 3.6 s, 2.0 s, 2.0 s (PAL frames at 25/s, NTSC at 30000/1001 per s)
wire [15:0] T_CLOSE    = ntsc ? 16'd225 : 16'd188;
wire [15:0] T_SPINUP   = ntsc ? 16'd165 : 16'd138;
wire [15:0] T_INFO     = ntsc ? 16'd108 : 16'd90;
wire [15:0] T_SPINDOWN = ntsc ? 16'd60  : 16'd50;
wire [15:0] T_LOWSCAN  = ntsc ? 16'd60  : 16'd50;
wire [15:0] T_TURN     = ntsc ? 16'd348 : 16'd290;   // 11.6 s (CLD-D925 footage, above)
wire [15:0] T_SRCH     = ntsc ? 16'd23  : 16'd19;    // 0.77 s, the shortest search (F1)
wire [15:0] T_PROBE    = ntsc ? 16'd108 : 16'd90;    // no picture from a jump for 3.6 s: the search gives up
wire  [6:0] T_CLVW     = ntsc ? 7'd60   : 7'd50;     // the CLV warning, about 2 s (OM p.68)
localparam S_IDLE = 4'd0, S_OPEN = 4'd1, S_CLOSING = 4'd2, S_STOP = 4'd3, S_SPINDOWN = 4'd4,
           S_SPINUP = 4'd5, S_INFO = 4'd6, S_PLAY = 4'd7, S_PAUSE = 4'd8, S_STILL = 4'd9, S_SCAN = 4'd10,
           S_TURN = 4'd11, S_SEARCH = 4'd12, S_MULTI = 4'd13;
localparam K_CH = 2'd0, K_PIC = 2'd1, K_TIME = 2'd2;            // what a search compares
localparam R_PLAY = 2'd0, R_STILL = 2'd1, R_PAUSE = 2'd2;       // what follows it

reg [15:0] t;              // frames in the current state
reg        play_after;     // CLOSING was started by PLAY
reg  [1:0] sys_seen, lang_seen;
reg        scan_dir;       // 1 = forward
reg        side_a_only;    // DISC SIDE A started play: stop at the end of side A
reg [12:0] seen_id;        // the load number already acted on
reg        reload;         // a disc was loaded while another played: open the tray, then close and play
wire       new_load = disc && load_id != seen_id;
wire       turn_done = disc && (side_b == (want_side == 2'd2));   // the side asked for is loaded

// SYSTEM mode (OM p.46): 0 MOD. PAL, 1 NTSC; only NTSC discs have modes. Background: black in MOD. PAL at power-on or
// with an NTSC disc; blue in NTSC mode, and for a PAL disc ("PAL mode").
assign osd_bg = (sys_mode == 2'd0 && !(disc && !ntsc)) ? 2'd2 : 2'd1;

// the menu value: 0 MOD. PAL, 1 NTSC; 2 is the earlier menu's MOD. PAL (a saved setting from before 2026-11-05)
wire [1:0] sys_m = (sys_mode_in == 2'd1) ? 2'd1 : 2'd0;

wire play_key = k_play | k_playpause;
wire [15:0] last = (frames == 16'd0) ? 16'd0 : frames - 16'd1;

task go(input [3:0] s);
	begin state <= s; t <= 16'd0; end
endtask

// ------------------------------------------------------------------ the disc's codes (IEC 60857, ld-decode vbidecoder)
wire [23:0] w0 = pic_vbi[23:0], w1 = pic_vbi[55:32], w2 = pic_vbi[87:64], w3 = pic_vbi[119:96];
function d9(input [3:0] d); d9 = d <= 4'd9; endfunction
// 10.1.3 CAV picture number: 0xF, then 5 BCD digits in the low 19 bits (the first 0-7; bit 19 is set, as on
// GGV1069: 0xF81841 = picture 1841, and ld-decode ignores it)
function is_pic(input [23:0] w);
	is_pic = w[23:20] == 4'hF && d9(w[15:12]) && d9(w[11:8]) && d9(w[7:4]) && d9(w[3:0]);
endfunction
// 10.1.5 chapter number: 0x8 x x D D D, the chapter in 2 BCD digits (the first 0-7)
function is_ch(input [23:0] w);
	is_ch = w[23:20] == 4'h8 && w[11:0] == 12'hDDD && d9(w[15:12]);
endfunction
// 10.1.6 CLV programme time code: 0xF h D D m m (hours, minutes)
function is_clvt(input [23:0] w);
	is_clvt = w[23:20] == 4'hF && w[15:8] == 8'hDD && d9(w[19:16]) && w[7:4] <= 4'd5 && d9(w[3:0]);
endfunction
// 10.1.10 CLV picture number: 0x8 s E s p p, the seconds' tens digit A-F
function is_clvs(input [23:0] w);
	is_clvs = w[23:20] == 4'h8 && w[15:12] == 4'hE && w[19:16] >= 4'hA && d9(w[11:8]);
endfunction

// 10.1.4 picture stop code, lines 16 or 17
wire        stopc_c = w0 == 24'h82CFFF || w1 == 24'h82CFFF || w2 == 24'h82CFFF || w3 == 24'h82CFFF;
wire        pv_c  = is_pic(w1) | is_pic(w3);
wire [19:0] pn_c  = is_pic(w1) ? {1'b0, w1[18:0]} : {1'b0, w3[18:0]};
wire        cv_c  = is_ch(w1) | is_ch(w3);
wire  [7:0] cn_c  = is_ch(w1) ? {1'b0, w1[18:12]} : {1'b0, w3[18:12]};
wire        tv_c  = is_clvt(w1) | is_clvt(w3);
wire [23:0] tw_c  = is_clvt(w1) ? w1 : w3;
wire        sv_c  = is_clvs(w0) | is_clvs(w2);
wire [23:0] sw_c  = is_clvs(w0) ? w0 : w2;
wire  [3:0] t_h_c = tw_c[19:16];
wire  [6:0] t_m_c = tw_c[7:4] * 4'd10 + tw_c[3:0];
wire  [3:0] s_tn_c = sv_c ? sw_c[19:16] - 4'hA : 4'd0;
wire  [3:0] s_un_c = sv_c ? sw_c[11:8] : 4'd0;
wire [16:0] tsec_c = t_h_c * 17'd3600 + t_m_c * 17'd60 + s_tn_c * 17'd10 + s_un_c;   // seconds from the side's start
wire  [9:0] tmin_c = t_h_c * 10'd60 + t_m_c;                                      // elapsed minutes
// the decoded codes, registered one clock after the picture's (timing: the time code's sums feed the search)
reg        stopc, pv, cv, tv, new_pic_d;
reg [19:0] pn;
reg  [7:0] cn;
reg [16:0] tsec;
reg  [9:0] tmin;
reg  [3:0] s_tn, s_un;
reg [15:0] pic_frame_d;
always @(posedge clk) begin
	stopc <= stopc_c; pv <= pv_c; cv <= cv_c; tv <= tv_c; pn <= pn_c; cn <= cn_c;
	tsec <= tsec_c; tmin <= tmin_c; s_tn <= s_tn_c; s_un <= s_un_c;
	new_pic_d <= new_pic; pic_frame_d <= pic_frame;
end
// elapsed minutes in 3 BCD digits (double dabble, < 1000)
function [11:0] bcd3(input [9:0] v);
	integer i;
	reg [21:0] s;
	begin
		s = {12'd0, v};
		for (i = 0; i < 10; i = i + 1) begin
			if (s[13:10] >= 4'd5) s[13:10] = s[13:10] + 4'd3;
			if (s[17:14] >= 4'd5) s[17:14] = s[17:14] + 4'd3;
			if (s[21:18] >= 4'd5) s[21:18] = s[21:18] + 4'd3;
			s = s << 1;
		end
		bcd3 = s[21:10];
	end
endfunction
// a time number entered as M.SS (OM p.62: 12 min 34 s is 1, 2, 3, 4): the last two digits are seconds
function [16:0] ent_secs(input [19:0] e);
	ent_secs = (e[19:16] * 17'd100 + e[15:12] * 17'd10 + e[11:8]) * 17'd60 + e[7:4] * 17'd10 + e[3:0];
endfunction
function [7:0] bcd_inc(input [7:0] b);
	bcd_inc = (b[3:0] == 4'd9) ? {b[7:4] + 4'd1, 4'd0} : b + 8'd1;
endfunction
function [7:0] bcd_dec(input [7:0] b);
	bcd_dec = (b == 8'h01 || b == 8'h00) ? 8'h01 : (b[3:0] == 4'd0) ? {b[7:4] - 4'd1, 4'd9} : b - 8'd1;
endfunction

// what the player knows of the disc from the pictures it has seen
reg        disc_cav, disc_clv;
reg        cur_pic_v, cur_ch_v, cur_t_v;
reg [19:0] cur_pic;
reg  [7:0] cur_ch;
reg [19:0] cur_time;                 // {minutes 3 BCD, seconds 2 BCD} for DISPLAY

// digit entry
reg [19:0] ent;
reg  [2:0] ent_n;
reg        ent_kind;                 // 0 chapter, 1 frame (CAV) / time (CLV)
reg        ent_normal;               // entered through CHP/TM ("normal search")
reg        disp_on;                  // DISPLAY
reg  [2:0] msg_src;                  // the bottom-row message: 1 audio, 2 SYSTEM, 3 repeat / LAST MEMORY, 4 level
reg        lm_show;                  // the message is LAST MEMORY
reg  [3:0] ms_sp;                    // multi-speed: 0 x3, 1 x2, 2 x1, 3 1/2, 4 1/4, 5 1/8, 6 1/16, 7 1/30, 8 1/90
reg        ms_dir;                   // 1 forward
reg  [6:0] ms_cnt, clv_t;
reg  [2:0] rep;                      // 0 none, 1 memory, 2 A-B, 3 chapter, 4 side
reg [15:0] rep_a, rep_b;
reg  [7:0] rep_ch;
reg        s_quiet;                  // a repeat's jump: no SEARCH text
reg        pg_edit, pg_play, pg_rep; // the programme screen; programme playback; program repeat (OM p.72)
reg  [4:0] pg_n, pg_i;
reg [191:0] pg;
reg        lm_v = 1'b0, lm_arm = 1'b0;   // LAST MEMORY: not cleared by reset (the power switch)
reg [15:0] lm_frame = 16'd0;
reg [12:0] lm_id = 13'd0;
reg        pg_dv;                    // a chapter being keyed in
reg  [7:0] pg_dval;
reg  [6:0] pg_dt;                    // frames until it is taken (about 1 s)
wire [6:0] T_PGDIG = ntsc ? 7'd30 : 7'd25;
wire [7:0] pg_cur = pg[{pg_i, 3'b000} +: 8];
wire [6:0] ms_per = (ms_sp == 4'd3) ? 7'd2 : (ms_sp == 4'd4) ? 7'd4 : (ms_sp == 4'd5) ? 7'd8 :
                    (ms_sp == 4'd6) ? 7'd16 : (ms_sp == 4'd7) ? 7'd30 : 7'd90;
wire [1:0] ms_k   = (ms_sp == 4'd0) ? 2'd3 : (ms_sp == 4'd1) ? 2'd2 : 2'd1;
reg  [6:0] msg_t;                    // frames left
wire [6:0] T_MSG = ntsc ? 7'd90 : 7'd75;     // 3 s (EST)
reg        turn_from_b;

// the search
reg  [1:0] s_kind, s_then;
reg [19:0] s_tgt;
reg  [7:0] s_ch;                     // the chapter shown
reg [15:0] s_lo, s_hi, s_mid, s_back_frame;
reg  [3:0] s_try, s_back;
reg        s_first, s_wait, s_done, s_skip, pend;
reg [15:0] s_wt;
reg  [1:0] p_kind, p_then;           // a search keyed in at STOP, made after spin-up
reg [19:0] p_tgt;
wire        s_val  = (s_kind == K_CH) ? cv : (s_kind == K_PIC) ? pv : tv;
wire [19:0] s_key  = (s_kind == K_CH) ? {12'd0, cn} : (s_kind == K_PIC) ? pn : {3'd0, tsec};
wire [15:0] s_mid0 = s_first ? ((pic_frame_d > s_hi) ? s_hi : (pic_frame_d < s_lo) ? s_lo : pic_frame_d)
                             : s_lo + ((s_hi - s_lo) >> 1);
wire [16:0] s_sum  = {1'b0, s_mid0} + {13'd0, s_try};
wire [15:0] s_probe = (s_sum > {1'b0, s_hi}) ? s_hi : s_sum[15:0];

task start_search(input [1:0] kind, input [19:0] tgt, input [1:0] then_, input skip);
	begin
		s_kind <= kind; s_then <= then_; s_skip <= skip; s_quiet <= 1'b0;
		s_tgt <= (kind == K_TIME) ? {3'd0, ent_secs(tgt)} : tgt;
		s_ch <= tgt[7:0];
		s_lo <= 16'd0; s_hi <= last; s_first <= 1'b1; s_try <= 4'd0; s_wait <= 1'b0; s_done <= 1'b0;
		s_back <= state; s_back_frame <= frame; s_wt <= 16'd0;
		video_on <= 1'b0;
		txt_n1 <= (kind == K_CH) ? {12'd0, tgt[7:0]} : tgt;
		txt_l1 <= (kind == K_CH) ? 2'd1 : (kind == K_PIC) ? 2'd2 : 2'd3;
		ent <= 20'd0; ent_n <= 3'd0; ent_kind <= 1'b0; ent_normal <= 1'b0;
		go(S_SEARCH);
	end
endtask

// a repeat's jump to a known frame: the search without its text
task jump(input [15:0] f);
	begin
		s_kind <= K_PIC; s_then <= R_PLAY; s_skip <= 1'b0; s_quiet <= 1'b1;
		s_lo <= f; s_hi <= f; s_done <= 1'b1; s_wait <= 1'b0; frame <= f;
		s_back <= S_PLAY; s_back_frame <= frame; s_wt <= 16'd0; video_on <= 1'b0;
		go(S_SEARCH);
	end
endtask

// the entry's search, from a PLAY or PAUSE key
wire       ent_go   = ent_n != 3'd0 && (play_key || k_pause);
wire [1:0] ent_k    = !ent_kind ? K_CH : disc_clv ? K_TIME : K_PIC;
wire [1:0] ent_then = (ent_k == K_PIC) ? R_STILL :                                   // OM p.62
                      k_pause ? (disc_clv ? R_PAUSE : R_STILL) :
                      (ent_k == K_CH && ent_normal && disc_cav) ? R_STILL : R_PLAY;  // OM p.58 (CAV, normal search)
wire [19:0] ent_t   = !ent_kind ? {12'd0, ent[7:0]} : ent;

always @(posedge clk) begin
	resync <= 1'b0;
	sys_mode_set <= 1'b0;

	// AUDIO D/A (CLD1750K OM p.20, "Switching audio"):
	//   LD with digital audio: digital (stereo) -> analog (stereo) -> L of analog -> R of analog -> L of digital ->
	//   R of digital -> digital (stereo);  LD with analog audio (CX auto-switching signals): stereo -> L -> R.
	// A newly loaded disc starts at the cycle's entry: digital stereo if it has digital audio, else stereo (EST: the
	// manual's diagram starts there; the power-on choice is not stated). (PAL digital discs carry no analogue
	// soundtrack: "no sound is heard if analog audio part is selected", European OM p.54.)
	if (new_load) begin audio_sel <= 2'd0; audio_src <= has_digital; end
	else if (k_audio) begin
		if (!has_digital) begin audio_src <= 1'b0; audio_sel <= (audio_sel == 2'd2) ? 2'd0 : audio_sel + 2'd1; end
		else if (audio_src) begin
			if (audio_sel == 2'd0) audio_src <= 1'b0;            // digital stereo -> analog stereo
			else audio_sel <= (audio_sel == 2'd2) ? 2'd0 : 2'd2; // digital L -> digital R -> digital stereo
		end else begin
			if (audio_sel == 2'd2) begin audio_src <= 1'b1; audio_sel <= 2'd1; end   // analog R -> digital L
			else audio_sel <= audio_sel + 2'd1;                  // analog stereo -> L -> R
		end
	end

	// SYSTEM mode: the menu and the SYSTEM key both set it; whichever changed last wins. The key acts with an NTSC
	// disc only: PAL discs play as PAL whatever the mode (OM p.46 table)
	lang_set <= 1'b0;
	lang_seen <= lang_in;
	if (lang_in != lang_seen) lang <= lang_in;
	if (k_lang) begin lang <= lang + 2'd1; lang_set <= 1'b1; end
	sys_seen <= sys_mode_in;
	if (sys_mode_in != sys_seen) sys_mode <= sys_m;
	if (k_system && disc && ntsc) begin
		sys_mode <= (sys_mode == 2'd0) ? 2'd1 : 2'd0;
		sys_mode_set <= 1'b1;
	end

	// what the pictures say: the disc's type, and where it is (for DISPLAY and the chapter keys)
	if (new_pic_d) begin
		if (pv) begin disc_cav <= 1'b1; cur_pic <= pn; cur_pic_v <= 1'b1; end
		if (tv) begin disc_clv <= 1'b1; cur_time <= {bcd3(tmin), s_tn, s_un}; cur_t_v <= 1'b1; end
		if (cv) begin cur_ch <= cn; cur_ch_v <= 1'b1; end
	end
	if (k_display) disp_on <= !disp_on;
	if (new_load) dlc <= 5'd0;
	else if (k_lvl_up && has_digital) begin if (dlc != 5'd0) dlc <= dlc - 5'd1; msg_src <= 3'd4; msg_t <= T_MSG; end
	else if (k_lvl_dn && has_digital) begin if (dlc != 5'd25) dlc <= dlc + 5'd1; msg_src <= 3'd4; msg_t <= T_MSG; end
	if (k_audio) begin msg_src <= 3'd1; msg_t <= T_MSG; end
	else if (k_rep_a || k_rep_b) begin msg_src <= 3'd3; msg_t <= T_MSG; lm_show <= 1'b0; end
	else if (k_system && disc && ntsc) begin msg_src <= 3'd2; msg_t <= T_MSG; end
	else if (frame_tick && msg_t != 7'd0) msg_t <= msg_t - 7'd1;
	if (frame_tick && clv_t != 7'd0) clv_t <= clv_t - 7'd1;

	if (reset) begin
		lm_arm <= lm_v;                                                     // power-on: the memorised position
		audio_sel <= 2'd0; audio_src <= 1'b0;
		state <= S_IDLE; t <= 16'd0; video_on <= 1'b0; frame <= 16'd0; osd_screen <= 3'd0;
		hold <= 1'b0; want_side <= 2'd0; side_a_only <= 1'b0; seen_id <= 13'd0; reload <= 1'b0;
		sys_mode <= sys_m; sys_seen <= sys_mode_in; lang <= lang_in; lang_seen <= lang_in;
		disc_cav <= 1'b0; disc_clv <= 1'b0; cur_pic_v <= 1'b0; cur_ch_v <= 1'b0; cur_t_v <= 1'b0;
		ent <= 20'd0; ent_n <= 3'd0; ent_kind <= 1'b0; ent_normal <= 1'b0; disp_on <= 1'b0; pend <= 1'b0;
		dlc <= 5'd0;
		rep <= 3'd0; pg_edit <= 1'b0; pg_play <= 1'b0; pg_n <= 5'd0; pg_dv <= 1'b0; clv_t <= 7'd0; msg_t <= 7'd0; lm_show <= 1'b0;
		txt_l0 <= 2'd0; txt_l1 <= 2'd0; txt_r0 <= 4'd0;
	end else begin
		if (frame_tick) t <= t + 16'd1;
		if (state == S_PLAY && video_on) begin lm_v <= 1'b1; lm_frame <= frame; lm_id <= load_id; end
		else if (state == S_STOP || state == S_OPEN) lm_v <= 1'b0;              // stopped: nothing to resume

		// digit entry (DIRECT SEARCH keys, CHP/TM, CLEAR), outside a search
		if (pg_edit) begin
			if (k_digit) begin pg_dv <= 1'b1; pg_dval <= pg_dv ? {pg_dval[3:0], digit} : {4'd0, digit}; pg_dt <= T_PGDIG; end
			else if (k_clear) begin
				if (pg_dv) pg_dv <= 1'b0;
				else if (pg_n != 5'd0) pg_n <= pg_n - 5'd1;
			end
			else if (pg_dv && frame_tick) begin
				if (pg_dt <= 7'd1) begin
					pg_dv <= 1'b0;
					if (pg_n != 5'd24 && pg_dval != 8'd0) begin pg[{pg_n, 3'b000} +: 8] <= pg_dval; pg_n <= pg_n + 5'd1; end
				end else pg_dt <= pg_dt - 7'd1;
			end
		end else if (state != S_SEARCH) begin
			if (k_chptm) begin ent_kind <= !ent_kind; ent <= 20'd0; ent_n <= 3'd0; ent_normal <= 1'b1; end
			else if (k_clear) begin ent <= 20'd0; ent_n <= 3'd0; end
			else if (k_digit) begin
				ent <= !ent_kind ? {12'd0, ent[3:0], digit} : {ent[15:0], digit};
				if (ent_n != 3'd5) ent_n <= ent_n + 3'd1;
			end
		end

		// Load disc (MiSTer menu or MGL) is the disc placed in the open tray and PLAY pressed: the tray closes and
		// play starts, with the player's own timings ("Tray closing (PLAY with tray open)", docs/player_logic.md).
		// A disc that is playing first stops and the tray opens, as on the machine (user, 2026-11-04: "once a disc
		// is selected in the mister menu it should play automatically", accounting for the player's behaviour).
		if (new_load) begin
			seen_id <= load_id;
			disc_cav <= 1'b0; disc_clv <= 1'b0; cur_pic_v <= 1'b0; cur_ch_v <= 1'b0; cur_t_v <= 1'b0; pend <= 1'b0;
			rep <= 3'd0;
			case (state)
			S_IDLE, S_STOP, S_OPEN, S_CLOSING: begin
				play_after <= 1'b1; side_a_only <= 1'b0; video_on <= 1'b0; go(S_CLOSING);
			end
			S_SPINDOWN: reload <= 1'b1;
			default: begin
				hold <= 1'b0; want_side <= 2'd0; video_on <= 1'b0; frame <= 16'd0; reload <= 1'b1; go(S_SPINDOWN);
			end
			endcase
		end else
		case (state)
		S_IDLE, S_STOP: begin
			video_on <= 1'b0;
			osd_screen <= (state == S_STOP) ? 3'd3 : 3'd0;
			if (k_pgm) begin pg_edit <= !pg_edit; pg_dv <= 1'b0; end
			else if (pg_edit && play_key && disc && pg_n != 5'd0) begin   // programme play from STOP: spin up first
				pg_edit <= 1'b0; pg_play <= 1'b1; pg_rep <= 1'b0; pg_i <= 5'd0;
				pend <= 1'b1; p_kind <= K_CH; p_tgt <= {12'd0, pg[7:0]}; p_then <= R_PLAY;
				side_a_only <= 1'b0; go(S_SPINUP);
			end
			else if (pg_edit) ;                                            // keys go to the programme
			// a search keyed in at STOP: the disc spins up first, then searches (OM p.58)
			else if (ent_go && disc) begin
				pend <= 1'b1; p_kind <= ent_k; p_tgt <= ent_t; p_then <= ent_then;
				ent <= 20'd0; ent_n <= 3'd0; ent_kind <= 1'b0; ent_normal <= 1'b0;
				side_a_only <= 1'b0; go(S_SPINUP);
			end
			else if (play_key && disc) begin side_a_only <= 1'b0; go(S_SPINUP); end
			else if (k_side_a && disc && !side_b) begin side_a_only <= 1'b1; go(S_SPINUP); end   // OM p.14
			else if (k_eject) go(S_SPINDOWN);
		end
		S_SPINDOWN: begin                       // disc stops before the tray opens (EST 2 s)
			osd_screen <= 3'd3;
			if (frame_tick && t + 16'd1 >= T_SPINDOWN) go(S_OPEN);
		end
		S_OPEN: begin
			video_on <= 1'b0; osd_screen <= 3'd6;
			pg_n <= 5'd0; pg_edit <= 1'b0; pg_play <= 1'b0;               // the programme goes with the disc
			if (reload) begin reload <= 1'b0; play_after <= 1'b1; side_a_only <= 1'b0; go(S_CLOSING); end
			else if (k_eject) begin play_after <= 1'b0; go(S_CLOSING); end
			else if (play_key) begin play_after <= 1'b1; side_a_only <= 1'b0; go(S_CLOSING); end
		end
		S_CLOSING: begin
			osd_screen <= 3'd4;
			if (frame_tick && t + 16'd1 >= T_CLOSE) go((play_after && disc) ? S_SPINUP : S_STOP);
		end
		S_SPINUP: begin
			osd_screen <= 3'd5; frame <= 16'd0;
			if (k_stop) begin pend <= 1'b0; go(S_STOP); end
			else if (frame_tick && t + 16'd1 >= T_SPINUP) go(S_INFO);
		end
		S_INFO: begin
			osd_screen <= 3'd1;
			if (k_stop) begin pend <= 1'b0; go(S_STOP); end
			else if (frame_tick && t + 16'd1 >= T_INFO) begin
				osd_screen <= 3'd0;
				if (lm_arm && lm_id == load_id) begin   // LAST MEMORY: back to where play was
					lm_arm <= 1'b0; jump(lm_frame); msg_src <= 3'd3; msg_t <= T_MSG; lm_show <= 1'b1;
				end else if (pend) begin        // the search keyed in at STOP
					pend <= 1'b0;
					start_search(p_kind, p_tgt, p_then, 1'b0);
				end else if (cur_ch_v)          // a disc with chapter numbers: to chapter 1 first (F1)
					start_search(K_CH, 20'h00001, R_PLAY, 1'b0);
				else begin video_on <= 1'b1; resync <= 1'b1; go(S_PLAY); end
			end
		end
		S_PLAY: begin
			osd_screen <= 3'd0;
			if (k_pgm) begin pg_edit <= !pg_edit; pg_dv <= 1'b0; end
			else if (pg_edit && play_key && pg_n != 5'd0) begin            // programme play from here
				pg_edit <= 1'b0; pg_play <= 1'b1; pg_rep <= 1'b0; pg_i <= 5'd0;
				start_search(K_CH, {12'd0, pg[7:0]}, R_PLAY, 1'b0);
			end
			else if (ent_go && !pg_edit) start_search(ent_k, ent_t, ent_then, 1'b0);
			else if (k_stop) begin video_on <= 1'b0; frame <= 16'd0; pg_play <= 1'b0; go(S_STOP); end
			else if (k_eject) begin video_on <= 1'b0; frame <= 16'd0; go(S_SPINDOWN); end
			else if (k_pause || k_playpause) begin video_on <= 1'b0; go(S_PAUSE); end
			else if (pg_play && k_clear && !pg_edit) begin pg_play <= 1'b0; pg_rep <= 1'b0; end   // programme play ends
			else if (pg_play && new_pic_d && cv && cn != pg_cur) begin       // the step's chapter ended
				if (pg_i + 5'd1 >= pg_n && pg_rep) begin                    // program repeat: from the first step
					pg_i <= 5'd0; start_search(K_CH, {12'd0, pg[7:0]}, R_PLAY, 1'b0);
				end
				else if (pg_i + 5'd1 >= pg_n) begin pg_play <= 1'b0; video_on <= 1'b0; frame <= 16'd0; go(S_STOP); end
				else begin
					pg_i <= pg_i + 5'd1;
					start_search(K_CH, {12'd0, pg[{pg_i + 5'd1, 3'b000} +: 8]}, R_PLAY, 1'b0);
				end
			end
			else if ((k_step_f || k_step_r || k_ms_f || k_ms_r) && disc_clv) clv_t <= T_CLVW;      // OM p.68
			else if (k_step_f || k_step_r) go(S_STILL);
			else if (k_ms_f || k_ms_r) begin ms_sp <= 4'd4; ms_dir <= k_ms_f; ms_cnt <= 7'd0; go(S_MULTI); end
			else if (scan_f || scan_r) begin scan_dir <= scan_f; go(S_SCAN); end
			// REPEAT (OM p.70-72)
			else if (k_rep_b && pg_play) pg_rep <= 1'b1;                   // program repeat
			else if (k_rep_a) begin rep <= 3'd1; rep_a <= frame; end
			else if (k_rep_b) begin
				if (rep == 3'd1) begin rep <= 3'd2; rep_b <= frame; jump(rep_a); end
				else if (rep == 3'd3 || !cur_ch_v) rep <= 3'd4;
				else begin rep <= 3'd3; rep_ch <= cur_ch; end
			end
			else if (k_clear && ent_n == 3'd0 && rep != 3'd0) rep <= 3'd0;
			else if (k_play && rep == 3'd1) jump(rep_a);                                            // back to point A
			else if (rep == 3'd2 && frame >= rep_b) jump(rep_a);
			else if (rep == 3'd3 && new_pic_d && cv && cn != rep_ch) begin                             // the chapter ended
				start_search(K_CH, {12'd0, rep_ch}, R_PLAY, 1'b0); s_quiet <= 1'b1;
			end
			else if (new_pic_d && stopc && disc_cav) go(S_STILL);                                    // picture stop code
			// CHAPTER SKIP (OM p.58): back to the start of this chapter, or on to the next
			else if (k_skip_f && cur_ch_v) start_search(K_CH, {12'd0, bcd_inc(cur_ch)}, R_PLAY, 1'b1);
			else if (k_skip_r && cur_ch_v) start_search(K_CH, {12'd0, cur_ch}, R_PLAY, 1'b1);
			// DISC SIDE A/B during play turns to that side, the picture held (D925 footage, 76.0 s)
			else if (k_side_b && two_sided && !side_b) begin
				hold <= 1'b1; want_side <= 2'd2; turn_from_b <= 1'b0; go(S_TURN);
			end else if (k_side_a && two_sided && side_b) begin
				hold <= 1'b1; want_side <= 2'd1; turn_from_b <= 1'b1; go(S_TURN);
			end else if (frame_tick) begin
				if (frame >= last && rep == 3'd4) jump(16'd0);                                   // one side repeat
				else if (frame >= last) begin
					if (two_sided && !side_b && !side_a_only) begin
						hold <= 1'b1; want_side <= 2'd2; turn_from_b <= 1'b0; go(S_TURN);
					end else begin video_on <= 1'b0; frame <= 16'd0; go(S_STOP); end   // end of disc
				end else frame <= frame + 16'd1;
			end
		end
		S_TURN: begin                           // the last picture held, no sound; then side B plays
			if (turn_done) frame <= 16'd0;      // decoded during the turn, so it is ready at the cut
			// the request goes back to 0 when the turn ends, so the HPS (which acts on a change) sees the next one
			if (k_stop) begin hold <= 1'b0; want_side <= 2'd0; video_on <= 1'b0; frame <= 16'd0; go(S_STOP); end
			else if (frame_tick && t + 16'd1 >= T_TURN && turn_done) begin
				hold <= 1'b0; want_side <= 2'd0; side_a_only <= 1'b0; frame <= 16'd0;
				cur_pic_v <= 1'b0; cur_ch_v <= 1'b0; cur_t_v <= 1'b0;     // the other side's codes from here
				go(S_PLAY);
			end
		end
		S_PAUSE: begin                          // picture and sound off (OM p.50)
			osd_screen <= 3'd2;
			if (ent_go) start_search(ent_k, ent_t, ent_then, 1'b0);
			else if (k_stop) begin frame <= 16'd0; go(S_STOP); end
			else if (k_eject) begin frame <= 16'd0; go(S_SPINDOWN); end
			else if (play_key || k_pause) begin video_on <= 1'b1; resync <= 1'b1; osd_screen <= 3'd0; go(S_PLAY); end
		end
		S_STILL: begin                          // still frame / frame advance (CAV), sound muted (OM p.68)
			osd_screen <= 3'd0;
			if (ent_go) start_search(ent_k, ent_t, ent_then, 1'b0);
			else if (k_stop) begin video_on <= 1'b0; frame <= 16'd0; go(S_STOP); end
			else if (k_play) go(S_PLAY);
			else if (k_ms_f || k_ms_r) begin ms_sp <= 4'd4; ms_dir <= k_ms_f; ms_cnt <= 7'd0; go(S_MULTI); end
			else if (k_step_f && frame < last) frame <= frame + 16'd1;
			else if (k_step_r && frame != 16'd0) frame <= frame - 16'd1;
		end
		S_SCAN: begin                           // ~x10 for ~2 s, then ~x30 (OM p.56)
			if (!(scan_f || scan_r)) go(S_PLAY);
			else if (frame_tick) begin
				if (scan_dir) frame <= (frame + ((t < T_LOWSCAN) ? 16'd10 : 16'd30) > last) ? last
				                      : frame + ((t < T_LOWSCAN) ? 16'd10 : 16'd30);
				else frame <= (frame < ((t < T_LOWSCAN) ? 16'd10 : 16'd30)) ? 16'd0
				              : frame - ((t < T_LOWSCAN) ? 16'd10 : 16'd30);
			end
		end
		S_MULTI: begin                          // multi-speed (CAV), sound muted (OM p.68)
			osd_screen <= 3'd0;
			if (k_stop) begin video_on <= 1'b0; frame <= 16'd0; go(S_STOP); end
			else if (k_play) go(S_PLAY);
			else if (k_step_f || k_step_r) go(S_STILL);
			else if (k_ms_f || k_ms_r) ms_dir <= k_ms_f;
			else if (k_sp_up && ms_sp != 4'd0) ms_sp <= ms_sp - 4'd1;
			else if (k_sp_dn && ms_sp != 4'd8) ms_sp <= ms_sp + 4'd1;
			else if (new_pic_d && stopc && ms_sp >= 4'd2) go(S_STILL);                               // x1 and slower
			else if (frame_tick) begin
				if (ms_sp <= 4'd2 || ms_cnt + 7'd1 >= ms_per) begin
					ms_cnt <= 7'd0;
					if (ms_dir) frame <= (frame + {14'd0, ms_k} > last) ? last : frame + {14'd0, ms_k};
					else frame <= (frame < {14'd0, ms_k}) ? 16'd0 : frame - {14'd0, ms_k};
				end else ms_cnt <= ms_cnt + 7'd1;
			end
		end
		S_SEARCH: begin
			// jump to a probe, read the codes of the picture there, narrow [lo, hi] to the first frame at or past the
			// target; the picture stays off (the background) until it lands
			if (frame_tick) s_wt <= s_wt + 16'd1;
			if (k_stop) begin video_on <= 1'b0; frame <= 16'd0; go(S_STOP); end
			else if (k_clear) begin                         // cancel (OM p.58): back to what it was doing
				frame <= s_back_frame;
				if (s_back == S_PAUSE) go(S_PAUSE);
				else begin video_on <= 1'b1; resync <= 1'b1; go((s_back == S_STILL) ? S_STILL : S_PLAY); end
			end else if (s_skip && (k_skip_f || k_skip_r)) begin   // further skips before the picture returns
				s_ch <= k_skip_f ? bcd_inc(s_ch) : bcd_dec(s_ch);
				s_tgt <= {12'd0, k_skip_f ? bcd_inc(s_ch) : bcd_dec(s_ch)};
				txt_n1 <= {12'd0, k_skip_f ? bcd_inc(s_ch) : bcd_dec(s_ch)};
				s_lo <= 16'd0; s_hi <= last; s_first <= 1'b0; s_try <= 4'd0; s_wait <= 1'b0; s_done <= 1'b0;
			end else if (s_done) begin
				if (t >= T_SRCH && pic_frame_d == frame) begin
					case (s_then)
					R_PAUSE: go(S_PAUSE);
					R_STILL: begin video_on <= 1'b1; resync <= 1'b1; go(S_STILL); end
					default: begin video_on <= 1'b1; resync <= 1'b1; go(S_PLAY); end
					endcase
				end
			end else if (!s_wait) begin
				if (s_lo >= s_hi) begin s_done <= 1'b1; frame <= s_lo; end
				else begin frame <= s_probe; s_mid <= s_probe; s_wait <= 1'b1; s_wt <= 16'd0; end
			end else if (pic_frame_d == s_mid) begin
				s_wait <= 1'b0; s_first <= 1'b0;
				if (s_val) begin
					s_try <= 4'd0;
					if (s_key >= s_tgt) s_hi <= s_mid; else s_lo <= s_mid + 16'd1;
				end else if (s_try == 4'd7 || s_mid == s_hi) begin s_try <= 4'd0; s_lo <= s_mid + 16'd1; end
				else s_try <= s_try + 4'd1;                     // no code on this picture: try the next
			end else if (s_wt >= T_PROBE) begin               // nothing comes: give up, back to what it was doing
				frame <= s_back_frame;
				if (s_back == S_PAUSE) go(S_PAUSE);
				else begin video_on <= 1'b1; resync <= 1'b1; go((s_back == S_STILL) ? S_STILL : S_PLAY); end
			end
		end
		default: go(S_IDLE);
		endcase

		// the variable text (screen 7): search, DISPLAY, side change, setting messages
		txt_l0 <= 2'd0; txt_r0 <= 4'd0; txt_side_b <= side_b; txt_msg <= 5'd0;
		txt_chap_v <= cur_ch_v; txt_chap <= cur_ch;
		txt_pg_show <= 1'b0; txt_pg_n <= pg_n; txt_pg_list <= pg; txt_pg_pend_v <= pg_dv; txt_pg_pend <= pg_dval;
		if (pg_edit && (state == S_STOP || state == S_IDLE || state == S_PLAY)) begin
			osd_screen <= 3'd7; txt_pg_show <= 1'b1; txt_l1 <= 2'd0;
			txt_r0 <= (state == S_PLAY) ? 4'd1 : 4'd0;
		end else if (state == S_SEARCH && s_quiet) begin
			osd_screen <= 3'd0;
		end else if (state == S_SEARCH) begin
			osd_screen <= 3'd7; txt_l0 <= 2'd1;
		end else if (state == S_TURN) begin
			osd_screen <= 3'd7; txt_l1 <= 2'd0; txt_r0 <= 4'd2; txt_side_b <= turn_from_b;
		end else if (video_on && (state == S_PLAY || state == S_STILL || state == S_SCAN || state == S_MULTI) &&
		             (disp_on || msg_t != 7'd0 || clv_t != 7'd0)) begin
			osd_screen <= 3'd7; txt_l1 <= 2'd0;
			if (disp_on) begin
				txt_l0 <= disc_clv ? (cur_t_v ? 2'd3 : 2'd0) : (cur_pic_v ? 2'd2 : 2'd0);
				txt_n0 <= disc_clv ? cur_time : cur_pic;
				txt_r0 <= (state == S_PLAY) ? 4'd1 : (state == S_STILL) ? 4'd3 : (state == S_MULTI) ? 4'd4 + ms_sp : 4'd0;
			end
			if (clv_t != 7'd0) txt_r0 <= 4'd13;
			if (msg_t != 7'd0 && msg_src == 3'd2) txt_msg <= (sys_mode == 2'd0) ? 5'd7 : 5'd8;
			else if (msg_t != 7'd0 && msg_src == 3'd4) txt_msg <= 5'd16;
			else if (msg_t != 7'd0 && msg_src == 3'd3)
				txt_msg <= lm_show ? 5'd15 : pg_rep ? 5'd14 : (rep == 3'd1) ? 5'd9 : (rep == 3'd2) ? 5'd10 : (rep == 3'd3) ? 5'd11 :
				           (rep == 3'd4) ? (side_b ? 5'd13 : 5'd12) : 5'd0;
			else if (msg_t != 7'd0 || disp_on) txt_msg <= (audio_src ? 5'd1 : 5'd4) + {3'd0, audio_sel};
		end
	end
end

endmodule
