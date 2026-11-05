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
always @(posedge clk) begin : cv_interp
	reg signed [24:0] acc;
	if (ce_4fsc) begin
		cx[0] <= cv_out;
		for (ck = 1; ck < 12; ck = ck + 1) cx[ck] <= cx[ck - 1];
		cph <= 2'd0;
	end else cph <= cph + 2'd1;
	for (ck = 0; ck < 12; ck = ck + 1) cprod[ck] <= $signed({1'b0, cx[ck]}) * cv_cf(cph, ck[3:0]);
	acc = 25'sd512;
	for (ck = 0; ck < 12; ck = ck + 1) acc = acc + cprod[ck];
	cv_hi <= (acc < 0) ? 8'd0 : (acc[24:10] > 15'd255) ? 8'd255 : acc[17:10];
end

