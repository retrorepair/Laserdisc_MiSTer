// ld_stream.sv - DSC frame decoder and frame buffers for Laserdisc_MiSTer.
//
// Derived from MiSTer-LaserActive's ld_video.sv (MegaCD_MiSTer @1d812165, SPDX MIT). Its DDR3 datapath is
// kept as it was: slot reads -> dsc_decoder -> fields woven into a frame buffer -> line fetch, with the same
// port arbitration. Changed for this core:
//   - The player chooses the frame (want); nothing is committed by the HPS. LaserActive's VDP cadence and
//     margin scheduler is removed. A new picture goes up only at our frame boundary (flip), which runs on the
//     Domesday86/ld-decode PAL TBC timing (tbc_timing: 1135 samples per line at 4fsc, fields of 312/313
//     lines, 25 frames/s).
//   - The HPS talks to the core through DDR3 only: a header block with the slot table comes in, and a
//     status block goes out (docs/streaming_design.md).
//   - Frames are up to 1 MB per slot (PAL 960x600 at 8 bpp is 576 000 B), and the frame buffers are 4 MB apart.
//   - The line fetch delivers full 24-bit pixels.
//   - Each frame's audio block (1024 words after its picture in the slot) is read into ld_audio's bank for the
//     frame buffer it was decoded into, before the frame counts as ready; new_pic says when it goes up.
//
// DDR3 map (physical byte addresses):
//   0x30000000  header block, HPS -> core, 28 x 64-bit words:
//                 w0  [31:0] "LDH1" 0x3148444C, [47:32] version 1, [63:48] disc generation (changes per load)
//                 w1  [31:0] frame count, [63:32] 64-bit words per frame
//                 w2  [10:0] field1_row, [26:16] crop_x (TBC sample of column 0), [41:32] crop_y (frame line),
//                     [48] stream: 0 = DSC picture, 1 = composite samples (add_cvbs.py: 2 x 313 lines of 142 words)
//                 w3  [16:0] audio block offset in the slot, in 64-bit words (0 = no audio; tbc2dscv.c)
//                     [48:32] VBI entry offset in the slot, words (0 = none): lines 16, 17, 329, 330 (2 words)
//                 w4..w19   DSC PPS, byte i in word 4 + i/8, lane i%8
//                 w20..w27  slot table: slot k's frame at word 20 + k/2, bits 32*(k%2) +: 32; all ones = empty
//   0x30000400  status block, core -> HPS, 4 words, written at every frame boundary:
//                 w0  [31:0] "LDS1" 0x3153444C, [63:32] frame boundaries counted
//                 w1  [31:0] wanted frame, [35:32] player state, [36] video on, [37] disc, [38] composite wanted
//                     (menu), [39] composite in use, [63:48] generation
//                 w2  [31:0] frame being decoded, [63:32] frame on screen (all ones = none)
//                 w3  {late, errors, decode clocks / 256, decoded}, 16 bits each
//                 w4  diagnostics: [2:0] cstate, [5:3] fstate, [10:6] bursts in flight, [16:11] header words in,
//                     [27:17] auxiliary words in, [37:28] line words left, [38] wr_burst, [39] cw_burst, [40] fresh,
//                     [41] loaded, [47:42] 0, [63:48] frame boundaries while the sequencer was busy
//   0x30100000 + k * 0x100000           slot k (0-15): one DSCV frame
//   0x31200000, 0x31600000, 0x31A00000  frame buffers, 32 bits per pixel (R in byte 0), fields woven
//
// SPDX-License-Identifier: MIT
`default_nettype none

module ld_stream #(
	parameter [31:0] HDR_BASE  = 32'h3000_0000,
	parameter [31:0] STAT_BASE = 32'h3000_0400,
	parameter [31:0] RING_BASE = 32'h3010_0000,
	parameter [31:0] FB0_BASE  = 32'h3120_0000,
	parameter [31:0] FB1_BASE  = 32'h3160_0000,
	parameter [31:0] FB2_BASE  = 32'h31A0_0000
) (
	input  wire        clk,
	input  wire        reset,

	// player (core/rtl/player.v)
	input  wire [15:0] want,            // frame to show from the next frame boundary on
	input  wire        flip,            // frame boundary (start of the first field)
	input  wire  [3:0] pstate,
	input  wire        video_on,
	input  wire        want_cvbs,       // the menu asks for composite output (the HPS switches streams)

	// disc, from the header block
	output reg         disc,            // a stream is loaded and its PPS is in the decoder
	output reg  [15:0] frames,
	output reg  [10:0] crop_x,
	output reg   [9:0] crop_y,
	output wire [10:0] pic_cols,
	output wire [10:0] pic_rows,
	output wire        shown,           // a picture is in the frame buffer on screen
	output reg         cvbs,            // the stream in use is the composite one: frames play from their slots
	output reg         new_pic,         // pulse: a newly decoded picture went up, in frame buffer pic_buf
	output reg   [1:0] pic_buf,
	output reg         has_audio,
	output reg [127:0] pic_vbi,         // VBI codes of the picture on screen: {330, 329, 17, 16}, 32 bits each

	// audio blocks (ld_audio bank RAM)
	output reg         aud_we,
	output reg  [11:0] aud_waddr,       // {frame buffer, word}
	output reg  [63:0] aud_wdata,

	// line fetch (ld_scan)
	input  wire        lf_req,          // read a line of the picture on screen
	input  wire  [9:0] lf_row,
	output reg         lf_we,
	output reg   [8:0] lf_addr,
	output reg  [63:0] lf_data,         // DSC: {16'd0, pixel 1, pixel 0}, each {B, G, R}; composite: 8 samples

	// DDR3
	input  wire        DDRAM_BUSY,
	output reg   [7:0] DDRAM_BURSTCNT,
	output reg  [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output reg         DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output reg         DDRAM_WE
);

localparam [31:0] HDR_MAGIC  = 32'h3148444C;   // "LDH1"
localparam [31:0] STAT_MAGIC = 32'h3153444C;   // "LDS1"
localparam  [5:0] HDR_WORDS  = 6'd28;

// ----------------------------------------------------------- picture size
reg         pps_we;
reg   [6:0] pps_addr;
reg   [7:0] pps_data;
reg  [15:0] pic_w, pic_h;
always @(posedge clk) if (pps_we) begin
	case (pps_addr)
		7'd6: pic_h[15:8] <= pps_data;
		7'd7: pic_h[7:0]  <= pps_data;
		7'd8: pic_w[15:8] <= pps_data;
		7'd9: pic_w[7:0]  <= pps_data;
		default: ;
	endcase
end
wire [13:0] stride_b = {pic_w[11:0], 2'b00};       // bytes per framebuffer line
wire [11:0] line_words = pic_w[12:1];               // 2 pixels per 64-bit word
assign pic_cols = pic_w[10:0];
assign pic_rows = pic_h[10:0];

reg  [17:0] frame_words;
reg  [10:0] field1_row;

reg  [1:0] disp_buf, ready_buf, back_buf;          // frame buffers 0-2
reg  [3:0] buf_slot [0:2];                         // composite: the slot each buffer's frame plays from
reg        fresh;                                   // ready_buf holds a picture not shown yet
reg        disp_v, ready_v;
reg [15:0] disp_f, ready_f, tgt;                    // the frame each holds / is being decoded
assign shown = disp_v;

reg [15:0] rd_count, late_count, error_count, decode_kclks;
localparam F_IDLE = 3'd0, F_SETUP = 3'd1, F_RUN = 3'd2, F_AUD = 3'd3, F_VBI = 3'd4, F_DONE = 3'd5;
reg  [2:0] fstate;
wire       fstate_busy = fstate != F_IDLE;
reg [31:0] seq;
reg [15:0] cur_gen;

function automatic [28:0] fb_word(input [1:0] n);
	fb_word = n == 2'd0 ? FB0_BASE[31:3] : n == 2'd1 ? FB1_BASE[31:3] : FB2_BASE[31:3];
endfunction

// --------------------------------------------------------------- decoder
wire        dec_busy, dec_done, dec_error;
wire [63:0] in_q;
wire        in_valid;
wire        in_ready;
wire        dec_out_valid;
wire        dec_out_ready;
wire [15:0] dec_x, dec_y;
wire [23:0] rgb0, rgb1, rgb2;
reg         dec_start;

dsc_decoder dec (
	.clk(clk), .reset(reset),
	.pps_we(pps_we), .pps_addr(pps_addr), .pps_data(pps_data),
	.start(dec_start), .busy(dec_busy), .done(dec_done), .error(dec_error),
	.in_data(in_q), .in_valid(in_valid), .in_ready(in_ready),
	.out_valid(dec_out_valid), .out_ready(dec_out_ready),
	.out_x(dec_x), .out_y(dec_y), .out_rgb0(rgb0), .out_rgb1(rgb1), .out_rgb2(rgb2)
);

// ------------------------------------------------- frame read: DDR3 -> FIFO
reg         flush;
reg  [17:0] rd_words_left;    // words not yet requested
reg   [8:0] rd_outstanding;   // requested, not yet returned
reg  [28:0] rd_addr;          // next word address
wire  [8:0] infifo_count;

// Reads come back in order: a small FIFO of the bursts in flight says whose each returning word is:
// 0 decoder, 1 line fetch, 2 header block, 3 audio block.
reg   [7:0] tag_len [0:15];
reg   [1:0] tag_k   [0:15];
reg   [3:0] tag_rd, tag_wr;
reg   [4:0] tag_n;
reg   [7:0] tag_left;         // words left of the burst at the head
wire        rd_ret  = DDRAM_DOUT_READY && tag_n != 0;
wire  [1:0] ret_k   = tag_k[tag_rd];
wire        ret_dec = rd_ret && ret_k == 2'd0;
wire        ret_lf  = rd_ret && ret_k == 2'd1;
wire        ret_hdr = rd_ret && ret_k == 2'd2;
wire        ret_aud = rd_ret && ret_k == 2'd3;

ld_fifo #(.W(64), .AW(8)) infifo (
	.clk(clk), .flush(flush),
	.push(ret_dec), .din(DDRAM_DOUT),
	.pop(in_valid && in_ready), .q(in_q), .valid(in_valid), .count(infifo_count)
);

// request another burst when the FIFO has room for it on top of what's in flight
wire  [7:0] rd_len  = rd_words_left > 18'd64 ? 8'd64 : rd_words_left[7:0];
wire        rd_want = rd_words_left != 0 && ({1'b0, infifo_count} + {1'b0, rd_outstanding} + rd_len) <= 10'd256 && tag_n < 5'd14;

// ------------------------------------------------- line fetch for ld_scan
reg   [9:0] lf_words_left;
reg  [28:0] lf_raddr;
reg         lf_pend;
reg   [9:0] lf_pend_row;
reg   [9:0] lf_outstanding;
reg   [8:0] lf_wcnt;
wire  [7:0] lf_len  = lf_words_left > 10'd128 ? 8'd128 : lf_words_left[7:0];
wire        lf_want = lf_words_left != 0 && tag_n < 5'd14;

// ------------------------------------------- control: header read, status write
reg         cw_want, cr_want;
reg         cw_burst;
reg   [2:0] cw_beats;
reg   [2:0] cw_idx;
reg  [15:0] busy_flips;        // diagnostics: boundaries that found the control sequencer busy
localparam C_IDLE = 3'd0, C_WST = 3'd1, C_RHD = 3'd2, C_WAIT = 3'd3, C_PARSE = 3'd4, C_PPS = 3'd5, C_HOLD = 3'd6;
reg   [2:0] cstate;
reg         loaded;           // the PPS for cur_gen is in the decoder
reg   [5:0] hdr_cnt;
reg  [16:0] aud_off;          // audio block offset in the slot, words (0 = none)
reg         aud_start;        // scheduler: fetch the audio block of cur_slot into bank back_buf
reg         vbi_start;        // scheduler: fetch the VBI entry of cur_slot
reg         aux_vbi;          // the auxiliary fetch in progress is the VBI entry
reg  [16:0] vbi_off;          // VBI entry offset in the slot, words (0 = none)
reg         has_vbi;
reg  [63:0] vbi_w [0:1];
reg [127:0] fb_vbi [0:2];     // VBI codes of the frame in each frame buffer
reg  [10:0] aud_left;         // words not yet requested
reg  [10:0] aud_cnt;          // words returned
reg  [28:0] aud_raddr;
wire  [7:0] ar_len  = aud_left > 11'd64 ? 8'd64 : aud_left[7:0];
wire        ar_want = aud_left != 0 && tag_n < 5'd14;
reg  [63:0] hdr [0:27];

// --------------------------------------- pixels: decoder -> FIFO of pairs
// 32-bit pixel: byte 0 = R, 1 = G, 2 = B
function automatic [31:0] px32(input [23:0] rgb);
	px32 = {8'h00, rgb[7:0], rgb[15:8], rgb[23:16]};
endfunction

reg   [1:0] pk_state;         // 0 idle, 1 second push pending
reg  [31:0] pk_hold;          // odd pixel waiting for its partner
reg         pk_hold_v;
reg  [63:0] pk_second;
reg         pk_push;
reg  [63:0] pk_din;
wire [63:0] px_q;
wire        px_valid;
wire  [8:0] px_count;
reg         px_pop;
reg         frame_setup;
reg   [3:0] cur_slot;

ld_fifo #(.W(64), .AW(8)) pxfifo (
	.clk(clk), .flush(flush),
	.push(pk_push), .din(pk_din),
	.pop(px_pop), .q(px_q), .valid(px_valid), .count(px_count)
);

assign dec_out_ready = pk_state == 2'd0 && px_count <= 9'd244;

always @(posedge clk) begin
	pk_push <= 1'b0;
	if (flush) begin
		pk_state <= 2'd0;
		pk_hold_v <= 1'b0;
	end else if (pk_state == 2'd1) begin
		pk_push <= 1'b1;
		pk_din <= pk_second;
		pk_state <= 2'd0;
	end else if (dec_out_valid && dec_out_ready) begin
		pk_push <= 1'b1;
		if (!pk_hold_v) begin
			pk_din <= {px32(rgb1), px32(rgb0)};
			pk_hold <= px32(rgb2);
			pk_hold_v <= 1'b1;
		end else begin
			pk_din <= {px32(rgb0), pk_hold};
			pk_second <= {px32(rgb2), px32(rgb1)};
			pk_hold_v <= 1'b0;
			pk_state <= 2'd1;
		end
	end
end

// -------------------------------------------- line writes: FIFO -> DDR3
reg  [10:0] wr_row;           // decoded row being written
reg  [11:0] wr_line_left;     // words of this line not yet started
reg  [28:0] wr_addr;          // next word address in the framebuffer
reg         wr_line_go;       // address for this row is set up
reg  [10:0] rows_done;
wire  [7:0] wr_len  = wr_line_left > 12'd128 ? 8'd128 : wr_line_left[7:0];
wire        wr_want = wr_line_go && wr_line_left != 0 && px_count >= {1'b0, wr_len};
reg   [7:0] wr_beats;         // beats left in the current burst
reg         wr_burst;

// row in the framebuffer: fields woven into alternate lines (registered;
// a new row waits one clock for it, see row_wait)
wire [10:0] fb_row = field1_row == 11'd0 ? wr_row :
                     wr_row < field1_row ? {wr_row[9:0], 1'b0} : {wr_row[9:0] - field1_row[9:0], 1'b1};
reg  [10:0] fb_row_r;
reg         row_wait;
always @(posedge clk) fb_row_r <= fb_row;

// status block words (core -> HPS)
reg  [63:0] st_word;
always @* begin
	case (cw_idx)
		3'd0: st_word = {seq, STAT_MAGIC};
		3'd1: st_word = {cur_gen, 8'd0, cvbs, want_cvbs, disc, video_on, pstate, 16'd0, want};
		3'd2: st_word = {disp_v ? {16'd0, disp_f} : 32'hFFFF_FFFF, fstate_busy ? {16'd0, tgt} : 32'hFFFF_FFFF};
		3'd3: st_word = {late_count, error_count, decode_kclks, rd_count};
		default: st_word = {busy_flips, 6'd0, loaded, fresh, cw_burst, wr_burst, lf_words_left, aud_cnt, hdr_cnt, tag_n,
		                    fstate, cstate};
	endcase
end

assign DDRAM_DIN = cw_burst ? st_word : px_q;
assign DDRAM_BE  = 8'hFF;

// ------------------------------------------------- DDR3 port arbitration
// A command (RD, or WE with the first beat) is held until BUSY is low.
// Line fetches first, then the control block, then decoder reads and writes in turn.
reg  prefer_rd;
// Platform rule (MiSTer sys): the emu's RESET is sysmem's reset_out, which also puts the DDR3 port's
// f2sdram_safe_terminator in charge. While it is, the terminator completes the transaction already under way
// but does not forward new commands, yet waitrequest still passes through: a read issued during reset looks
// accepted and never returns, which would leave a tag in flight for ever and credit every later read's words to
// the wrong burst. So nothing is issued while reset is asserted; commands already in flight complete normally.
wire port_free = !reset && !wr_burst && !cw_burst && (!DDRAM_BUSY || (!DDRAM_RD && !DDRAM_WE));
wire issue_lf  = port_free && lf_want;
wire issue_cw  = port_free && !issue_lf && cw_want;
wire issue_cr  = port_free && !issue_lf && !issue_cw && cr_want && tag_n < 5'd14;
wire issue_ar  = port_free && !issue_lf && !issue_cw && !issue_cr && ar_want;
wire issue_wr  = port_free && !issue_lf && !issue_cw && !issue_cr && !issue_ar && wr_want && (!rd_want || !prefer_rd);
wire issue_rd  = port_free && !issue_lf && !issue_cw && !issue_cr && !issue_ar && !issue_wr && rd_want;

always @(posedge clk) begin
	if (!DDRAM_BUSY) DDRAM_RD <= 1'b0;

	if (wr_burst && DDRAM_WE && !DDRAM_BUSY) begin
		if (wr_beats == 8'd1) begin
			wr_burst <= 1'b0;
			DDRAM_WE <= 1'b0;
		end
		wr_beats <= wr_beats - 8'd1;
	end
	if (cw_burst && DDRAM_WE && !DDRAM_BUSY) begin
		if (cw_beats == 3'd1) begin
			cw_burst <= 1'b0;
			DDRAM_WE <= 1'b0;
		end
		cw_beats <= cw_beats - 3'd1;
		cw_idx <= cw_idx + 3'd1;
	end

	if (issue_cw) begin
		DDRAM_ADDR <= STAT_BASE[31:3];
		DDRAM_BURSTCNT <= 8'd5;
		DDRAM_WE <= 1'b1;
		cw_burst <= 1'b1;
		cw_beats <= 3'd5;
		cw_idx <= 3'd0;
	end
	if (issue_cr) begin
		DDRAM_ADDR <= HDR_BASE[31:3];
		DDRAM_BURSTCNT <= {2'b00, HDR_WORDS};
		DDRAM_RD <= 1'b1;
	end
	if (issue_wr) begin
		DDRAM_ADDR <= wr_addr;
		DDRAM_BURSTCNT <= wr_len;
		DDRAM_WE <= 1'b1;
		wr_burst <= 1'b1;
		wr_beats <= wr_len;
		wr_addr <= wr_addr + wr_len;
		wr_line_left <= wr_line_left - wr_len;
		prefer_rd <= 1'b1;
	end
	if (issue_rd) begin
		DDRAM_ADDR <= rd_addr;
		DDRAM_BURSTCNT <= rd_len;
		DDRAM_RD <= 1'b1;
		rd_addr <= rd_addr + rd_len;
		rd_words_left <= rd_words_left - rd_len;
		prefer_rd <= 1'b0;
	end
	if (issue_lf) begin
		DDRAM_ADDR <= lf_raddr;
		DDRAM_BURSTCNT <= lf_len;
		DDRAM_RD <= 1'b1;
		lf_raddr <= lf_raddr + lf_len;
		lf_words_left <= lf_words_left - lf_len;
	end
	rd_outstanding <= rd_outstanding + (issue_rd ? {1'b0, rd_len} : 9'd0) - (ret_dec ? 9'd1 : 9'd0);

	// bursts in flight
	if (issue_ar) begin
		DDRAM_ADDR <= aud_raddr;
		DDRAM_BURSTCNT <= ar_len;
		DDRAM_RD <= 1'b1;
		aud_raddr <= aud_raddr + ar_len;
		aud_left <= aud_left - ar_len;
	end
	if (aud_start || vbi_start) begin
		aud_raddr <= RING_BASE[31:3] + {cur_slot, 17'd0} + (vbi_start ? vbi_off : aud_off);
		aud_left <= vbi_start ? 11'd2 : 11'd1024;
		aud_cnt <= 11'd0;
		aux_vbi <= vbi_start;
	end
	aud_we <= ret_aud && !aux_vbi;
	aud_waddr <= {back_buf, aud_cnt[9:0]};
	aud_wdata <= DDRAM_DOUT;
	if (ret_aud && aux_vbi) vbi_w[aud_cnt[0]] <= DDRAM_DOUT;
	if (ret_aud) aud_cnt <= aud_cnt + 11'd1;

	if (issue_rd || issue_lf || issue_cr || issue_ar) begin
		tag_len[tag_wr] <= issue_lf ? lf_len : issue_cr ? {2'b00, HDR_WORDS} : issue_ar ? ar_len : rd_len;
		tag_k[tag_wr] <= issue_lf ? 2'd1 : issue_cr ? 2'd2 : issue_ar ? 2'd3 : 2'd0;
		tag_wr <= tag_wr + 4'd1;
	end
	if (rd_ret) begin
		if ((tag_left == 8'd0 ? tag_len[tag_rd] : tag_left) == 8'd1) begin
			tag_rd <= tag_rd + 4'd1;
			tag_left <= 8'd0;
		end else tag_left <= (tag_left == 8'd0 ? tag_len[tag_rd] : tag_left) - 8'd1;
	end
	tag_n <= tag_n + ((issue_rd || issue_lf || issue_cr || issue_ar) ? 5'd1 : 5'd0)
	               - ((rd_ret && (tag_left == 8'd0 ? tag_len[tag_rd] : tag_left) == 8'd1) ? 5'd1 : 5'd0);

	// header block words
	if (issue_cr) hdr_cnt <= 6'd0;
	if (ret_hdr) begin
		hdr[hdr_cnt[4:0]] <= DDRAM_DOUT;
		hdr_cnt <= hdr_cnt + 6'd1;
	end

	// line fetch: returning words go to ld_scan's line buffer, full 24-bit pixels
	lf_we <= ret_lf;
	lf_addr <= lf_wcnt;
	lf_data <= cvbs ? DDRAM_DOUT : {16'd0, DDRAM_DOUT[55:32], DDRAM_DOUT[23:0]};
	if (ret_lf) lf_wcnt <= lf_wcnt + 9'd1;
	lf_outstanding <= lf_outstanding + (issue_lf ? {2'b00, lf_len} : 10'd0) - (ret_lf ? 10'd1 : 10'd0);
	if ((lf_req || lf_pend) && lf_words_left == 0 && lf_outstanding == 0 && !issue_lf) begin
		// a new line once every word of the last one is in
		if (cvbs) begin
			// row 0 (field 0, line 0) is fetched during the last line of the frame before: it belongs to the frame
			// that goes up at the coming boundary, the ready one if a fresh one is waiting
			lf_raddr <= RING_BASE[31:3] + {buf_slot[((lf_req ? lf_row : lf_pend_row) == 10'd0 && fresh) ? ready_buf : disp_buf], 17'd0}
			            + (lf_req ? lf_row : lf_pend_row) * 8'd142;
			lf_words_left <= 10'd142;
		end else begin
			lf_raddr <= fb_word(disp_buf) + (lf_req ? lf_row : lf_pend_row) * stride_b[13:3];
			lf_words_left <= {1'b0, line_words[8:0]};
		end
		lf_wcnt <= 9'd0;
		lf_pend <= 1'b0;
	end else if (lf_req) begin
		lf_pend <= 1'b1;
		lf_pend_row <= lf_row;
	end

	// set up the next row once every burst of this one has been sent
	row_wait <= 1'b0;
	if (wr_line_go && wr_line_left == 0 && !wr_burst && !issue_wr) begin
		wr_line_go <= 1'b0;
		wr_row <= wr_row + 11'd1;
		rows_done <= rows_done + 11'd1;
		row_wait <= 1'b1;
	end else if (!wr_line_go && !row_wait && wr_row < pic_h[10:0] && !frame_setup) begin
		wr_addr <= fb_word(back_buf) + fb_row_r * stride_b[13:3];
		wr_line_left <= line_words;
		wr_line_go <= 1'b1;
	end

	if (frame_setup) begin
		rd_addr <= RING_BASE[31:3] + {cur_slot, 17'd0};
		rd_words_left <= frame_words;
		wr_row <= 11'd0;
		rows_done <= 11'd0;
		wr_line_go <= 1'b0;
		row_wait <= 1'b1;
	end

	// On reset stop issuing, but never withdraw a command or cut a write
	// burst short (the DDR3 bridge needs every beat), and keep counting the
	// reads already in flight so they drain before the next frame starts.
	if (reset) begin
		rd_words_left <= 18'd0;
		wr_line_go <= 1'b0;
		wr_row <= 11'h7FF;
	end
end

// px_pop must be combinational to follow the FWFT FIFO
always @* px_pop = wr_burst && DDRAM_WE && !DDRAM_BUSY;

// ----------------------------------------------------- slot table lookup
// Slot k holds frame slot_f(k); registered so the 16 compares stay off the scheduler's path.
// want_r2 is the frame want_found/want_slot describe; a decode starts only when it is still the one wanted.
reg  [15:0] slot_hit;
reg         want_found;
reg   [3:0] want_slot;
reg  [15:0] want_r1, want_r2;
integer k;
always @(posedge clk) begin
	want_r1 <= want;
	want_r2 <= want_r1;
	for (k = 0; k < 16; k = k + 1)
		slot_hit[k] <= hdr[20 + k / 2][32 * (k % 2) +: 32] == {16'd0, want};
	want_found <= slot_hit != 16'd0;
	want_slot <= 4'd0;
	for (k = 15; k >= 0; k = k - 1) if (slot_hit[k]) want_slot <= k[3:0];
end

// ---------------------------------------------- control sequencer (per frame)
reg   [7:0] pps_i;
reg  [15:0] poll;             // re-read the header while the wanted frame is not in a slot
reg         need_poll;

wire        hdr_ok    = hdr[0][31:0] == HDR_MAGIC && hdr[0][47:32] == 16'd1 && hdr[1][31:0] != 32'd0;
wire [15:0] hdr_gen   = hdr[0][63:48];
wire  [7:0] pps_byte  = hdr[4 + pps_i[6:3]][{pps_i[2:0], 3'b000} +: 8];

// -------------------------------------------------------- frame scheduler
reg [23:0] clocks;
reg        dec_finished;

// the frame wanted is neither on screen nor ready
wire need = !(ready_v && ready_f == want) && !(disp_v && disp_f == want);

// Power-up state: nothing shown and the DDR3 port idle until the HPS writes a header.
initial begin
	fstate = F_IDLE;
	cstate = C_IDLE;
	disc = 1'b0;
	loaded = 1'b0;
	cvbs = 1'b0;
	pic_w = 16'd0;                        // no line fetch length until a PPS arrives
	pic_h = 16'd0;
	cur_gen = 16'd0;
	disp_v = 1'b0;
	ready_v = 1'b0;
	fresh = 1'b0;
	disp_buf = 2'd0;
	ready_buf = 2'd0;
	back_buf = 2'd1;
	seq = 32'd0;
	busy_flips = 16'd0;
	rd_count = 16'd0;
	late_count = 16'd0;
	error_count = 16'd0;
	decode_kclks = 16'd0;
	DDRAM_RD = 1'b0;
	DDRAM_WE = 1'b0;
	wr_burst = 1'b0;
	cw_burst = 1'b0;
	cw_want = 1'b0;
	cr_want = 1'b0;
	rd_words_left = 18'd0;
	rd_outstanding = 9'd0;
	tag_rd = 4'd0;
	tag_wr = 4'd0;
	tag_n = 5'd0;
	tag_left = 8'd0;
	lf_words_left = 10'd0;
	lf_outstanding = 10'd0;
	lf_pend = 1'b0;
	wr_line_go = 1'b0;
	wr_row = 11'h7FF;
	pk_state = 2'd0;
	pk_hold_v = 1'b0;
	pps_we = 1'b0;
	poll = 16'd0;
	aud_left = 11'd0;
	aud_cnt = 11'd0;
	aud_start = 1'b0;
	vbi_start = 1'b0;
	aux_vbi = 1'b0;
	has_vbi = 1'b0;
	pic_vbi = 128'd0;
	has_audio = 1'b0;
	new_pic = 1'b0;
end

// the buffer to decode into: neither the one on screen nor the newest
wire [1:0] free_buf = (disp_buf == ready_buf) ? (disp_buf == 2'd2 ? 2'd0 : disp_buf + 2'd1)
                                              : 2'd3 - disp_buf - ready_buf;

always @(posedge clk) begin
	dec_start <= 1'b0;
	flush <= 1'b0;
	frame_setup <= 1'b0;
	pps_we <= 1'b0;
	clocks <= clocks + 24'd1;
	aud_start <= 1'b0;
	vbi_start <= 1'b0;
	new_pic <= 1'b0;

	if (issue_cw) cw_want <= 1'b0;          // a status write went out (a request in this clock below wins)

	// ------------------------------------------ frame boundary: the next picture goes up
	if (flip) begin
		seq <= seq + 32'd1;
		if (cstate != C_IDLE) begin
			cw_want <= 1'b1;                  // the status still goes out, so a stuck sequencer can be seen
			busy_flips <= busy_flips + 16'd1;
		end
		if (fresh) begin
			new_pic <= 1'b1;
			pic_buf <= ready_buf;
			pic_vbi <= fb_vbi[ready_buf];
			disp_buf <= ready_buf;
			disp_f <= ready_f;
			disp_v <= 1'b1;
			fresh <= 1'b0;
			if (ready_f != want) late_count <= late_count + 16'd1;
		end else if (disc && !(disp_v && disp_f == want)) late_count <= late_count + 16'd1;
	end

	// ------------------------------------------ control: status out, header in, once per frame
	need_poll <= disc && need && !want_found;
	if (cstate == C_IDLE && poll != 16'd0) poll <= poll + 16'd1;
	case (cstate)
	C_IDLE:
		if (flip) begin cw_want <= 1'b1; cstate <= C_WST; end
		else if (need_poll && poll == 16'd0) begin poll <= 16'd1; cstate <= C_RHD; end   // about 0.9 ms apart
	C_WST:
		if (issue_cw) begin cw_want <= 1'b0; cstate <= C_RHD; end
	C_RHD: begin
		cr_want <= 1'b1;
		if (issue_cr) begin cr_want <= 1'b0; cstate <= C_WAIT; end
	end
	C_WAIT:
		if (hdr_cnt == HDR_WORDS) cstate <= C_PARSE;
	C_PARSE:
		if (!hdr_ok) begin
			disc <= 1'b0;
			loaded <= 1'b0;
			cstate <= C_IDLE;
		end else if (!loaded || hdr_gen != cur_gen) begin
			// a new disc: its PPS goes into the decoder once no frame is being decoded
			disc <= 1'b0;
			disp_v <= 1'b0;
			ready_v <= 1'b0;
			fresh <= 1'b0;
			if (!fstate_busy) begin
				cur_gen <= hdr_gen;
				frames <= hdr[1][31:16] != 16'd0 ? 16'hFFFF : hdr[1][15:0];
				frame_words <= hdr[1][49:32];
				field1_row <= hdr[2][10:0];
				crop_x <= hdr[2][26:16];
				crop_y <= hdr[2][41:32];
				cvbs <= hdr[2][48];
				aud_off <= hdr[3][16:0];
				has_audio <= hdr[3][16:0] != 17'd0;
				vbi_off <= hdr[3][48:32];
				has_vbi <= hdr[3][48:32] != 17'd0;
				pic_vbi <= 128'd0;
				pps_i <= 8'd0;
				cstate <= hdr[2][48] ? C_HOLD : C_PPS;   // composite: no picture decoder
			end
		end else cstate <= C_IDLE;
	C_PPS: begin
		pps_we <= 1'b1;
		pps_addr <= pps_i[6:0];
		pps_data <= pps_byte;
		pps_i <= pps_i + 8'd1;
		if (pps_i == 8'd127) cstate <= C_HOLD;
	end
	C_HOLD: begin                         // the last PPS byte is written this clock
		loaded <= 1'b1;
		disc <= 1'b1;
		cstate <= C_IDLE;
	end
	default: cstate <= C_IDLE;
	endcase

	// ------------------------------------------ decode the wanted frame when it is in a slot
	case (fstate)
	F_IDLE:
		if (disc && cstate == C_IDLE && need && want_found && want_r2 == want && !reset) begin
			// start once traffic from an abandoned frame has drained
			if (rd_outstanding == 0 && !wr_burst) begin
				back_buf <= free_buf;
				tgt <= want;
				cur_slot <= want_slot;
				if (cvbs) begin
					// composite: the frame plays from its slot; only its audio and VBI are fetched
					buf_slot[free_buf] <= want_slot;
					fb_vbi[free_buf] <= 128'd0;
					clocks <= 24'd0;
					if (has_audio) begin aud_start <= 1'b1; fstate <= F_AUD; end
					else if (has_vbi) begin vbi_start <= 1'b1; fstate <= F_VBI; end
					else fstate <= F_DONE;
				end else begin
					flush <= 1'b1;
					frame_setup <= 1'b1;
					fstate <= F_SETUP;
				end
			end
		end

	F_SETUP: begin
		dec_start <= 1'b1;
		dec_finished <= 1'b0;
		clocks <= 24'd0;
		fstate <= F_RUN;
	end

	F_RUN: begin
		if (dec_done) begin
			dec_finished <= 1'b1;
			if (dec_error) error_count <= error_count + 16'd1;
		end
		// done when the decoder has finished and every row is in the frame buffer
		if ((dec_finished || dec_done) && rows_done == pic_h[10:0] && !wr_burst) begin
			fb_vbi[back_buf] <= 128'd0;
			if (has_audio) begin aud_start <= 1'b1; fstate <= F_AUD; end
			else if (has_vbi) begin vbi_start <= 1'b1; fstate <= F_VBI; end
			else fstate <= F_DONE;
		end
	end

	F_AUD:                                // the frame's audio block into its bank
		if (!aud_start && aud_cnt == 11'd1024) begin
			if (has_vbi) begin vbi_start <= 1'b1; fstate <= F_VBI; end
			else fstate <= F_DONE;
		end

	F_VBI:                                // the frame's VBI entry (two words)
		if (!vbi_start && aud_cnt == 11'd2) begin
			fb_vbi[back_buf] <= {vbi_w[1], vbi_w[0]};
			fstate <= F_DONE;
		end

	F_DONE:                               // the frame is ready (not on a frame boundary clock)
		if (!flip) begin
			ready_buf <= back_buf;
			ready_f <= tgt;
			ready_v <= 1'b1;
			fresh <= 1'b1;
			rd_count <= rd_count + 16'd1;
			decode_kclks <= clocks[23:8];
			fstate <= F_IDLE;
		end

	default: fstate <= F_IDLE;
	endcase

	// A core reset abandons the frame in progress (it is decoded again from its slot).
	if (reset) begin
		fstate <= F_IDLE;
		flush <= 1'b1;
	end
end

endmodule

`default_nettype wire
