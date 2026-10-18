// Behavioral L2 / Main Memory Model for L1 Cache Verification.
// Features configurable response latency (default 8 cycles) to
// faithfully simulate DRAM / L2 miss penalty.

`timescale 1ns / 1ps

module main_memory_model #(
    parameter ADDR_WIDTH     = 32,
    parameter LINE_BYTES     = 16,
    parameter LATENCY_CYCLES = 8  // Configurable miss penalty (e.g. 8-10 cycles)
)(
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     mem_req,
    input  wire                     mem_write,
    input  wire [ADDR_WIDTH-1:0]    mem_addr,
    input  wire [LINE_BYTES*8-1:0]  mem_wdata,
    output reg  [LINE_BYTES*8-1:0]  mem_rdata,
    output reg                      mem_ready
);

    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam MEM_DEPTH  = 1024; // Holds up to 1024 cache lines (16 KB)

    // Storage array indexed by line address
    reg [LINE_WIDTH-1:0] mem_array [0:MEM_DEPTH-1];

    reg [3:0] latency_cnt;
    reg       busy;
    reg       saved_write;
    reg [ADDR_WIDTH-1:0] saved_addr;
    reg [LINE_WIDTH-1:0] saved_wdata;

    wire [9:0] line_idx = mem_addr[13:4]; // 10-bit line index

    integer i;
    initial begin
        // Pre-initialize memory with deterministic test patterns
        for (i = 0; i < MEM_DEPTH; i = i + 1) begin
            // Word 0 = base+0, Word 1 = base+1, Word 2 = base+2, Word 3 = base+3
            mem_array[i] = {
                {16'hBEEF, i[15:0]}, // Word 3
                {16'hCAFE, i[15:0]}, // Word 2
                {16'hDEAD, i[15:0]}, // Word 1
                {16'hA000, i[15:0]}  // Word 0
            };
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_ready   <= 1'b0;
            mem_rdata   <= {LINE_WIDTH{1'b0}};
            latency_cnt <= 4'd0;
            busy        <= 1'b0;
        end else begin
            if (!busy) begin
                mem_ready <= 1'b0;
                if (mem_req) begin
                    busy        <= 1'b1;
                    saved_write <= mem_write;
                    saved_addr  <= mem_addr;
                    saved_wdata <= mem_wdata;
                    latency_cnt <= 4'd1;
                end
            end else begin
                if (latency_cnt < LATENCY_CYCLES) begin
                    latency_cnt <= latency_cnt + 1'b1;
                end else begin
                    // Latency elapsed: complete transaction
                    mem_ready <= 1'b1;
                    busy      <= 1'b0;

                    if (saved_write) begin
                        mem_array[saved_addr[13:4]] <= saved_wdata;
                    end else begin
                        mem_rdata <= mem_array[saved_addr[13:4]];
                    end
                end
            end
        end
    end

endmodule