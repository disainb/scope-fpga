`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// afe_ctrl.v - analog front-end control (prototype AFE, Nov 2026 schematic)
//
//   att   : 0 = /1, 1 = /100 (K1)
//   gain  : 0 = low (x1.33), 1 = high (x13.5)  -> GAIN_HI (U3/U4 74LVC1G3157)
//   ofs   : 12-bit offset code -> PWM_OFS (100 MHz / 4096 = 24.4 kHz) ->
//           2-pole 10k/1u filter -> VOFS (U2B + input). VOFS = ofs/4096 * VCCO.
//
// K1 drive
//   K1_LATCH = 0 : non-latching relay (EE2-3NU). k1_set is a level, high = /100.
//                  k1_rst stays low.
//   K1_LATCH = 1 : latching relay through an H-bridge (v3 PCB, DRV8837):
//                  K1_PULSE_MS pulse on k1_set (-> /100) or k1_rst (-> /1).
//                  A reset pulse is sent after power-up so the state is known.
//
// Settling. Any change starts a hold-off; busy stays high until it ends and the
// controller does not arm a capture while busy.
//   relay       : K1_MS (operate + bounce), plus the pulse when latching
//   gain only   : 1 ms
//   offset code : OFS_T0_MS + OFS_TK_MS * (floor(log2 |delta|) + 1)
//                 The PWM filter's slow pole is 26 ms; this gives 0.5 LSB
//                 (8-bit ADC, high gain) after any step: 31 ms for 1 code,
//                 193 ms for the low<->high gain zero-code change, 229 ms max.
// settle_ms reports the hold-off started by the last change.
// -----------------------------------------------------------------------------
module afe_ctrl #(
    parameter integer MS_CYC      = 100_000,  // clocks per millisecond
    parameter integer K1_LATCH    = 0,
    parameter integer K1_PULSE_MS = 10,
    parameter integer K1_MS       = 5,
    parameter integer OFS_T0_MS   = 13,
    parameter integer OFS_TK_MS   = 18
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        att,
    input  wire        gain,
    input  wire [11:0] ofs,
    output reg         k1_set,
    output reg         k1_rst,
    output reg         gain_hi,
    output reg         pwm_ofs,
    output wire        busy,
    output reg  [15:0] settle_ms
);
    // ---- 1 ms tick -------------------------------------------------------------
    reg [31:0] pre;
    wire       tick = (pre == MS_CYC - 1);
    always @(posedge clk)
        if (rst || tick) pre <= 32'd0;
        else             pre <= pre + 32'd1;

    // ---- PWM -------------------------------------------------------------------------
    reg [11:0] pcnt;
    always @(posedge clk) begin
        pcnt    <= rst ? 12'd0 : pcnt + 12'd1;
        pwm_ofs <= !rst && (pcnt < ofs);
    end

    // ---- change detection (stage 1) ------------------------------------------------------
    reg        a_att, a_gain, a_init;          // applied values
    reg [11:0] a_ofs;
    wire       ch_att = (att != a_att) || a_init;
    wire       change = ch_att || (gain != a_gain) || (ofs != a_ofs);

    reg        s1_v, s1_att, s1_gain, s1_chatt, s1_chgain;
    reg [11:0] s1_ofs, s1_d;
    always @(posedge clk) begin
        s1_v      <= !rst && change;
        s1_att    <= att;
        s1_gain   <= gain;
        s1_ofs    <= ofs;
        s1_chatt  <= ch_att;
        s1_chgain <= (gain != a_gain);
        s1_d      <= (ofs > a_ofs) ? ofs - a_ofs : a_ofs - ofs;
    end

    // ---- settle time (stage 2) ---------------------------------------------------------------
    // floor(log2 d) + 1 = number of significant bits of d
    reg [3:0] nbits;
    integer i;
    always @* begin
        nbits = 4'd0;
        for (i = 0; i < 12; i = i + 1)
            if (s1_d[i]) nbits = i[3:0] + 4'd1;
    end

    localparam integer T_RLY_I = (K1_LATCH != 0) ? (K1_PULSE_MS + K1_MS) : K1_MS;
    localparam [15:0]  T_RLY   = T_RLY_I[15:0];
    localparam [15:0]  T0      = OFS_T0_MS[15:0];
    localparam [15:0]  TK      = OFS_TK_MS[15:0];
    localparam integer PULSE_I = K1_PULSE_MS + 1;
    localparam [15:0]  PULSE   = PULSE_I[15:0];
    wire [15:0] t_ofs  = (nbits == 4'd0) ? 16'd0 : T0 + TK * {12'd0, nbits};
    wire [15:0] t_rly  = s1_chatt  ? T_RLY : 16'd0;
    wire [15:0] t_gain = s1_chgain ? 16'd1 : 16'd0;
    wire [15:0] t_ra   = (t_rly > t_gain) ? t_rly : t_gain;
    wire [15:0] t_max  = (t_ofs > t_ra) ? t_ofs : t_ra;

    reg [15:0] left;       // ms of hold-off still to go
    reg [15:0] pulse;      // ms of relay pulse still to go (latching)
    assign busy = (left != 16'd0) || s1_v || change;

    always @(posedge clk) begin
        if (rst) begin
            a_att     <= 1'b0;
            a_gain    <= 1'b0;
            a_ofs     <= 12'd0;
            a_init    <= (K1_LATCH != 0);
            k1_set    <= 1'b0;
            k1_rst    <= 1'b0;
            gain_hi   <= 1'b0;
            left      <= 16'd0;
            pulse     <= 16'd0;
            settle_ms <= 16'd0;
        end else begin
            if (tick) begin
                if (left  != 16'd0) left  <= left - 16'd1;
                if (pulse != 16'd0) pulse <= pulse - 16'd1;
                else if (K1_LATCH != 0) begin
                    k1_set <= 1'b0;
                    k1_rst <= 1'b0;
                end
            end

            if (s1_v) begin
                a_att   <= s1_att;
                a_gain  <= s1_gain;
                a_ofs   <= s1_ofs;
                a_init  <= 1'b0;
                gain_hi <= s1_gain;
                // +1: the current ms is already partly gone
                if (t_max + 16'd1 > left) left <= t_max + 16'd1;
                if (t_max != 16'd0) settle_ms <= t_max;
                if (s1_chatt) begin
                    if (K1_LATCH != 0) begin
                        k1_set <= s1_att;
                        k1_rst <= ~s1_att;
                        pulse  <= PULSE;
                    end else
                        k1_set <= s1_att;
                end
            end
        end
    end
endmodule
