// =============================================================================
// File: cache_def.vh
// Description: Global constants and state definitions for L1 Cache Controller
// =============================================================================

`ifndef CACHE_DEF_VH
`define CACHE_DEF_VH

// FSM State Definitions
localparam S_IDLE        = 3'b000; // Idle / Compare Tag on CPU Request
localparam S_COMPARE_TAG = 3'b001; // Tag comparison & Hit/Miss determination
localparam S_WRITE_BACK  = 3'b010; // Write dirty victim line back to memory
localparam S_ALLOCATE    = 3'b011; // Fetch new line from lower-level memory
localparam S_UPDATE      = 3'b100; // Update cache line and serve CPU request

`endif // CACHE_DEF_VH