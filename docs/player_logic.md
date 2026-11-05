# CLD-1750 player logic (M4): specification for the pure-RTL implementation

User decision (2026-11-03): **pure RTL** (no soft CPU). Reference: CLD-1750 operating instructions VRE1009 (OM, PDF
page numbers), footage F1 (RetroGamerVX 1080p CLD-1750), F2 (CLD-3080), F3 (CLD-1750 STOP on black).
Every behaviour below cites its source; items marked **EST** are estimates pending evidence.

## Slice 1 (this implementation)

### Controls (OM p.48, 50-51, 56, 68)
| Function | CLD-1750 control | Keyboard (MiSTer) |
|---|---|---|
| Play | ▶/II (front: play/pause toggle), PLAY ▶ (remote) | Enter = PLAY ▶, Space = ▶/II |
| Pause | ▶/II, PAUSE II (remote): **video and sound disappear** (OM p.50) | Space / P |
| Stop | ■ (front), ■/▲ once (remote); next PLAY starts from the beginning (OM p.50) | S |
| Open/close | ▲ (front), ■/▲ twice (remote) (OM p.51) | E |
| Scan | SCAN ◀◀/▶▶ (remote), SCAN dial: Low Scan ≈×10 for ≈2 s, then High Scan ≈×30 (OM p.56) | Left / Right (hold) |
| Still / step (CAV) | STEP ◀II / II▶: freezes the picture, steps one frame, sound muted; ▶ resumes (OM p.68) | , / . |
| System | SYSTEM: output mode table; background **blue in NTSC/PAL mode, black in MOD. PAL** (OM p.46) | Y |

