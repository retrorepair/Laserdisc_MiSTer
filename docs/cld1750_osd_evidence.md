# CLD-1750 OSD and front-panel evidence: footage catalogue

## Source F1: RetroGamerVX, "Laserdisc Player Review: Pioneer CLD-1750 (Including Internal Workings)"

- URL: https://www.youtube.com/watch?v=IMdDAQigdmA (606 s, 1920x1080, 29.97 fps). Local copy in `ref/cld1750/footage/`
  (SHA-256 a725d4e4e9f91be16a635c7ded8a106815fd70aa6f5061d0d448399cad2ede10).
- **Unit:** European PAL model. The rear label reads MFD. OCTOBER 1992, serial MJ8508061 YD, and it is playing PAL discs
  (*Alien* PAL widescreen, *The Fifth Element*).
- **Capture conditions:** a camera pointed at a CRT. Auto-exposure shifts the blue background colour (cyan to blue).
  The **top of the picture is cropped** by the framing, so absolute vertical placement cannot be measured from this source.
- Frames: `analysis/footage_IMdDAQigdmA/osd/osd_NNN.png`, extracted at 2 fps from t=286 s, so frame N is at t ≈ 286 + N/2 s.
  (Contact-sheet timestamps run about 2 s off from this.)

### TV-screen OSD observed (white glyphs, black outline, on a blue background screen)

| Frames | Screen content (left block / right block) | Notes |
|---|---|---|
| osd_004-018 | `CLOSE` (top right) | Tray-closing state. "Lines will disappear once video starts" is the uploader's caption, not OSD. |
| osd_019-030 | `PLAY` (top right) | Spin-up |
| osd_030-036 | `LASERDISC` / ` -PAL-` (top left); `PLAY` / `SIDE -A` (top right) | Disc identification after spin-up |
| osd_036-038 | `CHAPTER   1` (top left) | First chapter is reached, then the picture fades in |
| osd_142-151 | `CHAPTER   1` / `TIME   0.00` (left); `PAUSE` then `EDITING` / `COMPUTE` (right); a 6×4 grid of `--` below | PAUSE screen with the Edit Compute program table (24 slots) |

Visual properties (to be measured precisely):
- Bordered (outlined) character mode on a solid blue raster, consistent with the M50552's background and border modes.
- Upper-case-only font in the observed text; `0` without a slash; `-` is a short bar; `.` sits at the baseline.
- Two text blocks: left starting around 10% of the visible width, right around 65%. Rows are evenly pitched.
- The `--` grid has 6 columns at an even pitch, aligned under the text blocks.

### FL (front-panel display) observed

| Time (contact sheet) | Content |
|---|---|
| 1:54-2:36 | Close-ups of the FL window in CD mode: `CD`/`CDV` disc-type legends, TRACK and TIME legends, `0  0M00S`, the 1-20 track calendar grid, and the red "LaserDisc" legend |
| 7:06-7:34 | Counting numeric display during jog/shuttle (values like 1135 … 1626) with legend segments lit |

### Other useful content
- 1:30-1:48: front panel close-up (REMOTE SENSOR, POWER STANDBY/ON, LEVEL, PHONES).
- 2:38-3:12: key legends: DIRECT SEARCH, 0-9, +10, PGM, SYSTEM, RANDOM PLAY, HILITE/INTRO SCAN, 16:9, LANGUAGE,
  1-BIT DLC, the SCAN/LEVEL jog dial, and REVERSE/FORWARD.
- 3:36-4:14: rear panel: AV CONNECTOR (SCART), VIDEO OUT, AUDIO OUT, DIGITAL OUT OPTICAL, CD-DECK SYNCHRO, CONTROL IN/OUT.
- 7:36-8:02: playback picture quality (camera focus poor).
- 8:04-9:02: internals: boards, pickup, loading mechanism.

## Source F2: Retrodiggs, "Pioneer CLD-3080 Laserdisc Player" (CLD-3080, believed to be the same M50552-132SP mask)

