// =============================================================================
// File: sync_2ff.sv
// Description: metastability-hardening syncchronizer cell
//              for multi-bit buses with gray-coded pointers
// =============================================================================

module sync_2ff(
    input  clk,
    input  rst_n,
    input  d,
    output reg q
);
    // clk, rst_n (destination's clock and reset)
    // d, q: ADDR_SIZE+1 's MSB => empty/full
    (* Async_REG = "TRUE" *) //preventing optimization from syncthesizer (for CDC regs)
        reg tmp_reg;
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            {q, tmp_reg} <= 2'b0;
        else
            {q, tmp_reg} <= {tmp_reg, d};
    end
endmodule