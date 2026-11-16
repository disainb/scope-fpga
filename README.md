# scope-fpga

FPGA gateware for the USB-C isolated oscilloscope dongle.
Bring-up target: **Digilent Cmod A7-35T** (`xc7a35tcpg236-1`).
Production target: Gowin FPGA (see `rtl/gowin/`).

Current state: **ADC08200 test design** — UART command line, programmable sample rate,
edge trigger with pre-trigger, up to 16384 samples, decimal / hex / binary output.

## Layout

```
rtl/              portable Verilog-2001, vendor-neutral, shared by every target
rtl/xilinx/       thin wrappers around Xilinx primitives (MMCM, BUFG, ODDR/IDDR)
rtl/gowin/        matching Gowin wrappers (same module names and ports) - later
constraints/      Cmod A7 XDC
sim/              cocotb testbenches (Python) + sim stubs for vendor wrappers
scripts/          Vivado non-project Tcl (build / program / flash) + Windows .cmd wrappers
                  gen_msg_rom.py: all UART text (help, status) -> rtl/msg_rom.v
.github/workflows CI: lint + sim on every push and pull request
build/            Vivado outputs (git-ignored)
```

**Porting rule:** only files in `rtl/<vendor>/` may instantiate vendor primitives.
Everything else is inferred logic so it carries over to the Gowin part unchanged.

## Tools

| Purpose | Tool | Where |
|---|---|---|
| Synthesis, P&R, bitstream, programming | Vivado ML Standard (free) | Windows |
| Lint | Verilator | WSL2 Ubuntu (or Linux) |
| Simulation | Icarus Verilog + cocotb | WSL2 Ubuntu |
| Waveforms | GTKWave or Surfer | either |
| Quick resource check | Yosys | WSL2 Ubuntu |

One-time setup in WSL2 Ubuntu:

```bash
sudo apt update
sudo apt install -y make git iverilog verilator yosys gtkwave python3-pip
pip install --break-system-packages cocotb
```

## Commands

Linux / WSL2:

```bash
make lint          # Verilator -Wall lint
make sim           # cocotb tests (fast-baud by default)
make synth-check   # Yosys xc7 resource estimate, no Vivado needed
make rom           # after editing text in scripts/gen_msg_rom.py
```

Windows (Vivado on PATH, or from the "Vivado Tcl Shell"):

```bat
scripts\build.cmd              :: -> build\cmod_top.bit, timing.rpt, util.rpt
scripts\program.cmd            :: JTAG load (lost at power-off)
scripts\program.cmd flash      :: write Quad-SPI flash (persistent)
```

The build exits with an error if setup or hold timing fails, so a green build means timing closed.

## ADC08200 wiring

| ADC08200 pin | Signal | Cmod A7 DIP pin | FPGA pin |
|---|---|---|---|
| 13 | D7 (MSB) | 26 | R3 |
| 14 | D6 | 27 | T3 |
| 15 | D5 | 28 | R2 |
| 16 | D4 | 29 | T1 |
| 19 | D3 | 30 | T2 |
| 20 | D2 | 31 | U1 |
| 21 | D1 | 32 | W2 |
| 22 | D0 (LSB) | 33 | V2 |
| 23 | PD | 34 | W3 |
| 24 | CLK | 36 | W5 |

VA / VDR from Pmod JA pin 6 or 12 (3.3 V); grounds to DIP pin 25 and Pmod JA 5/11.
**Never connect DIP pin 24 (VU = USB 5 V) to the ADC.**

## Bench use

Open the Cmod's USB serial port (higher-numbered of the two FTDI ports) at **115200 8N1**.
The board prints a banner after programming or btn0. Type `H` for help.

| LED | Meaning |
|---|---|
| led0 | heartbeat |
| led1 | capture running / waiting for trigger |
| RGB green | clock locked |
| RGB blue | continuous mode |

### Commands

One line of comma-separated tokens, ended with Enter. Case and spaces don't matter.
A line with no line ending is executed after 30 ms of silence.

