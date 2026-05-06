// =============================================================================
// axi4lite_slave.sv  —  AXI4-Lite Slave for 3×3 FP8 Systolic Array
//
// Designed to match systolic_array.v exactly:
//   - `rst`   is active-HIGH synchronous
//   - `done`  goes HIGH 1 cycle after computation ends (cnt==7)
//   - `busy`  derived as cnt!=0, exposed via STATUS[1]
//
// Register Map  (byte-addressed, 32-bit words)
//      ...case(reached addr) instead of FSM
// ─────────────────────────────────────────────────────────────
//  Offset  Name    R/W   Bits   Description
//  0x00    CTRL    RW    [0]    start  (write 1 → 1-cycle pulse, auto-clear)
//                        [1]    sa_rst (write 1 → assert SA rst for 1 cycle)
//  0x04    STATUS  RO    [0]    done   (reflects SA done, cleared on read)
//                        [1]    busy   (sa's cnt != 0)
//  0x08    IRQ_EN  RW    [0]    done_irq_en
//
//  0x10, 0x14, ... 0x30    Matrix A (A_00, A_01, ... A_22) RW (rows 0–2, cols 0–2)
//  0x34, 0x38, ... 0x54    Matrix B (B_00, B_01, ... B_22) RW (rows 0–2, cols 0–2)
//  0x58, 0x5C, ... 0x78    Result C (C_00, C_01, ... C_22) RO (valid after done=1)
// =============================================================================