### States and OSD (F1 timings at 2 fps and 10 fps, osd frame refs in cld1750_osd_evidence.md)
| Transition | Duration | OSD screen | Source |
|---|---|---|---|
| Tray closing (▲ or PLAY with tray open) | 7.5 s | `CLOSE` | F1 osd_004-018 |
| Spin-up after PLAY | 5.5 s | `PLAY` | F1 osd_019-029 |
| Disc identified | 3.6 s | `LASERDISC`/` -PAL-`, `PLAY`/`SIDE -A` | F1 301.0-304.6 s |
| Search to the first chapter, before the picture | 0.77 s | `SEARCH` / `CHAPTER  1` (rows 0-1, from column 1) | F1 304.67-305.44 s (re-measured frame by frame 2026-11-03). **Deferred**: the chapter number needs the VBI chapter decode, and the font lacks digits 2 and 4-9 |
| Picture on | **timing switch mid-field** | none | F1 305.44 s: the switch lands mid camera frame. The TV then rolls **upward** while its vertical hold re-locks: VBI code lines at about 85% of the screen height (305.47), then 61%/85%, then 14%/36% (305.51), faint (305.54), gone by 305.57. That is about 6 fields at roughly 12-15% of the height per field. The roll is the TV's; the player only switches sync and carries the VBI lines in its signal |
| Stopped | until a key | `STOP` | F1/F3 |
| Paused | until a key | `PAUSE` | F1 (F1's extra CHAPTER/TIME/EDITING COMPUTE rows are not shown: they belong to the edit function, **EST**) |
| Tray open | until a key | `OPEN` | **EST** (text not seen in footage) |
| Spin-down before the tray opens | 2.0 s | `STOP` | **EST** (not yet measured) |
| Seek (step back to frame 0 after STOP, search) | — | — | later slices (F2 CLD-3080 shows a ≈2-3 s chapter search) |
| Power-on | — | none, raster black (MOD. PAL at power-on, OM p.46) | OM p.46 |

### Sound (core/rtl/ld_audio.v)
Disc sound plays only in normal PLAY with the picture on. PAUSE: "the sound and/or video image disappears" (OM p.50).
SCAN on LD: "Others: Sound is muted" (p.56). Still frame / frame advance: "sound is muted" (p.68). Multi-speed: muted.
The AUDIO D/A selection (stereo / L / R for analogue discs) is not implemented yet; the output is stereo.

### AUDIO D/A (D/A/CX), implemented 2026-11-04 (key A)
CLD1750K/2750K OM p.20 figure, "Switching audio"; European OM p.54 (D/A/CX button, CX auto-switching):
- LD with digital audio: digital (stereo) → analog (stereo) → L of analog → R of analog → L of digital → R of digital.
  PAL digital-audio discs have nothing recorded on the analog part (EU OM p.54). **Not implemented: no digital audio
  source in the stream yet.**
- LD with analog audio, disc encoded with CX auto-switching signals (the programme status code): stereo → L channel →
  R channel. **Implemented.** One channel goes to both outputs ("to hear only one channel of stereo disc"). A new disc
  starts at stereo. Community North carries the status code (CX off), so it uses this cycle.
- Analog disc without the signals: CX off/on × stereo/L/R, six steps. **Not implemented: no CX expander yet.**
- No TV OSD for this key is documented; the FL display's audio indicators are not modelled.

### Two-side play: evidence from the same Pioneer family, CLD-2750K (CLD1750K/2750K OM)
- p.14: DISC SIDE A / SIDE B buttons. "To play side A only, press DISC SIDE A instead of ▶ … Side A will be played
  and then playback will stop". So ▶ on a two-sided disc plays side A, then turns and plays side B. In the core the
  turn streams the "…side2" file (user, 2026-11-04).
- p.20: QUICK TURN skips the TOC read, "so the time required before starting playback or turning the disc can be
  reduced". TOC-based time displays then do not work.
- Two-Side Repeat: REPEAT pressed three times (OM, REPEAT section).
- **Footage found 2026-11-04** (`ref/sidechange/footage/`, git-ignored; contact sheets in `analysis/sidechange/`). All three
  clips show the bare mechanism only, with no TV and no FL display:
  - [CLD-2950](https://www.youtube.com/watch?v=aJOZ2r3FAt0) (mnemo70): the pickup's sledge swings to the upper side on a
    turning axis; the disc is stopped and spun the other way (uploader's description).
  - [CLD-D515](https://www.youtube.com/watch?v=3BP9IRWVOLY): a switch from side A to side B.
  - [CLD-3070](https://www.youtube.com/watch?v=Lt3ZueIvCqw) (oldvcr.tv), the European PAL sibling of the CLD-3080. By
    frame-difference motion analysis, the sled transfer takes **about 7-8 s** (40.0-48.5 s and 64.5-71.5 s in the
    clip). The spindle stop before it and the spin-up and lead-in read after it are not separately visible.
- Forum reports ([lddb CLD-703](https://forum.lddb.com/viewtopic.php?t=3081),
  [AVS](https://www.avsforum.com/threads/pioneer-laserdisc-fix-help.1273828/page-6)): the carriage reaches the side-B
  position, the spindle spins up, then autoplay starts.
- **CLD-D925, with the TV in shot** ([26dn8tT74Io](https://youtube.com/watch?v=26dn8tT74Io), Karsten Schmidt; supplied by
  the user 2026-11-04). Analysed frame by frame at 30 fps (`analysis/sidechange/d925_turn.jpg`):
  - 64-73 s: side A plays (FL shows chapter 2, 4:00-4:10).
  - About **76.0 s: DISC SIDE B pressed**. The side lamps change about 76.1 s, so this turn was started by the button,
    not by the end of side A.
  - 77-86 s: the camera is on the FL display, which shows a moving bar pattern during the turn.
  - 86-87.57 s: the monitor shows **the last side-A frame, held** (the same scene as 71-73 s, perfectly steady). The
    D925 has a digital field memory ("Digital Memory" on its panel); the CLD-1750 has none.
  - **87.60 s: a hard cut to the side-B picture** within one camera frame: no blue raster, no OSD, no fade. Then the
    disc's own "Seite 2" card (90-93.5 s) and the side-B programme.
  - **Turn: about 11.6 s from the button to the side-B picture**, the picture held throughout.
  - **No sound during the turn** (user, 2026-11-04: "Sound doesn't play during the turn"). The camera microphone
    could not show it either way.
- For our core (user: "hold the last frame from side 1 until side 2 comes up and then just starts playing side 2"): at
  the end of side A, the last frame stays up for the turn, then side B's first frame cuts in and plays. The turn time
  comes from the D925 measurement. The auto turn at the end of a side has not been filmed; it is taken to be the same
  mechanism and the same time.
- **Implemented (2026-11-04):**
  - The player's S_TURN (state 11): the picture on screen is held (ld_stream `hold`: no new picture goes up, and a
    change of disc keeps it), with no sound or OSD, for 290 frames (11.6 s). Then side B's frame 0, decoded during
    the turn, cuts in and plays.
  - When: at the end of side A after PLAY; DISC SIDE B during play on side A; DISC SIDE A during play on side B.
    DISC SIDE A from stop plays side A only, then stops (p.14). Keys: F1 DISC SIDE A, F2 DISC SIDE B.
  - The Laserdisc Main pairs `…side1`/`…side2` files (the header's w2 bits 49-50 tell the core). On the core's
    request (status w1 bits 40-41) it opens the other file, keeping the slot of the held picture until the turn is over.
  - **Not implemented (no evidence yet):** a turn started from STOP (what the screen shows then), QUICK TURN,
    Two-Side Repeat.

### SEARCH / CHAPTER: evidence and implementation (2026-11-04/05)
- **Operation (European OM pp.58-62):** digit buttons (+10 for 10 and above), then PLAY or PAUSE ("Direct search";
  "normal search" goes through CHP/TM). CLEAR corrects or cancels. Chapter Skip: each press goes back to the start of
  the current chapter or forward one; presses before the picture returns accumulate. Frame Number Search (CAV only)
  and Time Number Search (CLV) through CHP/TM. The digits show in the front-panel display; the TV shows them only with
  DISPLAY. "Chapter Search is not possible with discs which are not divided into chapters."
- **The TV during a search (this player family):**
  - F1 (CLD-1750, 304.67-305.44 s): `SEARCH` / `CHAPTER  1` on rows 0-1 from column 1, on the background (no picture),
    then the picture-on roll. The chapter number is right-aligned in two places.
  - F2 (CLD-3080, same OSD family): `Search` / `Chapter 00` on the blue background, no picture.
  - CLD-D925 tour (kT6GRXhZ4, 1557-1575 s): repeated chapter skips show `SEARCH` / `CHAPTER 5`, `6`, `7`, `8`, `9`,
    one per press, top left. The D925 keeps a still picture behind the text (it has a field memory, which the
    CLD-1750 lacks), and its time display gives the digit shapes (`4.28`, `0.25`, `1.06`, `2.24` ...).
- **Implemented (core/rtl/player.v, osd_text.v; tb_player.sv on GGV1069's own codes: PASS):**
  1. Digit, CLEAR and chapter-skip keys on the keyboard (the remote's DIRECT SEARCH keys).
  2. The search itself as the player does it: jump, read the disc's VBI where it lands (chapter `0x8xxDDD`, picture
     number `0xF`+5 BCD), jump again. A bisection over the frame index, since chapter and picture numbers rise along
     the disc. The picture is off (background plus `SEARCH` / `CHAPTER nn`) until it lands, then picture-on as at
     the start of play. Duration: what the jumps take, with F1's 0.77 s and F2's 2-3 s as the measured
     references for the mechanism's time.
  3. Digits 2 and 4-9 for the OSD font, transcribed from the D925 frames (same Pioneer OSD style, approximated where
     the footage is soft).
  4. Test discs: GGV1069 (CAV, 30+ chapter codes) for chapter and frame search; Robocop (CLV) for chapters on CLV.
  5. Frame and time number search after that.

- **Keys:** 0-9 (and keypad) DIRECT SEARCH digits, Backspace CLEAR, C CHP/TM, [ and ] CHAPTER SKIP back/forward,
  D DISPLAY. The OM shows entered digits in the front-panel display only; the core has no front panel, so they are
  not shown until the search starts (as on the TV of the real player).
- **EST (no footage):** the frame and time search screens (`FRAME nnnnn`, `TIME M.SS`, made in the chapter screen's
  form); the CLD-1750's own DISPLAY layout (the core uses the CLD-D925's: value at row 0 left, `A PLAY` right); a
  chapter skip past the last chapter lands at the end of the disc.
- **Search timing:** the bisection takes what the jumps take (a jump is a frame fetch from the share, ~2-4 frames),
  at least 0.77 s (F1). Typically 1-2 s across a whole side, against F2's 2-3 s.

### Video sources
- **Disc video** (TBC from DDR3) in PLAY, STILL and SCAN.
- **Player raster** (no disc video): the player's own sync and colour burst with a blanking-level picture,
  over which the M50552 draws the background and OSD. Generated as standard PAL lines: sync 0-83, burst 98-138 at
  nominal amplitude with the PAL swing, subcarrier-locked (1135 samples/line, phase +270°/line). This models the
  player's sync generator.
- **Picture on (the roll):** the player's TBC output is locked to the reference H, and so is its raster, so the switch
  from raster to disc keeps horizontal sync continuous. Only the vertical phase changes, by how far the disc's field
  start is from the raster's. A TV's vertical oscillator misses the new field start (outside its sync window),
  free-runs at its own slightly longer period, and rolls the picture up until it re-locks. F1 305.44-305.57 s: the
  disc's VBI lines first appear at about 85% of the screen height, then roll up about 14% per field, locked in about
  6 fields. tbc_timing `vjump`: at picture-on, the field-line counter jumps at the end of the line to 48, so the next
  field start comes 266 lines (85% of a field) after the last; x runs on.
  - Until 2026-11-04 the core restarted the whole timing (x as well) at the switch, and switched at the raster's
    field start. That broke H (a flash, not a roll) and made almost no vertical jump. The user saw "it just kinda
    flashes on a random part of the screen" and wanted "the real almost lost sync before lock effect".
  - One measurement: the real offset depends on where the disc's field start falls. The line fetched across the jump
    is the one after the old line, which is invisible during the roll.

### SYSTEM mode, two-way with the MiSTer menu
Menu option `SYSTEM mode: PAL / NTSC / MOD.PAL`. Pressing SYSTEM on the player writes the new mode back to the menu
(hps_io status_set); changing it in the menu changes the player. Whichever changed last wins.

### SYSTEM mode, per the OM table (2026-11-05)
OM p.46: NTSC discs have two modes, NTSC and MOD. PAL (MOD. PAL at power-on); PAL discs play as PAL. The menu now
offers `MOD.PAL` (default) and `NTSC`; the SYSTEM key toggles them with an NTSC disc loaded and does nothing with a PAL
disc. Background: black in MOD. PAL (at power-on, or with an NTSC disc), blue in NTSC mode and for PAL discs.

### Side change OSD (CLD-D925, user: "the d925 in terms of side switching")
During the turn the OSD shows `A > B` (or `B > A`) at the right-hand block over the held picture (D925 tour
kT6GRXhZ4 ~772 s: "B > A"); the arrow is a solid triangle glyph (font code 0x3E).

### Closed-caption decoder box (menu option, 2026-11-05)
A model of an external line-21 decoder (rtl/cc608.v), not a player feature: EIA-608 CC1 from field 1 line 21, the
47 CFR 15.119 decoder rules (pop-on, roll-up, paint-on, PACs, mid-row codes, tab offsets, specials, doubled control
codes, parity errors as a solid block), 15 rows x 32 columns of 13 field lines, white 5x7 text in black boxes (the
user's UK deaf-institute decoder of ~1995). Approximated font (tools/cc/gen_cc_font.py, user-approved). Colours and
italics are not drawn; 608-B extended characters post-date a 1995 decoder. Verified with tb_cc.sv on standard line 21
waveforms; no captured disc carries captions yet (GGV1069 has none).

### More of the OM, implemented 2026-11-05 (tb_player: PASS)
| Function | Evidence | Core | EST / not done |
|---|---|---|---|
| DISPLAY | OM p.75 (cycles), p.44 figure "3 12.49 ... PLAY" | chapter, frame (CAV) or M.SS (CLV), state word at col 17 | the LD form of the figure (the figure is CD) |
| Setting words | OM p.44-45 tables (EN/FR/DE/IT) | AUDIO D/A: DIGITAL / ANALOG + STEREO, 1/L, 2/R; SYSTEM: PAL / NTSC 3.58 | bottom row and 3 s: EST |
| STILL word | OM p.44 | right block in still frame | |
| MULTI-SPEED | OM p.68 | x3 x2 x1 1/2 1/4 1/8 1/16 1/30 1/90 from 1/4, muted, DISPLAY shows the speed | keys M/N, = / - |
| CLV warning | OM p.68 ("CLV" about 2 s) | STEP / MULTI-SPEED on a CLV disc | position: right block (EST) |
| Picture stop code | OM p.68, IEC 60857 10.1.4 (0x82CFFF) | stills the picture at x1 and slower, normal play included | no captured disc has stop codes |
| REPEAT | OM p.70-72 | memory (A, PLAY returns), A-B, chapter (B), side (B twice / no chapters), program (B in programme play), CLEAR ends | the jump's picture-off: EST |
| PROGRAM | OM p.74 (figure) | 24 chapters, entry taken after ~1 s, the programme screen, programme play, stop after the last | TOTAL time needs a TOC: not shown |
| RANDOM PLAY | OM p.66: "LD with TOC/CD/CDV" | not available (no captured TOC) | |
| LANGUAGE | OM p.40, p.44-45 word tables | EN/FR/DE/IT; L key; kept in the menu | LASERDISC, SEARCH, CHAPTER, FRAME, TIME, TOTAL stay English (not in the OM tables); German side word from col 16 (EST) |
| LAST MEMORY | OM p.12, p.44 | position kept through a core reset; same disc resumes there | reset = the power switch |
| CX noise reduction | OM (CX ON / CX OFF words), SM IC700 HA12127 | **not done** | the expander's time constants are not published (Wikipedia gives 2:1, 14 dB, knee -28 dB only); needs the HA12127/HA12044 data |
| Digital level control | OM p.12 (0 to -25 dB, OUTPUT LEVEL) | not done | |
| 16:9 | OM p.52 (SCART wide signalling) | not applicable to composite | |
| HILITE / INTRO scan, PGM EDIT, DIRECT CD | CD / TOC functions | not applicable | |
