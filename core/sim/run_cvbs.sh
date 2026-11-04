#!/bin/sh
# tb_cvbs: ld_stream (composite stream) + cvbs_scan + tbc_timing against a DDR3 model holding a real composite frame.
# Inputs: gen_cvbs.py (dscv/cv_hdr.hex, dscv/cv_slot.hex). dsc_decoder: the sim copy, as run_ld_stream.sh.
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
awk 'NR==FNR { if (FNR==533 || FNR==534) d = d $0 "\n"; next }
     FNR==496 { printf "%s", d } FNR==533 || FNR==534 { next } { print }' ../rtl/dsc_decoder.sv ../rtl/dsc_decoder.sv > dscv/dsc_decoder_sim.sv
$M/vlib work_ls >/dev/null 2>&1
$M/vlog -work work_ls -sv -quiet ../rtl/ld_fifo.sv dscv/dsc_decoder_sim.sv ../rtl/ld_stream.sv ../rtl/tbc_timing.v ../rtl/cvbs_scan.v tb_cvbs.sv || exit 1
$M/vsim -c -quiet -lib work_ls tb_cvbs -l cvbs_sim.log -do "run -all; quit -f"
