project_open Laserdisc_MiSTer -revision Laserdisc_MiSTer
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 400 -detail summary -to_clock {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk} -file sta_paths.txt
project_close
