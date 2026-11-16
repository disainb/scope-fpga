`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// uart_rx.v - 8N1 UART receiver, portable Verilog-2001
//   cpb = clocks per bit = f_clk / baud (runtime, >= 16)
//   Input is double-registered for metastability. Samples at mid-bit.
//   'valid' pulses for one clock when 'data' holds a byte with a good stop bit.
// -----------------------------------------------------------------------------
module uart_rx (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] cpb,
    input  wire        rx,
    output reg  [7:0]  data,
    output reg         valid
);
    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    wire [15:0] full = cpb - 16'd1;
    wire [15:0] half = {1'b0, cpb[15:1]} - 16'd1;

    reg rx_meta = 1'b1;
    reg rx_s    = 1'b1;
    always @(posedge clk) begin
        rx_meta <= rx;
        rx_s    <= rx_meta;
    end

    reg [1:0]  state;
    reg [15:0] cnt;
    reg [2:0]  bitn;
    reg [7:0]  sh;

    always @(posedge clk) begin
        valid <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
            cnt   <= 16'd0;
            bitn  <= 3'd0;
            sh    <= 8'd0;
            data  <= 8'd0;
        end else begin
            case (state)
                S_IDLE:
                    if (!rx_s) begin
                        cnt   <= 16'd0;
                        state <= S_START;
                    end
                S_START:
                    if (cnt == half) begin
                        cnt   <= 16'd0;
                        bitn  <= 3'd0;
                        state <= rx_s ? S_IDLE : S_DATA;
                    end else
                        cnt <= cnt + 16'd1;
                S_DATA:
                    if (cnt == full) begin
                        cnt  <= 16'd0;
                        sh   <= {rx_s, sh[7:1]};
                        bitn <= bitn + 3'd1;
                        if (bitn == 3'd7) state <= S_STOP;
                    end else
                        cnt <= cnt + 16'd1;
                default: // S_STOP
                    if (cnt == full) begin
                        state <= S_IDLE;
                        if (rx_s) begin
                            data  <= sh;
                            valid <= 1'b1;
                        end
                    end else
                        cnt <= cnt + 16'd1;
            endcase
        end
    end
endmodule
