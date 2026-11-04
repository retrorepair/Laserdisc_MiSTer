// Streams TBC lines from DDR3 into a 4-line ring and serves one sample per ce.
//
// DDR3 layout (written by tools/mister/tbc_load.py, docs/core_architecture.md):
//   byte 0x30000000 : header word  [31:0] = "TBC1" (0x31434254), [63:32] = field count (even)
//   byte 0x30001000 : field 0, then fields contiguous; each line = 1136 samples = 284 x 64-bit words,
//                     each field = 313 lines (the first field of a pair uses 312).
// The reader prefills display lines 0-2, then fetches line k+2 as display line k begins.
module tbc_reader (
	input             clk,          // = DDRAM_CLK
	input             ce,
	input             reset,

	// display position (from tbc_timing) and its line-start pulse
	input      [10:0] x,
	input       [8:0] ln,
	input             fld,
	input             line_start,
	output reg        run,          // timing may run (prefill done)

	// transport (core/rtl/player.v)
	input             video_on,     // 1: disc video; 0: the player's own raster (sync + burst, blank picture)
	input      [15:0] frame,        // frame to show from the next frame boundary on
	input             resync,       // restart on 'frame' now (mid-field): the player switches timing to the disc
	output     [15:0] frames,       // frames available (field count / 2)
	output reg        disc,         // a TBC image is loaded (header valid)

	// sample out, one ce later, with its position
	output reg [15:0] s,
	output reg [10:0] xs,
	output reg  [8:0] lns,
	output reg        flds,

	input             ddr_busy,
	output reg  [7:0] ddr_burstcnt,
	output reg [28:0] ddr_addr,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	output reg        ddr_rd
);

localparam [28:0] HDR_WORD   = 29'h6000000;          // byte 0x30000000 / 8
localparam [28:0] DATA_WORD  = 29'h6000200;          // byte 0x30001000 / 8
localparam [31:0] MAGIC      = 32'h31434254;         // "TBC1"
localparam [16:0] FIELD_WDS  = 17'd88892;            // 313 * 284
localparam  [8:0] LINE_WDS   = 9'd284;
localparam  [7:0] BURST      = 8'd71;                // 4 bursts per line

// ------------------------------------------------------------ line ring (4 x 512 words)
reg [63:0] ring [0:2047];
reg  [1:0] dslot;                 // slot of the display line
reg [63:0] ring_q;
always @(posedge clk) ring_q <= ring[{dslot, x[10:2]}];

reg        valid;                 // header ok and count > 0

