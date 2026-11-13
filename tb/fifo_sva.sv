// =============================================================================
// fifo_sva.sv
// SystemVerilog Assertions for sync_fifo, attached with `bind` (in tb_top),
// so the RTL file stays clean and the checker can see internal pointers.
// =============================================================================
`timescale 1ns/1ps

module fifo_sva #(
    parameter int DEPTH = 16,
    parameter int AW    = $clog2(DEPTH)
) (
    input logic        clk,
    input logic        rst_n,
    input logic        wr_en,
    input logic        rd_en,
    input logic        full,
    input logic        empty,
    input logic        overflow,
    input logic        underflow,
    input logic [AW:0] wr_ptr,
    input logic [AW:0] rd_ptr,
    input logic [AW:0] count
);

    default clocking cb @(posedge clk); endclocking
    default disable iff (!rst_n);

    // ---------------- Safety properties ----------------

    // The FIFO can never be full and empty at the same time
    a_not_full_and_empty: assert property (!(full && empty))
        else $error("SVA: full and empty both high");

    // Occupancy never exceeds the depth
    a_count_in_range: assert property (count <= DEPTH)
        else $error("SVA: count=%0d exceeds DEPTH=%0d", count, DEPTH);

    // A full FIFO must not move its write pointer (no overwrite)
    a_no_write_when_full: assert property (full |=> $stable(wr_ptr))
        else $error("SVA: write pointer moved while full");

    // An empty FIFO must not move its read pointer (no stale read)
    a_no_read_when_empty: assert property (empty |=> $stable(rd_ptr))
        else $error("SVA: read pointer moved while empty");

    // ---------------- Flag behaviour ----------------

    a_overflow_flag: assert property ((wr_en && full) |=> overflow)
        else $error("SVA: overflow not flagged");

    a_no_false_overflow: assert property (!(wr_en && full) |=> !overflow)
        else $error("SVA: overflow flagged without cause");

    a_underflow_flag: assert property ((rd_en && empty) |=> underflow)
        else $error("SVA: underflow not flagged");

    a_no_false_underflow: assert property (!(rd_en && empty) |=> !underflow)
        else $error("SVA: underflow flagged without cause");

    // Writing the last free slot (with no read) makes the FIFO full
    a_becomes_full: assert property ((count == DEPTH - 1 && wr_en && !rd_en) |=> full)
        else $error("SVA: FIFO did not become full");

    // Reading the last entry (with no write) makes the FIFO empty
    a_becomes_empty: assert property ((count == 1 && rd_en && !wr_en) |=> empty)
        else $error("SVA: FIFO did not become empty");

    // ---------------- Reset ----------------

    // While reset is held, the FIFO reports empty (checked even during reset)
    a_reset_empty: assert property (@(posedge clk) disable iff (1'b0) !rst_n |-> empty)
        else $error("SVA: FIFO not empty during reset");

    // ---------------- Cover properties (did the scenario happen?) ----------------

    c_full:          cover property (full);
    c_overflow:      cover property (wr_en && full);
    c_underflow:     cover property (rd_en && empty);
    c_rw_when_full:  cover property (wr_en && rd_en && full);
    c_ptr_wraps:     cover property (wr_ptr[AW-1:0] == DEPTH - 1 && wr_en && !full);
    c_full_to_empty: cover property (full ##[1:$] empty);

endmodule
