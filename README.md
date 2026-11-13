# Parameterised Synchronous FIFO – RTL Design & Class-Based Verification

A parameterised single-clock FIFO written in SystemVerilog RTL, verified with a
**class-based SystemVerilog testbench** (generator, driver, monitor, scoreboard),
**constrained-random stimulus**, **SystemVerilog Assertions (SVA)** and
**functional coverage**.

```
rtl/sync_fifo.sv        FIFO design (DUT)
tb/fifo_if.sv           Interface with driver / monitor clocking blocks
tb/fifo_pkg.sv          Transaction, generator, driver, monitor, scoreboard, environment
tb/fifo_sva.sv          Assertions + cover properties (attached with bind)
tb/tb_top.sv            Clock, reset, DUT, bind, test start
eda_playground/         Same code as two files, ready to paste into EDA Playground
files.f, Makefile       Local runs with VCS / Questa / Xcelium
```

## Run it (free, in the browser)

1. Open <https://www.edaplayground.com> and log in (free account).
2. Left panel: **Testbench + Design** → `SystemVerilog/Verilog`.
3. **Tools & Simulators** → `Synopsys VCS` (or `Aldec Riviera Pro`).
4. Paste `eda_playground/testbench.sv` into the **testbench.sv** pane and
   `eda_playground/design.sv` into the **design.sv** pane.
5. Tick **Open EPWave after run** to see waveforms, then click **Run**.
6. Optional: add `+ntb_random_seed=7` to *Run Options* (VCS) to try other seeds.

Expected end of the log:

```
==================== SCOREBOARD ====================
 Writes accepted      : ...
 Reads accepted       : ...
 Read data checked    : ...
 Errors               : 0
 Functional coverage  : 100.00 %
====================================================
 TEST PASSED
```

Locally: `make vcs`, `make questa` or `make xcelium` (`SEED=5 make vcs`).

## Design

| Parameter | Default | Meaning |
|---|---|---|
| `DATA_WIDTH` | 8 | Bits per entry |
| `DEPTH` | 16 | Number of entries (power of 2) |
| `ALMOST_FULL_TH` | `DEPTH-2` | `almost_full` when count ≥ this |

**Full vs empty with one extra pointer bit.** Both pointers are `AW+1` bits
(`AW = log2(DEPTH)`). The low `AW` bits address the memory; the top bit flips
every time a pointer wraps around.

- `empty` = pointers exactly equal
- `full` = low bits equal **and** top bits different (writer is one lap ahead)
- `count = wr_ptr - rd_ptr` (modular subtraction gives 0 … DEPTH)

**Protection.** `do_write = wr_en && !full`, `do_read = rd_en && !empty`.
An illegal access is ignored and reported one cycle later on `overflow` or
`underflow`.

**Timing.** Read data is registered: a read accepted on clock edge N shows
`rd_data` after edge N, which the testbench checks at edge N+1. The memory
array has no reset (saves area); only pointers and flags are reset.

## Verification environment

```
            +-----------+   mailbox(1)   +--------+   drv_cb    +-----------+
 test plan->| generator |--------------->| driver |------------>|           |
            +-----------+                +--------+             | sync_fifo |
                                                                |   (DUT)   |
            +------------+   mailbox     +---------+   mon_cb   |           |
            | scoreboard |<--------------| monitor |<-----------|  + SVA    |
            |  queue     |               +---------+            +-----------+
            |  model +   |
            |  coverage  |
            +------------+
```

- **Transaction (`fifo_txn`)**: random `wr_en`, `rd_en`, `wr_data` for one
  cycle. Per-phase knobs `wr_pct` / `rd_pct` steer the `dist` constraints;
  data is biased towards `0x00` and `0xFF`.
- **Generator**: runs the test plan as phases; the size-1 mailbox keeps it in
  step with the driver.
- **Driver**: drives one transaction per clock through `drv_cb` (1 ns after
  the edge, so there is no race with the DUT).
- **Monitor**: passive; samples every pin through `mon_cb` (`#1step`, the
  values the DUT saw on that edge).
- **Scoreboard**: a SystemVerilog queue is the reference model. Each cycle it
  checks the read data from the previous cycle, `full` / `empty` /
  `almost_full`, and `overflow` / `underflow`. It then applies the writes and
  reads the DUT should accept, using the fill level *before* the edge exactly
  as the RTL does.

### Test plan

| Phase | Cycles | Write % | Read % | Purpose |
|---|---|---|---|---|
| fill to full | 200 | 90 | 10 | Reach full, attempt overflow |
| drain to empty | 200 | 10 | 90 | Reach empty, attempt underflow |
| random | 1000 | 50 | 50 | Random walk through all levels |
| hold near full | 300 | 80 | 60 | Read + write while full |
| hold near empty | 300 | 60 | 80 | Read + write while empty |
| idle | 5 | 0 | 0 | Let the last read data come out |

### Functional coverage (`fifo_scoreboard::cg`)

- `cp_level`: empty, low, high, one slot left, full
- `cp_op`: idle, read, write, read+write
- `cx_level_op`: every operation in every fill state (20 bins). It includes
  write-when-full, read-when-empty and simultaneous read+write at both ends.
- `cp_transitions`: became full, left full, became empty, left empty

### Assertions (`fifo_sva.sv`, attached with `bind`)

| Assertion | Checks |
|---|---|
| `a_not_full_and_empty` | Never full and empty together |
| `a_count_in_range` | Occupancy ≤ DEPTH |
| `a_no_write_when_full` | Write pointer frozen while full |
| `a_no_read_when_empty` | Read pointer frozen while empty |
| `a_overflow_flag`, `a_no_false_overflow` | `overflow` exactly when a write hit a full FIFO |
| `a_underflow_flag`, `a_no_false_underflow` | `underflow` exactly when a read hit an empty FIFO |
| `a_becomes_full`, `a_becomes_empty` | Last write fills it, last read empties it |
| `a_reset_empty` | Empty while reset is held |

Cover properties confirm that full, overflow, underflow, read+write when full,
pointer wrap-around and a full-to-empty sequence all happened.

## Next steps

- Port the environment to **UVM** (agent, sequencer, sequences, `uvm_config_db`).
- An **asynchronous FIFO** (two clocks) with Gray-coded pointers and
  two-flop synchronisers for clock domain crossing.
- Mid-test reset and back-to-back reset scenarios.
