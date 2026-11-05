# NTSC playback (phase 1: native NTSC output)

User decision, 2026-11-04: NTSC discs play as NTSC (525 lines, 60 Hz) first. The European CLD-1750's MOD. PAL and PAL
outputs for NTSC discs (OM p.46, the PALB board) come later, as phase 2.

## The capture (GGV1069 NTSC test disc, ld-decode)
- 4fsc = 14.318182 MHz, 910 samples per line, 525 lines, `field_height` 263, subcarrier-locked TBC.
- Levels (16-bit): blanking 15360, black 18048 (7.5 IRE setup), white 51200; 358.4 per IRE.
- Burst at samples 74-110 (9 cycles); active video 134-894.
- **Field structure (measured):** the first field's 263 stored lines are real, its line 262 a half line (normal sync,
  then an equalising pulse); the second field has 262 real lines and its stored line 262 is padding (a copy of the
  next field's line 0, mean difference 12). Same layout as PAL's 313/312.
  - First field: lines 0-2 equalising, 3-5 broad, 6-8 equalising, 9-261 normal, 262 normal + equalising.
  - Second field: 0-1 equalising, 2 equalising + broad, 3-4 broad, 5 broad + equalising, 6-7 equalising, 8 equalising
    + none, 9-261 normal.
  - Pulse widths at 50%: line sync 66, equalising 32, broad 386 samples (4.7, 2.3, 27.1 us).

## Converter (tools/convert/dscv)
- `tbc2dscv.py` takes the system from the `.tbc.db`. NTSC keeps samples 130-897 (768 = a multiple of 3 and 8, covering
  ld-decode's 134-893) and frame-flat lines 20-523 (field lines 10-261, VBI included). Frames are 33367 us, and the
  decoder is Decode-Orc's `ntsc3d`.
- `add_cvbs.py` takes the line length, field lines, white and blanking from the capture. NTSC lines are padded to 912
  bytes; a frame is 2 x 263 x 912.

## Core
- **Clock:** one reconfigurable fractional PLL, switched through `pll_cfg` when a parsed disc's system differs (header
  w3 bit 63, from the DSCV `src_height`). M = 8 in both; PAL K 2201376898, C 6 (70.9379 MHz); NTSC K 78090314, C 7
  (57.272727 MHz, within 0.01 ppb). The core is held in reset until the PLL locks.
- **Timing (`tbc_timing`):** 910 samples, fields of 263 then 262 lines; the picture-on jump goes to line 40 (85%).
- **Composite (`cvbs_scan`, `ld_stream`):** 114-word lines (912 B), 263 rows per field. The raster carries the
  measured NTSC vertical interval: sync tip -40 IRE (1024), burst +-20 IRE on every normal line, 227.5 subcarrier
  cycles per line (half a cycle per line), no burst blanking. DAC code = level x 255 / 51200.
- **RGB output:** HSync 0-66, active 134-893 by field lines 20-261, VSync on the broad pulses.
- **OSD (`osd_m50552`):**
  - The dot clock stays 7.03 MHz (the chip's own oscillator): STEP 32177, first dot at sample 221.
  - The blue's luma sits on the 7.5 IRE setup (YB 7775); its chroma is scaled by 0.925 and referred to NTSC's 180 deg
    burst with no V-switch (Q = -81671, 27499); the outline is black at the setup level.
  - **The first row (line 33, centring the 216-line grid) is an estimate:** no NTSC footage of this OSD has been
    found yet.
- **Burst measurement (`pal_decoder`):** NTSC window 78-109.
- **Audio:** 44.1 kHz exactly from clk_sys = 630 MHz / 11 (44100 x 11 / 630000000).
- **Player timings:** the same seconds, counted in 29.97 Hz frames (x 1.1988).

## Not yet
- Testing on hardware with the converted GGV1069.
- The SYSTEM menu modes for NTSC discs (MOD. PAL, PAL): phase 2.
- An NTSC simulation of the composite path.
