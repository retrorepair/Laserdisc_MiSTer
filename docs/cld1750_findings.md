# CLD-1750 (European, HEZ/HB): findings

Sources (hashes in `ref/PROVENANCE.md`):
- **SM**: service manual ARP2457 (Apr 1992), "applicable to the CLD-1750/HEZ and HB", 77 pp scan.
  OCR: `ref/cld1750/CLD-1750-EN_Service_Manual_ocr.txt`. Mechanism adjustments are deferred to **ARP2308 (CLD-1600 SM)**.
- **OM**: operating instructions VRE1009, EN/FR/DE/IT, 96 pp scan. OCR: `ref/cld1750/CLD-1750-EN-FR-DE-IT_ocr.txt`.
- **OM-K** (secondary): CLD-1750K US karaoke model, NTSC-only.

Page numbers below are PDF page numbers. OCR of part numbers must be confirmed against the page image.

## Control and video chips (SM parts lists pp.40-46, confirmed by eye for IC10)

| Ref (assembly) | Part | Role per SM | Program / data |
|---|---|---|---|
| IC101 (ASCB) | **PD0136A** | MECHANISM CONT. MCU | Pioneer mask MCU; core unknown |
| IC10 (FLKY) | **PDB068A** | MODE CONTROL MCU (FL tube, keys, remote; 5.50 MHz ceramic resonator) | Pioneer mask MCU; core unknown |
| IC11 (FLKY) | PST529C | Reset IC | n/a |
| (VDEM) | **M50552-132SP** | CHARACTER IC (on-screen display) | Mitsubishi catalogue OSD controller, customer font mask "-132" |
| (VDEM) | PA5013A, PM0001 (CCD delay line), CXL1009P, PA0017 | Video IC / TBC path | Same family as LD-V4300D VDEM |
| IC201 | CXD2500AQ | EFM demodulation | Fixed function |
| | SM5840AP | 8fs digital filter | Fixed function |
| | SAA7350 | DA converter (bitstream) | Fixed function |
| | CXA1081S | RF/servo | Fixed function |

## IC405 M50552-132SP pinout (SM p.29, VDTB board (1/2), read from the schematic image)

32-pin SDIP. 1 VSS1 · 2 SCK · 3 XAC (reset, from TBC XRESET) · 4 OSC1 · 5 OSC2 (LC dot-clock oscillator: L419 12 µH,
C501/C502 33 pF) · 6 N/XPAL · 7 XCS · 8 SDATA · 9 PAOUT · 10 SYEX · 11 VSS2 · 12 CV OUT · 13 CV IN · 14 LEBK · 15 LECHA ·
16 CB IN · 17 RS IN · 18 VDD2 · 19 RS OUT · 20 CB OUT · 21 YM · 22 BLNK · 23 CO · 24 B · 25 G · 26 R · 27 CSYNK · 28 OSCOUT ·
29 OSCIN (4FSC from TBC via C507) · 30 HOR · 31 VERT · 32 VDD.

- Serial control SCK/SDATA/XCS arrives from the ASCB board via CN (DATA, SCK1, SI1, XCS, plus CAV, FREQ DET, VSQ,
  CODE SUP on the same connector).
- **The chip itself superimposes onto composite video (CV IN → CV OUT)**, locked to the player's 4fsc. So the OSD
  composite artefacts originate inside this chip.
- **Digital R/G/B/BLNK/YM/CO outputs** make a bench capture of the real glyph raster possible (user may buy one, about £5).
- The serial protocol is undocumented (no datasheet found).

No EPROM appears anywhere in the parts lists. As expected, both MCUs are mask parts with no public dump. The
user has approved a documented reconstruction.

## OSD evidence available

- **Behaviour spec** (OM p.40): the DISPLAY button cycles, separately for LD with TOC, LD without TOC, CAV
  (DISC ABS after the frame number), CDV and CD. The OSD also auto-offs after a long period (any key restores it).
- **Four OSD languages** (OM p.40): the LANGUAGE button on the front panel cycles ENGLISH → FRANCAIS →
  DEUTSCH → ITALIANO; the setting persists through power-off. French strings seen: "RESTANTE TT", "RESTANTE PST",
  "TOTALE", "DISC ABS".
- **NTSC→PAL conversion** for NTSC discs on a PAL TV (OM p.~22). This affects the video path design: the player
  itself transcodes NTSC discs.
- **Test mode** (SM pp.48-52): entered by grounding TP (TEST MODE) on ASCB at power-on. TV-screen layouts are
  printed: `S-LD` / `S-CD`, `MODE00:00 00000`, `TRK-OFF`, `T-B:N` (tilt status), M-5 key reception data, SLD position,
  mechanism and key-control IC part numbers. There is also an FL-display layout for test mode.
- **OM illustrations are schematic** (boxes labelled "Screen display"), not glyph-accurate. **Font, glyph size,
  spacing and placement must come from real-unit footage**, cross-checked against the M50552 datasheet geometry.

## Gaps / next evidence needed

1. Good footage or photos of a real CLD-1750 OSD (user to source): every DISPLAY state, the four languages, search
   and number entry, repeat/program/chapter screens, the power-on/disc-load messages, and test mode if possible.
2. **M50552 datasheet**: screen geometry (characters per row, rows, dot matrix, character size and position
   registers, blinking, background/border modes). This pins down layout exactly, so footage only needs to supply glyph shapes.
3. Remaining OM pages: catalogue every function and its displayed messages (FL window and OSD).
4. SM schematics: which MCU drives the M50552 (expected: PDB068A or PD0136A over serial), and the FL tube
   segment/grid map for the front-panel display.
5. CLD-1600 SM ARP2308 (mechanism) if a deck model is needed.
