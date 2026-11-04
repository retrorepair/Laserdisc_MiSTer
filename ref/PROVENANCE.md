# Reference pack provenance

All files fetched 2026-11-03. SHA-256 recorded at download time. Treat as read-only inputs.

## Documents (`ref/docs/`)

| File | Source URL | SHA-256 |
|---|---|---|
| Pioneer-LD-V4300D-Service-Manual-DD86_2.pdf (ARP2311, 101 pp) | https://www.domesday86.com/wp-content/uploads/2018/09/Pioneer-LD-V4300D-Service-Manual-DD86_2.pdf | 54d7fadff6a1ff1623cbe01fff7bd359ecb8566f259cd89e251474a2f9907bfd |
| Pioneer-LD-V4300D-Operating-Instructions-EN.pdf (23 pp, contains RS-232C command table) | https://www.domesday86.com/wp-content/uploads/2017/12/Pioneer-LD-V4300D-Operating-Instructions-EN.pdf | c687547359d9a1bd1380b4bc8885ea090bf0ebf3248682a3279b3376a3e7ed74 |
| Pioneer-LD-V4300D-Specifications.pdf (6 pp) | https://www.domesday86.com/wp-content/uploads/2017/12/Pioneer-LD-V4300D-Specifications.pdf | f260ac824947a8510f79074674f99d17ddaf1589c6860ec4773564b5a5b11bf3 |

`*_ocr.txt` / `*_text.txt` are text layers extracted with PyMuPDF (the service manual's
is OCR of a scan; treat its digits/part numbers as needing visual confirmation).

## ROM (`ref/rom/`)

