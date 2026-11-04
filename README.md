# Laserdisc for MiSTer

A MiSTer FPGA core that behaves like a Pioneer LaserDisc player. It plays decoded RF captures of real discs
(Domesday Duplicator `.ldf` files, decoded by [ld-decode](https://github.com/happycube/ld-decode)), with the player's
own transport behaviour, on-screen display and sound handling. It can output **genuine composite video**: the
disc's own time-base-corrected signal, sample for sample, through the analogue I/O board's DAC, with no RGB
re-encoding.

> **Status: early test build.** PAL discs play from start to end with picture, sound and the player's OSD. Expect
> bugs. Please report what you see (with photos of the TV if you can) in the issues.

- [What it does](#what-it-does)
- [What you need](#what-you-need)
- [Tutorial 1: turning an LDF capture into a disc file](#tutorial-1-turning-an-ldf-capture-into-a-disc-file)
- [Tutorial 2: setting up the core](#tutorial-2-setting-up-the-core)
- [Tutorial 3: making the composite cable](#tutorial-3-making-the-composite-cable)
- [Controls](#controls)
- [Streaming from a network share](#streaming-from-a-network-share)
- [How it works](#how-it-works)
- [Credits and licences](#credits-and-licences)

## What it does

The aim is a faithful player, not a video file viewer. Every behaviour, OSD screen and timing is reconstructed from
Pioneer's service manuals, operating instructions and recordings of real players. Gaps in the evidence are listed
in `docs/`, not filled with guesses.

| | |
|---|---|
| Disc formats | PAL now. NTSC playback is next (the converter already handles NTSC captures). |
| Picture | **RGB**: decoded offline by Decode-Orc's Transform PAL 3D, the ld-decode project's reference decoder (HDMI or analogue RGB). **Composite**: the TBC samples replayed at 4fsc (17.734475 MHz), with the player's OSD mixed into the composite signal, as on the real machine. |
| Sound | The disc's analogue FM soundtracks (ld-decode's 44.1 kHz PCM). Muted outside normal play, as the player does. Channel select (stereo, L, R) with AUDIO D/A. Squelched where the disc's programme status code says there is no programme. |
| Transport | Tray open/close, spin-up, PLAY, PAUSE, STOP, still frame, step forward/back, scan forward/back, end of disc. Loading a disc closes the tray and starts play, as PLAY does with the tray open. Timings follow the manuals and footage. |
| Two-sided discs | At the end of side A the player turns the disc: the last picture holds, with no sound, then side B cuts in and plays. DISC SIDE A/B turn on request, and DISC SIDE A from stop plays side A only. |
| OSD | The player's character-generator screens, with the background blue (PAL/NTSC mode) or black (MOD. PAL), as the manual describes. |
| VBI | The disc's own vertical-interval lines are played, Philips codes included. |
| Coming next | NTSC, SEARCH/CHAPTER, digital audio. |

## What you need

- A MiSTer (DE10-Nano) with 1 GB DDR3. The core streams the disc from storage through DDR3.
- For composite: an **analogue I/O board** and a simple cable ([tutorial 3](#tutorial-3-making-the-composite-cable)).
  HDMI works for RGB.
- Disc files on the SD card, a USB drive, or a fast network share ([streaming](#streaming-from-a-network-share)).
- To make disc files: a PC (tested on Windows 11), Python 3.12, ld-decode, and Decode-Orc.

Disc captures are copyrighted works. This project ships no disc data: use captures of discs you own.

## Tutorial 1: turning an LDF capture into a disc file

A disc file (`.dscv`) holds every frame of one disc side: the RGB picture (DSC-compressed), the composite TBC
samples, the sound, and the VBI codes. Making one has three steps.

```
capture.ldf --ld-decode--> capture.tbc (+ .tbc.db, .pcm) --tbc2dscv.py--> disc.dscv --add_cvbs.py--> disc.dscv (with composite)
```

### 1. Decode the RF with ld-decode

Install [ld-decode](https://github.com/happycube/ld-decode) (tested: 7.0.0, commit `200b05d3`, Python 3.12 on
Windows). Then decode the whole side:

```
ld-decode --PAL -t 8 capture.ldf decoded/capture
```

This writes `decoded/capture.tbc` (the time-base-corrected video), `.tbc.json` and `.tbc.db` (metadata, VBI and
dropouts), `.pcm` (the analogue sound) and `.efm` (digital sound, not used yet). It is slow: about 2.5 frames per
second with 8 threads, so a full CAV side of 54,000 frames takes about 6 hours.

### 2. Make the RGB stream with tbc2dscv

PAL and NTSC captures both work: the converter takes the system from ld-decode's `.tbc.db` (Decode-Orc's
Transform PAL 3D, or its `ntsc3d` decoder). The core plays PAL only for now.

Install [Decode-Orc](https://github.com/simoninns/decode-orc) (tested: 2.10.1 for Windows; the MSI can be
extracted rather than installed). `tbc2dscv.py` runs its `orc-cli` in chunks and feeds the frames to `tbc2dscv.exe`,
the DSC encoder (prebuilt in the release; `tools/convert/dscv/build.sh` builds it with MinGW gcc).

```
python tools/convert/dscv/tbc2dscv.py decoded/capture.tbc MyDisc.dscv --orc "C:\path\to\Decode-Orc\bin\orc-cli.exe"
```

The `.tbc.db` and `.pcm` must sit beside the `.tbc`. Use `--first N --count N` to convert part of a disc for a
quick test, and `--no-audio` if you have no `.pcm`. Instead of `--orc`, you can set the `ORC_CLI` environment
variable.

### 3. Add the composite samples with add_cvbs

```
pip install numpy
python tools/convert/dscv/add_cvbs.py decoded/capture.tbc MyDisc.dscv
```

This appends the composite region: every TBC sample as an 8-bit DAC code, with dropouts replaced by the line
above, as the player's dropout compensator does. Without it the core can only show RGB. Check the result with:

```
python tools/convert/dscv/dscv_info.py MyDisc.dscv
```

A file is about 1.3 MB per frame: about 10 GB for 5 minutes, and about 70 GB for a full CAV side.

### Two-sided discs

Name the sides so the file names end `side1` and `side2`, for example `Domesday North side1.dscv` and
`Domesday North side2.dscv`, in the same folder. When side 1 ends, the player turns to the matching `side2` file.

## Tutorial 2: setting up the core

The core needs its own build of the MiSTer main program (the "Laserdisc Main"), which streams the disc into DDR3.
MiSTer switches to it only when this core loads, and uses your normal Main for everything else.

1. **Copy the files from the release:**
   - `Laserdisc_YYYYMMDD.rbf` into a core folder, for example `/media/fat/_Custom Cores/` (or `_Other`).
   - `MiSTer_Laserdisc` into `/media/fat/` (beside the stock `MiSTer` binary).
2. **Add this section to `/media/fat/MiSTer.ini`** (back the file up first):
   ```ini
   [Laserdisc]
   main=MiSTer_Laserdisc
   ```
3. **Put your disc files in `games/Laserdisc/`**, as for any other core: on the SD card
   (`/media/fat/games/Laserdisc/`), on USB, or on a network share mounted as `games`.
4. **Load the core**, open the OSD (F12), choose **Load disc**, and pick a `.dscv` file. The tray closes, the disc
   spins up and play starts, as on the player when PLAY is pressed with the tray open.
5. Optional: make a shortcut (`.mgl`) that loads the core and a disc in one step:
   ```xml
   <mistergamedescription>
       <rbf>_Custom Cores/Laserdisc_20261104</rbf>
       <file delay="2" type="s" index="0" path="/media/fat/games/Laserdisc/MyDisc.dscv"/>
   </mistergamedescription>
   ```

**Core menu:**
- **SYSTEM mode** (PAL, NTSC, MOD. PAL): the player's output mode. It also sets the background colour.
- **Video output** (RGB, Composite): Composite sends the disc's composite signal to the analogue VGA port.
- **Composite DAC** (Green 0.7 V, R+G+B tied 1.0 V): must match your cable ([tutorial 3](#tutorial-3-making-the-composite-cable)).
- **Chroma advance** (Off, 0.11-0.79 us): sends the colour signal early, to cancel the colour delay of the MiSTer's
  analogue output path (colour trailing to the right of edges). Off leaves the signal untouched. Pick the setting
  that looks best on your TV (0.34 us on the developer's).

**MiSTer.ini for composite:** keep `vga_mode=rgb` (the default) and `vga_scaler=0`. The `cvbs`, `svideo` and `ypbpr`
modes would run the framework's own colour conversion over the core's signal and wreck it.

## Tutorial 3: making the composite cable

The core puts a complete composite signal (sync, burst, picture) on the VGA port's colour pins. All you need is a
VGA plug (DE-15 male), some 75 Ω coax, and an RCA (phono) plug, or a SCART plug wired for composite in.

| VGA pin | Signal |
|---|---|
| 1 | red |
| 2 | green |
| 3 | blue |
| 6 | red return |
| 7 | green return |
| 8 | blue return |

**Option A: R+G+B tied, the best signal (1.0 V, standard level).** Join pins **1, 2 and 3** together to the coax
centre, and pins **6, 7 and 8** together to the shield. In the core menu set **Composite DAC: R+G+B tied (1.0V)**.
The three DAC outputs work in parallel and reach the standard 1 V sync-to-white into the TV's 75 Ω input, with
about 9.5 bits of resolution.

**Option B: green only (0.7 V).** Wire pin **2** to the centre and pin **7** to the shield. Set **Composite DAC:
Green (0.7V)**. This is simpler, but the signal is only 70% of the standard level (most TVs cope).

Don't use the tied setting with a green-only cable: the signal would be a third of its proper size, washed out
and grey.

Then set **Video output: Composite**. Notes:
- The MiSTer OSD menu shows in monochrome over the composite picture. The core builds the framework so its menu
  can't pull the signal down to sync level. The core's own player OSD is mixed into the composite signal properly.
- HDMI shows the raw composite waveform (green, or grey) while composite is selected. Use RGB for HDMI.

## Controls

Keyboard (the player's front panel and remote):

| Key | Function |
|---|---|
| Enter | PLAY |
| Space | PLAY/PAUSE |
| P | PAUSE |
| S | STOP |
| E | OPEN/CLOSE |
| Left / Right (hold) | SCAN reverse / forward |
| , / . | STEP reverse / forward (from still) |
| Y | SYSTEM (output mode) |
| A | AUDIO D/A (stereo, L, R) |
| F1 / F2 | DISC SIDE A / DISC SIDE B |

## Streaming from a network share

The core reads the disc as it plays: **14.6 MB/s for RGB, 18 MB/s for composite.** The SD card is fine. For a
network share:
- **Turn off SMB encryption** for the share on the server. Decrypting AES on the MiSTer's ARM caps reads at about
  10 MB/s. On Windows Server: `Set-SmbShare -Name <share> -EncryptData $false` and
  `Set-SmbServerConfiguration -EncryptData $false`.
- **Gigabit all the way.** One 100 Mbit/s switch, router port or powerline adapter in the path caps reads at about
  11 MB/s.
- **The server's disk must keep up** on a first read (a slow or busy drive can fall below 18 MB/s).

## How it works

- **The stream** follows [MiSTer-LaserActive](https://github.com/MukiEX/MiSTer-LaserActive)'s design: the picture is
  VESA DSC-compressed at a constant rate (DSCV), read by a thread in the Main into a ring of DDR3 slots, and decoded
  by its DSC decoder in the FPGA. The timings are the Domesday project's (ld-decode's PAL TBC: 1135 samples per
  line, 4fsc), not LaserActive's.
- **Composite** is the TBC replayed at 17.734475 MHz. That is the player's own output clock: its CCD time-base
  corrector is locked to a 4fsc crystal. The OSD is mixed into the composite domain, and the RGB path takes the
  same mixing decision.
- **The player logic** (transport, OSD, sound rules) is written from the service manual, operating instructions
  and footage. Each rule cites its source in the code and in `docs/player_logic.md`.
- Design notes: `docs/streaming_design.md`, `docs/composite_output.md`, `docs/player_logic.md`,
  `docs/core_architecture.md`.

Building: open `core/Laserdisc_MiSTer.qpf` in Quartus Prime Lite 17.0. The Laserdisc Main is the `laserdisc` branch
of [retrorepair/Main_MiSTer](https://github.com/retrorepair/Main_MiSTer/tree/laserdisc) (`support/laserdisc/`),
built with MiSTer's usual ARM toolchain (gcc 10.2, `arm-none-linux-gnueabihf`).

## Credits and licences

- [MiSTer-devel](https://github.com/MiSTer-devel): the MiSTer framework (`core/sys`, GPL-2.0-or-later) and Main_MiSTer
  (GPL-3.0).
- [MiSTer-LaserActive](https://github.com/MukiEX/MiSTer-LaserActive) by MukiEX: the DSCV stream format, DSC encoder and
  decoder, and the streaming design this core adopts (the reused files are MIT; see `THIRD_PARTY_NOTICES.md`).
- [ld-decode](https://github.com/happycube/ld-decode) and the Domesday86 project: RF decoding and the TBC format.
- [Decode-Orc](https://github.com/simoninns/decode-orc) by Simon Inns: the reference PAL decoder.

This core is licensed **GPL-3.0-or-later** (`LICENSE`). The stream uses VESA Display Stream Compression. VESA
distributes the standard free of charge, and patent licences are available from VESA member contributors on RAND
terms.

Pioneer and LaserDisc are trademarks of their owners. This project is not affiliated with or endorsed by Pioneer.
