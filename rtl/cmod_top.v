`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// cmod_top.v - ADC08200 test design for Digilent Cmod A7-35T
//
//   * 12 MHz -> MMCM -> 100 MHz system clock
//   * ADC08200 clocked from the FPGA (ODDR), data captured with IDDR
//   * UART command line over the onboard FT2232 (115200 8N1 at reset)
//     e.g.  SR=10MSPS,SS=1024,OFN,R      - see rtl/scope_ctrl.v / README
//
//   led[0]  heartbeat            led[1]  capture running
//   RGB green = MMCM locked      RGB blue = continuous mode
//   btn[0]  reset (also restores 115200 baud and default settings)
// -----------------------------------------------------------------------------
module cmod_top #(
    parameter SYS_HZ  = 100_000_000,
    parameter BAUD    = 115_200,
    parameter LINE_TO = 3_000_000,     // 30 ms idle ends a command line
    parameter AUTO_TO = 10_000_000     // 100 ms auto-trigger timeout
) (
    input  wire       clk_12m,
    input  wire [1:0] btn,
    input  wire       uart_txd_in,
    output wire       uart_rxd_out,
    output wire [1:0] led,
    output wire       led0_r,
    output wire       led0_g,
    output wire       led0_b,
    // ADC08200
    input  wire [7:0] adc_d,
    output wire       adc_clk,
    output wire       adc_pd
);
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

    // ---- UART -----------------------------------------------------------------
    wire [15:0] cpb;
    wire [7:0]  rx_data;
    wire        rx_valid;
    wire        tx_start, tx_busy;
    wire [7:0]  tx_byte;

    uart_rx u_rx (
        .clk(clk), .rst(rst), .cpb(cpb), .rx(uart_txd_in),
        .data(rx_data), .valid(rx_valid)
    );

    uart_tx u_tx (
        .clk(clk), .rst(rst), .cpb(cpb), .data(tx_byte), .start(tx_start),
        .tx(uart_rxd_out), .busy(tx_busy)
    );

    wire        op_go, fmt_ready;
    wire [1:0]  op_type;
    wire [31:0] op_val;

    tx_fmt u_fmt (
        .clk(clk), .rst(rst), .go(op_go), .typ(op_type), .val(op_val),
        .ready(fmt_ready), .tx_start(tx_start), .tx_byte(tx_byte), .tx_busy(tx_busy)
    );

    // ---- control ----------------------------------------------------------------
    wire [3:0]  cfg_n;
    wire [23:0] cfg_d;
    wire [4:0]  cfg_ph;
    wire        cfg_tp, cfg_te;
    wire [14:0] cfg_ss, cfg_pt;
    wire [1:0]  cfg_tm;
    wire [7:0]  cfg_tl, cfg_th;
    wire        cap_arm, cap_abort, cap_done, cap_trig, cap_busy;
    wire [13:0] rd_rel;
    wire [7:0]  rd_data;
    wire        running, cont_mode;

    scope_ctrl #(
        .SYS_HZ(SYS_HZ), .BAUD(BAUD), .LINE_TO(LINE_TO)
    ) u_ctrl (
        .clk(clk), .rst(rst),
        .rx_data(rx_data), .rx_valid(rx_valid), .uart_cpb(cpb), .tx_busy(tx_busy),
        .op_go(op_go), .op_type(op_type), .op_val(op_val), .fmt_ready(fmt_ready),
        .cfg_n(cfg_n), .cfg_d(cfg_d), .cfg_ph(cfg_ph), .cfg_tp(cfg_tp),
        .cfg_ss(cfg_ss), .cfg_pt(cfg_pt), .cfg_tm(cfg_tm), .cfg_te(cfg_te),
        .cfg_tl(cfg_tl), .cfg_th(cfg_th), .adc_pd(adc_pd),
        .cap_arm(cap_arm), .cap_abort(cap_abort), .cap_done(cap_done),
        .cap_trig(cap_trig), .rd_rel(rd_rel), .rd_data(rd_data),
        .running(running), .cont_mode(cont_mode)
    );

    // ---- ADC capture --------------------------------------------------------------
    wire       clk_d1, clk_d2;
    wire [7:0] q_rise, q_fall;

    capture #(.AW(14), .AUTO_TO(AUTO_TO)) u_cap (
        .clk(clk), .rst(rst),
        .cfg_n(cfg_n), .cfg_d(cfg_d), .cfg_ph(cfg_ph), .cfg_tp(cfg_tp),
        .cfg_ss(cfg_ss), .cfg_pt(cfg_pt), .cfg_tm(cfg_tm), .cfg_te(cfg_te),
        .cfg_tl(cfg_tl), .cfg_th(cfg_th),
        .clk_d1(clk_d1), .clk_d2(clk_d2), .q_rise(q_rise), .q_fall(q_fall),
        .arm(cap_arm), .abort(cap_abort), .busy(cap_busy), .done(cap_done),
        .trig_real(cap_trig), .rd_rel(rd_rel), .rd_data(rd_data)
    );

    adc_io u_io (
        .clk(clk), .clk_d1(clk_d1), .clk_d2(clk_d2), .adc_clk(adc_clk),
        .adc_d(adc_d), .q_rise(q_rise), .q_fall(q_fall)
    );

    // ---- LEDs ------------------------------------------------------------------------
    reg [26:0] hb;
    always @(posedge clk) hb <= rst ? 27'd0 : hb + 27'd1;

    assign led[0] = hb[26];
    assign led[1] = running;
    assign led0_r = 1'b1;
    assign led0_g = ~locked;
    assign led0_b = ~cont_mode;

    wire unused = &{1'b0, btn[1], cap_busy};
endmodule