| Command | Meaning | Default |
|---|---|---|
| `SR=n[K\|M]` | Sample rate: `SR=10MSPS`, `SR=500KSPS`, `SR=2000`. Rounded to 100 MHz/(N·D); the reply shows the real value | 10 MSPS |
| `SS=n` | Samples per capture, 1..16384 | 1024 |
| `PT=n` | Pre-trigger samples, 0..SS-1 (sample number PT is the trigger point) | 0 |
| `OFN` / `OFX` / `OFB` | Output: one decimal per line (plotters), hex 16 per line with header, raw binary with header | N |
| `TMA` / `TMN` / `TMI` | Trigger mode: auto (trigger, or force after 100 ms), normal (wait), immediate | A |
| `TER` / `TEF` | Trigger edge rising / falling | R |
| `TL=n` | Trigger level, 0..255 | 128 |
| `TH=n` | Trigger hysteresis (counts the signal must go below/above TL first) | 4 |
| `PH=n` / `PHA` | Capture phase in 5 ns steps, 0..2N-1; A = middle of the ADC period | A |
| `PD=0\|1` | ADC power-down | 0 |
| `TP=0\|1` | Test pattern: ramp instead of ADC data (checks the UART/plot path) | 0 |
| `BR=n` | UART baud, e.g. `BR=921600`, up to 6.25 Mbaud. Applied after the reply; btn0 restores 115200 | 115200 |
| `R` | Run one capture and send it | |
| `C` | Run continuously; send any character (not Enter alone) to stop | |
| `D` | Send the last capture again (e.g. after changing OF) | |
| `?` | Show settings | |
| `H` | Help | |

Settings-only lines reply with the status line (`OK SR=... ADC=...`).
Lines containing R/C/D/?/H reply only with their output, so a run line in `OFN` mode
produces nothing but numbers. Errors reply `ERR at col n` and skip the rest of the line.

Example for the Arduino Serial Plotter (115200, "Newline"):

```
SR=10MSPS,SS=1024,OFN,R
```

### How the sample rate works

- **ADC clock = 100 MHz / N**, N = 1..10 (100, 50, 33.3, 25, 20 ... 10 MHz). It never goes below
  10 MHz, because the ADC08200 is not meant to run slower.
- Below 10 MSPS the ADC stays at 10 MHz and the FPGA keeps 1 of every **D** samples.
- The `?` reply shows both: `SR=` is what you get, `ADC=` is the clock on the ADC pin.
- Maximum is 100 MSPS (the system clock), which is beyond what breadboard wiring will carry anyway.

### Finding the capture phase (PH)

The FPGA samples the data bus on both clock edges, so each ADC period has 2·N possible capture
points 5 ns apart. `PHA` (auto) samples about half an ADC period after the clock edge. That gives
plenty of margin at 10 MSPS; at 25 MSPS and above, check it. Feed a slow sine and try each `PH` value:

```
SR=50MSPS,SS=256,TMA,OFN,PH=0,R
SR=50MSPS,SS=256,TMA,OFN,PH=1,R      ... up to PH=3
```

Phases near a data transition show spikes or stuck bits. Use the middle of the clean range.

### Quick checks

1. `TP=1,SS=64,TMI,OFN,R` → ramp 0,1,2…: UART and plotting path work without the ADC.
2. `TP=0,PD=0,SS=64,TMI,OFX,R` with the input grounded / at mid-scale → a narrow band of codes.
3. Signal generator in, `SR=10MSPS,SS=1024,TL=128,TMN,PT=100,OFN,R` → stable triggered waveform.

## Working with Claude

- Claude writes RTL + cocotb tests on a branch, runs lint/sim/Yosys, and opens a pull request.
- You pull the branch, run `scripts\build.cmd`, try it on the board.
- Send back `build/timing.rpt`, `build/util.rpt` (or the failing log). Paste them in chat
  or commit them under `reports/`.
- Merge to `main` when it works on hardware. CI must be green before merging.
