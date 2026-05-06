module fp8_mul (
    input  [7:0] a,
    input  [7:0] b,
    output [7:0] result//sr, er, mant_r
);
    wire       sa = a[7], sb = b[7];
    wire [2:0] ea = a[6:4], eb = b[6:4];
    wire [4:0] ma = {1'b1, a[3:0]},
               mb = {1'b1, b[3:0]};

    //----- sign -----
    wire        sr = sa ^ sb;

    //----- fraction 1.xxxx -----
    wire [9:0]  prod = ma * mb; // 5'b * 5'b -> 10'b
        // Normalise: if bit[9]==1(aka product >= binary 10.0) -> fraction>>1 && exp +1
    wire        carry   = prod[9];
    wire [3:0]  mant_r  = carry ? prod[8:5] : prod[7:4];

    //----- biased 3 exponent -----
    wire [4:0]  er      = (ea + eb - 5'd3) + {4'b0, carry};
        //-3-3+3 => -3 bias
        //[4]:sign [3]:overflow [2:0]:exp
 
    //----- boundary check -----
    // zero check
    wire zero_a = (a[6:0] == 7'b0);
    wire zero_b = (b[6:0] == 7'b0);
    // overflow: er > 3'b111
    wire ovf = (~zero_a && ~zero_b) && (er > 5'b111);
    // underflow: er < 0 (sign bit er[4] = 1)
    wire udf = (~zero_a && ~zero_b) && er[4];
 
    assign result = (zero_a || zero_b) ? 8'b0 :
                    ovf                ? {sr, 3'b111, 4'b1111} :
                    udf                ? 8'b0 :
                                        {sr, er[2:0], mant_r};
 
endmodule