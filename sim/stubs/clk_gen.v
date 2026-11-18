`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// clk_gen.v  (simulation stub - NOT for synthesis)
//   Same ports as rtl/xilinx/clk_gen.v. The testbench drives clk_in_12m at
//   200 MHz; this stub passes it through as clk_200m and divides it by two for
//   clk_100m. The divider uses a blocking assignment so both clocks change in
//   the same simulation delta, like phase-aligned MMCM outputs.
// -----------------------------------------------------------------------------
module clk_gen (
    input  wire clk_in_12m,
    output wire clk_100m,
    output wire clk_200m,
    output wire locked
);
    reg div = 1'b0;
    /* verilator lint_off BLKSEQ */
    always @(posedge clk_in_12m) div = ~div;
    /* verilator lint_on BLKSEQ */

    assign clk_200m = clk_in_12m;
    assign clk_100m = div;
    assign locked   = 1'b1;
endmodule
