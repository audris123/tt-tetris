/*
 * 640x480 @ 60 Hz VGA timing generator (25.175 MHz pixel clock).
 *
 * The counters are mixed radix so the game board can share them:
 *   x = 200*q + 10*rrow + rcol     (rcol 0..9, rrow 0..19, q 0..3; 800 clocks)
 *   y = 20*yc + yf                 (yf 0..19, yc 0..26; 525 lines)
 * {rrow, rcol} is also the board cell at the tap of the rotating board, which
 * goes round exactly 4 times per scanline.
 */
`default_nettype none

module vga_sync (
    input  wire       clk,
    input  wire       rst_n,
    output reg  [3:0] rcol,
    output reg  [4:0] rrow,
    output reg  [1:0] q,
    output reg  [4:0] yf,
    output reg  [4:0] yc,
    output wire       hsync,
    output wire       vsync,
    output wire       frame_tick   // 1 clk pulse at first line of vertical blank
);
  wire end_row  = (rcol == 4'd9);
  wire end_ring = end_row && (rrow == 5'd19);
  wire end_line = end_ring && (q == 2'd3);

  always @(posedge clk) begin
    if (!rst_n) begin
      rcol <= 4'd0;
      rrow <= 5'd0;
      q    <= 2'd0;
      yf   <= 5'd0;
      yc   <= 5'd0;
    end else begin
      rcol <= end_row ? 4'd0 : rcol + 4'd1;
      if (end_row)  rrow <= end_ring ? 5'd0 : rrow + 5'd1;
      if (end_ring) q    <= q + 2'd1;
      if (end_line) begin
        if (yc == 5'd26 && yf == 5'd4) begin   // line 524
          yc <= 5'd0;
          yf <= 5'd0;
        end else if (yf == 5'd19) begin
          yc <= yc + 5'd1;
          yf <= 5'd0;
        end else begin
          yf <= yf + 5'd1;
        end
      end
    end
  end

  // hsync low for x = 656..751  (q = 3, ring index 56..151)
  wire ge56  = (rrow > 5'd5)  || (rrow == 5'd5  && rcol >= 4'd6);
  wire lt152 = (rrow < 5'd15) || (rrow == 5'd15 && rcol < 4'd2);
  assign hsync = ~((q == 2'd3) && ge56 && lt152);

  // vsync low for y = 490..491
  assign vsync = ~((yc == 5'd24) && (yf[4:1] == 4'd5));

  assign frame_tick = (q == 2'd0) && (rrow == 5'd0) && (rcol == 4'd0) &&
                      (yc == 5'd24) && (yf == 5'd0);
endmodule
