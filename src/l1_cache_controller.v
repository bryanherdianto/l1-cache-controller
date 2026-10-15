//! @brief Parameterized 2-Way Set-Associative L1 Cache Controller
//! @details High-performance L1 cache controller with Write-Back and Write-Allocate policy, 1-bit True-LRU replacement, 1-cycle hit latency, and hardware telemetry counters.

`timescale 1ns / 1ps

module l1_cache_controller #(
    parameter ADDR_WIDTH = 32,      //! 32-bit byte addressable memory space
    parameter DATA_WIDTH = 32,      //! 32-bit CPU data bus width
    parameter LINE_BYTES = 16,      //! 16 bytes per cache line (4 words = 128 bits)
    parameter NUM_SETS   = 64,      //! Number of cache sets (64 sets)
    parameter NUM_WAYS   = 2        //! Degrees of associativity (2-way set-associative)
)(
    input  wire                     clk,                //! Master clock input
    input  wire                     rst_n,              //! Active-low asynchronous reset

    // CPU Interface
    input  wire                     cpu_req,            //! High when CPU initiates read/write request
    input  wire                     cpu_write,          //! Access mode: 1 = Write, 0 = Read
    input  wire [ADDR_WIDTH-1:0]    cpu_addr,           //! 32-bit byte address from CPU
    input  wire [DATA_WIDTH-1:0]    cpu_wdata,          //! 32-bit write data from CPU
    input  wire [DATA_WIDTH/8-1:0]  cpu_wstrb,          //! 4-bit byte write strobes
    output reg  [DATA_WIDTH-1:0]    cpu_rdata,          //! 32-bit read data returned to CPU
    output reg                      cpu_ready,          //! Acknowledges completion of request (stalls CPU when 0)
    output wire                     cpu_hit,            //! Status flag: asserted on 1-cycle cache hit

    // Lower-Level Memory (L2 / DRAM) Interface
    output reg                      mem_req,            //! Request to main memory
    output reg                      mem_write,          //! Memory operation: 1 = Writeback line, 0 = Read line
    output reg  [ADDR_WIDTH-1:0]    mem_addr,           //! Line-aligned memory address
    output reg  [LINE_BYTES*8-1:0]  mem_wdata,          //! 128-bit cache line write data to memory
    input  wire [LINE_BYTES*8-1:0]  mem_rdata,          //! 128-bit cache line read data from memory
    input  wire                     mem_ready,          //! Acknowledgment from memory

    // Performance Metric Counters
    output reg  [31:0]              stat_read_hits,     //! Total number of successful read hits
    output reg  [31:0]              stat_read_misses,   //! Total number of read misses
    output reg  [31:0]              stat_write_hits,    //! Total number of successful write hits
    output reg  [31:0]              stat_write_misses,  //! Total number of write misses
    output reg  [31:0]              stat_writebacks     //! Total number of dirty line evictions written back
);

    // Local Parameters & Derived Dimensions
    localparam OFFSET_BITS      = 4;                                            //! Log2(LINE_BYTES): 4 bits for 16-byte line offset
    localparam SET_INDEX_BITS   = 6;                                            //! Log2(NUM_SETS): 6 bits for 64 sets
    localparam TAG_BITS         = ADDR_WIDTH - SET_INDEX_BITS - OFFSET_BITS;    //! Tag bit width (32 - 6 - 4 = 22 bits)
    localparam LINE_WIDTH       = LINE_BYTES * 8;                               //! Cache line width in bits (128 bits)
    localparam WORDS_PER_LINE   = LINE_BYTES / (DATA_WIDTH / 8);                //! Number of 32-bit words per line (4 words)
    localparam WORD_OFFSET_BITS = 2;                                            //! Word offset bit width within line (2 bits)

    // FSM States
    localparam [2:0] S_IDLE        = 3'b000; //! Idle and normal 1-cycle hit evaluation state
    localparam [2:0] S_COMPARE_TAG = 3'b001; //! Tag comparison state
    localparam [2:0] S_WRITE_BACK  = 3'b010; //! Evict dirty victim line to lower memory
    localparam [2:0] S_ALLOCATE    = 3'b011; //! Fetch requested line from lower memory

    reg [2:0] state; //! Current FSM control state

    // Cache Storage Arrays - Way 0
    reg [TAG_BITS-1:0]   tag_mem_0   [0:NUM_SETS-1]; //! Way 0 tag storage array (64 x 22 bits)
    reg                  valid_mem_0 [0:NUM_SETS-1]; //! Way 0 line valid flags (64 x 1 bit)
    reg                  dirty_mem_0 [0:NUM_SETS-1]; //! Way 0 line dirty flags (64 x 1 bit)
    reg [LINE_WIDTH-1:0] data_mem_0  [0:NUM_SETS-1]; //! Way 0 line data storage array (64 x 128 bits)

    // Cache Storage Arrays - Way 1
    reg [TAG_BITS-1:0]   tag_mem_1   [0:NUM_SETS-1]; //! Way 1 tag storage array (64 x 22 bits)
    reg                  valid_mem_1 [0:NUM_SETS-1]; //! Way 1 line valid flags (64 x 1 bit)
    reg                  dirty_mem_1 [0:NUM_SETS-1]; //! Way 1 line dirty flags (64 x 1 bit)
    reg [LINE_WIDTH-1:0] data_mem_1  [0:NUM_SETS-1]; //! Way 1 line data storage array (64 x 128 bits)

    // True 1-bit LRU per set (0 => Way 0 is LRU, 1 => Way 1 is LRU)
    reg                  lru_mem     [0:NUM_SETS-1]; //! True 1-bit LRU recency array per set

    // Address Decomposition
    wire [TAG_BITS-1:0]         cur_tag         = cpu_addr[ADDR_WIDTH-1 : SET_INDEX_BITS + OFFSET_BITS];    //! Extracted tag bits from current CPU address
    wire [SET_INDEX_BITS-1:0]   cur_set         = cpu_addr[SET_INDEX_BITS + OFFSET_BITS - 1 : OFFSET_BITS]; //! Extracted set index from current CPU address
    wire [WORD_OFFSET_BITS-1:0] cur_word_offset = cpu_addr[OFFSET_BITS-1 : 2];                              //! Extracted word offset within cache line

    // Latched request registers for servicing miss/allocation
    reg [ADDR_WIDTH-1:0]    latched_addr;       //! Latched CPU address during cache miss
    reg                     latched_write;      //! Latched CPU write enable during cache miss
    reg [DATA_WIDTH-1:0]    latched_wdata;      //! Latched CPU write data during cache miss
    reg [DATA_WIDTH/8-1:0]  latched_wstrb;      //! Latched byte write strobes during cache miss
    reg                     latched_victim_way; //! Latched selected victim way (0 or 1)

    wire [TAG_BITS-1:0]         saved_tag         = latched_addr[ADDR_WIDTH-1 : SET_INDEX_BITS + OFFSET_BITS];    //! Tag of latched miss address
    wire [SET_INDEX_BITS-1:0]   saved_set         = latched_addr[SET_INDEX_BITS + OFFSET_BITS - 1 : OFFSET_BITS]; //! Set index of latched miss address
    wire [WORD_OFFSET_BITS-1:0] saved_word_offset = latched_addr[OFFSET_BITS-1 : 2];                              //! Word offset of latched miss address

    // Tag Matching & Hit Logic (Combinational for 1-cycle latency)
    wire way0_hit = valid_mem_0[cur_set] && (tag_mem_0[cur_set] == cur_tag); //! Asserted when Way 0 matches tag and is valid
    wire way1_hit = valid_mem_1[cur_set] && (tag_mem_1[cur_set] == cur_tag); //! Asserted when Way 1 matches tag and is valid
    wire is_hit   = way0_hit || way1_hit;                                   //! Asserted when either way hits
    wire hit_way  = way1_hit ? 1'b1 : 1'b0;                                 //! Way index that hit (0 or 1)

    assign cpu_hit = is_hit && (state == S_IDLE) && cpu_req;

    //! Extracts a 32-bit word from a 128-bit cache line based on word index
    function [DATA_WIDTH-1:0] extract_word;
        input [LINE_WIDTH-1:0]       line_data; //! 128-bit cache line data
        input [WORD_OFFSET_BITS-1:0] word_idx;  //! 2-bit word offset selector
        begin
            case (word_idx)
                2'b00: extract_word = line_data[31:0];
                2'b01: extract_word = line_data[63:32];
                2'b10: extract_word = line_data[95:64];
                2'b11: extract_word = line_data[127:96];
            endcase
        end
    endfunction

    //! Merges a 32-bit CPU write word into a 128-bit line according to byte strobes
    function [LINE_WIDTH-1:0] merge_write_line;
        input [LINE_WIDTH-1:0]       orig_line; //! Original 128-bit cache line
        input [DATA_WIDTH-1:0]       wdata;     //! 32-bit CPU write data
        input [DATA_WIDTH/8-1:0]     wstrb;     //! 4-bit byte write enable mask
        input [WORD_OFFSET_BITS-1:0] word_idx;  //! 2-bit word offset selector
        reg   [DATA_WIDTH-1:0]       curr_word;
        reg   [DATA_WIDTH-1:0]       merged_word;
        begin
            curr_word = extract_word(orig_line, word_idx);
            merged_word[7:0]   = wstrb[0] ? wdata[7:0]   : curr_word[7:0];
            merged_word[15:8]  = wstrb[1] ? wdata[15:8]  : curr_word[15:8];
            merged_word[23:16] = wstrb[2] ? wdata[23:16] : curr_word[23:16];
            merged_word[31:24] = wstrb[3] ? wdata[31:24] : curr_word[31:24];

            merge_write_line = orig_line;
            case (word_idx)
                2'b00: merge_write_line[31:0]   = merged_word;
                2'b01: merge_write_line[63:32]  = merged_word;
                2'b10: merge_write_line[95:64]  = merged_word;
                2'b11: merge_write_line[127:96] = merged_word;
            endcase
        end
    endfunction

    // Victim line selection (prioritize invalid lines, then use True 1-bit LRU)
    //! Selected victim way (0 or 1) for eviction
    wire victim_select = (!valid_mem_0[cur_set]) ? 1'b0 :
                         (!valid_mem_1[cur_set]) ? 1'b1 :
                         lru_mem[cur_set];

    wire victim_is_dirty = (victim_select == 1'b0) ? dirty_mem_0[cur_set] : dirty_mem_1[cur_set]; //! True if the victim line is dirty and requires writeback
    wire victim_is_valid = (victim_select == 1'b0) ? valid_mem_0[cur_set] : valid_mem_1[cur_set]; //! True if the victim line is currently valid

    // Main Sequential Controller & FSM
    integer i; //! Loop index for array initialization
    reg [LINE_WIDTH-1:0] updated_line; //! Temporary buffer holding merged line data during write allocation

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            cpu_ready          <= 1'b0;
            cpu_rdata          <= {DATA_WIDTH{1'b0}};
            mem_req            <= 1'b0;
            mem_write          <= 1'b0;
            mem_addr           <= {ADDR_WIDTH{1'b0}};
            mem_wdata          <= {LINE_WIDTH{1'b0}};
            stat_read_hits     <= 32'd0;
            stat_read_misses   <= 32'd0;
            stat_write_hits    <= 32'd0;
            stat_write_misses  <= 32'd0;
            stat_writebacks    <= 32'd0;

            // Invalidate all cache lines and initialize LRU.
            // Note: tag_mem and data_mem are intentionally omitted from reset
            // to allow EDA tools (Quartus/Vivado) to infer high-density Block RAM (BRAM).
            for (i = 0; i < NUM_SETS; i = i + 1) begin
                valid_mem_0[i] <= 1'b0;
                dirty_mem_0[i] <= 1'b0;

                valid_mem_1[i] <= 1'b0;
                dirty_mem_1[i] <= 1'b0;

                lru_mem[i]     <= 1'b0;
            end
        end else begin
            case (state)
                // S_IDLE: Normal fast-path evaluation state
                S_IDLE: begin
                    if (cpu_req) begin
                        if (is_hit) begin
                            // Fast 1-Cycle Hit Path
                            cpu_ready <= 1'b1;

                            if (!cpu_write) begin
                                // Read Hit (Multiplex requested word from winning way)
                                cpu_rdata      <= (hit_way == 1'b0) ? 
                                                  extract_word(data_mem_0[cur_set], cur_word_offset) :
                                                  extract_word(data_mem_1[cur_set], cur_word_offset);
                                stat_read_hits <= stat_read_hits + 1'b1;
                            end else begin
                                // Write Hit (Update data line and mark dirty)
                                if (hit_way == 1'b0) begin
                                    data_mem_0[cur_set]  <= merge_write_line(data_mem_0[cur_set], cpu_wdata, cpu_wstrb, cur_word_offset);
                                    dirty_mem_0[cur_set] <= 1'b1;
                                end else begin
                                    data_mem_1[cur_set]  <= merge_write_line(data_mem_1[cur_set], cpu_wdata, cpu_wstrb, cur_word_offset);
                                    dirty_mem_1[cur_set] <= 1'b1;
                                end
                                stat_write_hits <= stat_write_hits + 1'b1;
                            end

                            // Update 1-bit LRU (Accessed way becomes Most Recently Used)
                            lru_mem[cur_set] <= ~hit_way;
                            state            <= S_IDLE;

                        end else begin
                            // Cache Miss: Stall CPU and Initiate Allocation
                            cpu_ready          <= 1'b0;
                            latched_addr       <= cpu_addr;
                            latched_write      <= cpu_write;
                            latched_wdata      <= cpu_wdata;
                            latched_wstrb      <= cpu_wstrb;
                            latched_victim_way <= victim_select;

                            if (cpu_write)
                                stat_write_misses <= stat_write_misses + 1'b1;
                            else
                                stat_read_misses  <= stat_read_misses + 1'b1;

                            // If victim is valid and dirty, write back to memory first
                            if (victim_is_valid && victim_is_dirty) begin
                                state     <= S_WRITE_BACK;
                                mem_req   <= 1'b1;
                                mem_write <= 1'b1;
                                mem_addr  <= (victim_select == 1'b0) ?
                                             {tag_mem_0[cur_set], cur_set, {OFFSET_BITS{1'b0}}} :
                                             {tag_mem_1[cur_set], cur_set, {OFFSET_BITS{1'b0}}};
                                mem_wdata <= (victim_select == 1'b0) ?
                                             data_mem_0[cur_set] :
                                             data_mem_1[cur_set];
                                stat_writebacks <= stat_writebacks + 1'b1;
                            end else begin
                                // Clean/invalid victim: allocate directly from memory
                                state     <= S_ALLOCATE;
                                mem_req   <= 1'b1;
                                mem_write <= 1'b0;
                                mem_addr  <= {cpu_addr[ADDR_WIDTH-1 : OFFSET_BITS], {OFFSET_BITS{1'b0}}};
                            end
                        end
                    end else begin
                        cpu_ready <= 1'b0;
                    end
                end

                // S_WRITE_BACK: Evict dirty victim line to lower memory
                S_WRITE_BACK: begin
                    if (mem_ready) begin
                        mem_req <= 1'b0;
                        // Clear victim dirty bit in cache
                        if (latched_victim_way == 1'b0)
                            dirty_mem_0[saved_set] <= 1'b0;
                        else
                            dirty_mem_1[saved_set] <= 1'b0;

                        // Now initiate line allocation for requested address
                        state     <= S_ALLOCATE;
                        mem_req   <= 1'b1;
                        mem_write <= 1'b0;
                        mem_addr  <= {latched_addr[ADDR_WIDTH-1 : OFFSET_BITS], {OFFSET_BITS{1'b0}}};
                    end
                end

                // S_ALLOCATE: Fetch requested line from memory
                S_ALLOCATE: begin
                    if (mem_ready) begin
                        mem_req   <= 1'b0;
                        cpu_ready <= 1'b1;

                        if (!latched_write) begin
                            // Read Miss: Install line clean, serve data to CPU
                            cpu_rdata <= extract_word(mem_rdata, saved_word_offset);

                            if (latched_victim_way == 1'b0) begin
                                data_mem_0[saved_set]  <= mem_rdata;
                                tag_mem_0[saved_set]   <= saved_tag;
                                valid_mem_0[saved_set] <= 1'b1;
                                dirty_mem_0[saved_set] <= 1'b0;
                            end else begin
                                data_mem_1[saved_set]  <= mem_rdata;
                                tag_mem_1[saved_set]   <= saved_tag;
                                valid_mem_1[saved_set] <= 1'b1;
                                dirty_mem_1[saved_set] <= 1'b0;
                            end
                        end else begin
                            // Write Miss (Write-Allocate): Merge CPU write into fetched line, mark dirty
                            updated_line = merge_write_line(mem_rdata, latched_wdata, latched_wstrb, saved_word_offset);

                            if (latched_victim_way == 1'b0) begin
                                data_mem_0[saved_set]  <= updated_line;
                                tag_mem_0[saved_set]   <= saved_tag;
                                valid_mem_0[saved_set] <= 1'b1;
                                dirty_mem_0[saved_set] <= 1'b1; // Marked dirty
                            end else begin
                                data_mem_1[saved_set]  <= updated_line;
                                tag_mem_1[saved_set]   <= saved_tag;
                                valid_mem_1[saved_set] <= 1'b1;
                                dirty_mem_1[saved_set] <= 1'b1; // Marked dirty
                            end
                        end

                        // Update LRU: newly allocated way becomes MRU
                        lru_mem[saved_set] <= ~latched_victim_way;
                        state              <= S_IDLE;
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
