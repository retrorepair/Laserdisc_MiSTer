# Third-party notices

Laserdisc_MiSTer includes or builds on the following third-party code. Each file keeps its original header.

## MiSTer-LaserActive (MukiEX), https://github.com/MukiEX/MiSTer-LaserActive
Submodules MegaCD_MiSTer @ 1d812165 and Main_MiSTer @ e57fd2d2. Both repositories ship a GPL-3 LICENSE. The files
used here are individually tagged `SPDX-License-Identifier: MIT` by their author:

| Our file | Source | Changes |
|---|---|---|
| `core/rtl/dsc_decoder.sv` | `MegaCD_MiSTer/rtl/LD/dsc_decoder.sv` | none (byte-identical) |
| `core/rtl/ld_fifo.sv` | `MegaCD_MiSTer/rtl/LD/ld_fifo.sv` | none (byte-identical) |
| `core/rtl/ld_stream.sv` | derived from `MegaCD_MiSTer/rtl/LD/ld_video.sv` | player-driven frame choice, DDR3 mailbox, 24-bit line fetch; the VDP cadence scheduler removed (see its header) |
| `tools/convert/dscv/tbc2dscv.exe` (built) | links `MegaCD_MiSTer/tools/mmidsc/src/{dsc.c,dscv.c,util.c}` | none; our driver is `tbc2dscv.c` |

The MIT licence, as it applies to those files:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
> documentation files (the "Software"), to deal in the Software without restriction, including without limitation
> the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
> permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of
> the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
> WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
> COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
> OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

The planned Main fork will be based on Main_MiSTer, which is GPL-3. Its source must be published with any binary.

## VESA Display Stream Compression
The stream format is VESA DSC (encoder and decoder by MiSTer-LaserActive, written from the DSC 1.2a text). The
mmidsc README notes that VESA distributes the standard free of charge, and that patent licences are available from
VESA member contributors under RAND terms. **Check VESA's terms before distributing hardware or software that
implements it.**

## MiSTer template (core/sys)
MiSTer-devel Template_MiSTer @ e901a9fa, GPL-2-or-later.

## Decode-Orc / ld-decode (offline tools, not distributed with the core)
Decode-Orc 2.10.1 and ld-decode are used offline to produce the streams; they are not part of the core.