- https://www.youtube.com/watch?v=f-a_ugpKomI. 854x480 only. Shown on a modern LCD TV, **whole raster visible**
  (stretched to 16:9). Frames are in `analysis/footage_f-a_ugpKomI/`.
- Screens: `LASERDISC` (row 0, left); `A PLAY` / `B PLAY` (row 0, right) because this is a two-sided auto-reverse player;
  `Search` + `B` (row 0); `Chapter 00` (row 1).
- **The font includes lower case** (`Search`, `Chapter`). The glyph shapes (narrow rounded `0`, `C`, `S`, `E`, `R`) and the
  thin dark outline match the CLD-1750. F1 looks bolder because of CRT bloom and the camera. Consistent with the same
  mask, but not proof at 480p.
- **Placement within the full raster** (as displayed by the LCD, whose own overscan is unknown): row 0 is about 14% down
  from the top of the picture, the left block starts about 11% in, the row pitch is about 8.2% of picture height, and the
  character pitch is about 1/32.5 of the visible width. The right-hand block is at col 14 on this player (col 17 on the
  CLD-1750: different mode-MCU firmware, so different layouts; this is a per-player string/layout choice, not the chip).
- The strings differ from the CLD-1750 (`PLAY`/`SIDE -A` vs `A PLAY`). **The text and layout come from the mode-MCU
  firmware; only the glyphs come from the M50552 mask.** CLD-3080 screens must not be used as CLD-1750 screens.

## Source F3: RetroGamerVX, "My First Ever Laserdisc Play On My First Ever Player! (Pioneer CLD-1750)"
- https://www.youtube.com/watch?v=lfdYgYbGg58, 720p, whole screen visible on a flat TV. Frame `analysis/footage_lfdYgYbGg58/t103_5.png`.
- About 1:40 (t≈100-104 s): **`STOP` on a black background**, row 0 at **col 17** (the right block, as `PAUSE`/`PLAY` on F1).
  Character pitch ≈28.75 px, about 31.3 chars across the visible width; row 0 centre about 16% down from the top of the visible
  picture. Black background = MOD. PAL per OM p.46.

## Background colour and SYSTEM modes (OM p.46, SYSTEM button)
- **Background is blue in NTSC mode or PAL mode, and black in MOD. PAL mode** at power-on or when NTSC
  discs are played. (The user also recalls blue/black; per the OM it is tied to the SYSTEM mode, not a free setting.)
- The SYSTEM button cycles the output mode for the disc/TV combination. For NTSC discs: NTSC (colour or B/W), MOD. PAL
  (colour), PAL (colour or B/W), each with a picture SIZE of FULL, SHRINK (vertical shrink) or STRETCH (about 120%
  vertical). PAL discs play as PAL. The exact table cells must be transcribed from the OM page image (the OCR is
  scrambled). This is the PALB-board NTSC→PAL converter behaviour.
- Re-checked 2026-11-03 (user recalls a background option): the OM has **no separate background setting**. The only
  rule is this SYSTEM-mode one (blue in NTSC/PAL mode, black in MOD. PAL at power-on or with NTSC discs). The core
  implements background = f(SYSTEM mode) and mirrors SYSTEM mode as a MiSTer menu option, two-way (whichever changed
  last wins).

## Overlay vs background screen
- The user recalls that the OSD **also overlays live video** (2026-11-03). The OM DISPLAY section describes on-screen
  time/frame info during playback, consistent with superimposition. Every screen in F1 is on the **blue background
  raster** (stop/load/pause). **Footage of the overlay mode during playback is still needed**: border/outline rendering
  over picture, and whether a background box is drawn.

## Screen geometry measured from F1 (osd_150 PAUSE, osd_032 load screen)
- Character pitch **≈62.75 px** in the 1080p capture, consistent across the `--` grid (grid spacing is exactly 4 chars).
- Text occupies **24 columns**: the left block starts at col 0, the right block (`PAUSE`, `PLAY`, `SIDE -A`, `EDITING`,
  `COMPUTE`) at **col 17**, and `COMPUTE` ends at col 23. This matches the 24-column Mitsubishi OSD family.
