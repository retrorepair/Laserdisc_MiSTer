# CLD-1750 video and audio paths, from the service manual (ARP2457)

The source is `ref/cld1750/CLD-1750-EN_Service_Manual_Scan.pdf`. "PDF n" is the scan's page; printed page numbers run 22
ahead (PDF 51 = printed p.73). Renders are in `analysis/sm/` (regenerate them with `tools/docs/render_page.py`).

## Video (VDTB board, 5.8 "VIDEO SECTION", PDF 29; waveforms PDF 31; adjustments PDF 54-55)
| Block | Part | What it does (from the schematic labels and adjustments) |
|---|---|---|
| Video processor | IC401 PA5013(A) | FM demodulator (limiters, D-MMV, multiplier), sync separators (H, V, composite, data separator), pedestal clamp, burst-gate amp. **DOS** (dropout sensor) → pulse stretch → a switch between the main video (pin 35) and the **1H-delayed video (pin 33)**: dropout compensation by the previous line |
| 1H delay | IC402 PM0001 | 112-stage CCD, clocked from **REF SC** (crystal reference subcarrier) ÷ 2. Its "1H DLY VIDEO LEVEL" (VR441) is set so pin 33 equals the main-line video at pin 35 (adjustment table, PAL mode, ±3%) |
| **TBC** | IC403 CXL1009P | Sony **CCD variable delay line**. The time-base corrector is analogue |
| CCD clock | IC404 PA0017 | **VCO** steered by **CCD ERR** from the TBC servo. VR471 sets the centre so the CCD output lags its input by **75 µs = 1H + 11 µs** (±2 µs, PAL); "minimise the jitter at VIDEO OUT on a magenta field" |
| Reference | X202 crystal | **17.734475 MHz ±100 Hz = 4fsc PAL**; 14.31818 MHz for NTSC; 3.5546875 MHz |
| Output | J401 pin 6 | **100% white = 2 Vp-p ±3%** (VR521), i.e. 1 Vp-p into 75 Ω |
| Character generator | IC405 (VDTB) | the OSD chip, mixed into the video before the output buffer |
| MOD.PAL / NTSC conversion | PALB board | "MOD video", "MOD Y/SC level", a comb filter and a 3.2 MHz LPF (IC201), and 1H/750 ns delay lines (DL101/DL201) |

The waveform sheet (PDF 31) was taken on an **NTSC test disc**: 63.5 µs lines, IC402's clock at 0.3 µs (3.58 MHz),
staircase test signal. It gives the shapes and levels of the chain (IC401 pin 1 = 2 Vp-p, pin 29 = 1.25 Vp-p,
pin 31 = 700 mVp-p), not PAL timings.

### What this means for the core
- ld-decode's TBC output is the digital equivalent of the CCD TBC's output: time-base corrected at 4fsc PAL, the
  player's own reference rate. Replaying it at 17.734475 MHz (our ce_4fsc) matches the player's output clock.
- **Dropout compensation:** the player replaces a dropout with the line before it. ld-decode records dropouts
  (`.tbc.db` drop_outs: field, line, start, end) but does not correct them in the TBC, and our converter does not
  either. The pulse-stretch time of IC401 is not given.
- The player's residual CCD-TBC jitter is not modelled (it is adjusted to a minimum; there is no figure).

## Analogue audio (ASCB 2/4, "AFM, SPDL D SECTION", PDF 24)
- IC700 HA12127ANT, **"AUDIO DEMODULATOR & CX NOISE REDUCTION"**, drives ANALOG L/R.
- Control lines **XCX, SQ1, SQ2** run from IC101, the mechanism-control MCU (PDF 28), **into** IC700 through
  D708/D705. So the MCU chooses CX and squelches each channel; IC700 does not report carrier loss. The manual
  gives no pin descriptions, so the condition is not stated there.
- The OM documents "CX auto-switching" and "Audio mode indicators" (the type of audio played). Both come from the
  disc's line-16 **programme status code** (IEC 60857 10.1.8), which the MCU therefore reads.

### Programme status on Community North (decoded with ld-decode-tools `vbidecoder.cpp`)
| Code | Frames in the 0-7499 clip | CX | Audio status (X41 X34 X43 X44) | Parity | Source audio |
|---|---|---|---|---|---|
| 0x8BA41F | 6-2025 (and others) | off | 1 = mono | valid | speech/music harmonics |
| 0x8BA426 | 2026-7499 | off | 2 = "future use" in IEC 60857 and Amendment 2 | valid | only 50/75 Hz buzz, hum and 15.625 kHz whine: no programme |

- No chapter-number codes (IEC 10.1.5, `0x8xxDDD` on lines 17/18) occur anywhere on Community North.
- ld-decode's `.pcm` is not CX-expanded (ld-decode ships a separate `scripts/cx-expander`, CX-14). Community North is
  CX off, so no expansion applies to it.
