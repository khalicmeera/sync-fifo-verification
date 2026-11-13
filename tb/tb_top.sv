// =============================================================================
// tb_top.sv
// Top-level testbench: clock, reset, interface, DUT, assertions, environment.
// =============================================================================
`timescale 1ns/1ps

module tb_top;

    import fifo_pkg::*;

    // ---------------- Clock: 100 MHz ----------------
    logic clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- Interface and DUT ----------------
    fifo_if #(.DATA_WIDTH(DATA_WIDTH)) intf (clk);

    sync_fifo #(
        .DATA_WIDTH     (DATA_WIDTH),
        .DEPTH          (DEPTH),
        .ALMOST_FULL_TH (ALMOST_FULL_TH)
    ) dut (
        .clk         (clk),
        .rst_n       (intf.rst_n),
        .wr_en       (intf.wr_en),
        .wr_data     (intf.wr_data),
        .rd_en       (intf.rd_en),
        .rd_data     (intf.rd_data),
        .full        (intf.full),
        .empty       (intf.empty),
        .almost_full (intf.almost_full),
        .overflow    (intf.overflow),
        .underflow   (intf.underflow)
    );

    // ---------------- Assertions, attached to every sync_fifo ----------------
    bind sync_fifo fifo_sva #(.DEPTH(DEPTH)) u_sva (
        .clk       (clk),
        .rst_n     (rst_n),
        .wr_en     (wr_en),
        .rd_en     (rd_en),
        .full      (full),
        .empty     (empty),
        .overflow  (overflow),
        .underflow (underflow),
        .wr_ptr    (wr_ptr),
        .rd_ptr    (rd_ptr),
        .count     (count)
    );

    // ---------------- Test ----------------
    fifo_env env;

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_top);

        // Hold reset for a few cycles with idle inputs
        intf.rst_n   = 1'b0;
        intf.wr_en   = 1'b0;
        intf.rd_en   = 1'b0;
        intf.wr_data = '0;
        repeat (3) @(posedge clk);
        @(negedge clk) intf.rst_n = 1'b1;

        env = new(intf);
        env.run_test();

        $finish;
    end

    // Safety net: stop if the test hangs
    initial begin
        #1ms;
        $fatal(1, "TIMEOUT: test did not finish");
    end

endmodule
