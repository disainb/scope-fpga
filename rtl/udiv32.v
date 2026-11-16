`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// udiv32.v - sequential unsigned 32/32 divider (restoring, 1 bit per clock)
//   Pulse 'start' with operands; 'done' pulses 32 clocks later and quotient /
//   remainder stay valid until the next start. A start while busy restarts.
//   Divide by zero returns quotient = all ones.
// -----------------------------------------------------------------------------
module udiv32 (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] dividend,
    input  wire [31:0] divisor,
    output wire [31:0] quotient,
    output wire [31:0] remainder,
    output reg         done,
    output wire        busy
);
    reg [5:0]  cnt;
    reg [31:0] q;
    reg [31:0] d;
    reg [31:0] r;

    wire [32:0] r_sh = {r, q[31]};
    wire [32:0] diff = r_sh - {1'b0, d};

    assign busy      = (cnt != 6'd0);
    assign quotient  = q;
    assign remainder = r;

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            cnt <= 6'd0;
            q   <= 32'd0;
            d   <= 32'd0;
            r   <= 32'd0;
        end else if (start) begin
            q   <= dividend;
            d   <= divisor;
            r   <= 32'd0;
            cnt <= 6'd32;
        end else if (cnt != 6'd0) begin
            if (!diff[32]) begin
                r <= diff[31:0];
                q <= {q[30:0], 1'b1};
            end else begin
                r <= r_sh[31:0];
                q <= {q[30:0], 1'b0};
            end
            cnt <= cnt - 6'd1;
            if (cnt == 6'd1) done <= 1'b1;
        end
    end
endmodule
