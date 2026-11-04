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
module player (
	input             clk,
	input             reset,
	input             frame_tick,   // one pulse per output frame (25 Hz)

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

	input             disc,         // a TBC image is loaded
	input      [15:0] frames,

	input       [1:0] sys_mode_in,  // SYSTEM mode from the MiSTer menu (0 PAL, 1 NTSC, 2 MOD.PAL)
	output reg  [1:0] sys_mode,
	output reg        sys_mode_set, // pulse: player changed SYSTEM mode (write back to the menu)

	output reg        video_on,
	output reg [15:0] frame,
	output reg        resync,       // pulse: switch output timing to the disc (picture on)
	output reg  [2:0] osd_screen,   // ids: tools/osd/gen_osd_rom.py
	output      [1:0] osd_bg,       // 1 blue, 2 black (OM p.46)
	output reg  [3:0] state,
	output reg  [1:0] audio_sel     // 0 stereo, 1 L channel, 2 R channel
);

localparam [15:0] T_CLOSE = 16'd188, T_SPINUP = 16'd138, T_INFO = 16'd90, T_SPINDOWN = 16'd50, T_LOWSCAN = 16'd50;
localparam S_IDLE = 4'd0, S_OPEN = 4'd1, S_CLOSING = 4'd2, S_STOP = 4'd3, S_SPINDOWN = 4'd4,
           S_SPINUP = 4'd5, S_INFO = 4'd6, S_PLAY = 4'd7, S_PAUSE = 4'd8, S_STILL = 4'd9, S_SCAN = 4'd10;

reg [15:0] t;              // frames in the current state
reg        play_after;     // CLOSING was started by PLAY
reg  [1:0] sys_seen;
reg        scan_dir;       // 1 = forward

assign osd_bg = (sys_mode == 2'd2) ? 2'd2 : 2'd1;

wire play_key = k_play | k_playpause;
wire [15:0] last = (frames == 16'd0) ? 16'd0 : frames - 16'd1;

task go(input [3:0] s);
	begin state <= s; t <= 16'd0; end
endtask

always @(posedge clk) begin
	resync <= 1'b0;
	sys_mode_set <= 1'b0;

	// AUDIO D/A: stereo -> L -> R -> stereo; a new disc starts at stereo
	if (!disc) audio_sel <= 2'd0;
	else if (k_audio) audio_sel <= (audio_sel == 2'd2) ? 2'd0 : audio_sel + 2'd1;

	// SYSTEM mode: the menu and the SYSTEM key both set it; whichever changed last wins
	sys_seen <= sys_mode_in;
	if (sys_mode_in != sys_seen) sys_mode <= sys_mode_in;
	if (k_system) begin
		sys_mode <= (sys_mode == 2'd2) ? 2'd0 : sys_mode + 2'd1;
		sys_mode_set <= 1'b1;
	end

	if (reset) begin
		audio_sel <= 2'd0;
		state <= S_IDLE; t <= 16'd0; video_on <= 1'b0; frame <= 16'd0; osd_screen <= 3'd0;
		sys_mode <= sys_mode_in; sys_seen <= sys_mode_in;
	end else begin
		if (frame_tick) t <= t + 16'd1;

		case (state)
		S_IDLE, S_STOP: begin
			video_on <= 1'b0;
			osd_screen <= (state == S_STOP) ? 3'd3 : 3'd0;
			if (play_key && disc) go(S_SPINUP);
			else if (k_eject) go(S_SPINDOWN);
		end
		S_SPINDOWN: begin                       // disc stops before the tray opens (EST 2 s)
			osd_screen <= 3'd3;
			if (frame_tick && t + 16'd1 >= T_SPINDOWN) go(S_OPEN);
		end
		S_OPEN: begin
			video_on <= 1'b0; osd_screen <= 3'd6;
			if (k_eject) begin play_after <= 1'b0; go(S_CLOSING); end
			else if (play_key) begin play_after <= 1'b1; go(S_CLOSING); end
		end
		S_CLOSING: begin
			osd_screen <= 3'd4;
			if (frame_tick && t + 16'd1 >= T_CLOSE) go((play_after && disc) ? S_SPINUP : S_STOP);
		end
		S_SPINUP: begin
			osd_screen <= 3'd5; frame <= 16'd0;
			if (k_stop) go(S_STOP);
			else if (frame_tick && t + 16'd1 >= T_SPINUP) go(S_INFO);
		end
		S_INFO: begin
			osd_screen <= 3'd1;
			if (k_stop) go(S_STOP);
			else if (frame_tick && t + 16'd1 >= T_INFO) begin
				video_on <= 1'b1; resync <= 1'b1; osd_screen <= 3'd0; go(S_PLAY);
			end
		end
		S_PLAY: begin
			osd_screen <= 3'd0;
			if (k_stop) begin video_on <= 1'b0; frame <= 16'd0; go(S_STOP); end
			else if (k_eject) begin video_on <= 1'b0; frame <= 16'd0; go(S_SPINDOWN); end
			else if (k_pause || k_playpause) begin video_on <= 1'b0; go(S_PAUSE); end
			else if (k_step_f || k_step_r) go(S_STILL);
			else if (scan_f || scan_r) begin scan_dir <= scan_f; go(S_SCAN); end
			else if (frame_tick) begin
				if (frame >= last) begin video_on <= 1'b0; frame <= 16'd0; go(S_STOP); end   // end of disc
				else frame <= frame + 16'd1;
			end
		end
		S_PAUSE: begin                          // picture and sound off (OM p.50)
			osd_screen <= 3'd2;
			if (k_stop) begin frame <= 16'd0; go(S_STOP); end
			else if (k_eject) begin frame <= 16'd0; go(S_SPINDOWN); end
			else if (play_key || k_pause) begin video_on <= 1'b1; resync <= 1'b1; osd_screen <= 3'd0; go(S_PLAY); end
		end
		S_STILL: begin                          // still frame / frame advance (CAV), sound muted (OM p.68)
			if (k_stop) begin video_on <= 1'b0; frame <= 16'd0; go(S_STOP); end
			else if (k_play) go(S_PLAY);
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
		default: go(S_IDLE);
		endcase
	end
end

endmodule
