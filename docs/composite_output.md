# Composite output through the MiSTer analogue I/O board

User decisions (2026-11-03):
- Composite through the I/O board's RGB DAC.
- Follow Mike Simone's composite work (MiSTer `sys/yc_out.sv`), "or just bypass the framework. I don't care".
- One file holding both streams, each streamed on its own.
- Project rule: composite = replay of the TBC samples, never RGB re-encoded.

## Why replaying the TBC is the player's own output (SM, `docs/sm_video_audio.md`)
- **The TBC:** the CLD-1750's TBC is a CCD variable delay line (IC403 CXL1009P). Its clock VCO (IC404) is steered by
  CCD ERR against the **17.734475 MHz = 4fsc** crystal reference.
- **The adjustments:** the CCD output lags its input by 1H + 11 µs, and jitter at VIDEO OUT is set to a minimum.
- **ld-decode's output:** its TBC is the same correction done digitally, on the same 4fsc sample grid. The core
  replays it at ce_4fsc = 70.9379 MHz / 4, the player's reference rate.
- **Dropout compensation:** IC401's DOS (dropout sensor) and pulse stretch switch to IC402's 1H-delayed video. The
  converter does the same: each ld-decode dropout span is replaced by the same span of the line before
  (`add_cvbs.py`). The pulse-stretch time is not given in the SM.

## Stream (`tools/convert/dscv/add_cvbs.py`)
- The composite region is appended to the `.dscv`, after the DSC region, and described in header bytes 256-299
  (`CVB1`).
- A frame is 2 fields × 313 lines × 1136 bytes (711 136 B), then the same audio block as the DSC frame. The stride is
  719 360 B, so **17.98 MB/s**: the SD card's 21.8 MB/s handles it, the NAS (about 10 MB/s, see below) does not.
- Samples are 8-bit DAC codes, code = s × 255 / 54016 (100 IRE white), clipped. The sync tip is about 0 → code 0,
  blanking 14442 → code 68, white → 255.

## Core (`cvbs_scan.v`, `ld_stream.sv` composite mode, top level)
- The menu option **Video output: RGB / Composite** (status[6]) goes to the HPS in the status block (w1 bit 38). The
  Laserdisc Main then re-announces the disc as the composite stream (header w2 bit 48, new generation).
- **ld_stream, composite mode:**
  - There is no PPS and no decode. A frame is ready once it is in a slot and its audio block and VBI are fetched.
  - The frame on screen plays straight from its slot, so the Main pins the shown frame as well as the wanted and
    decoding ones.
  - The line fetch reads 142 raw words: row = field × 313 + line.
- **cvbs_scan:**
  - It replays the samples at the TBC timing, with a two-line buffer whose bank toggles every line.
  - It outputs the 8-bit code unchanged, plus the same sample on the 16-bit TBC scale for the OSD.
  - With no disc video it outputs the player's raster (sync, burst, blanking; docs/player_logic.md).
- **OSD:** osd_m50552 mixes into the composite stream as the M50552 does (CV IN → CV OUT, bit-exact with
  `osd_fx.py`). Its blue raster takes its chroma from the line's own burst, which pal_decoder measures; only that
  part of pal_decoder is used.
- **DAC:** where the OSD passes the video, the output is the replayed code itself, so the replay is bit-exact.
  Where it draws, the output is its composite level, converted the same way.

## On the VGA connector, after Mike's composite (`sys/yc_out.sv`)
- yc_out's CVBS mode puts the composite on **green**, with red (chroma) at 0 in CVBS and blue at 0. Its waveform
  has no sync: blanking sits near code 64 and the I/O board's sync-on-green circuit (`vga_sog`) or the cable adds the
  sync.
- **We bypass yc_out**, because it re-encodes RGB. The core drives green with the disc's own waveform, sync and
  burst included, and red and blue with 0.
  - Levels: sync tip 0 V, blanking ≈ 0.19 V, white 0.7 V into 75 Ω.
  - The real player's VIDEO OUT is 1 Vp-p (SM: 2 Vp-p unterminated). The VGA DAC tops out at 0.7 V, so the signal is
    70% of that amplitude. That is a hardware limit, the same one yc_out's CVBS has.
