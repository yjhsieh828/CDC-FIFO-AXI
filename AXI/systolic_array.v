module systolic_array (
    input   clk,
    input   rst,
    input   start,

    // Matrix A (3x3)
    input [7:0] a00, a01, a02,
    input [7:0] a10, a11, a12,
    input [7:0] a20, a21, a22,

    // Matrix B (3x3)
    input [7:0] b00, b01, b02,
    input [7:0] b10, b11, b12,
    input [7:0] b20, b21, b22,

    // Result matrix C = A * B
    output reg [7:0] c00, c01, c02,
    output reg [7:0] c10, c11, c12,
    output reg [7:0] c20, c21, c22,

    output  done,
    output  running
);

    // ----- state counter per cycle: 1~7, 0 at idle -----
    reg [2:0] cnt;// 0–7
    assign    running = (cnt != 3'd0);
    wire      last    = (cnt == 3'd7);

    always @(posedge clk) begin
        if (rst)        cnt <= 3'd0;
        else if (start && ~running) cnt <= 3'd1; //for pipeline
        else if (running) cnt <= cnt + 3'd1;
        else if (last)  cnt <= 3'd0;
        else            cnt <= cnt;
    end
    // ----- control signals -----
    reg done_r;
    always @(posedge clk) done_r <= last;
    assign done = done_r;

    wire mac_rst = start | rst; // synchronous clear
    wire mac_en  = running;

    // ----- latch input matrix -----
    reg [7:0] la00,la01,la02, la10,la11,la12, la20,la21,la22;
    reg [7:0] lb00,lb01,lb02, lb10,lb11,lb12, lb20,lb21,lb22;
    always @(posedge clk) begin
        if (rst) begin
            la00<=8'b0; la01<=8'b0; la02<=8'b0;
            la10<=8'b0; la11<=8'b0; la12<=8'b0;
            la20<=8'b0; la21<=8'b0; la22<=8'b0;
            lb00<=8'b0; lb01<=8'b0; lb02<=8'b0;
            lb10<=8'b0; lb11<=8'b0; lb12<=8'b0;
            lb20<=8'b0; lb21<=8'b0; lb22<=8'b0;
        end
        else if (start) begin
            la00<=a00; la01<=a01; la02<=a02;
            la10<=a10; la11<=a11; la12<=a12;
            la20<=a20; la21<=a21; la22<=a22;
            lb00<=b00; lb01<=b01; lb02<=b02;
            lb10<=b10; lb11<=b11; lb12<=b12;
            lb20<=b20; lb21<=b21; lb22<=b22;
        end
    end

    // ----- matrix input cycle count -----
    reg [7:0] a_row0, a_row1, a_row2;
    reg [7:0] b_col0, b_col1, b_col2;
    always @(*) begin
        // Row 0 of A: no delay, active cycles 1-3
        case (cnt)
            3'd1: a_row0 = la00;
            3'd2: a_row0 = la01;
            3'd3: a_row0 = la02;
            default: a_row0 = 8'b0;
        endcase

        // Row 1 of A: 1-cycle delay, active cycles 2-4
        case (cnt)
            3'd2: a_row1 = la10;
            3'd3: a_row1 = la11;
            3'd4: a_row1 = la12;
            default: a_row1 = 8'b0;
        endcase

        // Row 2 of A: 2-cycle delay, active cycles 3-5
        case (cnt)
            3'd3: a_row2 = la20;
            3'd4: a_row2 = la21;
            3'd5: a_row2 = la22;
            default: a_row2 = 8'b0;
        endcase

        // Col 0 of B: no delay, active cycles 1-3
        case (cnt)
            3'd1: b_col0 = lb00;
            3'd2: b_col0 = lb10;
            3'd3: b_col0 = lb20;
            default: b_col0 = 8'b0;
        endcase

        // Col 1 of B: 1-cycle delay, active cycles 2-4
        case (cnt)
            3'd2: b_col1 = lb01;
            3'd3: b_col1 = lb11;
            3'd4: b_col1 = lb21;
            default: b_col1 = 8'b0;
        endcase

        // Col 2 of B: 2-cycle delay, active cycles 3-5
        case (cnt)
            3'd3: b_col2 = lb02;
            3'd4: b_col2 = lb12;
            3'd5: b_col2 = lb22;
            default: b_col2 = 8'b0;
        endcase
    end

    // ----- A passing right between MACs -----
    wire [7:0] a00_out, a01_out;
    wire [7:0] a10_out, a11_out;
    wire [7:0] a20_out, a21_out;

    // ----- B passing down between MACs -----
    wire [7:0] b00_out, b10_out;
    wire [7:0] b01_out, b11_out;
    wire [7:0] b02_out, b12_out;
    // ----- c to output reg -----
    wire [7:0]  c00_w, c01_w, c02_w;
    wire [7:0]  c10_w, c11_w, c12_w;
    wire [7:0]  c20_w, c21_w, c22_w;
    always@(*) begin
        if(rst) begin
            c00=8'b0; c01=8'b0; c02=8'b0;
            c10=8'b0; c11=8'b0; c12=8'b0;
            c20=8'b0; c21=8'b0; c22=8'b0;
        end else begin
            c00=c00_w; c01=c01_w; c02=c02_w;
            c10=c10_w; c11=c11_w; c12=c12_w;
            c20=c20_w; c21=c21_w; c22=c22_w;
        end
    end

    // ----- Row 0 input: a_row0 & b_cols -----
    fp8_mac mac00 (.clk(clk),.rst(mac_rst),.en(mac_en),
                   .a(a_row0), .b(b_col0),
                   .a_out(a00_out), .b_out(b00_out), .result(c00_w));

    fp8_mac mac01 (.clk(clk),.rst(mac_rst),.en(mac_en),
                   .a(a00_out), .b(b_col1),
                   .a_out(a01_out), .b_out(b01_out), .result(c01_w));

    fp8_mac mac02 (.clk(clk),.rst(mac_rst),.en(mac_en),
                   .a(a01_out), .b(b_col2),
                   .a_out(), .b_out(b02_out), .result(c02_w));

    // ----- Row 1 input: a_row1 -----
    fp8_mac mac10 (.clk(clk),.rst(mac_rst),.en(mac_en),
                   .a(a_row1), .b(b00_out),
                   .a_out(a10_out), .b_out(b10_out), .result(c10_w));

    fp8_mac mac11 (.clk(clk),.rst(mac_rst),.en(mac_en),
                   .a(a10_out), .b(b01_out),
                   .a_out(a11_out), .b_out(b11_out), .result(c11_w));

    fp8_mac mac12 (.clk(clk),.rst(mac_rst),.en(mac_en),
                   .a(a11_out), .b(b02_out),
                   .a_out(), .b_out(b12_out), .result(c12_w));

    // ----- Row 2 input: a_row2-----
    fp8_mac mac20 (.clk(clk),.rst(mac_rst),.en(mac_en),
                   .a(a_row2), .b(b10_out),
                   .a_out(a20_out), .b_out(), .result(c20_w));

    fp8_mac mac21 (.clk(clk),.rst(mac_rst),.en(mac_en),
                   .a(a20_out), .b(b11_out),
                   .a_out(a21_out), .b_out(), .result(c21_w));

    fp8_mac mac22 (.clk(clk),.rst(mac_rst),.en(mac_en),
                   .a(a21_out), .b(b12_out),
                   .a_out(), .b_out(), .result(c22_w));

endmodule