`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// cmod_top.v - ADC08200 test design for Digilent Cmod A7-35T
//
//   * 12 MHz -> MMCM -> 100 MHz system clock + 200 MHz capture clock
//   * ADC08200 clocked from the FPGA (ODDR, up to 200 MHz), data captured
//     with IDDR on the 200 MHz clock
//   * UART over the onboard FT2232, 921600 8N1 at reset:
//       text commands  e.g.  SR=10MSPS,SS=1024,OFN,R
//       SPC switches to the binary packet protocol (docs/protocol.md)
//   * board revision (WR/RR) kept in the last 4 KB sector of the config flash
//
//   led[0]  heartbeat            led[1]  capture running
//   RGB green = MMCM locked      RGB blue = continuous mode
//   RGB red   = packet mode
//   btn[0]  reset (restores 921600 baud, text mode and default settings)
// -----------------------------------------------------------------------------
module cmod_top #(
    parameter SYS_HZ  = 100_000_000,
    parameter BAUD    = 921_600,
    parameter LINE_TO = 3_000_000,     // 30 ms idle ends a command line / frame
    parameter AUTO_TO = 10_000_000     // 100 ms auto-trigger timeout (SYS clocks)
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
    output wire       adc_pd,
    // configuration flash (SCK via STARTUPE2)
    output wire       qspi_cs,
    output wire       qspi_dq0,
    input  wire       qspi_dq1,
    output wire       qspi_dq2,
    output wire       qspi_dq3
);
    // ---- clock & reset ------------------------------------------------------
    wire clk, clk_cap, locked, rst;

    clk_gen u_clk (
        .clk_in_12m (clk_12m),
        .clk_100m   (clk),
        .clk_200m   (clk_cap),
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

    // ---- revision store (config flash) --------------------------------------------
    wire        rev_wr_go, rev_busy, rev_done, rev_err, rev_ok;
    wire [63:0] rev_wr_data, rev;
    wire        f_sck, f_cs_n, f_mosi, f_miso;

    rev_store u_rev (
        .clk(clk), .rst(rst),
        .wr_go(rev_wr_go), .wr_rev(rev_wr_data),
        .rev(rev), .rev_ok(rev_ok), .busy(rev_busy), .done(rev_done), .err(rev_err),
        .sck(f_sck), .cs_n(f_cs_n), .mosi(f_mosi), .miso(f_miso)
    );

    flash_io u_fio (
        .sck(f_sck), .cs_n(f_cs_n), .mosi(f_mosi), .miso(f_miso),
        .qspi_cs(qspi_cs), .qspi_dq0(qspi_dq0), .qspi_dq1(qspi_dq1),
        .qspi_dq2(qspi_dq2), .qspi_dq3(qspi_dq3)
    );

    // ---- control ----------------------------------------------------------------
    wire [4:0]  cfg_m;
    wire [23:0] cfg_dm1;
    wire [5:0]  cfg_ph;
    wire        cfg_tp, cfg_te;
    wire [14:0] cfg_ss, cfg_pt, cfg_post;
    wire [1:0]  cfg_tm, cfg_ck;
    wire [7:0]  cfg_tl, cfg_th, bus_now;
    wire        cap_arm, cap_abort, cap_done, cap_trig;
    wire [13:0] rd_rel;
    wire [7:0]  rd_data;
    wire        running, cont_mode, pmode;

    scope_ctrl #(
        .SYS_HZ(SYS_HZ), .BAUD(BAUD), .LINE_TO(LINE_TO)
    ) u_ctrl (
        .clk(clk), .rst(rst),
        .rx_data(rx_data), .rx_valid(rx_valid), .uart_cpb(cpb), .tx_busy(tx_busy),
        .op_go(op_go), .op_type(op_type), .op_val(op_val), .fmt_ready(fmt_ready),
        .cfg_m(cfg_m), .cfg_dm1(cfg_dm1), .cfg_ph(cfg_ph), .cfg_tp(cfg_tp),
        .cfg_ss(cfg_ss), .cfg_pt(cfg_pt), .cfg_post(cfg_post),
        .cfg_tm(cfg_tm), .cfg_te(cfg_te), .cfg_tl(cfg_tl), .cfg_th(cfg_th),
        .cfg_ck(cfg_ck), .adc_pd(adc_pd), .bus_now(bus_now),
        .cap_arm(cap_arm), .cap_abort(cap_abort), .cap_done(cap_done),
        .cap_trig(cap_trig), .rd_rel(rd_rel), .rd_data(rd_data),
        .rev_wr_go(rev_wr_go), .rev_wr_data(rev_wr_data), .rev(rev),
        .rev_busy(rev_busy), .rev_done(rev_done), .rev_err(rev_err),
        .running(running), .cont_mode(cont_mode), .pmode(pmode)
    );

    // ---- ADC capture (200 MHz) ----------------------------------------------------
    wire       clk_d1, clk_d2;
    wire [7:0] q_rise, q_fall;

    capture #(.AW(14), .AUTO_TO(2 * AUTO_TO)) u_cap (
        .clk(clk), .clk_cap(clk_cap), .rst(rst),
        .cfg_m(cfg_m), .cfg_dm1(cfg_dm1), .cfg_ph(cfg_ph), .cfg_tp(cfg_tp),
        .cfg_pt(cfg_pt), .cfg_post(cfg_post), .cfg_tm(cfg_tm), .cfg_te(cfg_te),
        .cfg_tl(cfg_tl), .cfg_th(cfg_th), .cfg_ck(cfg_ck),
        .clk_d1(clk_d1), .clk_d2(clk_d2), .q_rise(q_rise), .q_fall(q_fall),
        .bus_now(bus_now),
        .arm(cap_arm), .abort(cap_abort), .done(cap_done), .trig_real(cap_trig),
        .rd_rel(rd_rel), .rd_data(rd_data)
    );

    adc_io u_io (
        .clk(clk_cap), .clk_d1(clk_d1), .clk_d2(clk_d2), .adc_clk(adc_clk),
        .adc_d(adc_d), .q_rise(q_rise), .q_fall(q_fall)
    );

    // ---- LEDs ------------------------------------------------------------------------
    reg [26:0] hb;
    always @(posedge clk) hb <= rst ? 27'd0 : hb + 27'd1;

    assign led[0] = hb[26];
    assign led[1] = running;
    assign led0_r = ~pmode;
    assign led0_g = ~locked;
    assign led0_b = ~cont_mode;

    wire unused = &{1'b0, btn[1], rev_ok, cfg_ss};
endmodule
