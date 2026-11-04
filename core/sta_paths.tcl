project_open Laserdisc_MiSTer -revision Laserdisc_MiSTer
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 25 -detail summary -to_clock {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} -file sta_paths.txt
project_close
