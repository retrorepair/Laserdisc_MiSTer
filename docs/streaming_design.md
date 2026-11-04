# Streaming + reference-decoded picture (M3): design, following MiSTer-LaserActive

User decisions (2026-11-03): (1) picture decoded **offline by the reference decoder** (Decode-Orc Transform PAL 3D);
(2) a **custom Main for this core**; (3) "go with whatever the LaserActive core is using ... established as working
well". Source studied: `ref/repos/MiSTer-LaserActive` @ c547721f with submodules MegaCD_MiSTer @ 1d812165 and
Main_MiSTer @ e57fd2d2. Both repos ship a GPL-3 LICENSE, but the files we reuse are individually SPDX-tagged MIT:
`rtl/LD/{dsc_decoder,ld_video,ld_fifo,ld_mix}.sv` and `tools/mmidsc/src/*`. A Main fork is GPL-3. Keep their headers and
credit them.

## Why compression (measured on the user's MiSTer)
SD card 21.8 MB/s, NAS share 11.5 MB/s; raw TBC needs 35.5 MB/s. LaserActive's answer is VESA DSC at a constant rate:
their 8 bpp files stream at 12.49 MB/s from SD.

## What LaserActive does (and we adopt)
| Piece | LaserActive | Ours |
|---|---|---|
| Codec | VESA DSC 1.2-style, constant bit rate, 8/9/10 bpp from the PPS, block prediction off, ICH on (`tools/mmidsc/src/dsc.c`) | **same encoder** (`dsc.c`), PAL picture |
| Picture kept | 792×525 incl. VBI lines, each field its own slice (rows 0-262 / 263-524) | Transform PAL 3D RGB, 960×600: TBC samples 152-1111, field lines 12-311 incl. VBI, each field its own slice (rows 0-299 / 300-599) |
| Stream | `DSCV` header (512 B, PPS, field rows, frame count, slice info, VBI table offset), fixed-size frames, no index | **same `DSCV` layout** (`dscv.h` is the authority); PAL field rows; 25 fps |
| VBI | 4 × 32-bit biphase codes per frame | 4 codes from ld-decode's `.tbc.db`: lines 16, 17, 329, 330 |
| Main | `megald_video.cpp`: reader thread, 8-16 slot ring in DDR3 (0x30100000, 512 KB-1 MB/slot), commit per frame | fork of the same code, driven by our player's frame requests (seek, still, scan, reverse) |
| Core | `ld_video.sv` + `dsc_decoder.sv` + `ld_fifo.sv`, decode into 2 DDR3 framebuffers, fields woven | same decoder; our player chooses the frame; we scan the framebuffer out at our own 15 kHz timing with the OSD drawn in RGB |
| Audio | analog track read ahead ~2 s by Main (`megald_audio.cpp`) | ld-decode PCM (44.1 kHz stereo) read ahead the same way |

## Converter (done): `tools/convert/dscv/`
`tbc2dscv.py IN.tbc OUT.dscv [--first F --count N --bpp 8 --verify]` runs Decode-Orc 2.10.1 (`orc-cli`, Transform PAL
3D) in 200-frame chunks and streams the RGB48 into `tbc2dscv.exe`. That program is LaserActive's `dsc.c`/`dscv.c`/`util.c`
built unchanged, plus our driver (`tbc2dscv.c`, with the same overflow fallbacks as `mmidsc`). Build it with `build.sh`
(MinGW gcc).
- **Chunking is exact.** Transform PAL 3D uses neighbouring fields: a run's first frame and last 3 frames differ from a
  whole-range decode, and every other frame is bit-identical. Each chunk is therefore decoded with 4 extra frames on
  each side, which are then discarded.
