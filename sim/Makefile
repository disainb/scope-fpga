# -----------------------------------------------------------------------------
# cocotb simulation of cmod_top (Icarus by default; SIM=verilator also works)
#
#   make            run all tests
#   make WAVES=1    also dump sim_build/cmod_top.fst for GTKWave / Surfer
# -----------------------------------------------------------------------------
SIM            ?= icarus
TOPLEVEL_LANG  ?= verilog

ROOT := $(abspath ..)
VERILOG_SOURCES := $(wildcard $(ROOT)/rtl/*.v) $(ROOT)/sim/stubs/clk_gen.v

COCOTB_TOPLEVEL     := cmod_top
COCOTB_TEST_MODULES := test_uart_echo

# Run the UART fast in simulation (100 clocks/bit at 100 MHz).
TEST_BAUD ?= 1000000
export TEST_BAUD

ifeq ($(SIM),icarus)
  COMPILE_ARGS += -Pcmod_top.BAUD=$(TEST_BAUD)
else ifeq ($(SIM),verilator)
  EXTRA_ARGS   += -GBAUD=$(TEST_BAUD) -Wno-fatal
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
