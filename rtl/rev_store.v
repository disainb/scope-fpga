`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// rev_store.v - 8-character board revision kept in SPI NOR flash
//
// Record (14 bytes) at ADDR (default 0x3FF000 = last 4 KB sector of the
// Cmod A7's 32 Mbit configuration flash, far above the bitstream):
//   0..3   "SREV"
//   4..11  revision, 8 ASCII characters
//   12..13 CRC-16/CCITT-FALSE of bytes 0..11, little-endian
//
// After reset the record is read; if magic or CRC is wrong 'rev' = "--------"
// and rev_ok = 0. A write (wr_go + wr_rev) does: WREN, 4 KB sector erase,
// poll, WREN, page program, poll, read back and compare. 'done' pulses at the
// end with 'err' = 1 if anything failed (busy timeout or verify mismatch).
//
// SPI mode 0, single bit (DQ0 = MOSI, DQ1 = MISO), commands 0x03 READ,
// 0x05 RDSR, 0x06 WREN, 0x20 SE(4K), 0x02 PP - common to Micron and Macronix.
// SCK = f_clk / (2*HP).
// -----------------------------------------------------------------------------
module rev_store #(
    parameter [23:0] ADDR    = 24'h3FF000,
    parameter        HP      = 4,             // clk cycles per SCK half period
    parameter        POLL_TO = 300_000        // max RDSR polls (~0.9 s at 12.5 MHz)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_go,
    input  wire [63:0] wr_rev,        // char 0 in bits [63:56]
    output reg  [63:0] rev,
    output reg         rev_ok,
    output wire        busy,
    output reg         done,
    output reg         err,
    // SPI
    output reg         sck,
    output reg         cs_n,
    output wire        mosi,
    input  wire        miso
);
`include "crc16.vh"

    localparam [63:0] REV_BLANK = "--------";
    localparam [31:0] MAGIC     = "SREV";

    // ---- record buffer -----------------------------------------------------------
    reg  [7:0] rec [0:13];
    reg  [7:0] rbk [0:13];            // read-back
    reg [15:0] crc_acc;

    // ---- byte engine ----------------------------------------------------------------
    reg  [7:0] sh_o, sh_i;
    reg  [3:0] bitc;
    reg  [3:0] hc;
    reg        x_busy, x_high;
    reg        x_go;
    reg  [7:0] x_out;
    wire [7:0] x_in = sh_i;

    assign mosi = sh_o[7];

    always @(posedge clk) begin
        if (rst) begin
            sck    <= 1'b0;
            x_busy <= 1'b0;
            x_high <= 1'b0;
            hc     <= 4'd0;
            bitc   <= 4'd0;
            sh_o   <= 8'hFF;
            sh_i   <= 8'h00;
        end else if (x_go) begin
            sh_o   <= x_out;
            bitc   <= 4'd8;
            hc     <= 4'd0;
            x_high <= 1'b0;
            x_busy <= 1'b1;
        end else if (x_busy) begin
            if (hc == HP - 1) begin
                hc <= 4'd0;
                if (!x_high) begin                // rising edge: sample
                    sck    <= 1'b1;
                    sh_i   <= {sh_i[6:0], miso};
                    x_high <= 1'b1;
                end else begin                    // falling edge: next bit
                    sck    <= 1'b0;
                    sh_o   <= {sh_o[6:0], 1'b1};
                    x_high <= 1'b0;
                    bitc   <= bitc - 4'd1;
                    if (bitc == 4'd1) x_busy <= 1'b0;
                end
            end else
                hc <= hc + 4'd1;
        end
    end

    // ---- sequencer --------------------------------------------------------------------
    localparam [4:0]
        Q_BOOT   = 5'd0,  Q_DUMMY  = 5'd1,  Q_RD_CMD = 5'd2,  Q_RD_DAT = 5'd3,
        Q_RD_END = 5'd4,  Q_IDLE   = 5'd5,  Q_WREN   = 5'd6,  Q_SE     = 5'd7,
        Q_POLL   = 5'd8,  Q_POLLW  = 5'd9,  Q_PP     = 5'd10, Q_PP_DAT = 5'd11,
        Q_CSHI   = 5'd12, Q_VERIFY = 5'd13, Q_DONE   = 5'd14, Q_WAITX  = 5'd15,
        Q_GAP    = 5'd16;

    reg [4:0]  q, q_next, q_after_poll;
    reg [3:0]  bi;             // byte index within command
    reg [3:0]  di;             // data index 0..13
    reg        writing;        // in a write sequence (read = verify)
    reg        wr_phase;       // 0 = erase, 1 = program
    reg [19:0] polls;
    reg [7:0]  gap;
    reg [63:0] new_rev;

    assign busy = (q != Q_IDLE);

    // command byte for the current position (READ / SE / PP header)
    function [7:0] hdr_byte;
        input [7:0] cmd;
        input [3:0] idx;
        begin
            case (idx)
                4'd0:    hdr_byte = cmd;
                4'd1:    hdr_byte = ADDR[23:16];
                4'd2:    hdr_byte = ADDR[15:8];
                default: hdr_byte = ADDR[7:0];
            endcase
        end
    endfunction

    integer n;

    always @(posedge clk) begin
        x_go <= 1'b0;
        done <= 1'b0;
        if (rst) begin
            q        <= Q_BOOT;
            cs_n     <= 1'b1;
            rev      <= REV_BLANK;
            rev_ok   <= 1'b0;
            err      <= 1'b0;
            writing  <= 1'b0;
            wr_phase <= 1'b0;
            bi       <= 4'd0;
            di       <= 4'd0;
            polls    <= 20'd0;
            gap      <= 8'd0;
            q_next   <= Q_IDLE;
            q_after_poll <= Q_IDLE;
            x_out    <= 8'hFF;
            new_rev  <= 64'd0;
        end else begin
            case (q)
                // 16 SCK cycles with CS high: STARTUPE2 ignores the first
                // three USRCCLKO edges after configuration
                Q_BOOT: begin
                    cs_n  <= 1'b1;
                    x_out <= 8'hFF;
                    x_go  <= 1'b1;
                    bi    <= 4'd0;
                    q     <= Q_DUMMY;
                end
                Q_DUMMY:
                    if (!x_busy && !x_go) begin
                        if (bi == 4'd1) begin
                            writing <= 1'b0;
                            q       <= Q_RD_CMD;
                            bi      <= 4'd0;
                        end else begin
                            bi    <= bi + 4'd1;
                            x_out <= 8'hFF;
                            x_go  <= 1'b1;
                        end
                    end

                // ---- READ 14 bytes into rbk ---------------------------------------
                Q_RD_CMD:
                    if (!x_busy && !x_go) begin
                        cs_n <= 1'b0;
                        if (bi == 4'd4) begin
                            di    <= 4'd0;
                            x_out <= 8'hFF;
                            x_go  <= 1'b1;
                            q     <= Q_RD_DAT;
                        end else begin
                            x_out <= hdr_byte(8'h03, bi);
                            x_go  <= 1'b1;
                            bi    <= bi + 4'd1;
                        end
                    end
                Q_RD_DAT:
                    if (!x_busy && !x_go) begin
                        rbk[di] <= x_in;
                        if (di == 4'd13)
                            q <= Q_RD_END;
                        else begin
                            di    <= di + 4'd1;
                            x_out <= 8'hFF;
                            x_go  <= 1'b1;
                        end
                    end
                Q_RD_END: begin
                    cs_n    <= 1'b1;
                    crc_acc <= 16'hFFFF;
                    di      <= 4'd0;
                    q       <= Q_VERIFY;
                end
                Q_VERIFY:
                    // CRC over rbk[0..11], one byte per clock
                    if (di != 4'd12) begin
                        crc_acc <= crc16_upd(crc_acc, rbk[di]);
                        di      <= di + 4'd1;
                    end else begin
                        if (writing) begin
                            err <= 1'b0;
                            for (n = 0; n < 14; n = n + 1)
                                if (rbk[n] != rec[n]) err <= 1'b1;
                            q <= Q_DONE;
                        end else
                            q <= Q_IDLE;
                        if ({rbk[0], rbk[1], rbk[2], rbk[3]} == MAGIC &&
                            crc_acc == {rbk[13], rbk[12]}) begin
                            rev    <= {rbk[4], rbk[5], rbk[6], rbk[7],
                                       rbk[8], rbk[9], rbk[10], rbk[11]};
                            rev_ok <= 1'b1;
                        end else begin
                            rev    <= REV_BLANK;
                            rev_ok <= 1'b0;
                        end
                    end
                Q_DONE: begin
                    done    <= 1'b1;
                    writing <= 1'b0;
                    q       <= Q_IDLE;
                end

                // ---- idle: accept a write ------------------------------------------
                Q_IDLE:
                    if (wr_go) begin
                        new_rev  <= wr_rev;
                        writing  <= 1'b1;
                        wr_phase <= 1'b0;
                        err      <= 1'b0;
                        q        <= Q_CSHI;       // first build the record
                        di       <= 4'd0;
                        crc_acc  <= 16'hFFFF;
                        rec[0] <= MAGIC[31:24]; rec[1] <= MAGIC[23:16];
                        rec[2] <= MAGIC[15:8];  rec[3] <= MAGIC[7:0];
                        rec[4]  <= wr_rev[63:56]; rec[5]  <= wr_rev[55:48];
                        rec[6]  <= wr_rev[47:40]; rec[7]  <= wr_rev[39:32];
                        rec[8]  <= wr_rev[31:24]; rec[9]  <= wr_rev[23:16];
                        rec[10] <= wr_rev[15:8];  rec[11] <= wr_rev[7:0];
                    end

                // record CRC, then WREN
                Q_CSHI:
                    if (di != 4'd12) begin
                        crc_acc <= crc16_upd(crc_acc, rec[di]);
                        di      <= di + 4'd1;
                    end else begin
                        rec[12] <= crc_acc[7:0];
                        rec[13] <= crc_acc[15:8];
                        bi      <= 4'd0;
                        q       <= Q_WREN;
                    end

                // ---- WREN (CS low, 0x06, CS high) -------------------------------------
                Q_WREN:
                    if (!x_busy && !x_go) begin
                        if (bi == 4'd0) begin
                            cs_n  <= 1'b0;
                            x_out <= 8'h06;
                            x_go  <= 1'b1;
                            bi    <= 4'd1;
                        end else begin
                            cs_n   <= 1'b1;
                            bi     <= 4'd0;
                            gap    <= 8'd0;
                            q_next <= wr_phase ? Q_PP : Q_SE;
                            q      <= Q_GAP;
                        end
                    end
                Q_GAP:                              // CS high time between commands
                    if (gap == 8'd15) q <= q_next;
                    else              gap <= gap + 8'd1;

                // ---- SECTOR ERASE (0x20 + addr) ---------------------------------------
                Q_SE:
                    if (!x_busy && !x_go) begin
                        cs_n <= 1'b0;
                        if (bi == 4'd4) begin
                            cs_n         <= 1'b1;
                            wr_phase     <= 1'b1;
                            q_after_poll <= Q_WREN;
                            bi           <= 4'd0;
                            gap          <= 8'd0;
                            q_next       <= Q_POLL;
                            q            <= Q_GAP;
                        end else begin
                            x_out <= hdr_byte(8'h20, bi);
                            x_go  <= 1'b1;
                            bi    <= bi + 4'd1;
                        end
                    end

                // ---- PAGE PROGRAM (0x02 + addr + 14 bytes) -------------------------------
                Q_PP:
                    if (!x_busy && !x_go) begin
                        cs_n <= 1'b0;
                        if (bi == 4'd4) begin
                            di    <= 4'd0;
                            x_out <= rec[0];
                            x_go  <= 1'b1;
                            q     <= Q_PP_DAT;
                        end else begin
                            x_out <= hdr_byte(8'h02, bi);
                            x_go  <= 1'b1;
                            bi    <= bi + 4'd1;
                        end
                    end
                Q_PP_DAT:
                    if (!x_busy && !x_go) begin
                        if (di == 4'd13) begin
                            cs_n         <= 1'b1;
                            q_after_poll <= Q_RD_CMD;
                            bi           <= 4'd0;
                            gap          <= 8'd0;
                            q_next       <= Q_POLL;
                            q            <= Q_GAP;
                        end else begin
                            di    <= di + 4'd1;
                            x_out <= rec[di + 4'd1];
                            x_go  <= 1'b1;
                        end
                    end

                // ---- poll status register until WIP = 0 -----------------------------------
                Q_POLL:
                    if (!x_busy && !x_go) begin
                        cs_n  <= 1'b0;
                        x_out <= 8'h05;
                        x_go  <= 1'b1;
                        polls <= 20'd0;
                        q     <= Q_POLLW;
                    end
                Q_POLLW:
                    if (!x_busy && !x_go) begin
                        if (polls != 20'd0 && !x_in[0]) begin   // WIP clear
                            cs_n <= 1'b1;
                            bi   <= 4'd0;
                            gap  <= 8'd0;
                            q_next <= q_after_poll;
                            q    <= Q_GAP;
                        end else if (polls == POLL_TO) begin
                            cs_n <= 1'b1;
                            err  <= 1'b1;
                            q    <= Q_WAITX;
                        end else begin
                            polls <= polls + 20'd1;
                            x_out <= 8'hFF;
                            x_go  <= 1'b1;
                        end
                    end
                Q_WAITX: begin                       // timeout: report error
                    done    <= 1'b1;
                    writing <= 1'b0;
                    q       <= Q_IDLE;
                end
                default: q <= Q_IDLE;
            endcase
        end
    end

    wire unused = &{1'b0, new_rev};
endmodule
