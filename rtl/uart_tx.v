`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// uart_tx.v - 8N1 UART transmitter, portable Verilog-2001
//   cpb = clocks per bit (runtime). Pulse 'start' for one clock while !busy;
//   'data' is captured on that edge. 'busy' rises on the following clock.
// -----------------------------------------------------------------------------
module uart_tx (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] cpb,
    input  wire [7:0]  data,
    input  wire        start,
    output reg         tx = 1'b1,
    output wire        busy
);
    reg [9:0]  sh;
    reg [3:0]  nbits;
    reg [15:0] cnt;

    assign busy = (nbits != 4'd0);

    always @(posedge clk) begin
        if (rst) begin
            tx    <= 1'b1;
            sh    <= 10'h3FF;
            nbits <= 4'd0;
            cnt   <= 16'd0;
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                sh    <= {1'b1, data, 1'b0};
                nbits <= 4'd10;
                cnt   <= 16'd0;
            end
        end else begin
            tx <= sh[0];
            if (cnt == cpb - 16'd1) begin
                cnt   <= 16'd0;
                sh    <= {1'b1, sh[9:1]};
                nbits <= nbits - 4'd1;
            end else
                cnt <= cnt + 16'd1;
        end
    end
endmodule
