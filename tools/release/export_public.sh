#!/bin/sh
# Export the public tree (github.com/retrorepair/Laserdisc_MiSTer) from this repository's HEAD into public/.
# Left out: manual OCR and text (Pioneer copyright), footage and disc-frame images (analysis/), session notes and
# planning documents, and the personal LDF front end. Then a check fails the export if anything private remains.
set -e
cd "$(dirname "$0")/../.."
OUT=public
mkdir -p "$OUT"
find "$OUT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git archive HEAD | tar -x -C "$OUT"
cd "$OUT"
rm -rf analysis research_notes HANDOFF.md CLAUDE.md LD-V4300D_MiSTer_Project_Plan.docx main_README.md "Convert LDF.bat" \
       tools/convert/ldf_convert.pyw
rm -f ref/cld1750/*_ocr.txt ref/docs/*.txt
rmdir ref/cld1750 ref/docs 2>/dev/null || true
# (bracketed so the patterns do not match this script)
if grep -rn -I -E '192[.]168[.]|googl[e]mail|-p[w] 1|Y:.MiST[e]r' . --exclude-dir=.git; then
	echo "export_public: private details found (above)"; exit 1
fi
# docs/images: the README's screenshots of the core (user, 2026-11-05); no other image goes public
if find . -path ./.git -prune -o -path ./docs/images -prune -o -type f \( -iname '*_ocr.txt' -o -iname '*.jpg' -o -iname '*.png' \) -print | grep .; then
	echo "export_public: OCR or image files found (above)"; exit 1
fi
echo "export_public: $(find . -path ./.git -prune -o -type f -print | wc -l) files in $OUT"
