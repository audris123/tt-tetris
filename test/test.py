# SPDX-FileCopyrightText: © 2026 Audris Vitolins
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

H_TOTAL = 800


def color(uo):
    """Decode TinyVGA PMOD byte into (r, g, b), 2 bits each."""
    r = ((uo >> 0) & 1) << 1 | ((uo >> 4) & 1)
    g = ((uo >> 1) & 1) << 1 | ((uo >> 5) & 1)
    b = ((uo >> 2) & 1) << 1 | ((uo >> 6) & 1)
    return r, g, b


async def reset(dut):
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1


async def capture_line(dut, line):
    """Return the 800 output bytes of the given scanline."""
    await ClockCycles(dut.clk, line * H_TOTAL)
    out = []
    for _ in range(H_TOTAL):
        await RisingEdge(dut.clk)
        out.append(int(dut.uo_out.value))
    return out


@cocotb.test()
async def test_hsync(dut):
    await reset(dut)
    line = await capture_line(dut, 2)
    hsync_low = sum(1 for v in line if not (v >> 7) & 1)
    assert hsync_low == 96, f"hsync low for {hsync_low} clocks, expected 96"
    assert all((v >> 3) & 1 for v in line), "vsync must be high on visible lines"


@cocotb.test()
async def test_vsync(dut):
    await reset(dut)
    low_lines = []
    for line in range(525):
        await ClockCycles(dut.clk, H_TOTAL // 2)   # sample mid-line
        if not (int(dut.uo_out.value) >> 3) & 1:
            low_lines.append(line)
        await ClockCycles(dut.clk, H_TOTAL // 2)
    assert low_lines == [490, 491], f"vsync low on lines {low_lines}, expected [490, 491]"


@cocotb.test()
async def test_board_frame(dut):
    await reset(dut)
    line = await capture_line(dut, 205)   # crosses the middle of the board
    grey = sum(1 for v in line if color(v) == (2, 2, 2))
    empty = sum(1 for v in line if color(v) == (0, 0, 1))
    # two 20 px wall blocks, minus 1 px dark gap and 1 px highlight each
    assert grey == 36, f"expected 2x18 px grey wall, got {grey}"
    assert empty == 200, f"expected 200 px of empty (dark blue) board, got {empty}"
