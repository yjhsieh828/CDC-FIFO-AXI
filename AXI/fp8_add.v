module fp8_add (
    input  [7:0] a,
    input  [7:0] b,
    output [7:0] result //sr, er, mant_r
);
 
    wire       sa = a[7], sb = b[7];
    wire [2:0] ea = a[6:4], eb = b[6:4];
    wire [4:0] ma = {1'b1, a[3:0]},
               mb = {1'b1, b[3:0]};
 
    wire zero_a = (a[6:0] == 7'b0);
    wire zero_b = (b[6:0] == 7'b0);
 
    // ----- Exponent alignment (choose bigger e) -----
    wire a_bigger = (ea >= eb);
    wire [2:0] er_unNorm  = a_bigger ? ea : eb;
    wire [2:0] exp_diff = a_bigger ? (ea - eb) : (eb - ea);
    // Shift the smaller-exponent fraction right : x.xxxx
    // (>> gets 0s on left) (shift out of fraction's 4bits => ignore)
    wire [4:0] ma_sh = a_bigger ? ma : (exp_diff > 3'd4 ? 5'b0 : (ma >> exp_diff));
    wire [4:0] mb_sh = a_bigger ? (exp_diff > 3'd4 ? 5'b0 : (mb >> exp_diff)) : mb;
 
    // ----- Fraction add/subtract -----
    wire same_sign = ~(sa ^ sb);
    wire [5:0] m_sum  = ma_sh + mb_sh; //xx.xxxx
    wire [5:0] m_sub = (ma_sh >= mb_sh) ? (ma_sh - mb_sh) : (mb_sh - ma_sh);
    wire [5:0] m_unNorm  = same_sign ? m_sum : m_sub;
    // Sign of result
    wire sr = same_sign ? sa : (ma_sh >= mb_sh ? sa : sb);
 
    // ----- Normalise -----
    // m_unNorm: xx.xxxx
    wire [3:0] mant_r; //->result
    wire [4:0] er; //->result
    wire zero_result = (m_unNorm == 6'b0);
    assign {er, mant_r} =
        m_unNorm[5] ? {er_unNorm + 3'd1, m_unNorm[4:1]}           :  // carry: shift right, exp+1
        m_unNorm[4] ? {er_unNorm,        m_unNorm[3:0]}           :  // normal
        m_unNorm[3] ? {er_unNorm - 3'd1, m_unNorm[2:0], 1'b0}     :  // 1 left shift
        m_unNorm[2] ? {er_unNorm - 3'd2, m_unNorm[1:0], 2'b0}     :  // 2
        m_unNorm[1] ? {er_unNorm - 3'd3, m_unNorm[0],   3'b0}     :  // 3
                      {er_unNorm - 3'd4, 4'b0};                      // 4
 
    wire ovf = ~zero_result && (er > 5'b111);
    //wire udf = ~zero_result && er[4]; // er < 0 //not possible
 
    assign result = zero_a              ? b :
                    zero_b              ? a :
                    zero_result         ? 8'b0 :
                    ovf                 ? {sr, 3'b111, 4'b1111} :
                    //udf                 ? 8'b0 :
                                          {sr, er[2:0], mant_r};
 
endmodule