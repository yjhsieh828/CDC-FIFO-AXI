module fp8_mac (
    input        clk,
    input        rst,
    input        en,
    input  [7:0] a,
    input  [7:0] b,
    output reg [7:0] a_out,
    output reg [7:0] b_out,
    output [7:0] result
);
    wire [7:0] product;  // a * b
    wire [7:0] new_acc;  // acc + product
 
    reg [7:0] acc;
 
    // combinational multiply
    fp8_mul mul (
        .a(a),
        .b(b),
        .result(product)
    );
 
    // combinational add into accumulator
    fp8_add add (
        .a(acc),
        .b(product),
        .result(new_acc)
    );
 
    assign result = acc;
 
    always @(posedge clk) begin
        if (rst) begin
            acc   <= 8'b0;
            a_out <= 8'b0;
            b_out <= 8'b0;
        end else if (en) begin
            acc   <= new_acc;
            a_out <= a;
            b_out <= b;
        end
    end
endmodule