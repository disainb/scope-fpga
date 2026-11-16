`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// adc_io.v  (simulation model - NOT for synthesis)
//   Behavioural ODDR (SAME_EDGE) and IDDR (SAME_EDGE_PIPELINED), same ports as
//   rtl/xilinx/adc_io.v. Zero I/O delay; the cocotb ADC model adds tOD.
// -----------------------------------------------------------------------------
/* verilator lint_off MULTIDRIVEN */
module adc_io (
    input  wire       clk,
    input  wire       clk_d1,
    input  wire       clk_d2,
    output reg        adc_clk = 1'b0,
    input  wire [7:0] adc_d,
    output reg  [7:0] q_rise = 8'd0,
    output reg  [7:0] q_fall = 8'd0
);
    reg       d2_r = 1'b0;
    reg [7:0] rr   = 8'd0;
    reg [7:0] ff   = 8'd0;

    // ODDR: both inputs captured at the rising edge, D2 shown after the fall
    always @(posedge clk) begin
        adc_clk <= clk_d1;
        d2_r    <= clk_d2;
    end
    always @(negedge clk) adc_clk <= d2_r;

    // IDDR SAME_EDGE_PIPELINED
    always @(posedge clk) rr <= adc_d;
    always @(negedge clk) ff <= adc_d;
    always @(posedge clk) begin
        q_rise <= rr;
        q_fall <= ff;
    end
endmodule
