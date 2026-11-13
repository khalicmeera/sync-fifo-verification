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
