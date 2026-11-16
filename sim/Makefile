# -----------------------------------------------------------------------------
# cocotb simulation of cmod_top (Icarus by default; SIM=verilator also works)
#
#   make                       run all tests
#   make COCOTB_TEST_FILTER=test_trigger_rising    run one test
#   make WAVES=1               also dump a waveform file
# -----------------------------------------------------------------------------
SIM            ?= icarus
TOPLEVEL_LANG  ?= verilog

ROOT := $(abspath ..)
VERILOG_SOURCES := $(wildcard $(ROOT)/rtl/*.v) $(wildcard $(ROOT)/sim/stubs/*.v)

COCOTB_TOPLEVEL     := cmod_top
COCOTB_TEST_MODULES := test_scope

# Shorter timings in simulation: UART at 1 Mbaud, 0.2 ms line timeout,
# 0.5 ms auto-trigger timeout.
TEST_BAUD    ?= 1000000
TEST_LINE_TO ?= 20000
TEST_AUTO_TO ?= 50000
export TEST_BAUD TEST_LINE_TO TEST_AUTO_TO

ifeq ($(SIM),icarus)
  COMPILE_ARGS += -I$(ROOT)/rtl \
                  -Pcmod_top.BAUD=$(TEST_BAUD) \
                  -Pcmod_top.LINE_TO=$(TEST_LINE_TO) \
                  -Pcmod_top.AUTO_TO=$(TEST_AUTO_TO)
else ifeq ($(SIM),verilator)
  EXTRA_ARGS   += -I$(ROOT)/rtl -Wno-fatal \
                  -GBAUD=$(TEST_BAUD) -GLINE_TO=$(TEST_LINE_TO) -GAUTO_TO=$(TEST_AUTO_TO)
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
