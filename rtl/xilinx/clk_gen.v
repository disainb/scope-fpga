`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// clk_gen.v  (Xilinx 7-series wrapper)
//   12 MHz -> MMCM -> 100 MHz (system) + 200 MHz (ADC capture), phase aligned
//   VCO = 12 MHz * 50 = 600 MHz (7-series range 600-1200 MHz)
//   CLKOUT0 = 600 / 6 = 100 MHz,  CLKOUT1 = 600 / 3 = 200 MHz
//
// Gowin version: rtl/gowin/clk_gen.v, same ports. Sim model: sim/stubs/clk_gen.v
// -----------------------------------------------------------------------------
module clk_gen (
    input  wire clk_in_12m,
    output wire clk_100m,
    output wire clk_200m,
    output wire locked
);
    wire clkfb;
    wire clk0_unbuf, clk1_unbuf;

    MMCME2_BASE #(
        .BANDWIDTH         ("OPTIMIZED"),
        .CLKIN1_PERIOD     (83.333),
        .DIVCLK_DIVIDE     (1),
        .CLKFBOUT_MULT_F   (50.0),
        .CLKFBOUT_PHASE    (0.0),
        .CLKOUT0_DIVIDE_F  (6.0),
        .CLKOUT0_PHASE     (0.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT1_DIVIDE    (3),
        .CLKOUT1_PHASE     (0.0),
        .CLKOUT1_DUTY_CYCLE(0.5),
        .STARTUP_WAIT      ("FALSE")
    ) u_mmcm (
        .CLKIN1   (clk_in_12m),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKFBOUTB(),
        .CLKOUT0  (clk0_unbuf),
        .CLKOUT0B (),
        .CLKOUT1  (clk1_unbuf),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0)
    );

    BUFG u_bufg0 (.I(clk0_unbuf), .O(clk_100m));
    BUFG u_bufg1 (.I(clk1_unbuf), .O(clk_200m));
endmodule