// Player raster (models the player's sync generator when no disc video is output): standard PAL line,
// sync 0-82, burst 98-137 at nominal amplitude (0.15 V of 0.7 V = 8481) with the PAL swing, blanking
// elsewhere; subcarrier-locked at 1135 samples/line, so the burst phase advances 270 deg per line and
// swings 135/225 deg: phi(L)/45 = 6L + (L odd ? 5 : 3), sample = cos(45 deg * (2x + phi/45)).
reg  [1:0] rline;                 // raster line counter mod 4
wire [2:0] rk = {x[1:0], 1'b0} + (rline * 3'd6) + (rline[0] ? 3'd5 : 3'd3);
wire       rpos = (rk == 3'd1) || (rk == 3'd7);
wire [15:0] raster = (x < 11'd83) ? 16'd0 :
                     (x >= 11'd98 && x < 11'd138) ? (rpos ? 16'd20439 : 16'd8445) : 16'd14442;
always @(posedge clk) if (ce && run && x == 11'd1134) rline <= rline + 2'd1;

// ring_q holds the word for the current x (read in the clocks after x changed), so the lane
// must be chosen with that same x; the sample is then presented one ce later with its position.
always @(posedge clk) if (ce) begin
	xs <= x; lns <= ln; flds <= fld;
	if (!valid || !video_on) s <= raster;
	else case (x[1:0])
		2'd0: s <= ring_q[15:0];
		2'd1: s <= ring_q[31:16];
		2'd2: s <= ring_q[47:32];
		2'd3: s <= ring_q[63:48];
	endcase
end

// ------------------------------------------------------------ fetch engine
localparam ST_HDR = 3'd0, ST_HDRW = 3'd1, ST_IDLE = 3'd2, ST_ISSUE = 3'd3, ST_ACC = 3'd4, ST_RECV = 3'd5;
reg  [2:0] st;
reg [31:0] count;                 // fields in DDR3
reg [31:0] ffs;                   // fetch field index
reg  [8:0] fln;                   // fetch line within field
reg  [1:0] fslot;                 // ring slot being filled
reg  [1:0] fburst;                // burst within line
reg  [6:0] fword;                 // word within burst
reg  [1:0] prefill;               // lines still to prefill
reg        pend;                  // a fetch request is waiting
reg [28:0] line_base;

wire [8:0] fln_last = ffs[0] ? 9'd312 : 9'd311;
assign frames = count[16:1];
reg        resync_req;
wire [8:0] waddr    = fburst * 9'd71 + fword;          // word within line (explicitly 9 bits wide)
wire       wrap     = ce && run && (x == 11'd1134);     // same ce edge on which tbc_timing wraps x to 0

always @(posedge clk) begin
	if (reset) begin
		st <= ST_HDR; ddr_rd <= 1'b0; valid <= 1'b0; run <= 1'b0; disc <= 1'b0; resync_req <= 1'b0;
		ffs <= 32'd0; fln <= 9'd0; fslot <= 2'd0; dslot <= 2'd0; prefill <= 2'd3; pend <= 1'b0;
	end else if ((resync || resync_req) && valid && (st == ST_IDLE)) begin
		// restart on the requested frame's first field: timing is held at its origin (run = 0) while
		// lines 0-2 prefill, then resumes: a sync discontinuity, as when the player switches to disc timing
		resync_req <= 1'b0;
		run <= 1'b0; ffs <= {15'd0, frame, 1'b0}; fln <= 9'd0;
		fslot <= 2'd0; dslot <= 2'd0; prefill <= 2'd3; pend <= 1'b0;
	end else begin
		if (resync) resync_req <= 1'b1;               // fetch in progress: restart when it completes
		if (wrap) begin
			dslot <= dslot + 2'd1;
			pend  <= 1'b1;
		end

		case (st)
		ST_HDR: begin
			ddr_addr <= HDR_WORD; ddr_burstcnt <= 8'd1; ddr_rd <= 1'b1; st <= ST_HDRW;
		end
		ST_HDRW: begin
			if (!ddr_busy) ddr_rd <= 1'b0;
			if (ddr_dout_ready) begin
				valid <= (ddr_dout[31:0] == MAGIC) && (ddr_dout[63:32] != 32'd0);
				disc  <= (ddr_dout[31:0] == MAGIC) && (ddr_dout[63:32] != 32'd0);
				count <= ddr_dout[63:32];
				st    <= ST_IDLE;
				if (!((ddr_dout[31:0] == MAGIC) && (ddr_dout[63:32] != 32'd0))) run <= 1'b1;   // no data: run black
			end
		end
		ST_IDLE: begin
			if (valid && (prefill != 2'd0 || pend)) begin
				if (prefill == 2'd0) pend <= 1'b0;
				line_base <= DATA_WORD + ffs[11:0] * FIELD_WDS + fln * LINE_WDS;
				fburst <= 2'd0;
				st <= ST_ISSUE;
			end
		end
		ST_ISSUE: begin
			ddr_addr     <= line_base + fburst * BURST;
			ddr_burstcnt <= BURST;
			ddr_rd       <= 1'b1;
			fword        <= 7'd0;
			st           <= ST_ACC;
		end
		ST_ACC: begin                       // request accepted on the first cycle with !busy
			if (!ddr_busy) begin ddr_rd <= 1'b0; st <= ST_RECV; end
			if (ddr_dout_ready) begin
				ring[{fslot, waddr}] <= ddr_dout;
				fword <= fword + 7'd1;
			end
		end
		ST_RECV: begin
			if (ddr_dout_ready) begin
				ring[{fslot, waddr}] <= ddr_dout;
				fword <= fword + 7'd1;
				if (fword == BURST - 7'd1) begin
					if (fburst == 2'd3) begin
						// line complete: advance fetch pointer
						fslot <= fslot + 2'd1;
						if (fln == fln_last) begin
							fln <= 9'd0;
							// first field -> its second field; second field -> the transport's next frame
							if (!ffs[0]) ffs <= ffs + 32'd1;
							else ffs <= ({15'd0, frame, 1'b0} + 32'd2 <= count) ? {15'd0, frame, 1'b0} : 32'd0;
						end else fln <= fln + 9'd1;
						if (prefill != 2'd0) begin
							prefill <= prefill - 2'd1;
							if (prefill == 2'd1) run <= 1'b1;
						end
						st <= ST_IDLE;
					end else begin
						fburst <= fburst + 2'd1;
						st <= ST_ISSUE;
					end
				end
			end
		end
		default: st <= ST_HDR;
		endcase
	end
end

endmodule