- **Geometry, measured against the TBC by correlation** (luma against composite, r = 0.99 to 0.999):
  - Decode-Orc pads the active area symmetrically to a multiple of 8. We request samples 152..1111 directly
    (`activeVideoStart=152:activeVideoEnd=1112`), so column c is TBC sample 152 + c. That gives a width of 960, a
    multiple of 3 for DSC, with no padding.
  - Frame-flat line L is first-field TBC line L/2 for even L and second-field line (L-1)/2 for odd L, counting from 0.
  - We keep `firstActiveFrameLine=24:lastActiveFrameLine=624`: field lines 12..311 of both fields. That includes the
    VBI lines 16-18 and 329-331, so the core displays the codes and the picture-start behaviour exactly as recorded.
  - The encoder de-weaves each frame into the LaserActive stacked layout: rows 0-299 are the first field (slice 0), and
    rows 300-599 are the second field (slice 1).
- **Header fields:** src_width 1135, src_height 625, crop_x 152, crop_y 24, width 960, height 600, field0 0/300,
  field1 300/300, frame_duration 40000 µs.
- **VBI table:** 16 bytes per frame, taken from ld-decode's `.tbc.db`, the same 24-bit codes LaserActive's decoder
  produces. The order is first-field line 16, first-field line 17, second-field line 329, second-field line 330, which
  are the PAL counterparts of LaserActive's lines 16/17/279/280.
- **Frame pairing:** frame k is fields 2k (first) and 2k+1 (second) on Community North. The tool refuses a capture
  where this does not hold, rather than guess.

## Measured (Community North frames 300-329, `--verify` decodes every frame again)
| Rate | Bytes/frame | Stream | Mean / min PSNR | Max error | Fits |
|---|---|---|---|---|---|
| **8 bpp** | 576 000 | **14.40 MB/s** | 51.46 / 51.14 dB | 7 | SD (21.8) |
| 7 bpp | 504 320 | 12.61 MB/s | 49.20 / 48.94 dB | 8 | SD |
| 6 bpp | 432 128 | 10.80 MB/s | 46.97 / 46.74 dB | 15 | SD and NAS (11.5), with little margin |

At 8 bpp the picture is visually identical to the source; the difference amplified 16× is near black
(`analysis/dscv/f305_compare.png`). 8 bpp is used for SD. NAS streaming needs 6 bpp or better reads; that is for later.

## Core side (implemented 2026-11-03, working on hardware)
User rule: **no LaserActive timings; use the Domesday project's.** Their VDP cadence/margin scheduler (29.97 fps
against 59.92 Hz) is removed. The output timing is ld-decode's PAL TBC timing (`tbc_timing`: 4fsc, 1135 samples per
line, fields of 312/313 lines, 25 frames/s), and a new picture goes up only at our frame boundary.
- `ld_stream.sv` is forked from LaserActive's `ld_video.sv` (MIT), keeping its DDR3 datapath.
  - The player's `frame` (one frame ahead, as with the TBC reader) is decoded from a DDR3 slot into one of three
    frame buffers.
  - At each frame boundary (`frame_tick`) the newest finished picture goes up. With nothing new, the last picture
    stays up and the frame is counted as late.
  - A disc change waits for any decode in progress before the new PPS is written.
- **DDR3 mailbox, instead of LaserActive's SPI commits** (our player is in the core, so the core asks for frames):
  - The header block at 0x30000000 (HPS → core) carries magic, version, generation, frame count, words per frame,
    field1_row, crop_x/crop_y, the PPS and a 16-entry slot table.
  - The status block at 0x30000400 (core → HPS) is written at every frame boundary: wanted frame, player state, the
    frame decoding and the frame on screen, and counters.
  - Slots are 1 MB at 0x30100000. Frame buffers are at 0x31200000, 0x31600000 and 0x31A00000.
  - The exact layout is in the `ld_stream.sv` header.
- **`ld_scan.v`** fetches each frame-buffer line one line ahead into a two-line buffer. TBC sample x of field line ln
  in field fld is pixel (x - crop_x, 2(ln - crop_y/2) + fld).
