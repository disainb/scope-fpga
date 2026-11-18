`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// flash_io.v  (simulation model - NOT for synthesis)
//   Same ports as rtl/xilinx/flash_io.v, plus a behavioural SPI NOR flash
//   (mode 0, single bit) holding only the last 4 KB sector (0x3FF000).
//   Commands: 03 READ, 05 RDSR, 06 WREN, 20 SE, 02 PP.
//   WIP stays set for BUSY_POLLS status reads after an erase / program.
//   bad_access counts any erase/program outside the modelled sector or
//   without WREN; tests check that it stays 0.
// -----------------------------------------------------------------------------
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off BLKSEQ */
module flash_io (
    input  wire sck,
    input  wire cs_n,
    input  wire mosi,
    output reg  miso = 1'b1,
    output wire qspi_cs,
    output wire qspi_dq0,
    input  wire qspi_dq1,
    output wire qspi_dq2,
    output wire qspi_dq3
);
    localparam [11:0] SECTOR = 12'h3FF;
    localparam        BUSY_POLLS = 3;

    assign qspi_cs  = cs_n;
    assign qspi_dq0 = mosi;
    assign qspi_dq2 = 1'b1;
    assign qspi_dq3 = 1'b1;

    reg [7:0]  mem [0:4095];
    reg [7:0]  sh_in = 8'd0;
    reg [7:0]  sh_out = 8'hFF;
    reg [2:0]  bitn = 3'd0;
    reg [31:0] nbyte = 0;
    reg [7:0]  cmd = 8'd0;
    reg [23:0] addr = 24'd0;
    reg        wel = 1'b0;
    integer    busy = 0;
    integer    bad_access = 0;
    integer    i;

    initial for (i = 0; i < 4096; i = i + 1) mem[i] = 8'hFF;


    // byte received on the 8th rising edge
    reg [7:0] b;
    always @(posedge sck) if (!cs_n) begin
        b = {sh_in[6:0], mosi};
        sh_in = b;
        if (bitn == 3'd7) begin
            if (nbyte == 0) cmd = b;
            else if (nbyte <= 3 && (cmd == 8'h03 || cmd == 8'h02 || cmd == 8'h20))
                addr = {addr[15:0], b};
            else if (cmd == 8'h02 && nbyte > 3) begin
                if ((addr[23:12] == SECTOR) && wel) mem[addr[11:0]] = mem[addr[11:0]] & b;
                else bad_access = bad_access + 1;
                addr = addr + 1;
            end
            nbyte = nbyte + 1;
            // prepare the next output byte
            if (cmd == 8'h05)
                sh_out = {7'd0, busy > 0};
            else if (cmd == 8'h03 && nbyte >= 4) begin
                sh_out = (addr[23:12] == SECTOR) ? mem[addr[11:0]] : 8'hFF;
                addr   = addr + 1;
            end else
                sh_out = 8'hFF;
            if (cmd == 8'h05 && nbyte > 1 && busy > 0) busy = busy - 1;
        end
        bitn = bitn + 3'd1;
    end

    // shift out on falling edge (MSB first)
    always @(negedge sck) if (!cs_n) begin
        if (bitn == 3'd0) begin
            miso   <= sh_out[7];
        end else
            miso <= sh_out[7 - bitn];
    end

    always @(negedge cs_n) begin
        bitn  = 3'd0;
        nbyte = 0;
        cmd   = 8'd0;
        sh_out = 8'hFF;
    end

    always @(posedge cs_n) begin
        if (cmd == 8'h06) wel = 1'b1;
        if (cmd == 8'h20 && nbyte == 4) begin
            if (wel && addr[23:12] == SECTOR) begin
                for (i = 0; i < 4096; i = i + 1) mem[i] = 8'hFF;
                busy = BUSY_POLLS;
            end else bad_access = bad_access + 1;
            wel = 1'b0;
        end
        if (cmd == 8'h02) begin
            busy = BUSY_POLLS;
            wel  = 1'b0;
        end
    end
endmodule
