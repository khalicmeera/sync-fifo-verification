// EDA Playground: paste into testbench.sv  (interface, package, assertions, top)

// ----------------------------------------------------------------- tb/fifo_if.sv
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

// ----------------------------------------------------------------- tb/fifo_pkg.sv
// =============================================================================
// fifo_pkg.sv
// Class-based verification environment for sync_fifo.
//
//   generator --(mailbox)--> driver ---> [ DUT ] ---> monitor --(mailbox)--> scoreboard
//                                                                      (reference model
//                                                                       + functional coverage)
// =============================================================================
`timescale 1ns/1ps

package fifo_pkg;

    // Shared configuration (tb_top passes the same values to the DUT)
    parameter int DATA_WIDTH     = 8;
    parameter int DEPTH          = 16;
    parameter int ALMOST_FULL_TH = DEPTH - 2;

    typedef virtual fifo_if #(.DATA_WIDTH(DATA_WIDTH)) fifo_vif_t;


    // =========================================================================
    // Transaction: what to drive on ONE clock cycle
    // =========================================================================
    class fifo_txn;

        rand bit                  wr_en;
        rand bit                  rd_en;
        rand bit [DATA_WIDTH-1:0] wr_data;

        // Knobs set per test phase (percent chance of each operation)
        int unsigned wr_pct = 50;
        int unsigned rd_pct = 50;

        constraint c_ops {
            wr_en dist {1 := wr_pct, 0 := 100 - wr_pct};
            rd_en dist {1 := rd_pct, 0 := 100 - rd_pct};
        }

        // Bias towards boundary data values (all zeros / all ones)
        constraint c_data {
            wr_data dist {
                0                                 := 5,
                (2**DATA_WIDTH) - 1               := 5,
                [1 : (2**DATA_WIDTH) - 2]         :/ 90
            };
        }

    endclass


    // =========================================================================
    // Sample: what the monitor observed at ONE clock edge
    // =========================================================================
    class fifo_sample;
        bit                  wr_en;
        bit                  rd_en;
        bit [DATA_WIDTH-1:0] wr_data;
        bit [DATA_WIDTH-1:0] rd_data;
        bit                  full;
        bit                  empty;
        bit                  almost_full;
        bit                  overflow;
        bit                  underflow;
    endclass


    // =========================================================================
    // Generator: creates constrained-random transactions
    // =========================================================================
    class fifo_generator;

        mailbox #(fifo_txn) gen2drv;
        int unsigned        total_generated;

        function new(mailbox #(fifo_txn) gen2drv);
            this.gen2drv = gen2drv;
        endfunction

        // Run one test phase: n cycles with the given operation probabilities
        task run_phase(string name, int unsigned n, int unsigned wr_pct, int unsigned rd_pct);
            fifo_txn t;
            $display("[%0t] GEN   phase '%s': %0d cycles, write %0d%%, read %0d%%",
                     $time, name, n, wr_pct, rd_pct);
            repeat (n) begin
                t = new();
                t.wr_pct = wr_pct;
                t.rd_pct = rd_pct;
                if (!t.randomize())
                    $fatal(1, "GEN: randomization failed");
                gen2drv.put(t);   // blocks until the driver takes it (mailbox size 1)
                total_generated++;
            end
        endtask

    endclass


    // =========================================================================
    // Driver: applies one transaction per clock through the clocking block
    // =========================================================================
    class fifo_driver;

        fifo_vif_t          vif;
        mailbox #(fifo_txn) gen2drv;
        int unsigned        total_driven;

        function new(fifo_vif_t vif, mailbox #(fifo_txn) gen2drv);
            this.vif     = vif;
            this.gen2drv = gen2drv;
        endfunction

        task run();
            fifo_txn t;
            forever begin
                gen2drv.get(t);
                @(vif.drv_cb);
                vif.drv_cb.wr_en   <= t.wr_en;
                vif.drv_cb.rd_en   <= t.rd_en;
                vif.drv_cb.wr_data <= t.wr_data;
                total_driven++;
            end
        endtask

    endclass


    // =========================================================================
    // Monitor: passively samples the pins at every clock edge
    // =========================================================================
    class fifo_monitor;

        fifo_vif_t             vif;
        mailbox #(fifo_sample) mon2scb;

        function new(fifo_vif_t vif, mailbox #(fifo_sample) mon2scb);
            this.vif     = vif;
            this.mon2scb = mon2scb;
        endfunction

        task run();
            fifo_sample s;
            forever begin
                @(vif.mon_cb);
                if (!vif.mon_cb.rst_n)
                    continue;            // ignore cycles while in reset

                s             = new();
                s.wr_en       = vif.mon_cb.wr_en;
                s.rd_en       = vif.mon_cb.rd_en;
                s.wr_data     = vif.mon_cb.wr_data;
                s.rd_data     = vif.mon_cb.rd_data;
                s.full        = vif.mon_cb.full;
                s.empty       = vif.mon_cb.empty;
                s.almost_full = vif.mon_cb.almost_full;
                s.overflow    = vif.mon_cb.overflow;
                s.underflow   = vif.mon_cb.underflow;
                mon2scb.put(s);
            end
        endtask

    endclass


    // =========================================================================
    // Scoreboard: reference model (a SystemVerilog queue) + checks + coverage
    // =========================================================================
    class fifo_scoreboard;

        mailbox #(fifo_sample) mon2scb;

        bit [DATA_WIDTH-1:0] model [$];     // golden FIFO contents

        // A read accepted on edge N shows its data on edge N+1
        bit                  read_pending;
        bit [DATA_WIDTH-1:0] expected_rd_data;

        // Error flags are registered: they report the previous edge
        bit                  expected_overflow;
        bit                  expected_underflow;

        int unsigned writes, reads, data_checks, errors;

        // ---------------------------------------------------------------------
        // Functional coverage
        // ---------------------------------------------------------------------
        covergroup cg with function sample(int unsigned level, bit wr, bit rd);
            option.per_instance = 1;

            cp_level : coverpoint level {
                bins empty       = {0};
                bins low         = {[1 : DEPTH/2 - 1]};
                bins high        = {[DEPTH/2 : DEPTH - 2]};
                bins one_left    = {DEPTH - 1};
                bins full        = {DEPTH};
            }

            cp_op : coverpoint {wr, rd} {
                bins idle  = {2'b00};
                bins read  = {2'b01};
                bins write = {2'b10};
                bins both  = {2'b11};
            }

            // Every operation in every fill state, including the corner cases:
            // write when full (overflow), read when empty (underflow),
            // simultaneous read+write when full and when empty.
            cx_level_op : cross cp_level, cp_op;

            cp_transitions : coverpoint level {
                bins became_full  = (DEPTH - 1 => DEPTH);
                bins left_full    = (DEPTH => DEPTH - 1);
                bins became_empty = (1 => 0);
                bins left_empty   = (0 => 1);
            }
        endgroup

        function new(mailbox #(fifo_sample) mon2scb);
            this.mon2scb = mon2scb;
            cg = new();
        endfunction

        task run();
            fifo_sample s;
            forever begin
                mon2scb.get(s);
                check(s);
            end
        endtask

        function void report_error(string msg);
            errors++;
            if (errors <= 10)
                $error("[%0t] SCB   %s", $time, msg);
        endfunction

        function void check(fifo_sample s);
            int unsigned level;
            bit          do_write;
            bit          do_read;

            level = model.size();

            // 1. Data from the read accepted on the previous edge
            if (read_pending) begin
                data_checks++;
                if (s.rd_data !== expected_rd_data)
                    report_error($sformatf("rd_data mismatch: expected 0x%0h, got 0x%0h",
                                    expected_rd_data, s.rd_data));
                read_pending = 0;
            end

            // 2. Status flags must agree with the model's fill level
            if (s.full !== (level == DEPTH))
                report_error($sformatf("full=%0b but model holds %0d entries", s.full, level));
            if (s.empty !== (level == 0))
                report_error($sformatf("empty=%0b but model holds %0d entries", s.empty, level));
            if (s.almost_full !== (level >= ALMOST_FULL_TH))
                report_error($sformatf("almost_full=%0b but model holds %0d entries", s.almost_full, level));

            // 3. Registered error flags refer to the previous edge
            if (s.overflow !== expected_overflow)
                report_error($sformatf("overflow=%0b, expected %0b", s.overflow, expected_overflow));
            if (s.underflow !== expected_underflow)
                report_error($sformatf("underflow=%0b, expected %0b", s.underflow, expected_underflow));

            expected_overflow  = s.wr_en && (level == DEPTH);
            expected_underflow = s.rd_en && (level == 0);

            cg.sample(level, s.wr_en, s.rd_en);

            // 4. Apply the operations the DUT should accept on this edge.
            //    Both decisions use the level BEFORE this edge, like the RTL.
            do_write = s.wr_en && (level < DEPTH);
            do_read  = s.rd_en && (level > 0);

            if (do_read) begin
                expected_rd_data = model.pop_front();
                read_pending     = 1;
                reads++;
            end

            if (do_write) begin
                model.push_back(s.wr_data);
                writes++;
            end
        endfunction

        function bit passed();
            return (errors == 0) && (data_checks > 0);
        endfunction

        function void report();
            $display("");
            $display("==================== SCOREBOARD ====================");
            $display(" Writes accepted      : %0d", writes);
            $display(" Reads accepted       : %0d", reads);
            $display(" Read data checked    : %0d", data_checks);
            $display(" Errors               : %0d", errors);
            $display(" Functional coverage  : %0.2f %%", cg.get_inst_coverage());
            $display("====================================================");
            if (passed())
                $display(" TEST PASSED");
            else
                $display(" TEST FAILED");
            $display("====================================================");
        endfunction

    endclass


    // =========================================================================
    // Environment: builds and connects the components, runs the test plan
    // =========================================================================
    class fifo_env;

        fifo_vif_t             vif;
        mailbox #(fifo_txn)    gen2drv;
        mailbox #(fifo_sample) mon2scb;

        fifo_generator  gen;
        fifo_driver     drv;
        fifo_monitor    mon;
        fifo_scoreboard scb;

        function new(fifo_vif_t vif);
            this.vif = vif;
            gen2drv  = new(1);
            mon2scb  = new();
            gen      = new(gen2drv);
            drv      = new(vif, gen2drv);
            mon      = new(vif, mon2scb);
            scb      = new(mon2scb);
        endfunction

        task run_test();
            fork
                drv.run();
                mon.run();
                scb.run();
            join_none

            // Test plan: phases chosen to reach every coverage bin
            gen.run_phase("fill to full",        200, 90, 10);
            gen.run_phase("drain to empty",      200, 10, 90);
            gen.run_phase("random",             1000, 50, 50);
            gen.run_phase("hold near full",      300, 80, 60);
            gen.run_phase("hold near empty",     300, 60, 80);
            gen.run_phase("idle",                  5,  0,  0);

            // Let the last transactions reach the DUT and the scoreboard
            repeat (5) @(vif.mon_cb);
            wait (mon2scb.num() == 0);

            disable fork;
            scb.report();
        endtask

    endclass

endpackage

// ----------------------------------------------------------------- tb/fifo_sva.sv
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

// ----------------------------------------------------------------- tb/tb_top.sv
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
