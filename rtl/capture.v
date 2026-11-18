`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// capture.v - ADC clock generation, sample selection, decimation, trigger and
//             circular capture buffer. Portable; everything runs on clk (100 MHz).
//
// ADC clock: f_clk / N  (N = cfg_n, 1..10), produced as an ODDR pattern
//   (clk_d1 = level for the high half of clk, clk_d2 = low half), so odd N
//   still gives 50 % duty: 100, 50, 33.3, 25, 20, 16.7, 14.3, 12.5, 11.1, 10 MHz.
//
// Capture: the I/O wrapper samples the data bus on both clk edges (IDDR), so
//   every ADC period offers 2*N candidate points, 5 ns apart. cfg_ph picks one
//   (bit0 = falling-edge sample, bits[4:1] = clk cycle within the ADC period).
//
// Decimation: keep 1 of every cfg_d ADC samples (sample rate = f_clk/(N*D)).
//
// Buffer: 2^AW samples, written continuously while armed. 'arm' starts a
//   capture: cfg_pt pre-trigger samples are collected, then the trigger is
//   searched, then SS-PT-1 post-trigger samples. 'done' pulses at the end.
//   Read back with rd_rel = 0..SS-1 (1 clock latency); sample cfg_pt is the
//   trigger sample.
// -----------------------------------------------------------------------------
module capture #(
    parameter AW      = 14,
    parameter AUTO_TO = 10_000_000      // auto-trigger timeout in clk cycles
) (
    input  wire          clk,
    input  wire          rst,
    // configuration (hold stable while busy)
    input  wire [3:0]    cfg_n,
    input  wire [23:0]   cfg_d,
    input  wire [4:0]    cfg_ph,
    input  wire          cfg_tp,
    input  wire [AW:0]   cfg_ss,
    input  wire [AW:0]   cfg_pt,
    input  wire [1:0]    cfg_tm,         // 0 auto, 1 normal, 2 immediate
    input  wire          cfg_te,         // 0 rising, 1 falling
    input  wire [7:0]    cfg_tl,
    input  wire [7:0]    cfg_th,
    input  wire [1:0]    cfg_ck,         // 0 run, 1 hold low, 2 hold high
    // to / from the I/O wrapper
    output reg           clk_d1,
    output reg           clk_d2,
    input  wire [7:0]    q_rise,
    input  wire [7:0]    q_fall,
    output reg  [7:0]    bus_now,        // raw data pins, for bring-up
    // control
    input  wire          arm,
    input  wire          abort,
    output reg           busy,
    output reg           done,
    output reg           trig_real,      // 1 = trigger condition met, 0 = forced
    // readout
    input  wire [AW-1:0] rd_rel,
    output reg  [7:0]    rd_data
);
    localparam [1:0] TM_AUTO = 2'd0, TM_IMM = 2'd2;
    localparam [1:0] C_IDLE = 2'd0, C_PRE = 2'd1, C_WAIT = 2'd2, C_POST = 2'd3;

    // ---- ADC clock pattern ----------------------------------------------------
    wire [3:0] nn   = (cfg_n == 4'd0) ? 4'd1 : cfg_n;
    wire [3:0] half = {1'b0, nn[3:1]};
    reg  [3:0] pc;

    always @(posedge clk) begin
        if (rst || pc >= nn - 4'd1) pc <= 4'd0;
        else                        pc <= pc + 4'd1;
        if (cfg_ck == 2'd0) begin
            clk_d1 <= (pc < half) || (nn[0] && pc == half);
            clk_d2 <= (pc < half);
        end else begin
            clk_d1 <= cfg_ck[1];
            clk_d2 <= cfg_ck[1];
        end
        bus_now <= q_rise;
    end

    // ---- sample select and decimation -----------------------------------------
    wire [3:0] sel_c = (cfg_ph[4:1] >= nn) ? nn - 4'd1 : cfg_ph[4:1];

    reg        s0_valid;
    reg  [7:0] s0_data;
    reg [23:0] dcnt;
    reg        s_valid;
    reg  [7:0] s_data;
    reg  [7:0] ramp;

    always @(posedge clk) begin
        s0_valid <= (pc == sel_c);
        s0_data  <= cfg_ph[0] ? q_fall : q_rise;
        s_valid  <= 1'b0;
        if (rst) begin
            dcnt <= 24'd0;
            ramp <= 8'd0;
        end else if (s0_valid) begin
            if (dcnt >= cfg_d - 24'd1) begin
                dcnt    <= 24'd0;
                s_valid <= 1'b1;
                s_data  <= cfg_tp ? ramp : s0_data;
                ramp    <= ramp + 8'd1;
            end else
                dcnt <= dcnt + 24'd1;
        end
    end

    // ---- trigger ----------------------------------------------------------------
    wire [8:0] lo_s = {1'b0, cfg_tl} - {1'b0, cfg_th};
    wire [8:0] hi_s = {1'b0, cfg_tl} + {1'b0, cfg_th};
    wire [7:0] lo   = lo_s[8] ? 8'h00 : lo_s[7:0];
    wire [7:0] hi   = hi_s[8] ? 8'hFF : hi_s[7:0];

    reg edge_armed;
    wire arm_cond = cfg_te ? (s_data >= hi) : (s_data <= lo);
    wire hit      = edge_armed && (cfg_te ? (s_data <= cfg_tl) : (s_data >= cfg_tl));

    // ---- capture state machine --------------------------------------------------
    reg [1:0]    st;
    reg [AW-1:0] wp;
    reg [AW-1:0] start_a;
    reg [AW:0]   cnt;
    reg [31:0]   to_cnt;
    reg          force_t;

    wire [AW:0] post_n = cfg_ss - cfg_pt - 1'b1;
    wire        we     = s_valid && (st != C_IDLE) && !arm && !abort;

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            st         <= C_IDLE;
            busy       <= 1'b0;
            trig_real  <= 1'b0;
            wp         <= {AW{1'b0}};
            start_a    <= {AW{1'b0}};
            cnt        <= {(AW+1){1'b0}};
            to_cnt     <= 32'd0;
            force_t    <= 1'b0;
            edge_armed <= 1'b0;
        end else if (abort) begin
            st   <= C_IDLE;
            busy <= 1'b0;
        end else if (arm) begin
            st         <= (cfg_pt == {(AW+1){1'b0}}) ? C_WAIT : C_PRE;
            busy       <= 1'b1;
            cnt        <= {(AW+1){1'b0}};
            to_cnt     <= 32'd0;
            force_t    <= 1'b0;
            edge_armed <= 1'b0;
            trig_real  <= 1'b0;
        end else begin
            if (st == C_WAIT && cfg_tm == TM_AUTO && !force_t) begin
                if (to_cnt >= AUTO_TO - 1) force_t <= 1'b1;
                else                       to_cnt  <= to_cnt + 32'd1;
            end
            if (we) begin
                wp <= wp + 1'b1;
                if (arm_cond) edge_armed <= 1'b1;
                case (st)
                    C_PRE: begin
                        cnt <= cnt + 1'b1;
                        if (cnt + 1'b1 == cfg_pt) st <= C_WAIT;
                    end
                    C_WAIT:
                        if (cfg_tm == TM_IMM || hit || force_t) begin
                            start_a   <= wp - cfg_pt[AW-1:0];
                            trig_real <= hit && (cfg_tm != TM_IMM);
                            if (post_n == {(AW+1){1'b0}}) begin
                                st   <= C_IDLE;
                                busy <= 1'b0;
                                done <= 1'b1;
                            end else begin
                                cnt <= post_n;
                                st  <= C_POST;
                            end
                        end
                    default: begin // C_POST
                        cnt <= cnt - 1'b1;
                        if (cnt == {{AW{1'b0}}, 1'b1}) begin
                            st   <= C_IDLE;
                            busy <= 1'b0;
                            done <= 1'b1;
                        end
                    end
                endcase
            end
        end
    end

    // ---- buffer (inferred simple dual-port block RAM) ----------------------------
    reg [7:0] mem [0:(1<<AW)-1];
    wire [AW-1:0] rd_a = start_a + rd_rel;

    always @(posedge clk) begin
        if (we) mem[wp] <= s_data;
        rd_data <= mem[rd_a];
    end
endmodule
