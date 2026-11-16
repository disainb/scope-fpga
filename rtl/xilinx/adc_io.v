`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// adc_io.v  (Xilinx 7-series wrapper)
//   ADC clock out : ODDR (SAME_EDGE) - Q = D1 while clk high, D2 while clk low
//   ADC data in   : IDDR (SAME_EDGE_PIPELINED) in the IOB - q_rise is the
//                   sample taken at a rising clk edge, q_fall the one taken at
//                   the falling edge that follows; both appear together.
// Gowin port: same module/ports using ODDR / IDDR primitives of that family.
// Simulation model: sim/stubs/adc_io.v
// -----------------------------------------------------------------------------
module adc_io (
    input  wire       clk,
    input  wire       clk_d1,
    input  wire       clk_d2,
    output wire       adc_clk,
    input  wire [7:0] adc_d,
    output wire [7:0] q_rise,
    output wire [7:0] q_fall
);
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_oddr (
        .Q  (adc_clk),
        .C  (clk),
        .CE (1'b1),
        .D1 (clk_d1),
        .D2 (clk_d2),
        .R  (1'b0),
        .S  (1'b0)
    );

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_iddr
            IDDR #(
                .DDR_CLK_EDGE ("SAME_EDGE_PIPELINED"),
                .INIT_Q1      (1'b0),
                .INIT_Q2      (1'b0),
                .SRTYPE       ("SYNC")
            ) u_iddr (
                .Q1 (q_rise[i]),
                .Q2 (q_fall[i]),
                .C  (clk),
                .CE (1'b1),
                .D  (adc_d[i]),
                .R  (1'b0),
                .S  (1'b0)
            );
        end
    endgenerate
endmodule
