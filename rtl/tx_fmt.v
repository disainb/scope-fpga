`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tx_fmt.v - formats one value per request and feeds uart_tx
//   typ 0 = CHAR : send val[7:0]
//   typ 1 = DEC  : send val as unsigned decimal, no leading zeros
//   typ 2 = HEX2 : send val[7:0] as two upper-case hex digits
//   Pulse 'go' while 'ready' is high. 'ready' drops on the next clock.
// -----------------------------------------------------------------------------
module tx_fmt (
    input  wire        clk,
    input  wire        rst,
    input  wire        go,
    input  wire [1:0]  typ,
    input  wire [31:0] val,
    output wire        ready,
    output reg         tx_start,
    output reg  [7:0]  tx_byte,
    input  wire        tx_busy
);
    localparam [2:0] F_IDLE = 3'd0, F_SEND = 3'd1, F_WAIT = 3'd2,
                     F_DIVW = 3'd3, F_POP  = 3'd4;

    reg [2:0]  st;
    reg [7:0]  next_byte;
    reg        have_next;
    reg [3:0]  ndig;
    reg [3:0]  dig [0:9];

    reg         div_go;
    reg  [31:0] div_a;
    wire [31:0] div_q, div_r;
    wire        div_done;

    /* verilator lint_off PINCONNECTEMPTY */
    udiv32 u_div (
        .clk(clk), .rst(rst), .start(div_go),
        .dividend(div_a), .divisor(32'd10),
        .quotient(div_q), .remainder(div_r),
        .done(div_done), .busy()
    );
    /* verilator lint_on PINCONNECTEMPTY */
    wire unused_r = &{1'b0, div_r[31:4]};

    function [7:0] hexc(input [3:0] n);
        hexc = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
    endfunction

    assign ready = (st == F_IDLE);

    always @(posedge clk) begin
        tx_start <= 1'b0;
        div_go   <= 1'b0;
        if (rst) begin
            st        <= F_IDLE;
            tx_byte   <= 8'd0;
            next_byte <= 8'd0;
            have_next <= 1'b0;
            ndig      <= 4'd0;
            div_a     <= 32'd0;
        end else begin
            case (st)
                F_IDLE:
                    if (go) begin
                        have_next <= 1'b0;
                        ndig      <= 4'd0;
                        case (typ)
                            2'd1: begin
                                div_a  <= val;
                                div_go <= 1'b1;
                                st     <= F_DIVW;
                            end
                            2'd2: begin
                                tx_byte   <= hexc(val[7:4]);
                                next_byte <= hexc(val[3:0]);
                                have_next <= 1'b1;
                                st        <= F_SEND;
                            end
                            default: begin
                                tx_byte <= val[7:0];
                                st      <= F_SEND;
                            end
                        endcase
                    end
                F_DIVW:
                    if (div_done) begin
                        dig[ndig] <= div_r[3:0];
                        ndig      <= ndig + 4'd1;
                        if (div_q == 32'd0)
                            st <= F_POP;
                        else begin
                            div_a  <= div_q;
                            div_go <= 1'b1;
                        end
                    end
                F_POP: begin
                    tx_byte <= 8'h30 + {4'd0, dig[ndig - 4'd1]};
                    ndig    <= ndig - 4'd1;
                    st      <= F_SEND;
                end
                F_SEND:
                    if (!tx_busy) begin
                        tx_start <= 1'b1;
                        st       <= F_WAIT;
                    end
                default: begin // F_WAIT: let uart_tx raise busy
                    if (have_next) begin
                        tx_byte   <= next_byte;
                        have_next <= 1'b0;
                        st        <= F_SEND;
                    end else if (ndig != 4'd0)
                        st <= F_POP;
                    else
                        st <= F_IDLE;
                end
            endcase
        end
    end
endmodule
