`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// cmod_top.v - "hello" bring-up design for Digilent Cmod A7-35T
//
//   * 12 MHz board clock -> clk_gen (MMCM wrapper) -> 100 MHz system clock
//   * UART echo through the onboard FT2232 at 115200 8N1
//   * led[0]  heartbeat (~0.75 Hz)      -> FPGA is configured and clock runs
//   * led[1]  toggles on each rx byte  -> UART RX path works
//   * RGB green on when MMCM is locked
//   * btn[0]  reset
//
// Next steps replace the echo with the command parser + capture engine.
// -----------------------------------------------------------------------------
module cmod_top #(
    parameter SYS_HZ = 100_000_000,
    parameter BAUD   = 115_200
) (
    input  wire       clk_12m,
    input  wire [1:0] btn,
    input  wire       uart_txd_in,    // FT2232 TX -> FPGA RX
    output wire       uart_rxd_out,   // FPGA TX  -> FT2232 RX
    output wire [1:0] led,
    output wire       led0_r,         // RGB LED, active low
    output wire       led0_g,
    output wire       led0_b
);
    localparam CPB = SYS_HZ / BAUD;

    // ---- clock & reset ------------------------------------------------------
    wire clk, locked, rst;

    clk_gen u_clk (
        .clk_in_12m (clk_12m),
        .clk_100m   (clk),
        .locked     (locked)
    );

    reset_sync u_rst (
        .clk  (clk),
        .arst (~locked | btn[0]),
        .rst  (rst)
    );

    // ---- UART echo ----------------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid;
    wire       tx_busy;

    uart_rx #(.CLKS_PER_BIT(CPB)) u_rx (
        .clk   (clk),
        .rst   (rst),
        .rx    (uart_txd_in),
        .data  (rx_data),
        .valid (rx_valid)
    );

    // one-byte holding register so back-to-back bytes from a slightly
    // fast host are not lost while the transmitter finishes
    reg  [7:0] pend;
    reg        pend_v;
    wire       tx_go = pend_v & ~tx_busy;

    always @(posedge clk) begin
        if (rst) begin
            pend   <= 8'd0;
            pend_v <= 1'b0;
        end else if (rx_valid) begin
            pend   <= rx_data;
            pend_v <= 1'b1;
        end else if (tx_go) begin
            pend_v <= 1'b0;
        end
    end

    uart_tx #(.CLKS_PER_BIT(CPB)) u_tx (
        .clk   (clk),
        .rst   (rst),
        .data  (pend),
        .start (tx_go),
        .tx    (uart_rxd_out),
        .busy  (tx_busy)
    );

    // ---- LEDs ---------------------------------------------------------------
    reg [26:0] hb;
    reg        rx_tgl;
    always @(posedge clk) begin
        if (rst) begin
            hb     <= 27'd0;
            rx_tgl <= 1'b0;
        end else begin
            hb <= hb + 1'b1;
            if (rx_valid) rx_tgl <= ~rx_tgl;
        end
    end

    assign led[0] = hb[26];
    assign led[1] = rx_tgl;
    assign led0_r = 1'b1;          // off
    assign led0_g = ~locked;       // on when locked
    assign led0_b = 1'b1;          // off

    wire unused = btn[1];
endmodule
