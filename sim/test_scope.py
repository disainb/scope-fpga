"""cocotb tests for the ADC08200 test design (cmod_top).

The testbench talks to the FPGA over its UART exactly like a terminal would,
and drives the ADC data bus from a behavioural ADC08200 model:
  * samples on the rising edge of adc_clk
  * 6-clock pipeline latency, data changes tOD = 4 ns after the clock edge
Timings are shortened via parameters (see sim/Makefile): 1 Mbaud UART,
0.2 ms line timeout, 0.5 ms auto-trigger timeout.
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer, with_timeout

SYS_NS = 10
BAUD = int(os.environ.get("TEST_BAUD", "1000000"))


# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
class Uart:
    def __init__(self, dut, baud):
        self.dut = dut
        self.set_baud(baud)
        self.rxq = Queue()
        dut.uart_txd_in.value = 1
        cocotb.start_soon(self._rx())

    def set_baud(self, baud):
        self.bit_ns = round(1e9 / baud)

    async def _rx(self):
        sig = self.dut.uart_rxd_out
        while True:
            await FallingEdge(sig)
            b = self.bit_ns
            await Timer(b + b // 2, unit="ns")
            v = 0
            for i in range(8):
                v |= int(sig.value) << i
                await Timer(b, unit="ns")
            assert int(sig.value) == 1, "framing error on FPGA TX"
            self.rxq.put_nowait(v)

    async def send(self, data):
        if isinstance(data, str):
            data = data.encode()
        sig, b = self.dut.uart_txd_in, self.bit_ns
        for byte in data:
            sig.value = 0
            await Timer(b, unit="ns")
            for i in range(8):
                sig.value = (byte >> i) & 1
                await Timer(b, unit="ns")
            sig.value = 1
            await Timer(b, unit="ns")

    async def cmd(self, line):
        await self.send(line + "\n")

    async def byte(self, timeout_us=20000):
        return await with_timeout(self.rxq.get(), timeout_us, "us")

    async def line(self, timeout_us=20000):
        buf = bytearray()
        while True:
            b = await self.byte(timeout_us)
            if b == 0x0A:
                return buf.decode(errors="replace").rstrip("\r")
            buf.append(b)

    async def lines(self, n, timeout_us=20000):
        return [await self.line(timeout_us) for _ in range(n)]


class Adc08200:
    """Behavioural ADC: 6-cycle pipeline, tOD after rising adc_clk."""

    def __init__(self, dut, func=lambda n: n, latency=6, tod_ns=4):
        self.dut = dut
        self.func = func
        self.latency = latency
        self.tod_ns = tod_ns
        dut.adc_d.value = 0
        cocotb.start_soon(self._run())

    async def _drive(self, v):
        await Timer(self.tod_ns, unit="ns")
        self.dut.adc_d.value = v

    async def _run(self):
        pipe = [0] * self.latency
        n = 0
        while True:
            await RisingEdge(self.dut.adc_clk)
            pipe.append(self.func(n) & 0xFF)
            n += 1
            cocotb.start_soon(self._drive(pipe.pop(0)))


def tri(n):
    m = n % 512
    return m if m < 256 else 511 - m


async def setup(dut, func=lambda n: n):
    dut.btn.value = 0b01
    u = Uart(dut, BAUD)
    adc = Adc08200(dut, func)
    cocotb.start_soon(Clock(dut.clk_12m, SYS_NS, unit="ns").start())
    await ClockCycles(dut.clk_12m, 20)
    dut.btn.value = 0
    while True:                       # wait for banner
        if (await u.line()).startswith("scope-fpga"):
            break
    return u, adc


def steps(vals):
    return [(b - a) & 0xFF for a, b in zip(vals, vals[1:])]


async def run_ofn(u, cmd, n):
    await u.cmd(cmd)
    return [int(x) for x in await u.lines(n)]


async def run_ofx(u, cmd):
    await u.cmd(cmd)
    hdr = await u.line()
    assert hdr.startswith("#N="), hdr
    fields = dict(kv.split("=") for kv in hdr[1:].split(","))
    vals = []
    while True:
        ln = await u.line()
        if ln == "#END":
            break
        vals += [int(x, 16) for x in ln.split()]
    assert len(vals) == int(fields["N"])
    return fields, vals


# ----------------------------------------------------------------------------
# tests
# ----------------------------------------------------------------------------
@cocotb.test()
async def test_status_defaults(dut):
    """'?' reports the reset defaults."""
    u, _ = await setup(dut)
    await u.cmd("?")
    st = await u.line()
    assert st == ("OK SR=10000000SPS ADC=10000000Hz SS=1024 PT=0 OF=N TM=A TE=R "
                  f"TL=128 TH=4 PH=10 PD=0 TP=0 BR={BAUD}"), st


@cocotb.test()
async def test_help(dut):
    u, _ = await setup(dut)
    await u.cmd("h")
    got = []
    while not got or not got[-1].startswith("Example"):
        got.append(await u.line())
    assert any(ln.lstrip().startswith("SR=") for ln in got)


@cocotb.test()
async def test_sample_rate_rounding(dut):
    """SR is rounded to f_clk/(N*D); settings-only lines echo the status."""
    u, _ = await setup(dut)
    cases = [
        ("SR=10MSPS", 10_000_000, 10_000_000),
        ("SR=25MSPS", 25_000_000, 25_000_000),
        ("SR=33MSPS", 33_333_333, 33_333_333),
        ("SR=200MSPS", 100_000_000, 100_000_000),
        ("SR=3MSPS", 3_333_333, 10_000_000),
        ("SR=500KSPS", 500_000, 10_000_000),
        ("SR=1000", 1_000, 10_000_000),
    ]
    for cmd, sr, adc in cases:
        await u.cmd(cmd)
        st = await u.line()
        assert f"SR={sr}SPS ADC={adc}Hz" in st, (cmd, st)


@cocotb.test()
async def test_user_example_testpattern(dut):
    """The example line with TP=1 returns a clean ramp, one number per line."""
    u, _ = await setup(dut)
    await u.cmd("tp=1")
    await u.line()
    vals = await run_ofn(u, "SR=10MSPS,SS=64,OFN,R", 64)
    assert steps(vals) == [1] * 63, vals


@cocotb.test()
async def test_adc_capture_rates(dut):
    """Counting ADC: consecutive samples step by D for every N and phase."""
    u, _ = await setup(dut, func=lambda n: n)
    cases = [("100MSPS", "0", 1), ("100MSPS", "1", 1), ("50MSPS", "A", 1),
             ("33MSPS", "A", 1), ("10MSPS", "A", 1), ("10MSPS", "3", 1),
             ("3MSPS", "A", 3), ("1MSPS", "A", 10)]
    for sr, ph, step in cases:
        vals = await run_ofn(u, f"SR={sr},PH={ph},SS=24,TMI,R", 24)
        assert steps(vals) == [step] * 23, (sr, ph, vals)


@cocotb.test()
async def test_trigger_rising(dut):
    u, _ = await setup(dut, func=tri)
    f, v = await run_ofx(u, "SS=32,PT=8,TL=100,TH=4,TER,TMN,OFX,R")
    assert f["TRIG"] == "1" and f["PT"] == "8"
    assert v[7] == 99 and v[8] == 100, v


@cocotb.test()
async def test_trigger_falling(dut):
    u, _ = await setup(dut, func=tri)
    f, v = await run_ofx(u, "SS=32,PT=8,TL=100,TH=4,TEF,TMN,OFX,R")
    assert f["TRIG"] == "1"
    assert v[7] == 101 and v[8] == 100, v


@cocotb.test()
async def test_auto_timeout_and_abort(dut):
    """Flat input: auto mode times out (TRIG=0); normal mode waits until a key."""
    u, _ = await setup(dut, func=lambda n: 50)
    f, v = await run_ofx(u, "SS=16,TL=100,TMA,OFX,R")
    assert f["TRIG"] == "0" and v == [50] * 16
    await u.cmd("TMN,R")
    await Timer(1, unit="ms")
    await u.send("S")
    assert await u.line() == "STOPPED"


@cocotb.test()
async def test_binary_and_redump(dut):
    u, _ = await setup(dut)
    await u.cmd("SS=16,TP=1,TMI,OFB,R")
    hdr = await u.line()
    assert hdr.startswith("#BIN N=16,"), hdr
    raw = [await u.byte() for _ in range(16)]
    assert steps(raw) == [1] * 15
    assert await u.line() == ""
    assert await u.line() == "#END"
    _, v = await run_ofx(u, "OFX,D")         # same capture again, as hex
    assert v == raw


@cocotb.test()
async def test_continuous(dut):
    u, _ = await setup(dut)
    await u.cmd("SS=8,TP=1,TMI,OFN,C")
    vals = [int(x) for x in await u.lines(24)]
    for f in range(3):                         # ramp runs on between frames
        assert steps(vals[8 * f:8 * f + 8]) == [1] * 7, vals
    await u.send("S")
    while (await u.line()) != "STOPPED":
        pass
    await u.cmd("?")
    assert (await u.line()).startswith("OK ")


@cocotb.test()
async def test_errors(dut):
    u, _ = await setup(dut)
    for cmd, col in [("SS=99999", 1), ("ZZ=1", 1), ("SS=10,QQ=1", 7),
                     ("OFQ", 1), ("PT=5000", 1), ("D", None)]:
        await u.cmd(cmd)
        ln = await u.line()
        if col is None:
            assert ln == "ERR no capture yet", ln
        else:
            assert ln == f"ERR at col {col}", (cmd, ln)


@cocotb.test()
async def test_no_line_ending(dut):
    """A line without CR/LF is executed after the idle timeout."""
    u, _ = await setup(dut)
    await u.send("?")
    assert (await u.line()).startswith("OK SR=")


@cocotb.test()
async def test_baud_change(dut):
    u, _ = await setup(dut)
    await u.cmd("BR=2000000")
    assert (await u.line()).endswith("BR=2000000")   # reply still at old rate
    await Timer(20, unit="us")
    u.set_baud(2_000_000)
    await u.cmd("?")
    assert (await u.line()).startswith("OK SR=")