- Row pitch **≈97.5 px**. Row 0: `PAUSE`, or `LASERDISC` + `PLAY`. Row 1: `CHAPTER   1`, or ` -PAL-` + `SIDE -A`.
  Row 2: `TIME   0.00` + `EDITING`. Row 3: `COMPUTE`. Rows 4-7: the 6 `--` entries at cols 1,5,9,13,17,21.
- Glyph height ≈72 px against the 97.5 px row pitch. The outline is black on all sides and heavier right/below (shadow-like).
- **Not determinable from F1:** absolute dot matrix (CRT blur and unknown camera scale), total rows (the top and bottom
  are cropped), absolute raster position.

## Clocking (SM p.54, 7.5 Electrical adjustments)
- The M50552 **OSCIN (pin 29, via C507) receives the current system's 4fsc**: PAL 17.734475 MHz ±100 Hz (VC401,
  measured at R506) and NTSC 14.31818 MHz ±100 Hz (VC201, at C507). So the OSD/background chroma is locked to the player's
  4fsc, exactly as the TBC samples are.
- The dot clock is a separate LC oscillator on OSC1/OSC2 (L419 12 µH, C501/C502 33 pF series), roughly 9.5-11.3 MHz
  including strays (estimate; to be measured on a real chip).
- The European unit's **PALB board** contains the **NTSC→PAL converter** (comb filter, "MOD" video path, adjustments
  8-11 on SM p.55). NTSC discs leave the player as PAL.

## M50552 leads (2026-11-03)
- **No M50552 datasheet** has been found (by the user or me); it is likely a customer-direct part.
- **Same mask, so the same font:** the CLD-3080 SM (ManualsLib 4235261, p.36) lists `M50552-1329`. That is very likely OCR of
  `M50552-132SP`, the CLD-1750's mask. **CLD-3080 footage or manual pages would be direct font evidence.** Confirm on the page image.
- **Other masks (user-pasted list, UNVERIFIED, source unknown):** -249SP (Pioneer CLD-V250; also claimed for
  Grundig/Blaupunkt, which is doubtful), -183SP (Hitachi VT-F770/F775/F780E), -148SP (Thomson/Saba/Telefunken). Different
  masks mean possibly different glyphs. They are useful only for chip-level behaviour (geometry, border mode, timing).
- **Hitachi VT-FX665A** footage (user): https://www.youtube.com/watch?v=cYgsGW5OK9M (0:44-0:47). The OSD looks very
  similar, including the small picture jump when playback starts. Mask unknown.
- **Mitsubishi data books on bitsavers** (http://bitsavers.trailing-edge.com/components/mitsubishi/_dataBooks/):
  `1990_Mitsubishi_Digital_ASSP.pdf` was checked: **no OSD chips** (logic ASSPs only). M50xxx is Mitsubishi's
  microcomputer-family numbering (cf. M50740). `1986_Mitsubishi_Single_Chip_8-Bit_Vol2.pdf` and
  `1990_Mitsubishi_Microprocessors_and_Peripheral_Circuits.pdf` were also checked: **no OSD chips in either**.
  Bitsavers has no Mitsubishi TV/VCR IC data book; that family is not covered there.
- **Sibling chip M50458** (MAME `src/devices/video/m50458.cpp`): 12×18-dot character cells, 0x120 character positions
  (probably 24×12), blink control, and a BAD_DUMP of the standard `-001SP` font. The family is related, but it is a
  different part, so it is a hint only.

## Gaps (for exact reproduction)
1. **M50552 datasheet**: not found in a first search. It is needed for the dot matrix, row and column counts, character
   pitch and the border-mode definition. Without it, these must be inferred from footage stroke and pixel measurements.
2. **Uncropped footage** of the full raster, to place text vertically.
3. Footage of the other DISPLAY states (time/frame counter during play, REMAIN/TOTAL), the language variants, and the
   search/number-entry, repeat and random screens.
4. Whether `CLOSE`/`PLAY` text is shown with no disc (the blue background appears while the disc spins up).