Source: https://www.domesday86.com/wp-content/uploads/2020/10/Pioneer_4400-4300_ROMs.zip
(linked from https://simoninns.github.io/DomesdayDuplicator-docs/Hardware/LDV4300D-Overview.html)

| File | Size | SHA-256 |
|---|---|---|
| Pioneer_4400-4300_ROMs.zip | 77520 | 98742350ffc68bef12bf5ffd52b04c262e601ced707ea0e437459d70c3ed8e54 |
| Pioneer_4300_PAL_DYW1362.BIN | 32768 | de807976ccbdffd793591c287d237888348ebf5a745f54a3d805788cb9f27219 |
| Pioneer_4300_PAL_DYW1362.HEX | 92190 | 07a62907fed22ac783a657d0ec2456e614673080d2ada002a394f17873528607 |
| Pioneer_4400_NTSC_DYW1385.BIN | 32768 | d321756220f31a53d793f12a87e91fd3d968ace5685c16247d459c9556962bd7 |
| Pioneer_4400_NTSC_DYW1385.HEX | 92190 | 7b1b5a6dfea49dd0e46f4c59e4eaf76409581e5b3653bbdb8a4748e33e5bf8ed |

**Discrepancy:** the service manual parts list (p.11, Interior 2) names the programmed EPROM
**DYW1134**; the dump is labelled **DYW1362**. Most likely a later firmware revision; unconfirmed.
The dump's provenance (which player/serial, read method) is not documented in the zip.

## Repositories (`ref/repos/`, shallow clones, submodules NOT fetched)

| Repo | Commit | Licence |
|---|---|---|
| https://github.com/MukiEX/MiSTer-LaserActive | c547721f52ee647c121a42e20cc36d3ca3e2e390 (2026-10-26) | **none declared at top level**: reference only, do not copy code until clarified |
| https://github.com/happycube/ld-decode | 200b05d3ebff463002003be3d0dc0e8d1106abb3 (2026-09-26) | GPL-3.0 |

## Not yet obtained

- **LD-V4300D User's Manual / Programmer's Reference Guide** (physical copy listed at
  computinghistory.org.uk det/57209). Not found online. The closest is the CLD-V2600/2400 Level I & III
  guide (TP 117, archive.org `manualsbase-id-57154`), which is the same Pioneer command family but a different
  player and is **not authoritative** for the 4300D.
- **IC2 PD0110A mode-control MCU internal mask ROM**: no public dump found.
- **IC601 MB90061-101A character generator** font: no public dump found.

## CLD-1750 (target from 2026-11-03) (`ref/cld1750/`)

| File | Source URL | SHA-256 |
|---|---|---|
| CLD1750K_OM_PIONEER_EN.pdf (29 pp, scan, no text layer) | https://archive.org/download/manual_CLD1750K_OM_PIONEER_EN/CLD1750K_OM_PIONEER_EN.pdf | f1a3badec3c721008f20f1c582dd45b5bb06f8843c57c85cc03dce8de15083bf |
| CLD1750K_OM_ocr.txt (archive.org OCR of the above) | https://archive.org/download/manual_CLD1750K_OM_PIONEER_EN/CLD1750K_OM_PIONEER_EN_djvu.txt | 8202a9ad73fa039be6c4e7fbcb82385ada3b7098854ea3d1194435e34e37dd0d |

**Caution:** this is the **CLD-1750K** (US karaoke model, "exclusively NTSC"). It is NOT the European PAL/NTSC unit.
Use it only as secondary evidence.

Supplied by the user 2026-11-03 (they downloaded these; exact source page not recorded by me):

| File | SHA-256 |
|---|---|
| CLD-1750-EN_Service_Manual_Scan.pdf (ARP2457, 77 pp, image-only; filename matches the LDDB scan) | 51949334e225e4c392cf5d378777a220f2ba3b1cf388e9a713307fd841425d4a |
| CLD-1750-EN-FR-DE-IT_Scan.pdf (VRE1009 OM, 96 pp, image-only) | ed59a8a21d89377e13f3360465f20df2d5e879a761b63627277af1244d862f7e |

`*_ocr.txt` for these were produced locally with Windows.Media.Ocr (`tools/docs/winocr.ps1`) at 200 dpi.

## CLD-1750 footage (`ref/cld1750/footage/`)

| File | Source | SHA-256 |
|---|---|---|
| IMdDAQigdmA_…CLD-1750 (Including Internal Workings).mp4 (1080p, 606 s) | https://www.youtube.com/watch?v=IMdDAQigdmA (RetroGamerVX), via yt-dlp 2026.10.26 | a725d4e4e9f91be16a635c7ded8a106815fd70aa6f5061d0d448399cad2ede10 |

Tools installed for this (user-approved, PyPI, --user): yt-dlp 2026.10.26 and imageio-ffmpeg (bundles ffmpeg 9.0.2).

## Mitsubishi data books (`ref/mitsubishi/`)

| File | Source | SHA-256 | Result |
|---|---|---|---|
| 1990_Mitsubishi_Digital_ASSP.pdf (445 pp, has text layer) | http://bitsavers.trailing-edge.com/components/mitsubishi/_dataBooks/1990_Mitsubishi_Digital_ASSP.pdf | 764d67dfd2e0111bd7881ac7d87e1c41aaedc02de1a20201513650d6ea0a5848 | **No OSD/CRT display controllers** (logic ASSPs only) |
| 1986_Mitsubishi_Single_Chip_8-Bit_Vol2.pdf (197 pp) | bitsavers …/_dataBooks/ | 7be19ffb02e99ada2d85d03d5ae90c11f0d941a98ee481ed3ca4c1bf88227e12 | No OSD chips (M5078x/M50790, M50740) |
| 1990_Mitsubishi_Microprocessors_and_Peripheral_Circuits.pdf (361 pp) | bitsavers …/_dataBooks/ | 7aba9955296c53f00a30909789abe04c53b6ca9d5fe104373e8a0c04abd53199 | No OSD chips |

## CLD-3080 footage

| File | Source | SHA-256 |
|---|---|---|
| f-a_ugpKomI_Pioneer CLD-3080 Laserdisc Player.mp4 (854x480, 117 s) | https://www.youtube.com/watch?v=f-a_ugpKomI (Retrodiggs, 2023-01-18) | 29896aea989bd810381b5ac25e055107b388b1d6df93eee0079d569939bb067c |
| lfdYgYbGg58_My First Ever Laserdisc Play On My First Ever Player! ( Pioneer CLD-1750 ).mp4 (1280x720, 483 s) | https://www.youtube.com/watch?v=lfdYgYbGg58 (RetroGamerVX, 2016-04-01) | 4ca1bf3e4653e5f937b51fb57aa7c115ae9313facaf4ee14bb3b3445fe208e45 |
