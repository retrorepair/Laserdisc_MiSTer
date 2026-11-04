#!/bin/sh
# tb_ld_stream: ld_stream + dsc_decoder against a DDR3 model holding a real DSCV frame.
# Inputs: python gen_ld_stream.py ../../analysis/dscv/test30a.dscv 5 ../../analysis/dscv/f305a_dsc.ppm dscv
# ModelSim ASE 10.5 rejects dsc_decoder.sv's two declarations placed after their first use (Quartus accepts
# them), so the simulation compiles a copy with lines 533-534 moved above the always block at line 496.
# core/rtl/dsc_decoder.sv itself stays identical to MiSTer-LaserActive's.
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
awk 'NR==FNR { if (FNR==533 || FNR==534) d = d $0 "\n"; next }
     FNR==496 { printf "%s", d } FNR==533 || FNR==534 { next } { print }' ../rtl/dsc_decoder.sv ../rtl/dsc_decoder.sv > dscv/dsc_decoder_sim.sv
$M/vlib work_ls >/dev/null 2>&1
$M/vlog -work work_ls -sv -quiet ../rtl/ld_fifo.sv dscv/dsc_decoder_sim.sv ../rtl/ld_stream.sv ../rtl/ld_audio.v tb_ld_stream.sv || exit 1
$M/vsim -c -quiet -lib work_ls tb_ld_stream -do "run -all; quit -f"
