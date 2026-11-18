`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// flash_io.v  (Xilinx 7-series wrapper)
//   Connects the portable SPI master (rev_store) to the configuration flash.
//   SCK goes out through STARTUPE2/USRCCLKO (CCLK is a dedicated config pin);
//   CS, DQ0 (MOSI) and DQ1 (MISO) are ordinary user I/O after configuration.
//   DQ2 (WP#) and DQ3 (HOLD#) are driven high.
// Simulation model: sim/stubs/flash_io.v (includes a small SPI flash model)
// -----------------------------------------------------------------------------
module flash_io (
    input  wire sck,
    input  wire cs_n,
    input  wire mosi,
    output wire miso,
    // pads
    output wire qspi_cs,
    output wire qspi_dq0,
    input  wire qspi_dq1,
    output wire qspi_dq2,
    output wire qspi_dq3
);
    assign qspi_cs  = cs_n;
    assign qspi_dq0 = mosi;
    assign miso     = qspi_dq1;
    assign qspi_dq2 = 1'b1;
    assign qspi_dq3 = 1'b1;

    STARTUPE2 #(
        .PROG_USR      ("FALSE"),
        .SIM_CCLK_FREQ (0.0)
    ) u_startup (
        .CFGCLK    (),
        .CFGMCLK   (),
        .EOS       (),
        .PREQ      (),
        .CLK       (1'b0),
        .GSR       (1'b0),
        .GTS       (1'b0),
        .KEYCLEARB (1'b1),
        .PACK      (1'b0),
        .USRCCLKO  (sck),
        .USRCCLKTS (1'b0),
        .USRDONEO  (1'b1),
        .USRDONETS (1'b1)
    );
endmodule