- **The framework zeroes RGB wherever DE is low** (`sys/sys_top.v`, VGA_scanlines `.din(de_emu ? {r,g,b} : 0)`).
  First CRT test (2026-11-04, user): a grey screen instead of the blue background, and the picture "looks terrible".
  The cause: with the normal DE (active picture only), the burst and the whole blanking interval became code 0, which is
  sync-tip level. With no burst the TV kills the colour, and the blanking turned into one long sync pulse.
  - First fix: DE high for every sample. That brought the colour back, but the MiSTer menu stopped drawing: `sys/osd.v`
    finds line starts from DE rises, and the frame start from more than 4 line-widths without one, measured against the
    last DE pulse. No DE pattern gives it both while every composite sample passes.
  - **Now:** the core builds with `MISTER_VGA_RAW` (qsf), a switch added to `sys_top.v` that leaves the analogue outputs
    as the core drives them, and DE is the normal active picture again. The core blanks RGB itself. In RGB mode the VBI
    lines therefore reach the analogue port too, as the player's video output carries them.
- **Field structure (measured on the Community North TBC, 2026-11-04).** The stored first field (`isFirstField`)
  holds PAL lines 1-313: its 313th stored line is line 313, with an equalising pulse in the first half and the
  second field's first broad pulse in the second. The second field holds lines 314-625 in stored lines 0-311; its
  stored line 312 is padding, a copy of the next frame's line 1 (mean difference 188 against 3500 for real lines).
  Until this date tbc_timing replayed 312 then 313 lines. That dropped line 313 and played the padding line, so both
  fields' vertical syncs started on a line boundary (no interlace), and the subcarrier phase jumped twice a frame.
  Now the replay is 313 then 312.
- **The player's own raster** (no disc picture) carries the same vertical interval: broad, equalising and line-sync
  pulses at the standard 27.3/2.35/4.7 µs (the service manual gives no widths for the sync generator). It also has
  PAL burst blanking, with the first and last burst of every field on a 135° line. The disc shows the same 4-field
  cycle: bursts from line 5 or 6, to line 307/308/309.
- **Colour saturation on composite (measured 2026-11-04, Community North frame 1950).** The TBC's chroma equals the
  reference decoder's (Decode-Orc Transform PAL 3D) chroma at its absolute level: the ratio is 1.00 over about 43,000
  points. But the TBC's colour burst is 9.1-10.5 IRE peak (ld-decode `medianBurstIRE` 10.5), 0.42-0.49 of PAL's nominal
  21.4 IRE. A TV sets its colour gain from the burst, so on composite this disc shows about 2.35x the reference
  saturation. **User decision: leave the TBC as captured** (no burst correction). Whether the low burst is on the disc
  or comes from the capture chain is open; another PAL capture would tell.
- **OSD outline and the dark band beside text (user photos 2026-11-04).** The outline (1 dot left/top, 2 right/bottom)
  switches the chroma off, as the letters do. A TV restores chroma gradually, so a desaturated dark band shows beyond
  the outline. F1 frame osd_024 (a real CLD-1750) shows full blue up to the outline, which fits an outline that keeps
  the background chroma at black level. That is an inference without the M50552 datasheet. **User decision: keep the
  outline as is** until there is better evidence.
- **Colour trailing to the right (chroma later than luma on the TV), 2026-11-04.** The disc's TBC has chroma and luma
  aligned within 0.1 us at the colour-bar edges, and the OSD aligns them by construction. The user reports MiSTer's own
  composite output (sys yc_out) shows the same trailing on this I/O board, which is why its author uses an external
  filter. So it is the analogue output path.
  - Tried first: 4x interpolation to clk_sys (a 48-tap reconstruction filter, flat to 5 MHz). It removes the DAC's
    4fsc images, but the trailing stayed.
  - **Menu option "Chroma advance"** (Off, 0.11-0.79 us in 0.113 us steps): the composite is split into chroma (a 17-tap
    band-pass at fsc) and its exact complement (luma and sync), and luma is delayed so chroma arrives early. Off is bit
    for bit the input. The burst moves with chroma, still within the back porch.
- **Raster subcarrier (dot crawl on the blue screens, not on the disc), 2026-11-04.** The raster used exactly 283.75
  subcarrier cycles per line. PAL is 283.75 + 1/625 (fsc = 283.75 fH + 25 Hz), the offset PAL chose to make the dot
  pattern least visible, and the disc's line-locked TBC carries it. The raster now steps its burst phase by
  283.75 + 1/625 cycles per line (rth, 1/5000-cycle units), so the OSD's blue (phase from the line's own burst) follows.
