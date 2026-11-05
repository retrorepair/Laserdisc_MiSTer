# MOD. PAL: the CLD-1750's NTSC-disc output for PAL TVs (NTSC phase 2)

Started 2026-11-04 after the user's NTSC test: raw NTSC 3.58 from the core rainbows badly on their PAL TV, while
other NTSC sources look clean. The GGV1069 TBC itself is clean: the burst flips 180 deg line to line (-33 / 147 deg,
within 1-2 deg) and the four-field sequence is correct, and the core replays it unchanged (910 samples per line at a
constant clk_sys/4, bit-exact through the chroma split when Chroma advance is Off).

## What the player does (evidence)
- **OM p.46 (SYSTEM button), render `analysis/sm/palb/om46.png`.** NTSC disc: mode NTSC = colour on an NTSC TV, B/W on
  a PAL TV; mode **MOD. PAL = colour on a PAL TV**, B/W on an NTSC TV. On a PAL TV the picture may shrink vertically
  or roll ("caused by the NTSC -> PAL conversion"): the output stays 525 lines / 60 Hz. MOD. PAL's background is
  black, and it is the mode at power-on.
- **Pioneer's conversion is "pseudo-PAL (PAL on 60 Hz)"**: PAL colour coding on the 60 Hz picture
  ([LaserDisc UK, CLD-1500](https://laserdiscarchive.lddb.com/laserdisc_archive/pioneer/pioneer_cld-1500/pioneer_cld-1500.htm),
  [CLD-1400](https://laserdiscarchive.lddb.com/laserdisc_archive/pioneer/pioneer_cld-1400/pioneer_cld-1400.htm)). A PAL-only TV
  shows colour, so the chroma is PAL-coded: 4.43361875 MHz, V switched line by line, swinging burst.
- **SM p.54 (PDF 35), PALB board** (renders `analysis/sm/palb/*.png`). Control lines from the mechanism MCU (PD0136A,
  SM PDF 28): `NTSC/XPAL`, `N TO P`, `P/X4.43`, `X PLAY`, `JUMP TRIG`, `JUMP F/XR`; from VDTB: `REF SC IN`, `B.F. IN`
  (burst flag); to VDTB: `4FSC OUT`, `910FH OUT`. The board holds the reference crystals: X201 14.3 MHz (4fsc NTSC),
  X202 17.7 MHz (4fsc PAL), X203 14.2 MHz.
  - NTSC chroma: video -> Q210 -> DL201 (VTF1037 delay line) -> Q209 -> **F202 3.58 MHz band-pass** -> **F201 comb
    filter block** (VTF1042) -> IC208.
  - **IC208 TA7320P**, a transistor-tree balanced mixer. Its carrier input comes through Q203 from an LC filter
    (L203/L204 120 uH, C210 220 pF, C212 68 pF, C213 100 pF: about 1 MHz) after IC102 (3/4), an XOR of crystal-derived
    clocks. So the carrier is the difference of the two subcarriers, 4.4336 - 3.5795 = 0.854 MHz: the chroma is
    **heterodyned** to 4.43 MHz. Its output tank is L205 12 uH // C223 100 pF (about 4.6 MHz), level VR201 ("MOD SC").
  - The carrier's phase is steered by a D flip-flop chain and gates (IC202, IC203 74HC74; IC206, IC207 74HC10;
    IC102 74HC86), clocked from the crystals and the H/burst-flag timing. This is where the line-by-line switching
    happens. **Not yet transcribed gate by gate.**
  - 4.43 chroma: IC201 (1/3) BU4053 switch -> Q213 -> **F101 4.43 MHz band-pass** (VTF1034) -> Q103.
  - Luma: **F102 3.2 MHz low-pass** (VTF1011), or the comb filter's luma. SM adjustment 10 ("MOD Y level") matches
    "IC201 pin 3 (passed through the comb filter)" and "IC201 pin 5 (passed through the 3.2M LPF)", so IC201 chooses
    between them. **Which one, and when (play vs still/scan?), is not yet established.** F203 is a 4.43 MHz trap.
  - DL101 (DTF1033, 1H delay line) with Q104/Q105 and VR101, and IC103 BU4053: SM adjustment 9 ("1H delay S.C.
    level", PAL mode, colour bars **in still mode** on a vectorscope). So this is the **PAL-disc still/jump chroma
    corrector** (`JUMP TRIG`, `JUMP F/XR`, `X PLAY`), a separate function, and MOD video level (adjustment 8,
    VR102) is set in PAL mode too.

## Implementation (core/rtl/modpal.v, 2026-11-04)
Active when an NTSC disc is loaded and SYSTEM mode is MOD. PAL. It takes the replayed composite after the OSD (as
the PALB board takes VDTB's video) and works per 4fsc sample on the 8-bit codes:
1. **1H comb** (F201): d = x - x(line before). The TBC is line-locked, so NTSC chroma is exactly inverted line to line.
2. **Band-pass** (F202): c4 = 2d[n-2] - d[n] - d[n-4], -(1 - z^-2)^2, peak at fsc; chroma(n-2) = c4 / 8.
   **Luma** = 8x[n-2] - c4 (the comb's luma, IC201 pin 3).
3. **Chroma to 4.43 MHz.** The 4fsc samples sit 90 deg apart on the subcarrier, so held samples of c4 give the chroma's
   complex envelope. A fixed 33 deg rotation puts the burst on the real axis: ld-decode samples NTSC on the I/Q axes,
   measured -32 to -33 / +147 to +148 deg line to line on GGV1069. The sign of the line's burst (samples 80-107) gives
   U and V. They modulate a 4.43361875 MHz carrier (NCO, 32-bit; the PALB board's X202 is also free-running against
   the NTSC reference), with V inverted on alternate lines. In the burst window (74-113) the burst is turned to
   135 / 225 deg at its own amplitude, so the TV's colour gain is set as the disc's burst sets it.
4. PAL at 4.43 MHz is below the 4fsc Nyquist frequency (7.16 MHz), so the composite goes on at 4fsc into the core's
   4x reconstruction filter. Chroma advance (menu) delays the luma here, and the core's own split runs Off.

Verification:
- `tools/analysis/modpal_ref.py` is the bit-exact model. On GGV1069's red field (field 25000), its output fitted by
  least squares gives chroma 60-62 against the NTSC input's 60-61, and luma 129-130 with no NTSC chroma left.
  Decoded by a software PAL decoder (V switch from the burst, delay-line average) it gives hue 103-105 deg (red is
  103 deg), and the burst sits at +-134.7 deg.
- `core/sim/tb_modpal.sv` (`run_modpal.sh`, vectors from `modpal_vectors.py`): the RTL against the model on 19,110
  samples from three GGV1069 stretches, including a chroma advance change: 0 errors.

- **Hardware, 2026-11-04:** GGV1069 in MOD. PAL on the user's PAL TV over composite: "there is colour on the NTSC
  test disc and it looks great" (raw NTSC 3.58 had rainbowed badly on the same set).

## Not modelled / approximations
- The F101/F201/F202/F102/F203 parts (Pioneer VTF/DTF numbers) have no published data; web searches for the part
  numbers found nothing. So the responses are the comb and band-pass above, at the printed frequencies.
- The board's own mechanism is a heterodyne (TA7320P with a 0.854 MHz carrier made by XORing crystal clocks). A
  heterodyne keeps the chroma's phase and amplitude, so the output format is the same; the core makes the PAL carrier
  directly. The flip-flop logic that switches the carrier phase line by line was not transcribed gate by gate.
- The 3.2 MHz low-pass luma path (IC201 pin 5) is not used. Which of the two luma paths IC201 picks, and when, is not
  established.
- The OM gives only NTSC and MOD. PAL as the modes for NTSC discs, with MOD. PAL at power-on. The core's menu still has
  a third "PAL" entry and defaults to PAL (for the user to decide).
