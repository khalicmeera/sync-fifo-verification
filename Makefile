# Local simulation (needs a commercial simulator with SystemVerilog class,
# covergroup and SVA support). For a free option, use EDA Playground (see README).
SEED ?= 1

vcs:
	vcs -sverilog -full64 -timescale=1ns/1ps -f files.f -o simv
	./simv +ntb_random_seed=$(SEED)

questa:
	vlib work
	vlog -sv -f files.f
	vsim -c -sv_seed $(SEED) tb_top -do "run -all; quit"

xcelium:
	xrun -sv -f files.f -svseed $(SEED) -access +r

clean:
	rm -rf simv* csrc *.log *.vcd *.vpd work transcript xcelium.d ucli.key DVEfiles
