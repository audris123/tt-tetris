/*
 * Copyright (c) 2026 Audris Vitolins
 * SPDX-License-Identifier: Apache-2.0
 *
 * Vulkos Tetris - Tiny Tapeout top level.
 * VGA output on uo_out using the TinyVGA PMOD pinout.
 */
`default_nettype none

module tt_um_audris123_tetris (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock (25.175 MHz)
    input  wire       rst_n     // reset_n - low to reset
);

  // ---------------------------------------------------------------------------
  // VGA timing (also drives the board ring position)
  // ---------------------------------------------------------------------------
  wire [3:0] rcol;
  wire [4:0] rrow, yf, yc;
  wire [1:0] q;
  wire       hsync, vsync, frame_tick;

  vga_sync vga (
      .clk       (clk),
      .rst_n     (rst_n),
      .rcol      (rcol),
      .rrow      (rrow),
      .q         (q),
      .yf        (yf),
      .yc        (yc),
      .hsync     (hsync),
      .vsync     (vsync),
      .frame_tick(frame_tick)
  );

  // ---------------------------------------------------------------------------
  // Buttons: single synchronizer stage (the game samples them once per frame)
  // ui_in[0]=left [1]=right [2]=rotate [3]=soft drop [4]=hard drop
  // ---------------------------------------------------------------------------
  reg [4:0] btn;
  always @(posedge clk) btn <= ui_in[4:0];

  // ---------------------------------------------------------------------------
  // Random source: 7-bit maximal-length LFSR (x^7+x^6+1) that steps every
  // clock while no button is held. Its state therefore depends on exactly how
  // many clocks (40 ns each) the player has held buttons so far, which no
  // human can repeat.
  // ---------------------------------------------------------------------------
  reg [6:0] lfsr;
  always @(posedge clk) begin
    if (!rst_n)
      lfsr <= 7'h5A;
    else if (~|btn)
      lfsr <= {lfsr[5:0], lfsr[6] ^ lfsr[5]};
  end

  // ---------------------------------------------------------------------------
  // Game
  // ---------------------------------------------------------------------------
  wire [5:0] rgb;

  tetris game (
      .clk       (clk),
      .rst_n     (rst_n),
      .rcol      (rcol),
      .rrow      (rrow),
      .q         (q),
      .yf        (yf),
      .yc        (yc),
      .frame_tick(frame_tick),
      .btn       (btn),
      .rnd       (lfsr[2:0]),
      .rgb       (rgb)
  );

  // ---------------------------------------------------------------------------
  // TinyVGA PMOD output: {hsync, B0, G0, R0, vsync, B1, G1, R1}
  // Syncs are registered (glitch free); colour comes straight from the
  // renderer, i.e. one pixel ahead of the syncs, which is invisible.
  // (the renderer only draws inside the visible area, so no blanking needed)
  // ---------------------------------------------------------------------------
  reg hsync_r, vsync_r;
  always @(posedge clk) begin
    hsync_r <= hsync;
    vsync_r <= vsync;
  end

  wire [7:0] vga_out = {hsync_r, rgb[0], rgb[2], rgb[4], vsync_r, rgb[1], rgb[3], rgb[5]};

  assign uo_out  = vga_out;
  assign uio_out = 8'h00;
  assign uio_oe  = 8'h00;

  wire _unused = &{ena, uio_in, ui_in[7:5], lfsr[6:3], 1'b0};

endmodule
