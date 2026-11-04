#!/bin/sh
# Builds tbc2dscv.exe with MiSTer-LaserActive's DSC encoder sources (MIT), unchanged.
S=../../../ref/repos/MiSTer-LaserActive/MegaCD_MiSTer/tools/mmidsc/src
cd "$(dirname "$0")" && gcc -O2 -Wall -Wextra -D_FILE_OFFSET_BITS=64 -static -I"$S" -o tbc2dscv.exe tbc2dscv.c "$S/dsc.c" "$S/dscv.c" "$S/util.c" -lpthread -lm
