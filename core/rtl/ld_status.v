// Programme status code (IEC 60857 10.1.8, VBI line 16 / 329), as the CLD-1750's control MCU uses it for sound.
//
// The MCU (IC101) squelches each analogue channel through SQ1/SQ2 and switches CX through XCX on IC700, the
// audio demodulator and CX decoder (SM ASCB 2/4, PDF 24). The OM's "CX auto-switching" and "audio mode
// indicators" come from this code. The decode follows ld-decode-tools vbidecoder.cpp (written from IEC 60857):
//   valid     prefix 0x8DC (CX on) or 0x8BA (CX off) in bits 23:12, and the Hamming parity X51-X53 over X41-X44
//   audio     status = {X41, X34, X43, X44}: 0 stereo, 1 mono, 3 bilingual, 4-7 FM-FM multiplex modes,
//             8-15 programme dump modes, 2 and 10 "future use"
// Squelch: audio status 2 or 10 means no sound programme. On Community North it marks exactly the stretch with
// only hum and buzz on the carriers (docs/sm_video_audio.md), and the user chose to mute it (2026-11-03). The
// last valid code is held while frames carry none, as the MCU keeps the last status it read.
module ld_status (
	input             clk,
	input             reset,
	input             new_pic,        // a new picture (and its VBI) went up
	input     [127:0] vbi,            // {330, 329, 17, 16}, 24-bit codes in 32-bit lanes
	output            squelch,        // no sound programme on this disc section
	output            cx              // CX noise reduction on (for the AUDIO D/A / CX work; not used yet)
);

function automatic ok(input [23:0] c);
	reg [3:0] x4, x5;
	begin
		x4 = c[7:4];
		x5 = c[3:0];
		ok = (c[23:12] == 12'h8DC || c[23:12] == 12'h8BA) &&
		     ((x4[3] ^ x4[2] ^ x4[0]) == x5[3]) &&
		     ((x4[3] ^ x4[1] ^ x4[0]) == x5[2]) &&
		     ((x4[2] ^ x4[1] ^ x4[0]) == x5[1]);
	end
endfunction

wire [23:0] f1 = vbi[23:0];               // line 16
wire [23:0] f2 = vbi[87:64];              // line 329
wire        v1 = ok(f1), v2 = ok(f2);
wire [23:0] now = v1 ? f1 : f2;
wire        have_now = v1 || v2;

reg  [23:0] held;
reg         held_v;
always @(posedge clk) begin
	if (reset) held_v <= 1'b0;
	else if (new_pic && have_now) begin held <= now; held_v <= 1'b1; end
end

// the code in force: this picture's if it carries one, else the last one read
wire [23:0] code  = have_now ? now : held;
wire        known = have_now || held_v;
wire  [3:0] audio = {code[7], code[8], code[5], code[4]};   // X41 X34 X43 X44
assign squelch = known && (audio == 4'd2 || audio == 4'd10);
assign cx      = known && code[23:12] == 12'h8DC;

initial held_v = 1'b0;

endmodule
