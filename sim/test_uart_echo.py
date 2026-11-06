"""cocotb tests for the cmod_top UART-echo bring-up design.

The sim stub for clk_gen passes clk_12m straight through, so the testbench
drives that pin at the 100 MHz system clock. BAUD is overridden at compile
time (see sim/Makefile) so each bit is only 100 clocks.
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer, with_timeout

SYS_PERIOD_NS = 10                      # 100 MHz
BAUD = int(os.environ.get("TEST_BAUD", "1000000"))
CLKS_PER_BIT = 100_000_000 // BAUD
BIT_NS = CLKS_PER_BIT * SYS_PERIOD_NS


async def uart_send(sig, byte: int, bit_ns: int = BIT_NS):
    """Drive one 8N1 frame onto 'sig' (LSB first)."""
    sig.value = 0
    await Timer(bit_ns, unit="ns")
    for i in range(8):
        sig.value = (byte >> i) & 1
        await Timer(bit_ns, unit="ns")
    sig.value = 1
    await Timer(bit_ns, unit="ns")


async def uart_recv(sig, bit_ns: int = BIT_NS) -> int:
    """Receive one 8N1 frame from 'sig', sampling at mid-bit."""
    await FallingEdge(sig)
    await Timer(bit_ns + bit_ns // 2, unit="ns")
    val = 0
    for i in range(8):
        val |= int(sig.value) << i
        await Timer(bit_ns, unit="ns")
    assert int(sig.value) == 1, "stop bit not high"
    return val


async def uart_recv_n(sig, n: int) -> bytes:
    return bytes([await uart_recv(sig) for _ in range(n)])


async def reset(dut):
    dut.uart_txd_in.value = 1
    dut.btn.value = 0b01
    cocotb.start_soon(Clock(dut.clk_12m, SYS_PERIOD_NS, unit="ns").start())
    await ClockCycles(dut.clk_12m, 10)
    dut.btn.value = 0
    await ClockCycles(dut.clk_12m, 10)


@cocotb.test()
async def test_echo_single(dut):
    """One byte in, same byte out."""
    await reset(dut)
    rx = cocotb.start_soon(uart_recv(dut.uart_rxd_out))
    await uart_send(dut.uart_txd_in, 0xA5)
    got = await with_timeout(rx, 30 * BIT_NS, "ns")
    assert got == 0xA5, f"echo mismatch: 0x{got:02X}"


@cocotb.test()
async def test_echo_burst(dut):
    """Back-to-back bytes with no idle time are all echoed in order."""
    await reset(dut)
    msg = b"HELLO SCOPE\r\n\x00\xff\x55"
    rx = cocotb.start_soon(uart_recv_n(dut.uart_rxd_out, len(msg)))
    for b in msg:
        await uart_send(dut.uart_txd_in, b)
    got = await with_timeout(rx, (len(msg) + 4) * 10 * BIT_NS, "ns")
    assert got == msg, f"echo mismatch: {got!r}"


@cocotb.test()
async def test_led_toggles_per_byte(dut):
    """led[1] toggles once per received byte."""
    await reset(dut)
    start = (int(dut.led.value) >> 1) & 1
    for b in b"abc":
        await uart_send(dut.uart_txd_in, b)
    await ClockCycles(dut.clk_12m, CLKS_PER_BIT)
    now = (int(dut.led.value) >> 1) & 1
    assert now == start ^ 1, "led[1] should be inverted after 3 bytes"


@cocotb.test()
async def test_start_glitch_ignored(dut):
    """A short low glitch on RX must not produce a byte."""
    await reset(dut)
    led_before = int(dut.led.value) & 0b10
    dut.uart_txd_in.value = 0
    await Timer(BIT_NS // 4, unit="ns")
    dut.uart_txd_in.value = 1
    await Timer(15 * BIT_NS, unit="ns")
    assert int(dut.led.value) & 0b10 == led_before, "glitch was taken as a byte"
    assert int(dut.uart_rxd_out.value) == 1, "TX should stay idle"
