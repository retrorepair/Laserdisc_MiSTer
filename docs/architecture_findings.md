# LD-V4300D control architecture: findings (Phase 0)

Sources: service manual ARP2311 (pages cited are PDF page numbers), dumped EPROM DYW1362.

## Two MCUs on the CONT assembly (DWG1207)

From the CONT parts list (PDF p.52) and the CONT schematic (PDF p.33):

| Ref | Part | Schematic marking | Role | Program |
|---|---|---|---|---|
| IC1 | PD0081A1 "MECHANISM CONT. MCU" | MECHA CONTROL, "7004" | Spindle/TBC/slider/tilt/tracking servo control, FG, V/H sync, EXTSYNC, CD subcode (SQSO/SCOR), handshake to IC2 (TRN_RQT/TRN_RDY, SO3/SCK3) | **External EPROM IC3 (256 Kbit) on a full A0-A15/D0-D7 bus: this is the dumped DYW1362/DYW1385** |
| IC2 | PD0110A "MODE CONT. MCU" | MODE CONTROL, "7400" | RS-232 TxD/RxD/DTR, remote (REMIN), KEY0-7 front panel, LED0-7, EEPROM IC13 (M6M80011, EEPBUSY/EEPDIS), display/character generator serial (DI/DO/SCK1, DBUSY, DISPDIS), PAL/NTSC, SYNCSEL/VDSEL/EXTDIS/PLL ON, AUX1/AUX2 | **Internal mask ROM. No external bus. Not dumped.** |
| IC601 (VDEM) | MB90061-101A | | On-screen character generator | Internal font. Not dumped. |
| IC3 | 256 Kbit EPROM | "256Kbit ROM" | IC1 program | dumped |
| IC4, IC5 | CXD1095Q | | Parallel I/O expanders on IC1 bus | n/a |
| IC6 | TC74HC139AF | | IC1 address decode | n/a |
| IC13 | M6M80011AL | MEMORY SWITCH | Serial EEPROM (settings) on IC2 | contents unknown |

The service-mode screen (PDF p.66, Fig. 6) shows `Mecha DYW1000A OK` and `Mode PD0110A OK`, i.e. the
firmware self-identifies both programs and checksums them. The OSD text of that screen ("Tracking
Open", "Focus Balance", …) does **not** appear in the EPROM, consistent with IC2 owning the display.

**Consequence:** the behaviour the user cares most about (OSD content/layout/timing, RS-232 command
parser and responses, front-panel/remote handling, error codes E00…) is implemented by IC2's
**undumped** mask ROM, and the glyph shapes by IC601's **undumped** font. The dumped EPROM covers the
mechanism/servo side only.

## IC1 CPU: Mitsubishi MELPS 740 (6502 superset), ROMless mode

Evidence from DYW1362:
- Reset handler `$B5A9`: `SEI; CLT; CLD; CLC; CLV; CLB4 $FF; LDX #$BF; TXS; LDM #$FF,$E8 …`.
  `CLT` (0x12), `LDM` (0x3C), `SEB/CLB/BBS/BBC` are 740-only opcodes.
- Vector block `$FFF4-$FFFF` (6 vectors), RESET at `$FFFE` (740 convention, not 6502 `$FFFC`):

  | Vector | Target |
  |---|---|
  | $FFF4 | $A69F |
  | $FFF6 | $B5A9 (same as reset) |
  | $FFF8 | $9E62 |
  | $FFFA | $A4BA |
  | $FFFC | $A5F2 |
  | $FFFE | $B5A9 RESET |

- SFRs written in zero page `$E8-$EE`, CPU mode register bit cleared at `$FF`: 740-family SFR block at `$00E0-$00FF`.
- Internal RAM used `$0000-$01BF` (stack top `$01BF`).
- External I/O: `$4000-$4004` and `$6000-$6004` only (two CXD1095Q expanders via 74HC139).
- ROM image `$8000-$FFFF`; used to `$C742` (PAL) / `$C4F7` (NTSC). `$8000-$803F` is a block of
  `JMP $FFFF; NOP` placeholders, `$8040+` a word table (indirect dispatch: needs following to raise coverage
  beyond the current 8 KB).
- PAL vs NTSC EPROMs differ in 17,637 bytes: separate builds, not a patch.

Exact 740 derivative (SFR map, timers, serial, the custom FG/servo blocks implied by pins like
RF FREQ, TILT_ERR, SLDR_DRV, PBFM, REFFRM) is **unidentified**. PD0081A1 is a Pioneer house number.

## Serial interface (authoritative: Operating Instructions p.12 onward)

15-pin D-sub; RS-232C on pins 2/3 (TxD/RxD) plus DTR pin 4; TTL TxD/RxD on 9/10; 1 start, 8 data, 1 stop;
9600/4800/1200 bps by FUNCTION switch; ASCII mnemonic commands, max 20 characters per line. Command table is
on the following pages of the Operating Instructions (`ref/docs/*Operating-Instructions*_text.txt`).

## Other Pioneer players with public firmware dumps (MAME, checked 2026-11-03)

| Player | What is dumped | OSD / character font |
|---|---|---|
| PR-8210 (NTSC consumer) | i8049 MCU `pr-8210_mcu_ud6005a.bin` (2 KB), LLE in MAME | Font **hand-drawn and incomplete** in MAME (many glyphs empty) |
| LD-V1000 (NTSC industrial, parallel I/F) | Z80 program `z03_1001_vyw-053_v1-0.bin` (8 KB), LLE in MAME | MAME TODO "add OSD" |
| LD-V4200 | nothing (MAME HLE from docs) | n/a |
| LD-V4300D / LD-V4400 | mechanism EPROM only | n/a |

No Pioneer player was found with **all** program ROMs and the character-generator font dumped.
