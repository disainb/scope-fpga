`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// capture.v - ADC clock generation, sample selection, decimation, trigger and
//             circular capture buffer.  Portable Verilog-2001.
//
// Clock domains
//   clk_cap (200 MHz) : ADC clock pattern, data capture, trigger, buffer write
//   clk     (100 MHz) : control (arm/abort/done handshake) and buffer readout
//   Both come from the same MMCM (phase aligned). Configuration inputs are
//   quasi-static: the controller only changes them while no capture runs.
//   arm / abort / done cross the domains as toggles through 2-FF synchronisers.
//
// ADC clock : f_cap / M  (M = cfg_m, 1..20)  -> 200, 100, 66.7, 50 ... 10 MHz,
//   produced as an ODDR pattern (clk_d1 = level for the high half of clk_cap,
//   clk_d2 = low half), so odd M still gives 50 % duty.
// Capture   : the I/O wrapper samples the data bus on both clk_cap edges
//   (IDDR), giving 2*M candidate points per ADC period, 2.5 ns apart. cfg_ph
//   picks one: bit0 = falling-edge sample, bits[5:1] = cycle within the period.
// Decimation: keep 1 of every D ADC samples (cfg_dm1 = D-1).
// Buffer    : 2^AW samples. 'arm' -> collect cfg_pt pre-trigger samples ->
//   wait for trigger -> collect cfg_post (= SS-PT-1) more -> 'done'.
//   Readout rd_rel = 0..SS-1 on clk (1 cycle latency); sample cfg_pt is the
//   trigger sample.
// -----------------------------------------------------------------------------
module capture #(
    parameter AW      = 14,
    parameter AUTO_TO = 20_000_000       // auto-trigger timeout, clk_cap cycles
) (
    input  wire          clk,            // 100 MHz control / readout
    input  wire          clk_cap,        // 200 MHz capture
    input  wire          rst,            // synchronous to clk
    // configuration (quasi-static)
    input  wire [4:0]    cfg_m,
    input  wire [23:0]   cfg_dm1,
    input  wire [5:0]    cfg_ph,
    input  wire          cfg_tp,
    input  wire [AW:0]   cfg_pt,
    input  wire [AW:0]   cfg_post,
    input  wire [1:0]    cfg_tm,         // 0 auto, 1 normal, 2 immediate
    input  wire          cfg_te,         // 0 rising, 1 falling
    input  wire [7:0]    cfg_tl,
    input  wire [7:0]    cfg_th,
    input  wire [1:0]    cfg_ck,         // 0 run, 1 hold low, 2 hold high
    // to / from the I/O wrapper (clk_cap domain)
    output reg           clk_d1,
    output reg           clk_d2,
    input  wire [7:0]    q_rise,
    input  wire [7:0]    q_fall,
    output reg  [7:0]    bus_now,
    // control (clk domain)
    input  wire          arm,
    input  wire          abort,
    output reg           done,
    output reg           trig_real,      // 1 = trigger met, 0 = forced / immediate
    // readout (clk domain)
    input  wire [AW-1:0] rd_rel,
    output reg  [7:0]    rd_data
);
    localparam [1:0] TM_AUTO = 2'd0, TM_IMM = 2'd2;
    localparam [1:0] C_IDLE = 2'd0, C_PRE = 2'd1, C_WAIT = 2'd2, C_POST = 2'd3;

    // ======================================================================
    // control handshake
    // ======================================================================
    reg arm_t = 1'b0, abort_t = 1'b0;            // clk: toggles
    always @(posedge clk) begin
        if (arm)   arm_t   <= ~arm_t;
        if (abort) abort_t <= ~abort_t;
    end

    (* ASYNC_REG = "TRUE" *) reg [1:0] arm_s = 2'b00, abort_s = 2'b00, rst_s = 2'b11;
    reg arm_q = 1'b0, abort_q = 1'b0;
    always @(posedge clk_cap) begin
        arm_s   <= {arm_s[0], arm_t};
        abort_s <= {abort_s[0], abort_t};
        rst_s   <= {rst_s[0], rst};
        arm_q   <= arm_s[1];
        abort_q <= abort_s[1];
    end
    wire c_rst   = rst_s[1];
    wire c_arm   = arm_s[1] ^ arm_q;
    wire c_abort = abort_s[1] ^ abort_q;

    reg done_t = 1'b0;                           // clk_cap: toggle
    (* ASYNC_REG = "TRUE" *) reg [1:0] done_s = 2'b00;
    reg done_q = 1'b0;
    always @(posedge clk) begin
        done_s <= {done_s[0], done_t};
        done_q <= done_s[1];
        done   <= done_s[1] ^ done_q;
    end

    // ======================================================================
    // configuration, re-registered on clk_cap
    //   The 100 -> 200 MHz crossing is then a plain register-to-register hop;
    //   derived values (thresholds, phase select) get their own register stage.
    // ======================================================================
    reg  [4:0]  m_c = 5'd1, half_c = 5'd0, sel_c = 5'd0;
    reg         mod_c = 1'b1;
    reg  [23:0] dm1_c = 24'd0;
    reg  [5:0]  ph_c = 6'd0;
    reg         tp_c = 1'b0, te_c = 1'b0;
    reg  [AW:0] pt_c = {(AW+1){1'b0}}, post_c = {(AW+1){1'b0}};
    reg  [1:0]  tm_c = 2'd0, ck_c = 2'd0;
    reg  [7:0]  tl_c = 8'd128, th_c = 8'd0, lo_c = 8'd128, hi_c = 8'd128;

    wire [8:0] lo_s = {1'b0, tl_c} - {1'b0, th_c};
    wire [8:0] hi_s = {1'b0, tl_c} + {1'b0, th_c};

    always @(posedge clk_cap) begin
        // stage 1: copies
        m_c    <= (cfg_m == 5'd0) ? 5'd1 : cfg_m;
        dm1_c  <= cfg_dm1;
        ph_c   <= cfg_ph;
        tp_c   <= cfg_tp;
        pt_c   <= cfg_pt;
        post_c <= cfg_post;
        tm_c   <= cfg_tm;
        te_c   <= cfg_te;
        tl_c   <= cfg_tl;
        th_c   <= cfg_th;
        ck_c   <= cfg_ck;
        // stage 2: derived
        half_c <= {1'b0, m_c[4:1]};
        mod_c  <= m_c[0];
        sel_c  <= (ph_c[5:1] >= m_c) ? m_c - 5'd1 : ph_c[5:1];
        lo_c   <= lo_s[8] ? 8'h00 : lo_s[7:0];
        hi_c   <= hi_s[8] ? 8'hFF : hi_s[7:0];
    end

    // ======================================================================
    // ADC clock pattern (clk_cap)
    // ======================================================================
    reg  [4:0] pc   = 5'd0;

    always @(posedge clk_cap) begin
        if (c_rst || pc >= m_c - 5'd1) pc <= 5'd0;
        else                           pc <= pc + 5'd1;
        if (ck_c == 2'd0) begin
            clk_d1 <= (pc < half_c) || (mod_c && pc == half_c);
            clk_d2 <= (pc < half_c);
        end else begin
            clk_d1 <= ck_c[1];
            clk_d2 <= ck_c[1];
        end
        bus_now <= q_rise;
    end

    // ======================================================================
    // sample select and decimation (clk_cap)
    // ======================================================================
    reg        s0_valid = 1'b0;
    reg  [7:0] s0_data;
    reg [23:0] dcnt = 24'd0;
    reg        s_valid = 1'b0;
    reg  [7:0] s_data = 8'd0;
    reg  [7:0] ramp = 8'd0;

    always @(posedge clk_cap) begin
        s0_valid <= (pc == sel_c);
        s0_data  <= ph_c[0] ? q_fall : q_rise;
        s_valid  <= 1'b0;
        if (c_rst) begin
            dcnt <= 24'd0;
            ramp <= 8'd0;
        end else if (s0_valid) begin
            if (dcnt == dm1_c) begin
                dcnt    <= 24'd0;
                s_valid <= 1'b1;
                s_data  <= tp_c ? ramp : s0_data;
                ramp    <= ramp + 8'd1;
            end else
                dcnt <= dcnt + 24'd1;
        end
    end

    // ======================================================================
    // trigger (clk_cap)
    // ======================================================================
    reg  edge_armed = 1'b0;
    wire arm_cond = te_c ? (s_data >= hi_c) : (s_data <= lo_c);
    wire at_level = te_c ? (s_data <= tl_c) : (s_data >= tl_c);
    wire hit      = edge_armed && at_level;

    // ======================================================================
    // capture state machine (clk_cap)
    // ======================================================================
    reg [1:0]    st = C_IDLE;
    reg [AW-1:0] wp = {AW{1'b0}};
    reg [AW-1:0] start_a = {AW{1'b0}};
    reg [AW:0]   cnt = {(AW+1){1'b0}};
    reg [25:0]   to_cnt = 26'd0;
    reg          force_t = 1'b0;
    reg          trig_c = 1'b0;

    wire we = s_valid && (st != C_IDLE) && !c_arm && !c_abort;

    always @(posedge clk_cap) begin
        if (c_rst) begin
            st         <= C_IDLE;
            trig_c     <= 1'b0;
            force_t    <= 1'b0;
            edge_armed <= 1'b0;
        end else if (c_abort) begin
            st <= C_IDLE;
        end else if (c_arm) begin
            st         <= (pt_c == {(AW+1){1'b0}}) ? C_WAIT : C_PRE;
            cnt        <= pt_c;                  // pre-trigger samples to go
            to_cnt     <= 26'd0;
            force_t    <= 1'b0;
            edge_armed <= 1'b0;
            trig_c     <= 1'b0;
        end else begin
            if (st == C_WAIT && tm_c == TM_AUTO && !force_t) begin
                if (to_cnt == AUTO_TO - 1) force_t <= 1'b1;
                else                       to_cnt  <= to_cnt + 26'd1;
            end
            if (we) begin
                wp <= wp + 1'b1;
                // arm below (rising) / above (falling) the hysteresis band; a crossing that
                // happens during the pre-trigger samples uses the arming up, so the trigger
                // is always a real crossing after the pre-trigger window
                if (arm_cond)                     edge_armed <= 1'b1;
                else if (st == C_PRE && at_level) edge_armed <= 1'b0;
                case (st)
                    C_PRE: begin
                        cnt <= cnt - 1'b1;
                        if (cnt == {{AW{1'b0}}, 1'b1}) st <= C_WAIT;
                    end
                    C_WAIT:
                        if (tm_c == TM_IMM || hit || force_t) begin
                            start_a <= wp - pt_c[AW-1:0];
                            trig_c  <= hit && (tm_c != TM_IMM);
                            if (post_c == {(AW+1){1'b0}}) begin
                                st     <= C_IDLE;
                                done_t <= ~done_t;
                            end else begin
                                cnt <= post_c;
                                st  <= C_POST;
                            end
                        end
                    default: begin // C_POST
                        cnt <= cnt - 1'b1;
                        if (cnt == {{AW{1'b0}}, 1'b1}) begin
                            st     <= C_IDLE;
                            done_t <= ~done_t;
                        end
                    end
                endcase
            end
        end
    end

    // trig flag: static once done has been signalled
    always @(posedge clk) trig_real <= trig_c;

    // ======================================================================
    // buffer: simple dual-port block RAM, write on clk_cap, read on clk
    // ======================================================================
    reg [7:0] mem [0:(1<<AW)-1];
    wire [AW-1:0] rd_a = start_a + rd_rel;

    always @(posedge clk_cap)
        if (we) mem[wp] <= s_data;

    always @(posedge clk)
        rd_data <= mem[rd_a];
endmodule
