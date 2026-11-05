#!/bin/sh
# tb_player: search, chapter skip and DISPLAY on GGV1069's VBI codes (player_vbi.hex from the capture's .tbc.db)
M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
$M/vlib work_pl >/dev/null 2>&1
$M/vlog -work work_pl -sv -quiet ../rtl/player.v tb_player.sv || exit 1
$M/vsim -c -quiet -lib work_pl tb_player -do "run -all; quit -f" | grep -v "^# Loading\|^# //"
