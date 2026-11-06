# scope-fpga

FPGA gateware for the USB-C isolated oscilloscope dongle.
Bring-up target: **Digilent Cmod A7-35T** (`xc7a35tcpg236-1`).
Production target: Gowin FPGA (see `rtl/gowin/`).

Current state: **UART-echo "hello" design**. It proves the toolchain loop end to end
(lint → sim → Vivado build → program → board answers over USB-UART) before capture logic is added.

## Layout

```
rtl/              portable Verilog-2001, vendor-neutral, shared by every target
rtl/xilinx/       thin wrappers around Xilinx primitives (MMCM, BUFG, IOB/IDELAY)
rtl/gowin/        matching Gowin wrappers (same module names and ports) - later
constraints/      Cmod A7 XDC
sim/              cocotb testbenches (Python) + sim stubs for vendor wrappers
scripts/          Vivado non-project Tcl (build / program / flash) + Windows .cmd wrappers
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
make sim TEST_BAUD=115200   # same tests at the real baud rate
make synth-check   # Yosys xc7 resource estimate, no Vivado needed
```

Windows (Vivado on PATH, or from the "Vivado Tcl Shell"):

```bat
scripts\build.cmd              :: -> build\cmod_top.bit, timing.rpt, util.rpt
scripts\program.cmd            :: JTAG load (lost at power-off)
scripts\program.cmd flash      :: write Quad-SPI flash (persistent)
```

The build exits with an error if setup or hold timing fails, so a green build means timing closed.

## Bench check (hello design)

1. Program the board. **led0** blinks (~0.75 Hz) and the **RGB LED is green** (MMCM locked).
2. Open the Cmod's USB serial port (the higher-numbered of the two FTDI ports) at **115200 8N1**.
3. Type: every character is echoed back and **led1** toggles per byte.
4. **btn0** = reset.

## Working with Claude

- Claude writes RTL + cocotb tests on a branch, runs lint/sim/Yosys, and opens a pull request.
- You pull the branch, run `scripts\build.cmd`, try it on the board.
- Send back `build/timing.rpt`, `build/util.rpt` (or the failing log). Paste them in chat
  or commit them under `reports/`.
- Merge to `main` when it works on hardware. CI must be green before merging.
