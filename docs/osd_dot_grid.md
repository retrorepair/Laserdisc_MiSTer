# M50552-132SP dot grid: what the footage does and does not establish (2026-11-03)

Goal: the character cell (dots wide × high), the glyph bitmaps, the dot clock, and the raster origin, all
**exact**. These must be known before glyphs can be transcribed "faithfully with the right size, spacing and placement".

## Established (consistent across F1, F2 and F3; see cld1750_osd_evidence.md)
- **24 text columns**. The right block starts at col 17 (`PLAY`, `PAUSE`, `STOP`, `SIDE -A`, `EDITING`, `COMPUTE`).
- Rows are evenly pitched; row 0 is near the top of the picture (about 14-16% down on full-raster footage).
- Character pitch ≈ 1/31-1/32.5 of the visible picture width, so about 1.6 µs per character (about 28 4fsc samples).
- Glyph style (F1, 1080p): vertical strokes are **about twice as thick as horizontal strokes** (≈10-12 px vs 7-9 px);
  corners have a **one-step 45° chamfer**; `A` has a flat chamfered top; `0` is a tall chamfered rectangle without a
  slash; `.` is a small square. White glyphs with a black shadow-style border (heavier right/below).
- Upper and lower case exist (F2: `Search`, `Chapter`).

## Established from a DIRECT capture (2026-11-03): Aladdin "Opening to" video, unknown NTSC player
Source: `ref/videos/Unknown player/Opening to Aladdin 1994 LaserDisc CAV Widescreen.mp4` (640x480 capture of the
player's video output, not a camera). Screen `LASERDISC` / `PLAY`, the same font style as the CLD-1750 footage.
- **Horizontal: 12 dots per character cell.** The glyph edge positions lock to a 1.744 px pitch (Rayleigh R = 0.48-0.52,
  well clear of every other pitch and of the capture's own pixel grid), and the glyph starts repeat every 20.94 px = 12 × 1.745.
- **Vertical: one dot row = one line per field** (2 frame lines). The `Y` arms step one dot sideways per 2 lines.
  Glyphs are **14 dot rows tall** (the capture shows 2.07 lines/row because it is rescaled).
- **Strokes are 2 dots wide and 2 rows tall; glyphs are 10 dots wide with a 2-dot gap.**
- Bitmaps for `L A S E R D I C P Y` transcribed on the fitted grid (`tools/osd/glyph_sample.py` →
  `tools/osd/font_transcribed.json`). Repeated letters (L, A, S) come out bit-identical.
- Character period ≈ 1.71 µs if the capture is square-pixel NTSC (12.27 MHz), so the **dot clock is about 7.0 MHz**. The
  24 columns span about 41 µs (≈78% of the active line), consistent with the CLD-1750 footage.
- Cell height: the CLD-1750 footage glyph/row-pitch ratio is 0.77, and 14 / 0.77 ≈ **18 rows per cell**: a 12×18 cell.
- Cross-check: these bitmaps rendered at the CLD-1750 F1 scale match the F1 `CHAPTER` letter shapes (C, A, P, E, R;
  `analysis/compare_CHAPTER.png`). The F1 strokes look bolder from its shadow border and CRT bloom.

## Still open
- Glyphs not yet transcribed (H, T, M, N, O, U, digits, lower case …): next sources are the CO-V100 service-mode photos,
  the 2850 OSD photo, the unknown-player PAL still and the CLD-1750 footage. **These come from other players/masks,
  so each glyph records its source.**
- Exact dot clock (depends on the capture's sampling rate), raster origin on the CLD-1750, and the shadow-border rule
  (F1, 2850 photo: black border heavier right/below).

## Former hypothesis (now superseded by the direct capture above)
12-dot-wide cell with 2-dot vertical strokes. F1: pitch 62.75 px / 12 = 5.23 px per dot, so a 10-12 px vertical
stroke is 2 dots. This matches the 12×18 cells of the related Mitsubishi M50458 (MAME), but that is a different chip.

## Earlier limits of the camera footage (vertical dot size and cell now RESOLVED by the direct capture above)
- **Vertical dot size and cell height.** In F1 a dot row is about 5.4 px if the cell is 18 rows, but horizontal strokes
  measure 7-9 px, between 1 and 2 rows. CRT bloom and interlace (each dot row drawn on one line of each field) blur this.
  F2 (LCD) and F3 (LCD, possible zoom mode) disagree on the row pitch as a fraction of picture height (≈24 vs ≈18
  field lines), so the TVs' scaling and cropping cannot be trusted for absolute vertical numbers.
- Dot clock (an LC oscillator, roughly 9.5-11.3 MHz from component values; its tolerance is unknown) and therefore the
  exact horizontal size in 4fsc samples.
- Raster origin (first row's line number, first column's sample position) and the border/shadow exact rule.

## How to close it
1. **A real M50552-132SP on the bench** (about £5, user may buy). Drive SCK/SDATA/XCS, feed HOR/VERT/4fsc, and capture
   R/G/B/BLNK: this gives the cell, glyphs, border rule and dot clock exactly. (The command protocol is unknown, so it
   must be found by experiment.)
2. A clean **direct capture** of a CLD-1750's video output (a capture card or Domesday-style CVBS capture) instead of a
   camera on a TV. Sample-exact geometry and glyphs, including the composite artefacts.
3. Until then, the OSD engine is built **parametric** (cell w/h, dot clock divider, origin, border rule as constants),
   and no glyph is committed as final.
