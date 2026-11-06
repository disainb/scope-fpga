# Gowin wrappers (placeholder)

Production target is a Gowin FPGA. When we port, this folder gets Gowin
versions of every file in `rtl/xilinx/`, with **identical module names and
port lists**:

| Xilinx (Cmod A7)            | Gowin equivalent              |
|-----------------------------|-------------------------------|
| `clk_gen.v` (MMCME2_BASE)   | `clk_gen.v` (rPLL / PLLVR)    |
| IOB input registers, IDELAY | IOLOGIC input registers / IODELAY |

Everything in `rtl/` (top level) stays vendor-neutral and is shared unchanged.
