# Disc TOC and EFM digital audio: what the captures hold (2026-11-04)

## What the TOC is for (CLD1750K OM)
- "Some LD discs are not provided with a TOC section" (OM, disc types page). On an LD the TOC is the EFM subcode
  (Q-channel) table in the lead-in, so only discs with digital audio have one.
- The player reads it at spin-up; QUICK TURN skips the read (OM p.20). Without it, "total time display, remaining time
  display and the elapsed time display of CAV" do not work.
- DISPLAY cycle (OM p.75): CAV with TOC: frame number -> Disc Time -> Remain ALL -> Total -> Off. CLV with TOC:
  elapsed -> Remain ALL -> Total -> Off. LD without TOC: frame number (CAV) / elapsed (CLV) and Off, alternately.
- The TOC also feeds the PGM screen and the front-panel track calendar (OM / SM function table: "Only discs with TOC").
- None of these screens exists in the core yet (no DISPLAY function).

## The captures
| Disc | Programme status (VBI line 16) | EFM | TOC |
|---|---|---|---|
| GGV1011 PAL test disc | 0x8BA800 / 0x8DC800: analogue stereo | none (slicer noise, no T11 syncs) | none |
| GGV1069 NTSC test disc | 0x8BA800 / 0x8DC800 (+0x8BA839) | none (no T11 syncs) | none |
| Community North | 0x8BA41F | **yes**: T11 2.2 %, textbook EFM, but a **data** track | lead-in not captured |

Community North EFM decode (Decode-Orc EFMSink, 4.6 min):
- One track, Q-channel mode 1 throughout, copy prohibited, no pre-emphasis, catalogue 0000000000000.
- **The track is a data track** (Q control bits, report Type "Data"). Decoded as audio it is steady noise at about
  -5 dBFS everywhere and does not correlate with the analogue sound. Community North has no digital audio; a player
  mutes a data track, and so does the converter. (Its files were deleted at the user's request, 2026-11-04.)
- Q absolute time tracks the CAV picture number (picture 1930 = 01:18:16).
- The capture starts with the player still settling (picture numbers 44, 94, 30, 80 in the first 8 s).
- EFM is unreadable in two stretches while the video is fine:
  - fields 400-4100 (pictures ~80-1930);
  - from field 89000 (picture 44380, 29:35) to the end.
- Decode-Orc splices the 74 s gap (5,584 sections) rather than filling it. **So `video_sync` alignment holds only up
  to the first gap**, and the converter's frame-count slicing of the digital track is wrong after it. The digital track
  ends at 29:36, about 6.5 minutes before the video.
- Report: POOR (0.25 % muted in the programme area, 129 missing sections interpolated).

## Decision (user, 2026-11-04): wait for a real TOC
- A disc gets TOC behaviour only when its capture includes a decodable lead-in TOC. Decode-Orc's report prints it
  under "Lead-in table of contents (Q-channel)", and that is the converter's source when such a capture turns up.
- The TOC is **not** rebuilt from programme-area subcode. Every capture without a captured lead-in behaves as an
  "LD without TOC" disc, Community North included.
- The TOC block's format (DSCV field, DDR3 location, spin-up read) is designed against the first real lead-in capture.

## Consequences
- Neither test disc can show TOC behaviour. They are "LD without TOC" discs.
- No capture we hold has a lead-in TOC to read.
- The converter decodes each run of readable EFM separately (`frame_map`), each aligned with its own first frame by
  `video_sync`, with digital silence between runs. Tested on Community North: runs (0-1), (117-165), (2026-44486), no
  timeline resyncs inside a run, the long run within 720 samples of its length. The alignment against real
  digital audio is **not yet verified**: no disc with digital audio has been captured yet.
- Data tracks are muted (no digital block content).
