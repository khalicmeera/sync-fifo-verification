// =============================================================================
// fifo_if.sv
// Interface bundling the FIFO pins, with clocking blocks so the testbench
// drives and samples at well-defined times (no race with the DUT):
//   * drv_cb drives inputs 1 ns after the rising edge
//   * mon_cb samples just before the rising edge (#1step), i.e. exactly the
//     values the DUT sees on that edge
// =============================================================================
`timescale 1ns/1ps

interface fifo_if #(parameter int DATA_WIDTH = 8) (input logic clk);

    logic                  rst_n;
    logic                  wr_en;
    logic [DATA_WIDTH-1:0] wr_data;
    logic                  rd_en;
    logic [DATA_WIDTH-1:0] rd_data;
    logic                  full;
    logic                  empty;
    logic                  almost_full;
    logic                  overflow;
    logic                  underflow;

    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output wr_en, wr_data, rd_en;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input rst_n, wr_en, wr_data, rd_en, rd_data,
              full, empty, almost_full, overflow, underflow;
    endclocking

endinterface
