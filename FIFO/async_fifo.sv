// =============================================================================
// File: async_fifo.sv
// Description: Asynchronous FIFO (Gray-coded pointers + Two-FF synchronizers)
// Parameters:
//   DATA_WIDTH : data bus width (default 8)
//   DEPTH      : FIFO depth (power-of-2 for gray code, default 8)
// Key implementation notes:
//   1. Gray code  — only 1 bit changes per increment, safe for 2-FF synchronization.
//   2. Full/Empty check — wr_ptr equals rd_ptr (address same)
//                         MSB opposite:Full / Exactly same:Empty
//   3. Storage is a simple register array
// =============================================================================

module async_fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH      = 8
)(
    // Write domain
    input                  wr_clk,
    input                  wr_rst_n,
    input                  wr_en,
    input [DATA_WIDTH-1:0] wr_data,
    output reg             full,

    // Read domain
    input                       rd_clk,
    input                       rd_rst_n,
    input                       rd_en,
    output reg [DATA_WIDTH-1:0] rd_data,
    output reg                  empty
);
    //FIFO storage
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    //Write and read pointers
    localparam int PTR_W = $clog2(DEPTH);
    reg [PTR_W:0] wr_ptr_bin, wr_ptr_gray, wr_ptr_gray_sync;//after 2-FF synchronization
    reg [PTR_W:0] rd_ptr_bin, rd_ptr_gray, rd_ptr_gray_sync;//after 2-FF synchronization
    
    //===== binary -> gray & gray to binary =====
    function [PTR_W:0] bin2gray;
        input [PTR_W:0] bin;
        return bin ^ (bin >> 1);
    endfunction

    /*function [PTR_W:0] gray2bin;
        input [PTR_W:0] gray;
        reg [PTR_W:0] bin;
        int i;
        bin = gray;
        for (i = PTR_W; i > 0; i--)
            bin[i-1] = bin[i] ^ gray[i-1];
        return bin;
    endfunction */

    //===== write domain =====
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (~wr_rst_n) begin
            wr_ptr_bin <= 0;
            wr_ptr_gray <= 0;
        end else begin // wr_ptr + 1
            wr_ptr_bin <= (wr_en & ~full) ? (wr_ptr_bin + 1) : wr_ptr_bin;
            wr_ptr_gray <= bin2gray(wr_ptr_bin);
        end
    end
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (wr_en & ~full)
            mem[wr_ptr_bin[PTR_W-1:0]] <= wr_data;
    end

    // full check
    // binary: wr vs rd pointers differ in MSB, all other bits (address) same
    // =>gray: wr vs rd pointers differ in MSB and MSB-1, all other bits same
    assign full = (wr_ptr_gray[PTR_W]   != rd_ptr_gray_sync[PTR_W]  ) &&
                  (wr_ptr_gray[PTR_W-1] != rd_ptr_gray_sync[PTR_W-1]) &&
                  (wr_ptr_gray[PTR_W-2:0] == rd_ptr_gray_sync[PTR_W-2:0]);

    //===== read domain =====
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (~rd_rst_n) begin
            rd_ptr_bin <= 0;
            rd_ptr_gray <= 0;
        end else begin // rd_ptr + 1
            rd_ptr_bin <= (rd_en & ~empty) ? (rd_ptr_bin + 1) : rd_ptr_bin;
            rd_ptr_gray <= bin2gray(rd_ptr_bin);
        end
    end
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (rd_en & ~empty)
            rd_data <= mem[rd_ptr_bin[PTR_W-1:0]];
    end

    // empty check
    assign empty = (wr_ptr_gray_sync == rd_ptr_gray);

    //===== synchronizers =====
    // wr need full, rd need empty
    // hardware replication instead of multi-bit synchronizer => bit-to-bit arrival skew
    initial begin
        wr_ptr_gray_sync = 0;
        rd_ptr_gray_sync = 0;
    end

    genvar i;
    generate
        for (i = 0; i <= PTR_W; i = i + 1) begin : gen_sync_wr2rd
            sync_2ff u_wr2rd (
                .clk(wr_clk),
                .rst_n(wr_rst_n),
                .d(wr_ptr_gray[i]),
                .q(wr_ptr_gray_sync[i])
            );
        end
        for (i = 0; i <= PTR_W; i = i + 1) begin : gen_sync_rd2wr
            sync_2ff u_rd2wr (
                .clk(rd_clk),
                .rst_n(rd_rst_n),
                .d(rd_ptr_gray[i]),
                .q(rd_ptr_gray_sync[i])
            );
        end
    endgenerate
endmodule