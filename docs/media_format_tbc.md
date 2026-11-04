# ld-decode output format: verified on a real decode

Decoder: ld-decode 7.0.0 from `ref/repos/ld-decode` @ 200b05d3, installed in `tools/venv-lddecode`, run natively on
Windows (Python 3.12). Command:

```
tools/venv-lddecode/Scripts/ld-decode --PAL -t 8 --length 50 <in.ldf> decoded/CommunityNorth_test/cn_test
```

Source: `Domesday_DD86-DS11_CommunityNorth_20200814_CAV_PAL_00001-54000.ldf` (MD5 b4fcb12999ae9dd981f8dc0b4e56dcd5,
matching archive.org item `BBC-Domesday-AIV-LaserDisc-DD86-Disc-Set-11`). Speed: about 2.5 frames/s with 8 threads, so a
full CAV side (54,000 frames) takes about 6 h.

## Files produced

| File | Content |
|---|---|
| `.tbc` | Video: raw fields, back to back |
| `.tbc.json` | Metadata (legacy JSON) |
| `.tbc.db` | The same metadata in SQLite (tables `capture`, `field_record`, `vbi`, `drop_outs`, `vits_metrics`, `vitc`, `closed_caption`, `pcm_audio_parameters`) |
| `.pcm` | Analogue audio |
| `.efm` | EFM T-values (digital audio/data front end; needs a separate EFM decoder) |
| `.log` | Decode log |

## `.tbc` video (PAL)

- **uint16 little-endian**, unsigned.
- **Field = 1135 samples × 313 lines** = 355,255 samples = **710,510 bytes**. Two fields per frame, field 1 then field 2
  (`isFirstField` in the metadata). 50 frames = 71,051,000 bytes, which matches exactly.
- Sample rate **17,734,475 Hz** = 4 × 4.43361875 MHz (4fsc PAL).
- **Every line holds the complete waveform**: the sync tip is at the start of the line (value about 0), the colour
  burst is at samples **98-138**, and active video is at **185-1107**.
- Levels (from `videoParameters`): blanking = black = **14442**, white = **54016** (16-bit IRE scale). The sync tip
  sits near 0 (the observed minimum is 0; the maximum 65535 is clipped excursions).
- Per-field `fieldPhaseID` (1-8 for PAL) gives the 8-field PAL subcarrier sequence position. It is needed to
  keep chroma phase correct across seeks and stills.
- 1135 samples/line at 4fsc is the 625-line convention (PAL has 1135.0064 samples per line; ld-decode TBCs
  to an integer 1135 per line plus 4 extra samples on some lines, as handled by its tools). **TODO: confirm how the
  0.0064 samples/line (4 samples/frame) are handled before building the FPGA line timer.**

## Per-field metadata of interest

- `vbi.vbiData[3]`: the 24-bit Philips codes from lines 16/17/18. For example, `0xF00044` = CAV picture number 44
  (`F` + 5 BCD digits). Other values are status, chapter and lead-in/out codes. The player's chapter/frame display
  and search will be driven from these, as the real player reads them.
- `dropOuts`: line/start/end per dropout. (The real player has its own dropout compensator; behaviour TBD from SM.)
- `audioSamples`: PCM samples belonging to this field (881/882 alternating at 44.1 kHz / 50 fields).
- `diskLoc`, `fileLoc`, `seqNo`, `syncConf`, `medianBurstIRE`, `vitsMetrics`.

## `.pcm` audio

16-bit signed little-endian, **stereo interleaved, 44,100 Hz** (`pcmAudioParameters`). 50 frames = 352,800 bytes =
1764 stereo samples per frame, which matches. These are the two analogue FM sound carriers. Channel conventions per disc
are still to be confirmed (the Domesday discs carry the program audio on both channels).

## Design rules derived (user direction, 2026-11-03)

1. **Output RGB first.** The composite-DAC output path is deferred until a working core exists.
2. **The OSD must be inserted in the composite domain.** On the real player the M50552 output is mixed into the
   composite video, and the footage shows the resulting composite artefacts (moiré on the blue raster,
   fringing on the glyph outlines). So the core must mix the OSD (and the blue background raster) into the
   composite sample stream, then PAL-decode to RGB. **Never paint the OSD over RGB.**
   This also means the core needs a PAL chroma decoder in the FPGA for the RGB path. Which decoder the player's
   own chain resembles is TBD; see the VDEM path in the SM (PA5013A / PM0001 CCD delay line / CXL1009P / PA0017).