- (The DAC modes are below.)
- **MiSTer.ini for this core:** `vga_mode=rgb` (not cvbs, which would route our RGB through yc_out), `vga_scaler=0`
  and `vga_sog=0`. The user's [MiSTer] section already has these, so nothing changes.
- **The DAC:** the I/O board's DAC is 6 bits per channel (`VGA_G = vga_o[15:10]`). The two LSBs go out on the SD
  pins for boards that use them.
- **HDMI** shows what the VGA port gets (the scaler is fed the same RGB): the raw composite on green. Composite mode
  is for an analogue CRT.

## Composite DAC modes (menu "Composite DAC", user 2026-11-04: modern I/O board with 8 bits per channel; "whatever will get us the best possible signal")
- **Signal depth:** the Domesday Duplicator samples the RF at 10 bits. ld-decode writes 16-bit TBC samples, but the
  disc's video SNR (about 45-50 dB) is about 8 effective bits. The stream stores 8-bit codes, and 8-bit
  quantisation adds only about 0.3 dB of noise. So more bits per channel gain nothing; **amplitude** is what was
  missing.
- **Green (0.7 V):** composite on the green pin alone, with red and blue at 0 (as yc_out's CVBS). Sync to white is
  0.7 V, 70% of standard.
- **R+G+B tied (1.0 V), the best signal:** the cable joins VGA pins 1, 2 and 3 (red, green, blue) to the composite
  centre conductor, and pins 6, 7 and 8 (their returns) to the shield.
  - Three 0.7 V outputs in parallel into the TV's 75 Ω reach (3 × 1.4 V) / 4 = **1.05 V** at full scale. That holds
    whether each output is a voltage source with 75 Ω, or a current DAC with its own 75 Ω termination
    (3I × 18.75 Ω).
  - The core sends T = round(code × 20/7) units out of 765, split ⌊T/3⌋, ⌊(T+1)/3⌋, ⌊(T+2)/3⌋. Code 255 (100 IRE
    white, 1.0 V above the sync tip) is therefore 729 units = **1.00 V**: the player's own level (SM: VIDEO OUT
    2 Vp-p unterminated = 1 Vp-p into 75 Ω).
  - That is about 9.5 bits of output resolution. The real amplitude depends on the board's channel matching (a few
    %), which is a hardware tolerance.
- In both modes HDMI shows the raw composite: green only, or grey with the channels tied.

## Network streaming (measured 2026-11-03/04 on a Windows Server 2019 SMB share)
- Needed: **14.6 MB/s** for an RGB stream, **18 MB/s** for composite.
- **SMB encryption costs the MiSTer most of its CPU.** With AES-128-GCM (SMB 3.1.1) reads top out at 8.5-10 MB/s,
  with 0% ARM idle: decryption takes one core, and Main's scheduler loop (stock behaviour, no sleep) the other. Turn
  encryption off for the share on the server (`Set-SmbShare -Name <share> -EncryptData $false`, and
  `Set-SmbServerConfiguration -EncryptData $false`). Check on the MiSTer: the packets must be plain SMB2 (0xFE 'SMB'),
  not transform headers (0xFD); `/proc/fs/cifs/DebugData` lists the negotiated cipher even when it is not used.
- **A 100 Mbit/s hop anywhere in the path caps reads at about 11 MB/s**, even with 1 Gbps links at both ends. The
  symptom: two transfers from different hosts share the 11 MB/s. With the hop removed, reads ran at 50 MB/s.
- **The server's disk is the next limit:** a first read ran at 14.6 MB/s and a cached re-read at 50 MB/s.
- Lossless compression of the composite samples does not help much: prediction from one subcarrier cycle back
  (x-4) with per-line Rice coding reaches only 1.48:1. The disc's noise leaves about 5.4 bits per sample.

## Not modelled
- The CCD TBC's residual jitter: it is adjusted to a minimum and the SM gives no figure.
- The DOS pulse-stretch time.
- 1 Vp-p output amplitude (see the hardware limit above).
- The RGB (DSC) stream was decoded by Decode-Orc without the player's 1H dropout compensation. That would mean
  re-encoding from a compensated TBC, which is open.
