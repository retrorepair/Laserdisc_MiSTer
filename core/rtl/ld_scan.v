// RGB scan-out of the decoded frame buffer at the TBC replay timing, with the OSD drawn in RGB.
//
// The DSCV picture keeps TBC samples crop_x.. and field lines crop_y/2.. of both fields, woven in the frame
// buffer (docs/streaming_design.md): TBC sample x of field line ln in field fld (0 = first) is
// column x - crop_x of frame-buffer row 2 * (ln - crop_y/2) + fld. Each line is fetched while the line before
// it is shown, into the other half of a two-line buffer (ld_stream line fetch).
//
// OSD colours for the RGB path (osd_m50552 cls): glyph white, border and black raster black, blue raster
// BG_RGB of tools/osd/osd_fx.py (0.05, 0.10, 0.70; the mock-up value the user approved) = (13, 26, 179).
// Outside the picture, or with no disc video, the output is black (blanking level).
module ld_scan (
	input             clk,
	input             ce,

	// position and OSD decision, as osd_m50552 outputs them
	input      [10:0] x,
	input       [8:0] ln,
	input             fld,
	input       [1:0] cls,

	input             show,         // disc video on and a picture in the frame buffer
	input             ntsc,         // 525-line timing (tbc_timing)
	input      [10:0] crop_x,
	input       [9:0] crop_y,
	input      [10:0] pic_cols,
	input      [10:0] pic_rows,

	// line fetch (ld_stream)
	output reg        lf_req,
	output reg  [9:0] lf_row,
	input             lf_we,
	input       [8:0] lf_addr,
	input      [47:0] lf_data,

	// one ce later
	output reg  [7:0] r,
	output reg  [7:0] g,
	output reg  [7:0] b,
	output reg [10:0] xo,
	output reg  [8:0] lno,
	output reg        fo
);

localparam [7:0] BLUE_R = 8'd13, BLUE_G = 8'd26, BLUE_B = 8'd179;

wire [8:0] y0 = {1'b0, crop_y[9:1]};               // first field line kept

// ------------------------------------------------------------------ two-line buffer
reg [47:0] lb [0:1023];
reg        bank_w;
reg  [9:0] rd_a;
reg [47:0] lb_q;
always @(posedge clk) begin
	if (lf_we) lb[{bank_w, lf_addr}] <= lf_data;
	lb_q <= lb[rd_a];
end

// ------------------------------------------------------------------ fetch the next line at each line start
wire       last_ln = ln == (ntsc ? (fld ? 9'd261 : 9'd262) : (fld ? 9'd311 : 9'd312));   // tbc_timing
wire [8:0] nln     = last_ln ? 9'd0 : ln + 9'd1;
wire       nfld    = last_ln ? ~fld : fld;
wire [10:0] nrow   = {1'b0, nln - y0, 1'b0} + nfld;
always @(posedge clk) begin
	lf_req <= 1'b0;
	if (ce && x == 11'd0 && nln >= y0 && nrow < pic_rows) begin
		lf_req <= 1'b1;
		lf_row <= nrow[9:0];
		bank_w <= nln[0];
	end
end

// ------------------------------------------------------------------ pixel
wire [10:0] col   = x - crop_x;
wire [10:0] row   = {1'b0, ln - y0, 1'b0} + fld;
wire        inpic = x >= crop_x && col < pic_cols && ln >= y0 && row < pic_rows;

reg        half, in1;
reg  [1:0] c1;
reg [10:0] x1;
reg  [8:0] ln1;
reg        f1;
always @(posedge clk) if (ce) begin
	rd_a <= {ln[0], col[9:1]};
	half <= col[0];
	in1  <= inpic && show;
	c1   <= cls;
	x1 <= x; ln1 <= ln; f1 <= fld;

	xo <= x1; lno <= ln1; fo <= f1;
	case (c1)
		2'd1: {r, g, b} <= 24'hFFFFFF;
		2'd2: {r, g, b} <= 24'h000000;
		2'd3: {r, g, b} <= {BLUE_R, BLUE_G, BLUE_B};
		default:
			if (!in1) {r, g, b} <= 24'h000000;
			else if (half) {r, g, b} <= {lb_q[31:24], lb_q[39:32], lb_q[47:40]};
			else           {r, g, b} <= {lb_q[7:0],   lb_q[15:8],  lb_q[23:16]};
	endcase
end

endmodule
