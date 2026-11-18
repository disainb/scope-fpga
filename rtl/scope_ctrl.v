`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// scope_ctrl.v - UART front end: text command line and binary packet mode
//
// TEXT MODE (after reset)
//   One line of comma-separated tokens, ended by CR or LF (or 30 ms silence).
//   Case-insensitive, spaces ignored. Token = KEY[=]VALUE, KEY = 1-2 letters:
//     SR=10MSPS SS=1024 PT=0 OFN|OFX|OFB TMA|TMN|TMI TER|TEF TL=128 TH=4
//     PH=n|PHA PD=0|1 TP=0|1 BR=921600 CK=S|0|1 RB WR=xxxxxxxx RR SPC
//     R C D ? H
//   Settings-only lines answer with the status line; R/C/D/?/H/RB/RR/WR
//   answer with their own output. Errors: "ERR at col n", rest of line dropped.
//   During a capture or dump any character except CR/LF stops it.
//
// PACKET MODE (after "SPC"; leave with a TEXT packet or btn0)
//   Frame: 0xA5 | TYPE | LEN lo | LEN hi | PAYLOAD[LEN] | CRC lo | CRC hi
//   CRC-16/CCITT-FALSE over TYPE, LEN and PAYLOAD. Response TYPE = request
//   TYPE | 0x80, or 0xFF (NAK: code, request type). See docs/protocol.md.
// -----------------------------------------------------------------------------
module scope_ctrl #(
    parameter SYS_HZ  = 100_000_000,
    parameter BAUD    = 921_600,
    parameter LINE_TO = 3_000_000      // idle clocks that end a line / frame
) (
    input  wire        clk,
    input  wire        rst,
    // UART
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    output reg  [15:0] uart_cpb,
    input  wire        tx_busy,
    // formatter
    output reg         op_go,
    output reg  [1:0]  op_type,
    output reg  [31:0] op_val,
    input  wire        fmt_ready,
    // capture configuration
    output reg  [4:0]  cfg_m,
    output reg  [23:0] cfg_dm1,
    output wire [5:0]  cfg_ph,
    output reg         cfg_tp,
    output reg  [14:0] cfg_ss,
    output reg  [14:0] cfg_pt,
    output reg  [14:0] cfg_post,
    output reg  [1:0]  cfg_tm,
    output reg         cfg_te,
    output reg  [7:0]  cfg_tl,
    output reg  [7:0]  cfg_th,
    output reg  [1:0]  cfg_ck,
    output reg         adc_pd,
    input  wire [7:0]  bus_now,
    // capture control / readout
    output reg         cap_arm,
    output reg         cap_abort,
    input  wire        cap_done,
    input  wire        cap_trig,
    output reg  [13:0] rd_rel,
    input  wire [7:0]  rd_data,
    // revision store
    output reg         rev_wr_go,
    output reg  [63:0] rev_wr_data,
    input  wire [63:0] rev,
    input  wire        rev_busy,
    input  wire        rev_done,
    input  wire        rev_err,
    // status
    output reg         running,
    output reg         cont_mode,
    output reg         pmode
);
`include "msg_ids.vh"
`include "crc16.vh"

    localparam [31:0]  SYS    = SYS_HZ;
    localparam [31:0]  CAP    = 2 * SYS_HZ;          // capture clock
    localparam integer CPB0_I = (SYS_HZ + BAUD / 2) / BAUD;
    localparam [15:0]  CPB0   = CPB0_I[15:0];
    localparam [31:0]  BR0    = BAUD;
    localparam [4:0]   M_MAX  = 5'd20;               // slowest ADC clock = CAP/20
    localparam [1:0]   OP_CHR = 2'd0, OP_DEC = 2'd1, OP_HEX = 2'd2;
    localparam [1:0]   OF_N = 2'd0, OF_X = 2'd1, OF_B = 2'd2;
    localparam [7:0]   CH_CR = 8'h0D, CH_LF = 8'h0A, CH_SP = 8'h20;
    localparam [7:0]   SYNC = 8'hA5;
    localparam [7:0]   PROTO_VER = 8'd1, FW_MAJ = 8'd0, FW_MIN = 8'd4;

    // NAK codes
    localparam [7:0] NAK_CRC = 8'd1, NAK_LEN = 8'd2, NAK_TYPE = 8'd3,
                     NAK_ARG = 8'd4;

    localparam [6:0]
        // text mode
        S_BOOT  = 7'd0,  S_IDLE  = 7'd1,
        P_TOK   = 7'd2,  P_KEY2  = 7'd3,  P_EQ    = 7'd4,  P_VAL   = 7'd5,
        P_UNIT  = 7'd6,  P_DISP  = 7'd7,  P_REV   = 7'd8,
        X_SR1   = 7'd9,  X_SR2   = 7'd10, X_SR2W  = 7'd11, X_SR3   = 7'd12,
        X_SR3W  = 7'd13, X_SR4W  = 7'd14, X_BR1   = 7'd15, X_REVGO = 7'd16,
        X_REVW  = 7'd17, X_SPC   = 7'd18,
        R_ARM   = 7'd19, R_WAIT  = 7'd20, R_AFTER = 7'd21,
        D_START = 7'd22, D_ADDR  = 7'd23, D_W1    = 7'd24, D_W2    = 7'd25,
        D_OUT   = 7'd26, D_SEP1  = 7'd27, D_SEP2  = 7'd28, D_NEXT  = 7'd29,
        L_END   = 7'd30, L_BAUD  = 7'd31, E_ERR   = 7'd32,
        M_FETCH = 7'd33, M_EMIT  = 7'd34,
        // packet receive / execute
        K_SYNC  = 7'd40, K_TYPE  = 7'd41, K_L0    = 7'd42, K_L1    = 7'd43,
        K_PAY   = 7'd44, K_C0    = 7'd45, K_C1    = 7'd46, K_DISP  = 7'd47,
        K_CFG   = 7'd48, K_CFGR  = 7'd49, K_ARM   = 7'd50, K_WAIT  = 7'd51,
        K_REVGO = 7'd52, K_REVW  = 7'd53,
        // packet transmit
        T_SYNC  = 7'd60, T_TYPE  = 7'd61, T_L0    = 7'd62, T_L1    = 7'd63,
        T_HDR   = 7'd64, T_DADDR = 7'd65, T_DW1   = 7'd66, T_DW2   = 7'd67,
        T_DATA  = 7'd68, T_C0    = 7'd69, T_C1    = 7'd70, T_END   = 7'd71;

    reg [6:0] state, m_ret, x_ret;

    // ---- settings -------------------------------------------------------------
    reg [31:0] sr_eff, adc_hz, br_val, br_req;
    reg [23:0] cfg_d;
    reg [1:0]  of;
    reg [5:0]  ph_val;
    reg        ph_auto;
    reg [15:0] pend_cpb;
    reg        pend_baud;
    reg [7:0]  bus_snap;

    assign cfg_ph = ph_auto ? {1'b0, cfg_m} : ph_val;

    // quasi-static values for the 200 MHz capture domain, registered here
    always @(posedge clk) begin
        cfg_dm1  <= cfg_d - 24'd1;
        cfg_post <= cfg_ss - cfg_pt - 15'd1;
    end

    // ---- line / payload buffer ----------------------------------------------------
    reg [7:0]  lbuf [0:63];
    reg [6:0]  llen, pi, tok_col;
    reg [23:0] lto;
    reg        abort_req, printed, have_cap;

    wire       is_crlf = (rx_data == CH_CR) || (rx_data == CH_LF);
    wire [7:0] rx_uc   = (rx_data >= 8'h61 && rx_data <= 8'h7A) ? rx_data - 8'h20 : rx_data;
    wire [7:0] c       = (pi < llen) ? lbuf[pi[5:0]] : 8'h00;
    wire       c_sep   = (c == 8'h2C) || (c == 8'h3B) || (c == 8'h00);
    wire       c_dig   = (c >= 8'h30) && (c <= 8'h39);
    wire       c_let   = (c >= 8'h41) && (c <= 8'h5A);

    // ---- token -----------------------------------------------------------------------
    reg [7:0]  key0, key1, vch;
    reg [31:0] num;
    reg        has_num, unit_set, bad;
    reg [2:0]  mcnt;
    reg [3:0]  rcnt;
    reg        rbad;
    wire [15:0] key     = {key0, key1};
    wire [31:0] num_x10 = {num[28:0], 3'b000} + {num[30:0], 1'b0};
    wire        num_big = (num > 32'd400_000_000);

    // ---- dump / data stream ----------------------------------------------------------
    reg [14:0] k, n_last;
    wire       last = (k == n_last - 15'd1);

    // ---- divider -----------------------------------------------------------------------
    reg         div_go;
    reg  [31:0] div_a, div_b;
    wire [31:0] div_q;
    wire        div_done;
    wire [28:0] md_prod = cfg_m * cfg_d;

    /* verilator lint_off PINCONNECTEMPTY */
    udiv32 u_div (
        .clk(clk), .rst(rst), .start(div_go),
        .dividend(div_a), .divisor(div_b),
        .quotient(div_q), .remainder(),
        .done(div_done), .busy()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ---- packet state -------------------------------------------------------------------
    reg [7:0]  k_type;
    reg [15:0] k_len, k_crc;
    reg [7:0]  k_crc_lo;
    reg [6:0]  k_idx;
    reg [23:0] kto;
    reg [15:0] seq;

    reg [7:0]  t_type;
    reg [6:0]  t_hlen, tj;
    reg        t_src;          // 0 = rbuf, 1 = lbuf (PING echo)
    reg [14:0] t_dn;
    reg [15:0] tcrc;
    reg        t_exit;
    reg [7:0]  rbuf [0:19];        // response header (longest: CONFIG, 20 bytes)

    wire [15:0] t_len  = {9'd0, t_hlen} + {1'b0, t_dn};
    wire [7:0]  t_hb   = t_src ? lbuf[tj[5:0]] : rbuf[tj[4:0]];

    // SET_CONFIG payload fields (little-endian)
    wire [31:0] p_sr = {lbuf[3], lbuf[2], lbuf[1], lbuf[0]};
    wire [15:0] p_ss = {lbuf[5], lbuf[4]};
    wire [15:0] p_pt = {lbuf[7], lbuf[6]};
    wire        p_ok = (p_sr != 32'd0) && (p_ss >= 16'd1) && (p_ss <= 16'd16384) &&
                       (p_pt < p_ss) && (lbuf[8] <= 8'd2) && (lbuf[9] <= 8'd1) &&
                       (lbuf[12] == 8'hFF || lbuf[12] <= 8'd39) &&
                       (lbuf[13] <= 8'd1) && (lbuf[14] <= 8'd1);

    // ---- message ROM ----------------------------------------------------------------------
    reg  [MSG_AW-1:0] m_addr;
    wire [7:0]        m_data;

    msg_rom u_rom (.clk(clk), .addr(m_addr), .data(m_data));

    reg [31:0] vval;
    always @* begin
        case (m_data[4:0])
            V_SR:    vval = sr_eff;
            V_ADC:   vval = adc_hz;
            V_SS:    vval = {17'd0, cfg_ss};
            V_PT:    vval = {17'd0, cfg_pt};
            V_TL:    vval = {24'd0, cfg_tl};
            V_TH:    vval = {24'd0, cfg_th};
            V_PH:    vval = {26'd0, cfg_ph};
            V_PD:    vval = {31'd0, adc_pd};
            V_TP:    vval = {31'd0, cfg_tp};
            V_BR:    vval = br_val;
            V_TRIG:  vval = {31'd0, cap_trig};
            V_N:     vval = {27'd0, cfg_m};
            V_D:     vval = {8'd0, cfg_d};
            V_COL:   vval = {25'd0, tok_col};
            V_NLAST: vval = {17'd0, n_last};
            V_BUS:   vval = {24'd0, bus_snap};
            default: vval = 32'd0;
        endcase
    end

    reg [7:0] cval;
    always @* begin
        case (m_data[4:0])
            C_OF:    cval = (of == OF_X) ? "X" : (of == OF_B) ? "B" : "N";
            C_TM:    cval = (cfg_tm == 2'd1) ? "N" : (cfg_tm == 2'd2) ? "I" : "A";
            C_TE:    cval = cfg_te ? "F" : "R";
            C_CK:    cval = (cfg_ck == 2'd1) ? "0" : (cfg_ck == 2'd2) ? "1" : "S";
            C_B7:    cval = bus_snap[7] ? "1" : "0";
            C_B6:    cval = bus_snap[6] ? "1" : "0";
            C_B5:    cval = bus_snap[5] ? "1" : "0";
            C_B4:    cval = bus_snap[4] ? "1" : "0";
            C_B3:    cval = bus_snap[3] ? "1" : "0";
            C_B2:    cval = bus_snap[2] ? "1" : "0";
            C_B1:    cval = bus_snap[1] ? "1" : "0";
            C_B0:    cval = bus_snap[0] ? "1" : "0";
            C_R0:    cval = rev[63:56];
            C_R1:    cval = rev[55:48];
            C_R2:    cval = rev[47:40];
            C_R3:    cval = rev[39:32];
            C_R4:    cval = rev[31:24];
            C_R5:    cval = rev[23:16];
            C_R6:    cval = rev[15:8];
            C_R7:    cval = rev[7:0];
            default: cval = "?";
        endcase
    end

    wire send_ok = fmt_ready && !op_go;
    wire k_rx    = (state >= K_SYNC && state <= K_C1);


    // ---- main state machine --------------------------------------------------------------
    always @(posedge clk) begin
        op_go     <= 1'b0;
        div_go    <= 1'b0;
        cap_arm   <= 1'b0;
        cap_abort <= 1'b0;
        rev_wr_go <= 1'b0;

        if (rst) begin
            state     <= S_BOOT;
            m_ret     <= S_IDLE;
            x_ret     <= P_TOK;
            m_addr    <= MSG_BANNER;
            uart_cpb  <= CPB0;
            op_type   <= OP_CHR;
            op_val    <= 32'd0;
            cfg_m     <= M_MAX;
            cfg_d     <= 24'd1;
            cfg_tp    <= 1'b0;
            cfg_ss    <= 15'd1024;
            cfg_pt    <= 15'd0;
            cfg_tm    <= 2'd0;
            cfg_te    <= 1'b0;
            cfg_tl    <= 8'd128;
            cfg_th    <= 8'd4;
            cfg_ck    <= 2'd0;
            adc_pd    <= 1'b0;
            bus_snap  <= 8'd0;
            sr_eff    <= CAP / 20;
            adc_hz    <= CAP / 20;
            br_val    <= BR0;
            br_req    <= BR0;
            of        <= OF_N;
            ph_val    <= 6'd0;
            ph_auto   <= 1'b1;
            pend_cpb  <= CPB0;
            pend_baud <= 1'b0;
            llen      <= 7'd0;
            pi        <= 7'd0;
            tok_col   <= 7'd0;
            lto       <= 24'd0;
            abort_req <= 1'b0;
            printed   <= 1'b0;
            have_cap  <= 1'b0;
            key0      <= 8'd0;
            key1      <= 8'd0;
            vch       <= 8'd0;
            num       <= 32'd0;
            has_num   <= 1'b0;
            unit_set  <= 1'b0;
            bad       <= 1'b0;
            mcnt      <= 3'd0;
            rcnt      <= 4'd0;
            rbad      <= 1'b0;
            k         <= 15'd0;
            n_last    <= 15'd0;
            rd_rel    <= 14'd0;
            div_a     <= 32'd0;
            div_b     <= 32'd1;
            running   <= 1'b0;
            cont_mode <= 1'b0;
            pmode     <= 1'b0;
            rev_wr_data <= 64'd0;
            k_type    <= 8'd0;
            k_len     <= 16'd0;
            k_crc     <= 16'hFFFF;
            k_crc_lo  <= 8'd0;
            k_idx     <= 7'd0;
            kto       <= 24'd0;
            seq       <= 16'd0;
            t_type    <= 8'd0;
            t_hlen    <= 7'd0;
            tj        <= 7'd0;
            t_src     <= 1'b0;
            t_dn      <= 15'd0;
            tcrc      <= 16'hFFFF;
            t_exit    <= 1'b0;
        end else begin
            // stop requests while busy
            if (rx_valid) begin
                if (state == K_WAIT)
                    abort_req <= 1'b1;
                else if (!pmode && state != S_IDLE && !is_crlf)
                    abort_req <= 1'b1;
            end

            // packet receive timeout: drop a half-received frame
            if (k_rx && state != K_SYNC) begin
                if (rx_valid)                  kto <= 24'd0;
                else if (kto >= LINE_TO - 1) begin
                    kto   <= 24'd0;
                    state <= K_SYNC;
                end else                       kto <= kto + 24'd1;
            end

            case (state)
                // =================================================================
                // TEXT MODE
                // =================================================================
                S_BOOT: begin
                    m_addr <= MSG_BANNER;
                    m_ret  <= S_IDLE;
                    state  <= M_FETCH;
                end

                S_IDLE: begin
                    if (rx_valid) begin
                        lto <= 24'd0;
                        if (is_crlf) begin
                            if (llen != 7'd0) begin
                                pi        <= 7'd0;
                                printed   <= 1'b0;
                                abort_req <= 1'b0;
                                state     <= P_TOK;
                            end
                        end else if (rx_data == 8'h08 || rx_data == 8'h7F) begin
                            if (llen != 7'd0) llen <= llen - 7'd1;
                        end else if (rx_data > CH_SP && rx_data < 8'h7F && llen < 7'd64) begin
                            lbuf[llen[5:0]] <= rx_uc;
                            llen            <= llen + 7'd1;
                        end
                    end else if (llen != 7'd0) begin
                        if (lto >= LINE_TO - 1) begin
                            lto       <= 24'd0;
                            pi        <= 7'd0;
                            printed   <= 1'b0;
                            abort_req <= 1'b0;
                            state     <= P_TOK;
                        end else
                            lto <= lto + 24'd1;
                    end
                end

                // ---- tokenizer ---------------------------------------------------
                P_TOK:
                    if (pi >= llen)
                        state <= L_END;
                    else if (c == 8'h2C || c == 8'h3B)
                        pi <= pi + 7'd1;
                    else begin
                        key0    <= c;
                        tok_col <= pi + 7'd1;
                        pi      <= pi + 7'd1;
                        state   <= P_KEY2;
                    end

                P_KEY2: begin
                    if (c_let && key0 >= 8'h41 && key0 <= 8'h5A) begin
                        key1 <= c;
                        pi   <= pi + 7'd1;
                    end else
                        key1 <= CH_SP;
                    state <= P_EQ;
                end

                P_EQ: begin
                    if (c == 8'h3D) pi <= pi + 7'd1;   // '='
                    num      <= 32'd0;
                    has_num  <= 1'b0;
                    unit_set <= 1'b0;
                    vch      <= 8'd0;
                    mcnt     <= 3'd0;
                    bad      <= 1'b0;
                    rcnt     <= 4'd0;
                    rbad     <= 1'b0;
                    state    <= (key == "WR") ? P_REV : P_VAL;
                end

                // WR=xxxxxxxx : take the characters as they are
                P_REV:
                    if (c_sep) begin
                        printed <= 1'b1;
                        if (rcnt == 4'd8 && !rbad)
                            state <= X_REVGO;
                        else begin
                            m_addr <= MSG_REVLEN;
                            m_ret  <= L_BAUD;
                            state  <= M_FETCH;
                        end
                    end else begin
                        pi <= pi + 7'd1;
                        if (rcnt == 4'd8)
                            rbad <= 1'b1;
                        else begin
                            rev_wr_data <= {rev_wr_data[55:0], c};
                            rcnt        <= rcnt + 4'd1;
                        end
                    end

                P_VAL:
                    if (c_sep)
                        state <= P_UNIT;
                    else begin
                        pi <= pi + 7'd1;
                        if (c_dig) begin
                            if (unit_set || vch != 8'd0 || num_big)
                                bad <= 1'b1;
                            else begin
                                num     <= num_x10 + {28'd0, c[3:0]};
                                has_num <= 1'b1;
                            end
                        end else if (c_let) begin
                            if (has_num) begin
                                if (!unit_set) begin
                                    unit_set <= 1'b1;
                                    mcnt     <= (c == "M") ? 3'd6 : (c == "K") ? 3'd3 : 3'd0;
                                end
                            end else if (vch == 8'd0)
                                vch <= c;
                        end else
                            bad <= 1'b1;
                    end

                P_UNIT:
                    if (mcnt != 3'd0) begin
                        if (num_big) bad <= 1'b1;
                        else         num <= num_x10;
                        mcnt <= mcnt - 3'd1;
                    end else
                        state <= P_DISP;

                // ---- execute one token --------------------------------------------
                P_DISP: begin
                    state <= P_TOK;
                    if (bad)
                        state <= E_ERR;
                    else case (key)
                        "SR":
                            if (has_num && num != 32'd0) begin
                                div_a  <= CAP + {1'b0, num[31:1]};
                                div_b  <= num;
                                div_go <= 1'b1;
                                x_ret  <= P_TOK;
                                state  <= X_SR1;
                            end else state <= E_ERR;
                        "SS":
                            if (has_num && num >= 32'd1 && num <= 32'd16384) begin
                                cfg_ss <= num[14:0];
                                if ({17'd0, cfg_pt} >= num) cfg_pt <= num[14:0] - 15'd1;
                            end else state <= E_ERR;
                        "PT":
                            if (has_num && num < {17'd0, cfg_ss}) cfg_pt <= num[14:0];
                            else state <= E_ERR;
                        "OF":
                            if      (vch == "N") of <= OF_N;
                            else if (vch == "X") of <= OF_X;
                            else if (vch == "B") of <= OF_B;
                            else state <= E_ERR;
                        "TM":
                            if      (vch == "A") cfg_tm <= 2'd0;
                            else if (vch == "N") cfg_tm <= 2'd1;
                            else if (vch == "I") cfg_tm <= 2'd2;
                            else state <= E_ERR;
                        "TE":
                            if      (vch == "R") cfg_te <= 1'b0;
                            else if (vch == "F") cfg_te <= 1'b1;
                            else state <= E_ERR;
                        "TL":
                            if (has_num && num <= 32'd255) cfg_tl <= num[7:0];
                            else state <= E_ERR;
                        "TH":
                            if (has_num && num <= 32'd255) cfg_th <= num[7:0];
                            else state <= E_ERR;
                        "PH":
                            if (vch == "A") ph_auto <= 1'b1;
                            else if (has_num && num <= 32'd39) begin
                                ph_val  <= num[5:0];
                                ph_auto <= 1'b0;
                            end else state <= E_ERR;
                        "PD":
                            if (has_num && num <= 32'd1) adc_pd <= num[0];
                            else state <= E_ERR;
                        "TP":
                            if (has_num && num <= 32'd1) cfg_tp <= num[0];
                            else state <= E_ERR;
                        "CK":
                            if      (vch == "S")              cfg_ck <= 2'd0;
                            else if (has_num && num == 32'd0) cfg_ck <= 2'd1;
                            else if (has_num && num == 32'd1) cfg_ck <= 2'd2;
                            else state <= E_ERR;
                        "BR":
                            if (has_num && num >= 32'd1600 && num <= 32'd6_250_000) begin
                                div_a  <= SYS + {1'b0, num[31:1]};
                                div_b  <= num;
                                div_go <= 1'b1;
                                br_req <= num;
                                state  <= X_BR1;
                            end else state <= E_ERR;
                        "RB": begin
                            printed  <= 1'b1;
                            bus_snap <= bus_now;
                            m_addr   <= MSG_BUS;
                            m_ret    <= P_TOK;
                            state    <= M_FETCH;
                        end
                        "RR": begin
                            printed <= 1'b1;
                            m_addr  <= MSG_REV;
                            m_ret   <= P_TOK;
                            state   <= M_FETCH;
                        end
                        "SP":
                            if (vch == "C") begin
                                printed <= 1'b1;
                                m_addr  <= MSG_SPC;
                                m_ret   <= X_SPC;
                                state   <= M_FETCH;
                            end else state <= E_ERR;
                        "R ": begin
                            printed   <= 1'b1;
                            cont_mode <= 1'b0;
                            state     <= R_ARM;
                        end
                        "C ": begin
                            printed   <= 1'b1;
                            cont_mode <= 1'b1;
                            state     <= R_ARM;
                        end
                        "D ": begin
                            printed <= 1'b1;
                            if (have_cap) state <= D_START;
                            else begin
                                m_addr <= MSG_NODATA;
                                m_ret  <= P_TOK;
                                state  <= M_FETCH;
                            end
                        end
                        "? ": begin
                            printed <= 1'b1;
                            m_addr  <= MSG_STATUS;
                            m_ret   <= P_TOK;
                            state   <= M_FETCH;
                        end
                        "H ": begin
                            printed <= 1'b1;
                            m_addr  <= MSG_HELP;
                            m_ret   <= P_TOK;
                            state   <= M_FETCH;
                        end
                        default: state <= E_ERR;
                    endcase
                end

                // ---- sample rate ---------------------------------------------------
                // P = round(CAP/SR). P <= 20: M = P, D = 1. Else M = 20, D = round(P/20).
                X_SR1:
                    if (div_done) begin
                        num   <= (div_q == 32'd0) ? 32'd1 : div_q;
                        state <= X_SR2;
                    end
                X_SR2:
                    if (num <= {27'd0, M_MAX}) begin
                        cfg_m <= num[4:0];
                        cfg_d <= 24'd1;
                        state <= X_SR3;
                    end else begin
                        div_a  <= num + 32'd10;
                        div_b  <= {27'd0, M_MAX};
                        div_go <= 1'b1;
                        state  <= X_SR2W;
                    end
                X_SR2W:
                    if (div_done) begin
                        cfg_m <= M_MAX;
                        cfg_d <= (div_q > 32'd16_000_000) ? 24'd16_000_000 : div_q[23:0];
                        state <= X_SR3;
                    end
                X_SR3: begin
                    div_a  <= CAP;
                    div_b  <= {27'd0, cfg_m};
                    div_go <= 1'b1;
                    state  <= X_SR3W;
                end
                X_SR3W:
                    if (div_done) begin
                        adc_hz <= div_q;
                        div_a  <= CAP;
                        div_b  <= {3'd0, md_prod};
                        div_go <= 1'b1;
                        state  <= X_SR4W;
                    end
                X_SR4W:
                    if (div_done) begin
                        sr_eff <= div_q;
                        state  <= x_ret;
                    end

                // ---- baud: applied after this line's response -------------------------
                X_BR1:
                    if (div_done) begin
                        pend_cpb  <= div_q[15:0];
                        pend_baud <= 1'b1;
                        br_val    <= br_req;
                        state     <= P_TOK;
                    end

                // ---- revision write ------------------------------------------------------
                X_REVGO:
                    if (!rev_busy) begin
                        rev_wr_go <= 1'b1;
                        state     <= X_REVW;
                    end
                X_REVW:
                    if (rev_done) begin
                        m_addr <= rev_err ? MSG_FLERR : MSG_REVOK;
                        m_ret  <= P_TOK;
                        state  <= M_FETCH;
                    end

                // ---- enter packet mode (after the OK line has gone out) -----------------
                X_SPC:
                    if (send_ok && !tx_busy) begin
                        if (pend_baud) begin
                            uart_cpb  <= pend_cpb;
                            pend_baud <= 1'b0;
                        end
                        llen      <= 7'd0;
                        cont_mode <= 1'b0;
                        pmode     <= 1'b1;
                        kto       <= 24'd0;
                        state     <= K_SYNC;
                    end

                // ---- run -------------------------------------------------------------------
                R_ARM: begin
                    cap_arm <= 1'b1;
                    n_last  <= cfg_ss;
                    running <= 1'b1;
                    state   <= R_WAIT;
                end
                R_WAIT:
                    if (cap_done) begin
                        have_cap <= 1'b1;
                        running  <= 1'b0;
                        state    <= D_START;
                    end else if (abort_req) begin
                        cap_abort <= 1'b1;
                        running   <= 1'b0;
                        cont_mode <= 1'b0;
                        m_addr    <= MSG_STOP;
                        m_ret     <= L_BAUD;
                        state     <= M_FETCH;
                    end
                R_AFTER:
                    if (cont_mode) begin
                        if (abort_req) begin
                            cont_mode <= 1'b0;
                            m_addr    <= MSG_STOP;
                            m_ret     <= L_BAUD;
                            state     <= M_FETCH;
                        end else
                            state <= R_ARM;
                    end else
                        state <= P_TOK;

                // ---- text dump ----------------------------------------------------------------
                D_START: begin
                    k <= 15'd0;
                    if (of == OF_N)
                        state <= D_ADDR;
                    else begin
                        m_addr <= (of == OF_B) ? MSG_HDRB : MSG_HDR;
                        m_ret  <= D_ADDR;
                        state  <= M_FETCH;
                    end
                end
                D_ADDR: begin
                    rd_rel <= k[13:0];
                    state  <= D_W1;
                end
                D_W1: state <= D_W2;
                D_W2: state <= D_OUT;
                D_OUT:
                    if (send_ok) begin
                        op_go   <= 1'b1;
                        op_type <= (of == OF_N) ? OP_DEC : (of == OF_X) ? OP_HEX : OP_CHR;
                        op_val  <= {24'd0, rd_data};
                        state   <= D_SEP1;
                    end
                D_SEP1:
                    if (send_ok) begin
                        if (of == OF_N || last || (of == OF_X && k[3:0] == 4'hF)) begin
                            op_go   <= 1'b1;
                            op_type <= OP_CHR;
                            op_val  <= {24'd0, CH_CR};
                            state   <= D_SEP2;
                        end else if (of == OF_X) begin
                            op_go   <= 1'b1;
                            op_type <= OP_CHR;
                            op_val  <= {24'd0, CH_SP};
                            state   <= D_NEXT;
                        end else
                            state <= D_NEXT;
                    end
                D_SEP2:
                    if (send_ok) begin
                        op_go   <= 1'b1;
                        op_type <= OP_CHR;
                        op_val  <= {24'd0, CH_LF};
                        state   <= D_NEXT;
                    end
                D_NEXT:
                    if (last) begin
                        if (of == OF_N)
                            state <= R_AFTER;
                        else begin
                            m_addr <= MSG_END;
                            m_ret  <= R_AFTER;
                            state  <= M_FETCH;
                        end
                    end else begin
                        k     <= k + 15'd1;
                        state <= D_ADDR;
                    end

                // ---- end of line -----------------------------------------------------------------
                E_ERR: begin
                    m_addr <= MSG_ERR;
                    m_ret  <= L_BAUD;
                    state  <= M_FETCH;
                end
                L_END:
                    if (!printed) begin
                        m_addr <= MSG_STATUS;
                        m_ret  <= L_BAUD;
                        state  <= M_FETCH;
                    end else
                        state <= L_BAUD;
                L_BAUD:
                    if (!pend_baud) begin
                        llen      <= 7'd0;
                        lto       <= 24'd0;
                        cont_mode <= 1'b0;
                        state     <= S_IDLE;
                    end else if (send_ok && !tx_busy) begin
                        uart_cpb  <= pend_cpb;
                        pend_baud <= 1'b0;
                    end

                // ---- print message from ROM, then go to m_ret ----------------------------------
                M_FETCH: state <= M_EMIT;
                M_EMIT:
                    if (m_data == 8'h00)
                        state <= m_ret;
                    else if (send_ok) begin
                        op_go <= 1'b1;
                        if (m_data[7:6] == 2'b10) begin
                            op_type <= OP_DEC;
                            op_val  <= vval;
                        end else if (m_data[7:6] == 2'b11) begin
                            op_type <= OP_CHR;
                            op_val  <= {24'd0, cval};
                        end else begin
                            op_type <= OP_CHR;
                            op_val  <= {24'd0, m_data};
                        end
                        m_addr <= m_addr + 1'b1;
                        state  <= M_FETCH;
                    end

                // =================================================================
                // PACKET MODE - receive
                // =================================================================
                K_SYNC: begin
                    abort_req <= 1'b0;
                    if (rx_valid && rx_data == SYNC) begin
                        k_crc <= 16'hFFFF;
                        kto   <= 24'd0;
                        state <= K_TYPE;
                    end
                end
                K_TYPE:
                    if (rx_valid) begin
                        k_type <= rx_data;
                        k_crc  <= crc16_upd(k_crc, rx_data);
                        state  <= K_L0;
                    end
                K_L0:
                    if (rx_valid) begin
                        k_len[7:0] <= rx_data;
                        k_crc      <= crc16_upd(k_crc, rx_data);
                        state      <= K_L1;
                    end
                K_L1:
                    if (rx_valid) begin
                        k_len[15:8] <= rx_data;
                        k_crc       <= crc16_upd(k_crc, rx_data);
                        k_idx       <= 7'd0;
                        if ({rx_data, k_len[7:0]} > 16'd64) begin
                            rbuf[0] <= NAK_LEN;
                            rbuf[1] <= k_type;
                            t_type  <= 8'hFF;
                            t_hlen  <= 7'd2;
                            t_src   <= 1'b0;
                            t_dn    <= 15'd0;
                            state   <= T_SYNC;
                        end else if ({rx_data, k_len[7:0]} == 16'd0)
                            state <= K_C0;
                        else
                            state <= K_PAY;
                    end
                K_PAY:
                    if (rx_valid) begin
                        lbuf[k_idx[5:0]] <= rx_data;
                        k_crc            <= crc16_upd(k_crc, rx_data);
                        k_idx            <= k_idx + 7'd1;
                        if ({9'd0, k_idx} + 16'd1 == k_len) state <= K_C0;
                    end
                K_C0:
                    if (rx_valid) begin
                        k_crc_lo <= rx_data;
                        state    <= K_C1;
                    end
                K_C1:
                    if (rx_valid) begin
                        t_src <= 1'b0;
                        t_dn  <= 15'd0;
                        if ({rx_data, k_crc_lo} == k_crc)
                            state <= K_DISP;
                        else begin
                            rbuf[0] <= NAK_CRC;
                            rbuf[1] <= k_type;
                            t_type  <= 8'hFF;
                            t_hlen  <= 7'd2;
                            state   <= T_SYNC;
                        end
                    end

                // ---- execute ----------------------------------------------------------------------
                K_DISP: begin
                    t_type <= k_type | 8'h80;
                    t_exit <= 1'b0;
                    state  <= T_SYNC;
                    case (k_type)
                        8'h01: begin                                  // PING: echo
                            t_src  <= 1'b1;
                            t_hlen <= k_len[6:0];
                        end
                        8'h02: begin                                  // GET_INFO
                            rbuf[0]  <= PROTO_VER;
                            rbuf[1]  <= FW_MAJ;
                            rbuf[2]  <= FW_MIN;
                            rbuf[3]  <= 8'd8;                         // ADC bits
                            rbuf[4]  <= CAP[7:0];
                            rbuf[5]  <= CAP[15:8];
                            rbuf[6]  <= CAP[23:16];
                            rbuf[7]  <= CAP[31:24];
                            rbuf[8]  <= 8'h00;                        // 16384
                            rbuf[9]  <= 8'h40;
                            rbuf[10] <= rev[63:56];
                            rbuf[11] <= rev[55:48];
                            rbuf[12] <= rev[47:40];
                            rbuf[13] <= rev[39:32];
                            rbuf[14] <= rev[31:24];
                            rbuf[15] <= rev[23:16];
                            rbuf[16] <= rev[15:8];
                            rbuf[17] <= rev[7:0];
                            t_hlen   <= 7'd18;
                        end
                        8'h03:                                        // SET_CONFIG
                            if (k_len != 16'd16) begin
                                rbuf[0] <= NAK_LEN; rbuf[1] <= k_type;
                                t_type  <= 8'hFF;   t_hlen  <= 7'd2;
                            end else
                                state <= K_CFG;
                        8'h04: state <= K_CFGR;                       // GET_CONFIG
                        8'h05: state <= K_ARM;                        // ACQUIRE
                        8'h07: begin                                  // GET_REV
                            rbuf[0] <= rev[63:56]; rbuf[1] <= rev[55:48];
                            rbuf[2] <= rev[47:40]; rbuf[3] <= rev[39:32];
                            rbuf[4] <= rev[31:24]; rbuf[5] <= rev[23:16];
                            rbuf[6] <= rev[15:8];  rbuf[7] <= rev[7:0];
                            t_hlen  <= 7'd8;
                        end
                        8'h08:                                        // SET_REV
                            if (k_len != 16'd8) begin
                                rbuf[0] <= NAK_LEN; rbuf[1] <= k_type;
                                t_type  <= 8'hFF;   t_hlen  <= 7'd2;
                            end else begin
                                rev_wr_data <= {lbuf[0], lbuf[1], lbuf[2], lbuf[3],
                                                lbuf[4], lbuf[5], lbuf[6], lbuf[7]};
                                state <= K_REVGO;
                            end
                        8'h09: begin                                  // TEXT: leave
                            t_hlen <= 7'd0;
                            t_exit <= 1'b1;
                        end
                        default: begin
                            rbuf[0] <= NAK_TYPE; rbuf[1] <= k_type;
                            t_type  <= 8'hFF;    t_hlen  <= 7'd2;
                        end
                    endcase
                end

                K_CFG:
                    if (!p_ok) begin
                        rbuf[0] <= NAK_ARG; rbuf[1] <= k_type;
                        t_type  <= 8'hFF;   t_hlen  <= 7'd2;
                        state   <= T_SYNC;
                    end else begin
                        cfg_ss  <= p_ss[14:0];
                        cfg_pt  <= p_pt[14:0];
                        cfg_tm  <= lbuf[8][1:0];
                        cfg_te  <= lbuf[9][0];
                        cfg_tl  <= lbuf[10];
                        cfg_th  <= lbuf[11];
                        ph_auto <= (lbuf[12] == 8'hFF);
                        ph_val  <= lbuf[12][5:0];
                        adc_pd  <= lbuf[13][0];
                        cfg_tp  <= lbuf[14][0];
                        div_a   <= CAP + {1'b0, p_sr[31:1]};
                        div_b   <= p_sr;
                        div_go  <= 1'b1;
                        x_ret   <= K_CFGR;
                        state   <= X_SR1;
                    end

                K_CFGR: begin                                         // CONFIG response
                    rbuf[0]  <= sr_eff[7:0];   rbuf[1]  <= sr_eff[15:8];
                    rbuf[2]  <= sr_eff[23:16]; rbuf[3]  <= sr_eff[31:24];
                    rbuf[4]  <= adc_hz[7:0];   rbuf[5]  <= adc_hz[15:8];
                    rbuf[6]  <= adc_hz[23:16]; rbuf[7]  <= adc_hz[31:24];
                    rbuf[8]  <= cfg_ss[7:0];   rbuf[9]  <= {1'b0, cfg_ss[14:8]};
                    rbuf[10] <= cfg_pt[7:0];   rbuf[11] <= {1'b0, cfg_pt[14:8]};
                    rbuf[12] <= {6'd0, cfg_tm};
                    rbuf[13] <= {7'd0, cfg_te};
                    rbuf[14] <= cfg_tl;
                    rbuf[15] <= cfg_th;
                    rbuf[16] <= {2'd0, cfg_ph};
                    rbuf[17] <= {7'd0, adc_pd};
                    rbuf[18] <= {7'd0, cfg_tp};
                    rbuf[19] <= {6'd0, cfg_ck};
                    t_type   <= k_type | 8'h80;
                    t_hlen   <= 7'd20;
                    t_src    <= 1'b0;
                    t_dn     <= 15'd0;
                    state    <= T_SYNC;
                end

                K_ARM: begin
                    cap_arm   <= 1'b1;
                    n_last    <= cfg_ss;
                    running   <= 1'b1;
                    abort_req <= 1'b0;
                    state     <= K_WAIT;
                end
                K_WAIT:
                    if (cap_done || abort_req) begin
                        running <= 1'b0;
                        seq     <= seq + 16'd1;
                        rbuf[0] <= cap_done ? 8'd0 : 8'd2;             // 0 ok, 2 aborted
                        rbuf[1] <= {7'd0, cap_done & cap_trig};
                        rbuf[2] <= seq[7:0];
                        rbuf[3] <= seq[15:8];
                        rbuf[4] <= sr_eff[7:0];   rbuf[5] <= sr_eff[15:8];
                        rbuf[6] <= sr_eff[23:16]; rbuf[7] <= sr_eff[31:24];
                        rbuf[8]  <= cfg_pt[7:0];  rbuf[9]  <= {1'b0, cfg_pt[14:8]};
                        if (cap_done) begin
                            have_cap <= 1'b1;
                            rbuf[10] <= n_last[7:0];
                            rbuf[11] <= {1'b0, n_last[14:8]};
                            t_dn     <= n_last;
                        end else begin
                            cap_abort <= 1'b1;
                            rbuf[10]  <= 8'd0;
                            rbuf[11]  <= 8'd0;
                            t_dn      <= 15'd0;
                        end
                        t_type <= 8'h85;
                        t_hlen <= 7'd12;
                        t_src  <= 1'b0;
                        state  <= T_SYNC;
                    end

                K_REVGO:
                    if (!rev_busy) begin
                        rev_wr_go <= 1'b1;
                        state     <= K_REVW;
                    end
                K_REVW:
                    if (rev_done) begin
                        rbuf[0] <= {7'd0, rev_err};
                        rbuf[1] <= rev[63:56]; rbuf[2] <= rev[55:48];
                        rbuf[3] <= rev[47:40]; rbuf[4] <= rev[39:32];
                        rbuf[5] <= rev[31:24]; rbuf[6] <= rev[23:16];
                        rbuf[7] <= rev[15:8];  rbuf[8] <= rev[7:0];
                        t_type  <= 8'h88;
                        t_hlen  <= 7'd9;
                        t_src   <= 1'b0;
                        t_dn    <= 15'd0;
                        state   <= T_SYNC;
                    end

                // =================================================================
                // PACKET MODE - transmit  (SYNC TYPE LEN PAYLOAD CRC)
                // =================================================================
                T_SYNC:
                    if (send_ok) begin
                        op_go   <= 1'b1;
                        op_type <= OP_CHR;
                        op_val  <= {24'd0, SYNC};
                        tcrc    <= 16'hFFFF;
                        tj      <= 7'd0;
                        k       <= 15'd0;
                        state   <= T_TYPE;
                    end
                T_TYPE:
                    if (send_ok) begin
                        op_go  <= 1'b1;
                        op_val <= {24'd0, t_type};
                        tcrc   <= crc16_upd(tcrc, t_type);
                        state  <= T_L0;
                    end
                T_L0:
                    if (send_ok) begin
                        op_go  <= 1'b1;
                        op_val <= {24'd0, t_len[7:0]};
                        tcrc   <= crc16_upd(tcrc, t_len[7:0]);
                        state  <= T_L1;
                    end
                T_L1:
                    if (send_ok) begin
                        op_go  <= 1'b1;
                        op_val <= {24'd0, t_len[15:8]};
                        tcrc   <= crc16_upd(tcrc, t_len[15:8]);
                        state  <= (t_hlen != 7'd0) ? T_HDR :
                                  (t_dn != 15'd0)  ? T_DADDR : T_C0;
                    end
                T_HDR:
                    if (send_ok) begin
                        op_go  <= 1'b1;
                        op_val <= {24'd0, t_hb};
                        tcrc   <= crc16_upd(tcrc, t_hb);
                        tj     <= tj + 7'd1;
                        if (tj + 7'd1 == t_hlen)
                            state <= (t_dn != 15'd0) ? T_DADDR : T_C0;
                    end
                T_DADDR: begin
                    rd_rel <= k[13:0];
                    state  <= T_DW1;
                end
                T_DW1: state <= T_DW2;
                T_DW2: state <= T_DATA;
                T_DATA:
                    if (send_ok) begin
                        op_go  <= 1'b1;
                        op_val <= {24'd0, rd_data};
                        tcrc   <= crc16_upd(tcrc, rd_data);
                        k      <= k + 15'd1;
                        state  <= (k + 15'd1 == t_dn) ? T_C0 : T_DADDR;
                    end
                T_C0:
                    if (send_ok) begin
                        op_go  <= 1'b1;
                        op_val <= {24'd0, tcrc[7:0]};
                        state  <= T_C1;
                    end
                T_C1:
                    if (send_ok) begin
                        op_go  <= 1'b1;
                        op_val <= {24'd0, tcrc[15:8]};
                        state  <= T_END;
                    end
                T_END:
                    if (t_exit) begin
                        if (send_ok && !tx_busy) begin
                            pmode  <= 1'b0;
                            t_exit <= 1'b0;
                            llen   <= 7'd0;
                            lto    <= 24'd0;
                            state  <= S_IDLE;
                        end
                    end else begin
                        kto   <= 24'd0;
                        state <= K_SYNC;
                    end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