- **OSD in RGB:** `osd_m50552` now also outputs its per-dot decision (`cls`). The colours are a white glyph, a black
  border or black raster, and the blue raster (13, 26, 179) = `BG_RGB` of `osd_fx.py`.
- **Picture-on jump:** `run` drops for one ce on `resync`, so the timing restarts at that instant
  (docs/player_logic.md).
- **Verified:**
  - **Simulation** (`core/sim/run_ld_stream.sh`): a real DSCV frame decoded by the RTL equals the C decoder's
    picture in all 288 000 frame-buffer words, and the line fetch and status block check out. One frame takes
    2 018 438 clocks = **28.45 ms at 70.94 MHz** (the frame is 40 ms).
  - **Quartus:** timing is met at 70.94 MHz (slack +1.836 ns). Block RAM 11%, DSP 36%.
  - **Hardware**, with `tools/mister/ld_feed.py` as the reader:
    - It plays at 25 frames/s, with 0 decode errors, 28.5 ms per decode, and late frames only before the first decode.
    - The STOP, PLAY and PAUSE screens and resume all work.
    - Screenshots match the Decode-Orc reference at zero pixel offset (`analysis/hw/m3/`).

## Audio (implemented 2026-11-03)
- **Source:** ld-decode's `.pcm`, the disc's analogue sound tracks as 16-bit stereo at 44.1 kHz. Each field's sample
  count is in `field_record.audio_samples`: 881/883 on Community North, so **every frame has exactly 1764 samples**,
  and 1764 × 25 = 44 100. At our exact 25 frames/s, a constant 44.1 kHz output never drifts.
- **Stream (Laserdisc_MiSTer extension of DSCV):** each frame's samples sit inside its frame stride after the
  picture, so one sequential read per frame brings both.
  - Header bytes 72-87 hold audio_offset, rate, channels, bits and max samples. The block is u32 count + u32 0 +
    samples; layout in `tbc2dscv.c`.
  - The stride grows to 584 192 B, or **14.60 MB/s**.
  - `tbc2dscv.py` adds the audio by default (`--no-audio` leaves it out). The blocks are checked byte for byte
    against the `.pcm`.
- **Core:**
  - `ld_stream` reads a frame's audio block (1024 words) into the `ld_audio` bank of the frame buffer it decoded into,
    before the frame counts as ready. `new_pic` marks when that picture goes up.
  - `ld_audio` queues the block's samples and plays them at exactly 44.1 kHz from clk_sys
    (44100/70937900, by a remainder accumulator), with a 64-sample cushion. `AUDIO_S` = signed.
- **Muting** follows the CLD-1750 OM, via the player state (sound only in PLAY with the picture on):
  - PAUSE: "the sound and/or video image disappears" (p.50).
  - SCAN on LD: "Others: Sound is muted" (p.56).
  - Still frame / frame advance: "sound is muted" (p.68).
  - Multi-speed playback: muted.
- **Verified in simulation:** the bank holds the exact block, and all 1764 samples play in order, 22.68 µs apart.
- **Not yet:**
  - The AUDIO D/A key. The OM's "LD with analog audio" cycles stereo → L → R, or CX auto-switching on CX discs; the
    output is stereo for now.
  - Whether ld-decode's `.pcm` needs CX noise reduction, as the player applies to CX-encoded discs. Check per disc.
  - Digital (EFM) audio for discs that have it.

## Open points
1. The Main fork: file selection from the MiSTer menu, and the reader thread doing `ld_feed.py`'s job in C. Its
   base is MukiEX/Main_MiSTer `laseractive-step1` or the user's retrorepair/Main_MiSTer. Build it with the WSL
   toolchain `/root/mister/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf` (memory: arm-toolchain).
2. Audio (ld-decode PCM), and NAS streaming (6 bpp, or better reads).
3. The TBC/composite path (`tbc_reader`, `pal_decoder`, the composite OSD mix) is kept in the tree for the composite
   DAC but is no longer built.
