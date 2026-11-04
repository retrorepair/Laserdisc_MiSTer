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

### SEARCH / CHAPTER (planned): what the evidence gives
- **Operation (European OM pp.58-62):**
  - Chapter Search: digit buttons (+10 for 10 and above), then PLAY or PAUSE. "Direct search" starts on the digits;
    "normal search" goes through CHP/TM. On CAV discs a chapter search started with PLAY gives "the beginning of the
    designated chapter … with still frame". CLEAR corrects the entry or cancels the search.
  - Chapter Skip: each press goes back to the start of the chapter being played, or forward one chapter; several
    presses before the picture reappears count.
  - Frame Number Search (CAV only): CHP/TM until "Frame 0" shows, the digits, then PLAY or PAUSE: "the designated frame is
    played as a still frame". +10 does not work.
  - Time Number Search (CLV): CHP/TM, the digits (min, sec), then PLAY or PAUSE. CLEAR resets the time number to "0.00".
  - "The display" in these steps is the front-panel FL window. The TV shows the information when DISPLAY is pressed.
- **The disc side:** the core reads CAV picture numbers (`0xF`+5 BCD digits) and chapter numbers (`0x8xxDDD`) from lines
  17/18, which the stream carries per frame. Community North has no chapter codes, so chapter search needs another
  test disc.
- **Gaps (needed before the OSD part can be built without guessing):**
  1. Footage of a CLD-1750 (or a same-family player, `M50552-132SP`) with the TV in shot during chapter, frame and time
     entry and search: what the screen shows while digits are entered, and while the player searches.
  2. Glyphs for the digits 2 and 4-9 (the font so far comes from F1's screens).
  3. Search durations. F1 gives 0.77 s for `SEARCH`/`CHAPTER 1` before the first chapter; F2 (CLD-3080) a 2-3 s chapter
     search. There is nothing yet for a frame search across the disc.

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
