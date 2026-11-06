`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// clk_gen.v  (Xilinx 7-series wrapper)
//   12 MHz -> MMCM -> 100 MHz
//   VCO = 12 MHz * 62.5 = 750 MHz (range 600-1200), CLKOUT0 = 750 / 7.5 = 100 MHz
//
// Vendor-specific: the Gowin version lives in rtl/gowin/clk_gen.v with the
// same port list. A behavioural stub for simulation is in sim/stubs/clk_gen.v.
// Later: add a phase-shifted CLKOUT1 for ADC data capture.
// -----------------------------------------------------------------------------
module clk_gen (
    input  wire clk_in_12m,
    output wire clk_100m,
    output wire locked
);
    wire clkfb;
    wire clk0_unbuf;

    MMCME2_BASE #(
        .BANDWIDTH        ("OPTIMIZED"),
        .CLKIN1_PERIOD    (83.333),
        .DIVCLK_DIVIDE    (1),
        .CLKFBOUT_MULT_F  (62.5),
        .CLKFBOUT_PHASE   (0.0),
        .CLKOUT0_DIVIDE_F (7.5),
        .CLKOUT0_PHASE    (0.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .STARTUP_WAIT     ("FALSE")
    ) u_mmcm (
        .CLKIN1   (clk_in_12m),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKFBOUTB(),
        .CLKOUT0  (clk0_unbuf),
        .CLKOUT0B (),
        .CLKOUT1  (),
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

    BUFG u_bufg (
        .I (clk0_unbuf),
        .O (clk_100m)
    );
endmodule
