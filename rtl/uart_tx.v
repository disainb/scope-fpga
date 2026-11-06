`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// uart_tx.v - 8N1 UART transmitter, portable Verilog-2001
//   Pulse 'start' for one clock while !busy; 'data' is captured on that edge.
// -----------------------------------------------------------------------------
module uart_tx #(
    parameter CLKS_PER_BIT = 868
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       start,
    output reg        tx = 1'b1,
    output wire       busy
);
    localparam CW = $clog2(CLKS_PER_BIT);
    localparam [CW-1:0] FULL = CLKS_PER_BIT - 1;

    reg [9:0]    sh;      // {stop, data[7:0], start}
    reg [3:0]    nbits;   // bits left to send
    reg [CW-1:0] cnt;

    assign busy = (nbits != 4'd0);

    always @(posedge clk) begin
        if (rst) begin
            tx    <= 1'b1;
            sh    <= 10'h3FF;
            nbits <= 4'd0;
            cnt   <= {CW{1'b0}};
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                sh    <= {1'b1, data, 1'b0};
                nbits <= 4'd10;
                cnt   <= {CW{1'b0}};
            end
        end else begin
            tx <= sh[0];
            if (cnt == FULL) begin
                cnt   <= {CW{1'b0}};
                sh    <= {1'b1, sh[9:1]};
                nbits <= nbits - 1'b1;
            end else
                cnt <= cnt + 1'b1;
        end
    end
endmodule
