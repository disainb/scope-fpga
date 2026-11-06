`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// clk_gen.v  (simulation stub - NOT for synthesis)
//   Same ports as rtl/xilinx/clk_gen.v. The testbench drives clk_in_12m at the
//   system frequency (100 MHz) and this stub passes it straight through, so the
//   portable RTL can be simulated without vendor primitive models.
// -----------------------------------------------------------------------------
module clk_gen (
    input  wire clk_in_12m,
    output wire clk_100m,
    output wire locked
);
    assign clk_100m = clk_in_12m;
    assign locked   = 1'b1;
endmodule
