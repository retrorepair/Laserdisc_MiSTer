#!/bin/sh
# tb_modpal: modpal.v against tools/analysis/modpal_ref.py. Vectors: modpal_vectors.py <GGV1069 tbc> core/sim
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
$M/vlib work_mp >/dev/null 2>&1
$M/vlog -work work_mp -sv -quiet ../rtl/modpal.v tb_modpal.sv || exit 1
$M/vsim -c -quiet -lib work_mp tb_modpal -do "run -all; quit -f" | grep -v "^#   \|^# Loading\|^# //"
