# -----------------------------------------------------------------------------
# USB-C scope dongle - FPGA (Cmod A7-35T bring-up target)
#
#   make lint         Verilator lint of portable RTL
#   make sim          cocotb tests (Icarus)
#   make synth-check  quick Yosys synthesis + resource estimate (no Vivado)
#   make bit          Vivado build -> build/cmod_top.bit
#   make prog         JTAG load (volatile)
#   make flash        write Quad-SPI flash (persistent)
#   make rom          regenerate rtl/msg_rom.v from scripts/gen_msg_rom.py
#   make clean
# -----------------------------------------------------------------------------
TOP      := cmod_top
RTL      := $(wildcard rtl/*.v)
XIL_RTL  := $(wildcard rtl/xilinx/*.v)
SIM_STUB := $(wildcard sim/stubs/*.v)
VIVADO   ?= vivado
VFLAGS   := -mode batch -nojournal

.PHONY: all lint sim synth-check bit prog flash rom clean

all: lint sim

lint:
	verilator --lint-only -Wall -Irtl --top-module $(TOP) $(RTL) $(SIM_STUB)

sim:
	$(MAKE) -C sim

synth-check:
	@mkdir -p build
	yosys -q -l build/yosys.log -p "read_verilog -Irtl $(RTL) $(XIL_RTL); synth_xilinx -family xc7 -top $(TOP); tee -o build/yosys_stat.txt stat"
	@cat build/yosys_stat.txt

bit:
	@mkdir -p build
	$(VIVADO) $(VFLAGS) -log build/vivado_build.log -source scripts/build.tcl

prog:
	$(VIVADO) $(VFLAGS) -log build/vivado_prog.log -source scripts/program.tcl

flash:
	$(VIVADO) $(VFLAGS) -log build/vivado_flash.log -source scripts/flash.tcl $(if $(PART),-tclargs $(PART))

rom:
	python3 scripts/gen_msg_rom.py

clean:
	rm -rf build sim/sim_build sim/results.xml sim/__pycache__ .Xil *.jou *.log
