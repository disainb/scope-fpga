// crc16.vh - CRC-16/CCITT-FALSE, one byte per call (MSB first)
//   poly 0x1021, init 0xFFFF, no reflection, no final XOR
//   check: "123456789" -> 0x29B1
// Include inside a module body.
/* verilator lint_off BLKSEQ */
function [15:0] crc16_upd;
    input [15:0] c;
    input [7:0]  d;
    integer i;
    reg [15:0] x;
    begin
        x = c ^ {d, 8'h00};
        for (i = 0; i < 8; i = i + 1)
            x = x[15] ? ({x[14:0], 1'b0} ^ 16'h1021) : {x[14:0], 1'b0};
        crc16_upd = x;
    end
endfunction
/* verilator lint_on BLKSEQ */
