`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// reset_sync.v - asynchronous assert, synchronous de-assert reset (active high)
// -----------------------------------------------------------------------------
module reset_sync #(
    parameter STAGES = 3
) (
    input  wire clk,
    input  wire arst,   // async, active high
    output wire rst     // sync to clk, active high
);
    reg [STAGES-1:0] r = {STAGES{1'b1}};
    always @(posedge clk or posedge arst) begin
        if (arst) r <= {STAGES{1'b1}};
        else      r <= {r[STAGES-2:0], 1'b0};
    end
    assign rst = r[STAGES-1];
endmodule
