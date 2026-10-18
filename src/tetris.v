/*
 * Tetris game core + pixel renderer, sized for a 1x1 Tiny Tapeout tile.
 *
 * Board: 10 x 20 cells kept in a 200-bit circular shift register that
 * rotates one cell per clock. Cell (rrow, rcol) is at the tap ring[0];
 * its new value (wr) is shifted in at ring[199]. Plain DFFs with no reset,
 * enable or read multiplexers keep the board as small as possible.
 *
 * Every game operation is one "pass" = one full rotation (200 clocks):
 *   CHECK : does the piece overlap blocks or leave the board?
 *   LOCK  : OR the piece into the board (and look for a full row)
 *   SCAN  : look for a full row
 *   CLEAR : remove row frow; rows above it take the value seen 10 clocks
 *           earlier (= the row above) from a 10-bit delay line
 *   WIPE  : write 0 everywhere
 *
 * The ring position {rrow, rcol} comes from the VGA counters: a scanline is
 * 800 clocks = 4 rotations. The display copies the row it needs into a
 * 10-bit row buffer before the board area of every line. During vertical
 * blank the same buffer serves as the 10-cell delay line for CLEAR.
 */
`default_nettype none

module tetris (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [3:0] rcol,        // x = 200*q + 10*rrow + rcol
    input  wire [4:0] rrow,
    input  wire [1:0] q,
    input  wire [4:0] yf,          // y = 20*yc + yf
    input  wire [4:0] yc,
    input  wire       frame_tick,
    input  wire [4:0] btn,         // synced, active high: {hard, down, rotate, right, left}
    input  wire [2:0] rnd,         // random bits
    output wire [5:0] rgb          // {r[1:0], g[1:0], b[1:0]}
);

  // ---------------------------------------------------------------------------
  // Tetromino ROM, spawn orientation only: bit index = y*4 + x
  // Types: 0=I 1=O 2=T 3=S 4=Z 5=J 6=L
  // ---------------------------------------------------------------------------
  function [15:0] shape;
    input [2:0] t;
    begin
      case (t)
        3'd0:    shape = 16'h00F0;  // I  ....|XXXX
        3'd1:    shape = 16'h0066;  // O  .XX.|.XX.
        3'd2:    shape = 16'h0072;  // T  .X. |XXX
        3'd3:    shape = 16'h0036;  // S  .XX |XX.
        3'd4:    shape = 16'h0063;  // Z  XX. |.XX
        3'd5:    shape = 16'h0071;  // J  X.. |XXX
        default: shape = 16'h0074;  // L  ..X |XXX
      endcase
    end
  endfunction

  // Is cell (x, y) of the 4x4 box set after rotating clockwise r times?
  // Rotation happens inside a 4x4 box for I, 3x3 for the others (SRS);
  // O never rotates.
  function pcell;
    input [15:0] sh;
    input [2:0]  t;
    input [1:0]  r;
    input [1:0]  x;
    input [1:0]  y;
    reg   [1:0]  m, bx, by;
    begin
      m = (t == 3'd0) ? 2'd3 : 2'd2;
      case ((t == 3'd1) ? 2'd0 : r)
        2'd0:    begin bx = x;     by = y;     end
        2'd1:    begin bx = y;     by = m - x; end
        2'd2:    begin bx = m - x; by = m - y; end
        default: begin bx = m - y; by = x;     end
      endcase
      pcell = sh[{by, bx}] && (t == 3'd0 || (x != 2'd3 && y != 2'd3));
    end
  endfunction

  localparam S_IDLE  = 3'd0;  // waiting for a button to start (also game over)
  localparam S_RUN   = 3'd1;  // waiting for next frame tick
  localparam S_CHECK = 3'd2;  // passes: S_CHECK .. S_SCAN
  localparam S_LOCK  = 3'd3;
  localparam S_CLEAR = 3'd4;
  localparam S_WIPE  = 3'd5;
  localparam S_SCAN  = 3'd6;
  localparam S_PICK  = 3'd7;  // 7-bag selection

  // last move, undone when the CHECK pass fails
  localparam M_LEFT  = 3'd0;
  localparam M_RIGHT = 3'd1;
  localparam M_ROT   = 3'd2;
  localparam M_DOWN  = 3'd3;
  localparam M_HARD  = 3'd4;
  localparam M_SPAWN = 3'd5;

  reg [2:0]   state;
  reg [199:0] ring;            // the board
  reg [9:0]   rowbuf;          // row being displayed / CLEAR delay line

  reg [2:0]   ptype;           // falling piece
  reg [2:0]   ntype;           // next piece (preview)
  reg [1:0]   prot;
  reg [4:0]   pxp;             // column of 4x4 box, two's complement (-2..9)
  reg [4:0]   pyp;             // row of 4x4 box (0..19)
  reg [2:0]   mv;

  reg         run;             // pass in progress
  reg         hit;             // CHECK: overlap found
  reg [2:0]   cnt;             // CHECK: piece cells inside the board
  reg         racc;            // row-full accumulator
  reg         found;           // LOCK/SCAN: a full row exists
  reg [4:0]   frow;            // ... and its index

  reg [2:0]   pick;
  reg [6:0]   bag;             // pieces already dealt from the current bag
  reg [7:0]   lines;
  reg [5:0]   grav_cnt;
  reg [2:0]   das_cnt;         // left/right auto-repeat
  reg [4:0]   btn_prev;
  reg         play;
  reg         game_over;

  // ---------------------------------------------------------------------------
  // Ring pass engine
  // ---------------------------------------------------------------------------
  wire tap   = ring[0];
  wire at0   = (rrow == 5'd0)  && (rcol == 4'd0);
  wire at199 = (rrow == 5'd19) && (rcol == 4'd9);
  wire go    = (state >= S_CHECK) && (state <= S_SCAN) && (run || at0);

  wire [3:0] dcol = rrow[4:1];      // display cell under the beam
  wire [4:0] drow = yc - 5'd2;

  // next-piece preview box: 4x4 cells at x 480..559, y 80..159
  wire       in_prev = !go && (q == 2'd2) && (rrow[4:3] == 2'b01) && (yc[4:2] == 3'b001);

  // ---------------------------------------------------------------------------
  // Piece hit test, shared: the ring tap cell during a pass (vertical blank),
  // otherwise the display cell under the beam (falling piece on the board,
  // or the next piece in the preview box)
  // ---------------------------------------------------------------------------
  wire [2:0] htype = in_prev ? ntype : ptype;
  wire [4:0] tdx   = in_prev ? {3'b000, rrow[2:1]} : (go ? {1'b0, rcol} : {1'b0, dcol}) - pxp;
  wire [4:0] tdy   = in_prev ? {3'b000, yc[1:0]}   : (go ? rrow : drow) - pyp;
  wire       r_pc  = (tdx < 5'd4) && (tdy < 5'd4) &&
                     pcell(shape(htype), htype, in_prev ? 2'd0 : prot, tdx[1:0], tdy[1:0]);

  // Row buffer: the displayed row is copied as it passes the tap. During a
  // pass every cell is copied, so rowbuf[rcol] holds the cell 10 clocks back
  // (same column, row above) when it is read again.
  wire rb = rowbuf[go ? rcol : dcol];

  always @(posedge clk)
    if (go || rrow == drow) rowbuf[rcol] <= tap;

  // ---------------------------------------------------------------------------
  // Board write-back
  // ---------------------------------------------------------------------------
  wire last = go && at199;
  wire scan = (state == S_LOCK) || (state == S_SCAN);

  reg wr;
  always @(*) begin
    wr = tap;
    if (go) begin
      case (state)
        S_LOCK:  wr = tap | r_pc;
        S_CLEAR: wr = (rrow > frow) ? tap : (rrow != 5'd0) & rb;
        S_WIPE:  wr = 1'b0;
        default: wr = tap;
      endcase
    end
  end

  wire row_full = racc & wr & (rcol == 4'd9);
  wire ok       = !(hit | (r_pc & tap)) && (cnt + {2'b00, r_pc} == 3'd4);

  always @(posedge clk)
    ring <= {wr, ring[199:1]};

  // ---------------------------------------------------------------------------
  // Input handling (evaluated at frame rate => also debounces)
  // ---------------------------------------------------------------------------
  wire [4:0] btn_edge = btn & ~btn_prev;
  wire       das_fire = (das_cnt == 3'd7);
  wire       move_l   = btn[0] & (btn_edge[0] | das_fire);
  wire       move_r   = btn[1] & (btn_edge[1] | das_fire);
  wire [2:0] level    = (lines[7:5] != 3'd0) ? 3'd7 : lines[4:2];   // +1 every 4 lines
  wire [5:0] interval = {~level, 3'b111};                           // 63 .. 7 frames

  always @(posedge clk) begin
    // ---- per-cell work while a pass runs ----
    if (go) begin
      run  <= !at199;
      hit  <= hit | (r_pc & tap);
      cnt  <= cnt + {2'b00, r_pc};
      racc <= (rcol == 4'd0) ? wr : racc & wr;
      if (scan && row_full) begin
        found <= 1'b1;
        frow  <= rrow;
      end
    end

    case (state)

      S_IDLE: if (frame_tick) begin
        btn_prev <= btn;
        if (|btn_edge) begin
          lines     <= 8'd0;
          bag       <= 7'd0;
          play      <= 1'b1;
          game_over <= 1'b0;
          state     <= S_WIPE;
        end
      end

      S_RUN: if (frame_tick) begin
        btn_prev <= btn;
        if (grav_cnt != 6'h3F) grav_cnt <= grav_cnt + 6'd1;
        das_cnt  <= (btn_edge[0] | btn_edge[1]) ? 3'd0 : das_cnt + 3'd1;
        hit      <= 1'b0;
        cnt      <= 3'd0;

        if (btn_edge[4]) begin
          mv    <= M_HARD;
          pyp   <= pyp + 5'd1;
          state <= S_CHECK;
        end else if (btn_edge[2]) begin
          mv    <= M_ROT;
          prot  <= prot + 2'd1;
          state <= S_CHECK;
        end else if (move_l) begin
          mv    <= M_LEFT;
          pxp   <= pxp - 5'd1;
          state <= S_CHECK;
        end else if (move_r) begin
          mv    <= M_RIGHT;
          pxp   <= pxp + 5'd1;
          state <= S_CHECK;
        end else if (grav_cnt >= interval || (btn[3] && grav_cnt >= 6'd2)) begin
          grav_cnt <= 6'd0;
          mv       <= M_DOWN;
          pyp      <= pyp + 5'd1;
          state    <= S_CHECK;
        end
      end

      S_CHECK: if (last) begin
        hit <= 1'b0;
        cnt <= 3'd0;
        if (ok) begin
          if (mv == M_HARD) pyp   <= pyp + 5'd1;   // keep falling
          else              state <= S_RUN;
        end else begin
          case (mv)                                // undo the move
            M_LEFT:  pxp  <= pxp + 5'd1;
            M_RIGHT: pxp  <= pxp - 5'd1;
            M_ROT:   prot <= prot - 2'd1;
            M_SPAWN: ;
            default: pyp  <= pyp - 5'd1;
          endcase
          if (mv == M_SPAWN) begin
            play      <= 1'b0;
            game_over <= 1'b1;
            state     <= S_IDLE;
          end else if (mv >= M_DOWN) begin
            found <= 1'b0;
            state <= S_LOCK;
          end else begin
            state <= S_RUN;
          end
        end
      end

      S_LOCK, S_SCAN: if (last) begin
        found <= 1'b0;
        if (found || row_full) begin
          if (lines != 8'hFF) lines <= lines + 8'd1;
          state <= S_CLEAR;
        end else begin
          pick  <= rnd;
          state <= S_PICK;
        end
      end

      S_CLEAR: if (last) state <= S_SCAN;

      S_WIPE: if (last) begin
        pick  <= rnd;
        mv    <= M_LEFT;                      // first PICK only fills the preview
        state <= play ? S_PICK : S_IDLE;
      end

      S_PICK: begin
        if (pick == 3'd7 || bag[pick]) begin
          pick <= (pick == 3'd6) ? 3'd0 : pick + 3'd1;
        end else if (mv == M_LEFT) begin
          bag      <= bag | (7'd1 << pick);
          ntype    <= pick;
          pick     <= rnd;
          mv       <= M_SPAWN;
        end else begin
          bag      <= ((bag | (7'd1 << pick)) == 7'h7F) ? 7'd0 : (bag | (7'd1 << pick));
          ptype    <= ntype;
          ntype    <= pick;
          prot     <= 2'd0;
          pxp      <= 5'd3;
          pyp      <= 5'd0;
          mv       <= M_SPAWN;
          hit      <= 1'b0;
          cnt      <= 3'd0;
          grav_cnt <= 6'd0;
          state    <= S_CHECK;
        end
      end

      default: state <= S_IDLE;
    endcase

    // Only control state is reset; everything else is (re)loaded before use
    // (WIPE clears the board, a game start clears bag/lines, PICK loads the
    // piece). Leaving the rest without reset saves area.
    if (!rst_n) begin
      state     <= S_WIPE;
      run       <= 1'b0;
      lines     <= 8'd0;
      btn_prev  <= 5'd0;
      play      <= 1'b0;
      game_over <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Renderer: 20x20 px cells. Board columns are rrow/2 while q == 1
  // (x 200..399), board rows are yc 2..21 (y 40..439). Walls on both sides
  // and a floor at yc 22; lines counter LEDs at the top (yc 0); next-piece
  // preview to the right of the board.
  // ---------------------------------------------------------------------------
  wire       d_piece  = play && r_pc;

  wire       in_rows  = (yc >= 5'd2) && (yc < 5'd22);
  wire       in_board = in_rows && (q == 2'd1);
  wire       in_wall  = (yc >= 5'd2) && (yc <= 5'd22) &&
                        ((q == 2'd1) || (q == 2'd0 && dcol == 4'd9) || (q == 2'd2 && dcol == 4'd0));
  wire       in_led   = (yc == 5'd0) && (q == 2'd1) && !rrow[4];
  wire       gap      = (!rrow[0] && rcol == 4'd0) || (yf == 5'd0);
  wire       shine    = (!rrow[0] && rcol == 4'd1) || (yf == 5'd1);

  reg [5:0] piece_rgb;
  always @(*) begin
    case (htype)
      3'd0:    piece_rgb = 6'b00_11_11;  // I cyan
      3'd1:    piece_rgb = 6'b11_11_00;  // O yellow
      3'd2:    piece_rgb = 6'b10_00_11;  // T purple
      3'd3:    piece_rgb = 6'b00_11_00;  // S green
      3'd4:    piece_rgb = 6'b11_00_00;  // Z red
      3'd5:    piece_rgb = 6'b00_01_11;  // J blue
      default: piece_rgb = 6'b11_10_00;  // L orange
    endcase
  end

  wire [5:0] block_rgb = game_over ? 6'b10_00_00 : 6'b10_10_10;

  // block = bevelled 20x20 tile; empty board/preview cells are dark blue
  reg       block;
  reg [5:0] c;
  always @(*) begin
    block = 1'b1;
    c     = 6'b00_00_00;
    if (in_board) begin
      if (d_piece)           c = piece_rgb;
      else if (rb)           c = block_rgb;
      else begin             c = 6'b00_00_01; block = 1'b0; end
    end else if (in_wall) begin
      c = block_rgb;
    end else if (in_led) begin
      c = lines[~dcol[2:0]] ? 6'b00_11_00 : 6'b01_01_01;
    end else if (in_prev) begin
      if (d_piece)           c = piece_rgb;
      else begin             c = 6'b00_00_01; block = 1'b0; end
    end else begin
      block = 1'b0;
    end
    if (block && gap)        c = 6'b00_00_00;
    else if (block && shine) c = 6'b11_11_11;
  end

  assign rgb = c;

endmodule
