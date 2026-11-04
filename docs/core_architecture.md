# CLD-1750 core: architecture (milestone M1, "TBC replay to RGB")

## M1 goal
Replay ld-decode TBC fields held in DDR3 at native 4fsc timing and output RGB at 15 kHz through
the MiSTer video path. There is no player logic yet. This proves the clocking, memory, timing and PAL decode.

## Data flow

```
HPS (Linux) tools/mister/tbc_load.py ── mmap /dev/mem ──► DDR3 @ 0x30000000 (packed fields)
                                                              │ DDRAM (64-bit, clk_sys)
                                                    rtl/tbc_reader.sv  (line prefetch, 2-line BRAM ring)
                                                              │ 16-bit sample per ce_4fsc
                                                    rtl/tbc_timing.sv  (x 0..1134, line, field 312/313)
                                                              │
                                   [M2+: OSD + blue raster mixed HERE, composite domain]
                                                              │
                                                    rtl/pal_decoder.sv (≡ tools/model/pal_decode_fx.py)
                                                              │ RGB888 + HS/VS/DE
                                                          MiSTer video (analogue RGB / HDMI scaler)
```

## Clocks
- `clk_sys` = 4 × 4fsc PAL = **70.9379 MHz** (PLL from 50 MHz). `ce_4fsc` = 1 in 4.
  The pal_decoder therefore has 4 clocks per sample for resource sharing.
- PAL 4fsc = 17.734475 MHz exactly (SM p.54 trims the player's clock to this ±100 Hz). The PLL error must be
  documented once the PLL is generated (Cyclone V fractional PLL).
- NTSC (14.31818 MHz) is a later milestone; the CLD-1750 converts NTSC discs to PAL (PALB board).

## DDR3 layout (written by the HPS loader)
- Base byte address **0x30000000** (DDRAM_ADDR = {4'b0011, …}), the FPGA-owned DDR3 window.
- Each line is padded to **1136 samples = 2272 bytes = 284 × 64-bit words**. A field is 313 lines = 88,892 words.
  Fields are contiguous; field *n* starts at word 88,892·n. Little-endian uint16 as in the `.tbc`.
- Header-free for M1. The loader writes the field count to a fixed mailbox word (TBD) so the reader can loop.
- Capacity: about 726 fields (about 14.5 s) in 512 MB. This is for testing only; SD streaming comes in M3.

## Timing (tbc_timing.sv)
- 1135 samples per line, fields alternate **312 / 313 lines** (ld-decode PAL `field_lines = (312, 313)`;
  the 313-line .tbc field of the first field is padded, so the reader skips line 313 of the first field).
- Output: HSync = samples [0, 83) (4.7 µs at 4fsc); DE = samples [185, 1107) on lines with active video;
  VSync per field; VGA_F1 = field parity. **TODO:** align VSync/interlace phase with the sync pulses embedded in
  the TBC lines (equalising/broad pulses in lines 0-6) so 2:1 interlace is exact.

## PAL decoder (pal_decoder.sv)
Bit-exact with `tools/model/pal_decode_fx.py`, which is verified against the float golden model
`tools/model/pal_decode.py` (≥43.7 dB PSNR, max error 5/255 on Domesday frames 60 and 300).
- d = s − 14442; fs/4 mix; 7-tap [1 2 3 4 3 2 1] LPF; luma double notch [1 0 2 0 1]/4.
- Burst vector B = Σ LPF over centre samples 102..133. Colour killer: |B|² < KILL2.
- Ident: inverted ⇔ B·B_prev > 0 (dot product). Per-line coefficient via **one divide**
  q = ⌊N_DIV / |B|²⌋ (N_DIV = ⌊K_UV·2⁴⁸⌉), then c = (q·conj(B)(−1±j)) >> 24, uv = (L·c) >> 24.
- PAL delay line: uv_out = (uv + uv_prev) >> 1. YUV → RGB in Q12, clamp to 0..255.
- This decoder is a **TV-side stand-in** (user direction: RGB for now). The CLD-1750 itself outputs
  composite; the faithful output is the M4 composite DAC.

## Milestones
- **M1** TBC replay → RGB (this document).
- **M2** OSD: M50552 behaviour (24-column grid, glyphs from footage) mixed in the composite domain with the blue raster.
- **M3** Media streaming from SD (Main_MiSTer integration), indexed by VBI frame numbers; PCM audio.
- **M4** Player logic (keys/remote/FL display/modes per OM + SM), composite DAC output.
