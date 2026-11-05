#!/bin/sh
# tb_cc: the caption decoder box on EIA-608 line 21 waveforms
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
$M/vlib work_cc >/dev/null 2>&1
$M/vlog -work work_cc -sv -quiet ../rtl/cc608.v tb_cc.sv || exit 1
$M/vsim -c -quiet -lib work_cc tb_cc -do "run -all; quit -f" | grep -v "^# Loading\|^# //"