module axi4lite_slave #(
    parameter int ADDR_WIDTH = 8
)(
    // ── AXI4-Lite global ──────────────────────────────────────
    input  logic        aclk,
    input  logic        aresetn,    // active-low async reset

    // ── Write Address Channel ─────────────────────────────────
    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,

    // ── Write Data Channel ────────────────────────────────────
    input  logic [31:0]           s_axi_wdata,
    input  logic [3:0]            s_axi_wstrb, //bit select
    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,

    // ── Write Response Channel ────────────────────────────────
    output logic [1:0]            s_axi_bresp,
    output logic                  s_axi_bvalid,
    input  logic                  s_axi_bready,

    // ── Read Address Channel ──────────────────────────────────
    input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic                  s_axi_arvalid,
    output logic                  s_axi_arready,

    // ── Read Data Channel ─────────────────────────────────────
    output logic [31:0]           s_axi_rdata,
    output logic [1:0]            s_axi_rresp,
    output logic                  s_axi_rvalid,
    input  logic                  s_axi_rready,

    // ── Systolic Array ports (flat, matches systolic_array.v) ─
    output logic       sa_start,   // 1-cycle pulse
    output logic       sa_rst,     // active-high sync reset to SA
    input  logic       sa_done,    // high 1 cycle after computation ends
    input  logic       sa_busy,    // sa's cnt != 0 (output running)

    output logic [7:0] sa_a00, sa_a01, sa_a02,
    output logic [7:0] sa_a10, sa_a11, sa_a12,
    output logic [7:0] sa_a20, sa_a21, sa_a22,

    output logic [7:0] sa_b00, sa_b01, sa_b02,
    output logic [7:0] sa_b10, sa_b11, sa_b12,
    output logic [7:0] sa_b20, sa_b21, sa_b22,

    input  logic [7:0] sa_c00, sa_c01, sa_c02,
    input  logic [7:0] sa_c10, sa_c11, sa_c12,
    input  logic [7:0] sa_c20, sa_c21, sa_c22,

    // ── IRQ output ────────────────────────────────────────────
    output logic       irq         // level, active-high
);

    // ----- Register address -----
    localparam logic [ADDR_WIDTH-1:0]
        A_CTRL   = 'h00,  A_STATUS = 'h04,  A_IRQ_EN = 'h08,
        A_A00='h10, A_A01='h14, A_A02='h18,
        A_A10='h1C, A_A11='h20, A_A12='h24,
        A_A20='h28, A_A21='h2C, A_A22='h30,
        A_B00='h34, A_B01='h38, A_B02='h3C,
        A_B10='h40, A_B11='h44, A_B12='h48,
        A_B20='h4C, A_B21='h50, A_B22='h54,
        A_C00='h58, A_C01='h5C, A_C02='h60,
        A_C10='h64, A_C11='h68, A_C12='h6C,
        A_C20='h70, A_C21='h74, A_C22='h78;

    // ----- Internal -----
    logic [7:0] reg_a [0:8];   // original a00..a22 flattened
    logic [7:0] reg_b [0:8];   // original b00..b22 flattened
    logic        reg_irq_en;
    logic        done_sticky;   // latched "done" until read

    // ----- Byte-enable(strb) mux -----
    function automatic logic [7:0] strb8(
        input logic [7:0] old_v,
        input logic [7:0] new_v,
        input logic       strb
    );
        return strb ? new_v : old_v;
    endfunction

    // =========================================================================
    // Write latched seq signals control  (AW + W independent, commit on both done)
    // =========================================================================
    // latch in input signals when handshake approved
    logic                  aw_pend;
    logic [ADDR_WIDTH-1:0] aw_addr_lat;
    logic                  w_pend;
    logic [31:0]           w_data_lat;
    logic [3:0]            w_strb_lat;

    // AW handshake (aw_pend: handshake v but haven't commit)
    always_ff @(posedge aclk or negedge aresetn) begin
        if (~aresetn) begin
            aw_pend     <= 0;
            aw_addr_lat <= '0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                aw_pend     <= 1;
                aw_addr_lat <= s_axi_awaddr;
            end else if (s_axi_bvalid && s_axi_bready)
                aw_pend <= 0; //response handshake
        end
    end
    assign s_axi_awready = ~aw_pend;

    // W handshake (w_pend: write data in and ready)
    always_ff @(posedge aclk or negedge aresetn) begin
        if (~aresetn) begin
            w_pend    <= 0;
            w_data_lat<= '0;
            w_strb_lat<= '0;
        end else begin
            if (s_axi_wvalid && s_axi_wready) begin
                w_pend    <= 1;
                w_data_lat<= s_axi_wdata;
                w_strb_lat<= s_axi_wstrb;
            end else if (s_axi_bvalid && s_axi_bready)
                w_pend <= 0;
        end
    end
    assign s_axi_wready = ~w_pend; //next cyc of loaded w data

    // response handshake (B channel)
    logic bvalid_r;//latch
    always_ff @(posedge aclk or negedge aresetn) begin
        if (~aresetn) bvalid_r <= 0;
        else if (aw_pend && w_pend && ~bvalid_r) bvalid_r <= 1; //busy(working): bvalid 0->1
        else if (s_axi_bready) bvalid_r <= 0;
    end
    assign s_axi_bvalid = bvalid_r;
    assign s_axi_bresp  = 2'b00;//OK

    // =========================================================================
    // Register write commit @bvalid
    // =========================================================================
    logic do_write;
    assign do_write = aw_pend && w_pend && ~bvalid_r;//both busy(transfer data) -> do_write(commit) -> bvalid

    // load in data per byte with strobe (macro)
    `define WA8(idx) strb8(reg_a[idx], w_data_lat[7:0], w_strb_lat[0])
    `define WB8(idx) strb8(reg_b[idx], w_data_lat[7:0], w_strb_lat[0])

    always_ff @(posedge aclk or negedge aresetn) begin
        if (~aresetn) begin
            foreach (reg_a[i]) reg_a[i] <= '0;
            foreach (reg_b[i]) reg_b[i] <= '0;
            reg_irq_en <= 0;
            sa_start   <= 0;
            sa_rst     <= 1;
        end else begin
            if(sa_rst) begin
                foreach (reg_a[i]) reg_a[i] <= '0;
                foreach (reg_b[i]) reg_b[i] <= '0;
            end
            sa_start <= 0;   // self-clear every cycle
            sa_rst   <= 0;

            if (do_write) begin
                case (aw_addr_lat)
                    A_CTRL:   begin
                        if (w_data_lat[0] && w_strb_lat[0]) sa_start <= 1;
                        if (w_data_lat[1] && w_strb_lat[0]) sa_rst   <= 1;
                    end
                    A_IRQ_EN: reg_irq_en <= w_strb_lat[0] ? w_data_lat[0] : reg_irq_en; //masked for byte-wise access
                    // Matrix A
                    A_A00: reg_a[0] <= `WA8(0);  A_A01: reg_a[1] <= `WA8(1);  A_A02: reg_a[2] <= `WA8(2); 
                    A_A10: reg_a[3] <= `WA8(3);  A_A11: reg_a[4] <= `WA8(4);  A_A12: reg_a[5] <= `WA8(5);
                    A_A20: reg_a[6] <= `WA8(6);  A_A21: reg_a[7] <= `WA8(7);  A_A22: reg_a[8] <= `WA8(8);
                    // Matrix B
                    A_B00: reg_b[0] <= `WB8(0);  A_B01: reg_b[1] <= `WB8(1);  A_B02: reg_b[2] <= `WB8(2);
                    A_B10: reg_b[3] <= `WB8(3);  A_B11: reg_b[4] <= `WB8(4);  A_B12: reg_b[5] <= `WB8(5);
                    A_B20: reg_b[6] <= `WB8(6);  A_B21: reg_b[7] <= `WB8(7);  A_B22: reg_b[8] <= `WB8(8);
                    default: ;
                endcase
            end
        end
    end
    `undef WA8
    `undef WB8

    // ----- Done sticky latch — [ sa_done rising ~ CPU read status ] -----
    logic status_read;   // pulsed when CPU reads STATUS register
    always_ff @(posedge aclk or negedge aresetn) begin
        if (~aresetn)     done_sticky <= 0;
        else if (sa_done) done_sticky <= 1;
        else if (status_read) done_sticky <= 0;
    end

    // =========================================================================
    // Read latched seq signals control
    // =========================================================================
    logic                  ar_pend;
    logic [ADDR_WIDTH-1:0] ar_addr_lat;
    logic [31:0]           rdata_r;
    logic                  rvalid_r;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (~aresetn) begin
            ar_pend    <= 0;
            ar_addr_lat<= '0;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                ar_pend    <= 1;
                ar_addr_lat<= s_axi_araddr;
            end else if (s_axi_rvalid && s_axi_rready)
                ar_pend <= 0;
        end
    end
    assign s_axi_arready = ~ar_pend;

    // STATUS read pulse: CPU want access A_STATUS check busy or not (for done_sticky clear)
    assign status_read = ar_pend && ~rvalid_r && (ar_addr_lat == A_STATUS);

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rvalid_r <= 0;
            rdata_r  <= '0;
        end else if (ar_pend && ~rvalid_r) begin
            rvalid_r <= 1;
            case (ar_addr_lat)
                A_CTRL:   rdata_r <= 32'h0;   // start is self-clear, always reads 0
                A_STATUS: rdata_r <= {30'b0, sa_busy, done_sticky};
                A_IRQ_EN: rdata_r <= {31'b0, reg_irq_en}; //busy
                // A
                A_A00: rdata_r <= {24'b0, reg_a[0]}; A_A01: rdata_r <= {24'b0, reg_a[1]}; A_A02: rdata_r <= {24'b0, reg_a[2]};
                A_A10: rdata_r <= {24'b0, reg_a[3]}; A_A11: rdata_r <= {24'b0, reg_a[4]}; A_A12: rdata_r <= {24'b0, reg_a[5]};
                A_A20: rdata_r <= {24'b0, reg_a[6]}; A_A21: rdata_r <= {24'b0, reg_a[7]}; A_A22: rdata_r <= {24'b0, reg_a[8]};
                // B
                A_B00: rdata_r <= {24'b0, reg_b[0]}; A_B01: rdata_r <= {24'b0, reg_b[1]}; A_B02: rdata_r <= {24'b0, reg_b[2]};
                A_B10: rdata_r <= {24'b0, reg_b[3]}; A_B11: rdata_r <= {24'b0, reg_b[4]}; A_B12: rdata_r <= {24'b0, reg_b[5]};
                A_B20: rdata_r <= {24'b0, reg_b[6]}; A_B21: rdata_r <= {24'b0, reg_b[7]}; A_B22: rdata_r <= {24'b0, reg_b[8]};
                // C (read-only, directly from SA output)
                A_C00: rdata_r <= {24'b0, sa_c00}; A_C01: rdata_r <= {24'b0, sa_c01}; A_C02: rdata_r <= {24'b0, sa_c02};
                A_C10: rdata_r <= {24'b0, sa_c10}; A_C11: rdata_r <= {24'b0, sa_c11}; A_C12: rdata_r <= {24'b0, sa_c12};
                A_C20: rdata_r <= {24'b0, sa_c20}; A_C21: rdata_r <= {24'b0, sa_c21}; A_C22: rdata_r <= {24'b0, sa_c22};
                default: rdata_r <= 32'hDEAD_BEEF;
            endcase
        end else if (s_axi_rready)
            rvalid_r <= 0;
    end

    assign s_axi_rvalid = rvalid_r;
    assign s_axi_rdata  = rdata_r;
    assign s_axi_rresp  = 2'b00;//OK

    // ----- reg arrays → SA ports -----
    assign {sa_a00,sa_a01,sa_a02} = {reg_a[0],reg_a[1],reg_a[2]};
    assign {sa_a10,sa_a11,sa_a12} = {reg_a[3],reg_a[4],reg_a[5]};
    assign {sa_a20,sa_a21,sa_a22} = {reg_a[6],reg_a[7],reg_a[8]};

    assign {sa_b00,sa_b01,sa_b02} = {reg_b[0],reg_b[1],reg_b[2]};
    assign {sa_b10,sa_b11,sa_b12} = {reg_b[3],reg_b[4],reg_b[5]};
    assign {sa_b20,sa_b21,sa_b22} = {reg_b[6],reg_b[7],reg_b[8]};

    // ----- IRQ -----
    assign irq = done_sticky & reg_irq_en;

endmodule