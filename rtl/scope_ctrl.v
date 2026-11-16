`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// scope_ctrl.v - UART command line: parse, apply settings, run captures, dump
//
// A line is a list of comma-separated tokens, ended by CR or LF (or 30 ms of
// silence, so terminals that send no line ending still work). Case-insensitive,
// spaces ignored. Token = KEY[=]VALUE, KEY is 1-2 letters:
//   SR=10MSPS  SS=1024  PT=0  OFN|OFX|OFB  TMA|TMN|TMI  TER|TEF  TL=128  TH=4
//   PH=n|PHA  PD=0|1  TP=0|1  BR=115200  R  C  D  ?  H
// Settings-only lines answer with the status line ("OK SR=..."); lines with
// R/C/D/?/H answer with their output only. An error prints "ERR at col n" and
// discards the rest of the line. While a capture or dump runs, any received
// character other than CR/LF stops it (and is otherwise dropped).
// -----------------------------------------------------------------------------
module scope_ctrl #(
    parameter SYS_HZ  = 100_000_000,
    parameter BAUD    = 115_200,
    parameter LINE_TO = 3_000_000      // idle clocks that end a line
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
    output reg  [3:0]  cfg_n,
    output reg  [23:0] cfg_d,
    output wire [4:0]  cfg_ph,
    output reg         cfg_tp,
    output reg  [14:0] cfg_ss,
    output reg  [14:0] cfg_pt,
    output reg  [1:0]  cfg_tm,
    output reg         cfg_te,
    output reg  [7:0]  cfg_tl,
    output reg  [7:0]  cfg_th,
    output reg         adc_pd,
    // capture control / readout
    output reg         cap_arm,
    output reg         cap_abort,
    input  wire        cap_done,
    input  wire        cap_trig,
    output reg  [13:0] rd_rel,
    input  wire [7:0]  rd_data,
    // status
    output reg         running,
    output reg         cont_mode
);
`include "msg_ids.vh"

    localparam [31:0] SYS  = SYS_HZ;
    localparam integer CPB0_I = SYS_HZ / BAUD;
    localparam [15:0]  CPB0   = CPB0_I[15:0];
    localparam [31:0] BR0  = BAUD;
    localparam [1:0]  OP_CHR = 2'd0, OP_DEC = 2'd1, OP_HEX = 2'd2;
    localparam [1:0]  OF_N = 2'd0, OF_X = 2'd1, OF_B = 2'd2;
    localparam [7:0]  CH_CR = 8'h0D, CH_LF = 8'h0A, CH_SP = 8'h20;

    localparam [5:0]
        S_BOOT  = 6'd0,  S_IDLE  = 6'd1,
        P_TOK   = 6'd2,  P_KEY2  = 6'd3,  P_EQ    = 6'd4,  P_VAL   = 6'd5,
        P_UNIT  = 6'd6,  P_DISP  = 6'd7,
        X_SR1   = 6'd8,  X_SR2   = 6'd9,  X_SR2W  = 6'd10, X_SR3   = 6'd11,
        X_SR3W  = 6'd12, X_SR4W  = 6'd13, X_BR1   = 6'd14,
        R_ARM   = 6'd15, R_WAIT  = 6'd16, R_AFTER = 6'd17,
        D_START = 6'd18, D_ADDR  = 6'd19, D_W1    = 6'd20, D_W2    = 6'd21,
        D_OUT   = 6'd22, D_SEP1  = 6'd23, D_SEP2  = 6'd24, D_NEXT  = 6'd25,
        L_END   = 6'd26, L_BAUD  = 6'd27, E_ERR   = 6'd28,
        M_FETCH = 6'd29, M_EMIT  = 6'd30;

    reg [5:0] state, m_ret;

    // ---- settings -------------------------------------------------------------
    reg [31:0] sr_eff, adc_hz, br_val, br_req;
    reg [1:0]  of;
    reg [4:0]  ph_val;
    reg        ph_auto;
    reg [15:0] pend_cpb;
    reg        pend_baud;

    assign cfg_ph = ph_auto ? {1'b0, cfg_n} : ph_val;

    // ---- line buffer ------------------------------------------------------------
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

    // ---- token -------------------------------------------------------------------
    reg [7:0]  key0, key1, vch;
    reg [31:0] num;
    reg        has_num, unit_set, bad;
    reg [2:0]  mcnt;
    wire [15:0] key      = {key0, key1};
    wire [31:0] num_x10  = {num[28:0], 3'b000} + {num[30:0], 1'b0};
    wire        num_big  = (num > 32'd400_000_000);

    // ---- dump ----------------------------------------------------------------------
    reg [14:0] k, n_last;
    wire       last = (k == n_last - 15'd1);

    // ---- divider -------------------------------------------------------------------
    reg         div_go;
    reg  [31:0] div_a, div_b;
    wire [31:0] div_q;
    wire        div_done;
    wire [27:0] nd_prod = cfg_n * cfg_d;

    /* verilator lint_off PINCONNECTEMPTY */
    udiv32 u_div (
        .clk(clk), .rst(rst), .start(div_go),
        .dividend(div_a), .divisor(div_b),
        .quotient(div_q), .remainder(),
        .done(div_done), .busy()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ---- message ROM ------------------------------------------------------------------
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
            V_PH:    vval = {27'd0, cfg_ph};
            V_PD:    vval = {31'd0, adc_pd};
            V_TP:    vval = {31'd0, cfg_tp};
            V_BR:    vval = br_val;
            V_TRIG:  vval = {31'd0, cap_trig};
            V_N:     vval = {28'd0, cfg_n};
            V_D:     vval = {8'd0, cfg_d};
            V_COL:   vval = {25'd0, tok_col};
            V_NLAST: vval = {17'd0, n_last};
            default: vval = 32'd0;
        endcase
    end

    reg [7:0] cval;
    always @* begin
        case (m_data[4:0])
            C_OF:    cval = (of == OF_X) ? "X" : (of == OF_B) ? "B" : "N";
            C_TM:    cval = (cfg_tm == 2'd1) ? "N" : (cfg_tm == 2'd2) ? "I" : "A";
            C_TE:    cval = cfg_te ? "F" : "R";
            default: cval = "?";
        endcase
    end

    wire send_ok = fmt_ready && !op_go;

    // ---- main state machine --------------------------------------------------------
    always @(posedge clk) begin
        op_go     <= 1'b0;
        div_go    <= 1'b0;
        cap_arm   <= 1'b0;
        cap_abort <= 1'b0;

        if (rst) begin
            state     <= S_BOOT;
            m_ret     <= S_IDLE;
            m_addr    <= MSG_BANNER;
            uart_cpb  <= CPB0;
            op_type   <= OP_CHR;
            op_val    <= 32'd0;
            cfg_n     <= 4'd10;
            cfg_d     <= 24'd1;
            cfg_tp    <= 1'b0;
            cfg_ss    <= 15'd1024;
            cfg_pt    <= 15'd0;
            cfg_tm    <= 2'd0;
            cfg_te    <= 1'b0;
            cfg_tl    <= 8'd128;
            cfg_th    <= 8'd4;
            adc_pd    <= 1'b0;
            sr_eff    <= SYS / 10;
            adc_hz    <= SYS / 10;
            br_val    <= BR0;
            br_req    <= BR0;
            of        <= OF_N;
            ph_val    <= 5'd0;
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
            k         <= 15'd0;
            n_last    <= 15'd0;
            rd_rel    <= 14'd0;
            div_a     <= 32'd0;
            div_b     <= 32'd1;
            running   <= 1'b0;
            cont_mode <= 1'b0;
        end else begin
            if (state != S_IDLE && rx_valid && !is_crlf)
                abort_req <= 1'b1;

            case (state)
                // ---------------------------------------------------------------
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
                    state    <= P_VAL;
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

                // ---- execute one token ------------------------------------------------
                P_DISP: begin
                    state <= P_TOK;
                    if (bad)
                        state <= E_ERR;
                    else case (key)
                        "SR":
                            if (has_num && num != 32'd0) begin
                                div_a  <= SYS + {1'b0, num[31:1]};
                                div_b  <= num;
                                div_go <= 1'b1;
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
                            else if (has_num && num <= 32'd19) begin
                                ph_val  <= num[4:0];
                                ph_auto <= 1'b0;
                            end else state <= E_ERR;
                        "PD":
                            if (has_num && num <= 32'd1) adc_pd <= num[0];
                            else state <= E_ERR;
                        "TP":
                            if (has_num && num <= 32'd1) cfg_tp <= num[0];
                            else state <= E_ERR;
                        "BR":
                            if (has_num && num >= 32'd1600 && num <= 32'd6_250_000) begin
                                div_a  <= SYS + {1'b0, num[31:1]};
                                div_b  <= num;
                                div_go <= 1'b1;
                                br_req <= num;
                                state  <= X_BR1;
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

                // ---- sample rate: P = round(f/SR); N = P (P<=10) else N=10, D=round(P/10)
                X_SR1:
                    if (div_done) begin
                        num   <= (div_q == 32'd0) ? 32'd1 : div_q;
                        state <= X_SR2;
                    end
                X_SR2:
                    if (num <= 32'd10) begin
                        cfg_n <= num[3:0];
                        cfg_d <= 24'd1;
                        state <= X_SR3;
                    end else begin
                        div_a  <= num + 32'd5;
                        div_b  <= 32'd10;
                        div_go <= 1'b1;
                        state  <= X_SR2W;
                    end
                X_SR2W:
                    if (div_done) begin
                        cfg_n <= 4'd10;
                        cfg_d <= (div_q > 32'd16_000_000) ? 24'd16_000_000 : div_q[23:0];
                        state <= X_SR3;
                    end
                X_SR3: begin
                    div_a  <= SYS;
                    div_b  <= {28'd0, cfg_n};
                    div_go <= 1'b1;
                    state  <= X_SR3W;
                end
                X_SR3W:
                    if (div_done) begin
                        adc_hz <= div_q;
                        div_a  <= SYS;
                        div_b  <= {4'd0, nd_prod};
                        div_go <= 1'b1;
                        state  <= X_SR4W;
                    end
                X_SR4W:
                    if (div_done) begin
                        sr_eff <= div_q;
                        state  <= P_TOK;
                    end

                // ---- baud: applied after this line's response has been sent ----------
                X_BR1:
                    if (div_done) begin
                        pend_cpb  <= div_q[15:0];
                        pend_baud <= 1'b1;
                        br_val    <= br_req;
                        state     <= P_TOK;
                    end

                // ---- run ------------------------------------------------------------------
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

                // ---- dump -------------------------------------------------------------------
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

                // ---- end of line ---------------------------------------------------------------
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

                // ---- print message from ROM, then go to m_ret --------------------------------
                M_FETCH: state <= M_EMIT;      // ROM read latency
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

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
