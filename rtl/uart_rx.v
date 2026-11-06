`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// uart_rx.v - 8N1 UART receiver, portable Verilog-2001
//   CLKS_PER_BIT = f_clk / baud  (100 MHz / 115200 -> 868)
//   Input is double-registered for metastability. Samples at mid-bit.
//   'valid' pulses for one clock when 'data' holds a byte with a good stop bit.
// -----------------------------------------------------------------------------
module uart_rx #(
    parameter CLKS_PER_BIT = 868
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid
);
    localparam CW = $clog2(CLKS_PER_BIT);
    localparam [CW-1:0] FULL = CLKS_PER_BIT - 1;
    localparam [CW-1:0] HALF = CLKS_PER_BIT / 2 - 1;

    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    // synchroniser, idle-high initial state
    reg rx_meta = 1'b1;
    reg rx_s    = 1'b1;
    always @(posedge clk) begin
        rx_meta <= rx;
        rx_s    <= rx_meta;
    end

    reg [1:0]    state;
    reg [CW-1:0] cnt;
    reg [2:0]    bitn;
    reg [7:0]    sh;

    always @(posedge clk) begin
        valid <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
            cnt   <= {CW{1'b0}};
            bitn  <= 3'd0;
            sh    <= 8'd0;
            data  <= 8'd0;
        end else begin
            case (state)
                S_IDLE:
                    if (!rx_s) begin
                        cnt   <= {CW{1'b0}};
                        state <= S_START;
                    end
                S_START:  // wait to middle of start bit, re-check it
                    if (cnt == HALF) begin
                        cnt   <= {CW{1'b0}};
                        bitn  <= 3'd0;
                        state <= rx_s ? S_IDLE : S_DATA;  // glitch -> back to idle
                    end else
                        cnt <= cnt + 1'b1;
                S_DATA:   // LSB first
                    if (cnt == FULL) begin
                        cnt  <= {CW{1'b0}};
                        sh   <= {rx_s, sh[7:1]};
                        bitn <= bitn + 1'b1;
                        if (bitn == 3'd7) state <= S_STOP;
                    end else
                        cnt <= cnt + 1'b1;
                S_STOP:
                    if (cnt == FULL) begin
                        state <= S_IDLE;
                        if (rx_s) begin   // framing error -> byte dropped
                            data  <= sh;
                            valid <= 1'b1;
                        end
                    end else
                        cnt <= cnt + 1'b1;
            endcase
        end
    end
endmodule
