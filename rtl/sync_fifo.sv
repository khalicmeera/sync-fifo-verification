// =============================================================================
// sync_fifo.sv
// Parameterised synchronous FIFO (single clock).
//
// Design choices
//   * Read and write pointers are AW+1 bits wide (one extra "wrap" bit).
//       - empty : pointers are identical
//       - full  : lower AW bits match but the wrap bits differ
//     This tells full from empty without a separate counter register.
//   * DEPTH must be a power of 2 so the pointers wrap naturally.
//   * Writes when full and reads when empty are ignored (data is protected)
//     and flagged one cycle later on `overflow` / `underflow`.
//   * Read data is registered: rd_data is valid on the clock edge AFTER the
//     read is accepted (1-cycle read latency).
// =============================================================================
`timescale 1ns/1ps

module sync_fifo #(
    parameter int DATA_WIDTH     = 8,
    parameter int DEPTH          = 16,         // must be a power of 2
    parameter int ALMOST_FULL_TH = DEPTH - 2   // almost_full when count >= this
) (
    input  logic                  clk,
    input  logic                  rst_n,       // active-low, asynchronous

    input  logic                  wr_en,
    input  logic [DATA_WIDTH-1:0] wr_data,

    input  logic                  rd_en,
    output logic [DATA_WIDTH-1:0] rd_data,

    output logic                  full,
    output logic                  empty,
    output logic                  almost_full,
    output logic                  overflow,    // write attempted while full (registered pulse)
    output logic                  underflow    // read attempted while empty (registered pulse)
);

    localparam int AW = $clog2(DEPTH);

    // synthesis translate_off
    initial begin
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "sync_fifo: DEPTH (%0d) must be a power of 2 and >= 2", DEPTH);
    end
    // synthesis translate_on

    logic [DATA_WIDTH-1:0] mem [DEPTH];

    logic [AW:0] wr_ptr;     // MSB = wrap bit, [AW-1:0] = address
    logic [AW:0] rd_ptr;
    logic [AW:0] count;      // number of stored entries (0 .. DEPTH)

    logic do_write;
    logic do_read;

    // -------------------------------------------------------------------------
    // Status flags (combinational, from the pointers)
    // -------------------------------------------------------------------------
    assign count       = wr_ptr - rd_ptr;
    assign empty       = (wr_ptr == rd_ptr);
    assign full        = (wr_ptr[AW] != rd_ptr[AW]) &&
                         (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
    assign almost_full = (count >= ALMOST_FULL_TH);

    // An operation is accepted only if it is legal in the current state.
    assign do_write = wr_en && !full;
    assign do_read  = rd_en && !empty;

    // -------------------------------------------------------------------------
    // Storage: no reset needed for the data array
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (do_write)
            mem[wr_ptr[AW-1:0]] <= wr_data;
    end

    // -------------------------------------------------------------------------
    // Pointers, read data and error flags
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr    <= '0;
            rd_ptr    <= '0;
            rd_data   <= '0;
            overflow  <= 1'b0;
            underflow <= 1'b0;
        end
        else begin
            if (do_write)
                wr_ptr <= wr_ptr + 1'b1;

            if (do_read) begin
                rd_data <= mem[rd_ptr[AW-1:0]];
                rd_ptr  <= rd_ptr + 1'b1;
            end

            overflow  <= wr_en && full;
            underflow <= rd_en && empty;
        end
    end

endmodule
