/*
 * tbc2dscv - encode reference-decoded LaserDisc frames into a DSCV stream for
 * Laserdisc_MiSTer, using MiSTer-LaserActive's DSC encoder (dsc.c/dscv.c,
 * MIT, by the MiSTer-LaserActive authors) unchanged.
 *
 * Input (stdin): frames of raw RGB48 little-endian, interleaved, width x height,
 * as Decode-Orc's video_sink writes with output_mode=raw:raw_format=rgb. Rows
 * are frame-flat lines starting at an even frame line (crop_y), so even rows
 * belong to the first field and odd rows to the second.
 *
 * Output: a DSCV stream laid out exactly as dscv.h describes. Each frame is
 * stored as two DSC slices, first field then second field (the same stacked
 * field layout LaserActive uses), so the decoder can deliver one field at a
 * time. The VBI table holds four 24-bit biphase codes per frame, read from
 * ld-decode's own VBI decode (.tbc.db) by tbc2dscv.py: the PAL equivalents of
 * LaserActive's lines 16/17/279/280, namely lines 16 and 17 of the first field
 * and lines 329 and 330 of the second.
 *
 * Audio (Laserdisc_MiSTer extension, optional): each frame's ld-decode PCM samples are stored inside its frame
 * stride, after the DSC picture, so one sequential read per frame brings picture and sound. Header bytes 72-87
 * (reserved in dscv.h) describe it:
 *   72 u32 audio_offset   bytes from the frame's start to its audio block (0 = no audio), 8-aligned
 *   76 u32 audio_rate     44100
 *   80 u16 channels (2), 82 u16 bits (16)
 *   84 u32 audio_max      most samples a block holds (2046: the block is 1024 64-bit words)
 * Block: u32 sample count, u32 0, then the samples, interleaved little-endian int16 L, R (ld-decode .pcm order).
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#define fseek64 _fseeki64
#else
#define fseek64 fseeko
#endif

#include "dsc.h"
#include "dscv.h"

#define AUDIO_MAX 2046

static void wr32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

static void die(const char *msg, const char *arg)
{
	fprintf(stderr, "tbc2dscv: ");
	fprintf(stderr, msg, arg);
	fprintf(stderr, "\n");
	exit(1);
}

typedef struct {
	const dsc_pps *p;
	const dsc_enc_opts *opts;
	int w, h, verify;
	uint8_t *pic;  /* field-stacked 8-bit RGB, w*3 per row */
	uint8_t *out;  /* frame_stride bytes */
	uint8_t *dec;  /* verify: decoded picture */
	size_t frame_bytes;
	int fail, fallback;
	double psnr;
	int max_err;
} frame_job;

static double rgb_psnr(const uint8_t *a, const uint8_t *b, size_t n, int *max_err)
{
	double se = 0;
	int me = 0;
	for (size_t i = 0; i < n; i++) {
		int d = (int)a[i] - (int)b[i];
		se += (double)d * d;
		if (d < 0) d = -d;
		if (d > me) me = d;
	}
	*max_err = me;
	if (se == 0) return 99.0;
	return 10 * log10(255.0 * 255.0 / (se / (double)n));
}

/* Same overflow fallbacks as mmidsc's encode_with_fallback(): the other ICH
 * setting, then a light horizontal blur. Both keep the stream valid DSC. */
static void *encode_worker(void *arg)
{
	frame_job *J = arg;
	J->fallback = 0;
	J->fail = dsc_encode_picture(J->p, J->opts, J->pic, (size_t)J->w * 3, J->out, NULL, NULL);
	if (J->fail) {
		dsc_enc_opts o2 = *J->opts;
		o2.disable_ich = !o2.disable_ich;
		J->fallback = 1;
		J->fail = dsc_encode_picture(J->p, &o2, J->pic, (size_t)J->w * 3, J->out, NULL, NULL);
	}
	if (J->fail) {
		size_t row = (size_t)J->w * 3;
		uint8_t *soft = malloc(row * J->h);
		for (int y = 0; y < J->h; y++)
			for (int x = 0; x < J->w; x++)
				for (int c = 0; c < 3; c++) {
					int l = J->pic[y * row + (size_t)(x > 0 ? x - 1 : x) * 3 + c];
					int m = J->pic[y * row + (size_t)x * 3 + c];
					int r = J->pic[y * row + (size_t)(x < J->w - 1 ? x + 1 : x) * 3 + c];
					soft[y * row + (size_t)x * 3 + c] = (uint8_t)((l + 2 * m + r + 2) / 4);
				}
		J->fail = dsc_encode_picture(J->p, J->opts, soft, row, J->out, NULL, NULL);
		free(soft);
	}
	if (J->verify && !J->fail) {
		if (dsc_decode_picture(J->p, J->out, J->frame_bytes, J->dec)) J->fail = 1;
		else J->psnr = rgb_psnr(J->pic, J->dec, (size_t)J->w * J->h * 3, &J->max_err);
	}
	return NULL;
}

static void write_ppm(const char *path, const uint8_t *pic, int w, int h)
{
	FILE *f = fopen(path, "wb");
	if (!f) die("cannot write %s", path);
	fprintf(f, "P6\n%d %d\n255\n", w, h);
	fwrite(pic, 1, (size_t)w * h * 3, f);
	fclose(f);
}

static void usage(void)
{
	fprintf(stderr,
	        "usage: tbc2dscv -o OUT.dscv -n FRAMES -w WIDTH -h HEIGHT [options] < frames.rgb48\n"
	        "  -bpp X        DSC rate in bits per pixel (default 8)\n"
	        "  -vbi FILE     VBI table, 16 bytes per frame (from tbc2dscv.py)\n"
	        "  -crop-x N     first TBC sample of each row (header crop_x)\n"
	        "  -crop-y N     first frame-flat line, even (header crop_y)\n"
	        "  -src-w N      TBC samples per line (header src_width, default 1135)\n"
	        "  -src-h N      frame lines (header src_height, default 625)\n"
	        "  -fdur US      frame duration in microseconds (default 40000)\n"
	        "  -threads N    encoder threads (default 8)\n"
	        "  -verify       decode every frame again and report PSNR\n"
	        "  -dump K PFX   write frame K before (PFX_src.ppm) and after (PFX_dsc.ppm) coding\n"
	        "  -pcm FILE OFF COUNTS  audio: ld-decode .pcm from byte OFF, samples per frame in COUNTS (u32 each)\n");
	exit(2);
}

int main(int argc, char **argv)
{
	const char *out_path = NULL, *vbi_path = NULL, *dump_pfx = NULL, *pcm_path = NULL, *counts_path = NULL;
	long long pcm_off = 0;
	long frames = 0, dump_k = -1;
	int w = 0, h = 0, crop_x = 0, crop_y = 0, src_w = 1135, src_h = 625, fdur = 40000, threads = 8, verify = 0;
	double bpp = 8.0;
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		int more = i + 1 < argc;
		if (!strcmp(a, "-o") && more) out_path = argv[++i];
		else if (!strcmp(a, "-n") && more) frames = atol(argv[++i]);
		else if (!strcmp(a, "-w") && more) w = atoi(argv[++i]);
		else if (!strcmp(a, "-h") && more) h = atoi(argv[++i]);
		else if (!strcmp(a, "-bpp") && more) bpp = atof(argv[++i]);
		else if (!strcmp(a, "-vbi") && more) vbi_path = argv[++i];
		else if (!strcmp(a, "-crop-x") && more) crop_x = atoi(argv[++i]);
		else if (!strcmp(a, "-crop-y") && more) crop_y = atoi(argv[++i]);
		else if (!strcmp(a, "-src-w") && more) src_w = atoi(argv[++i]);
		else if (!strcmp(a, "-src-h") && more) src_h = atoi(argv[++i]);
		else if (!strcmp(a, "-fdur") && more) fdur = atoi(argv[++i]);
		else if (!strcmp(a, "-threads") && more) threads = atoi(argv[++i]);
		else if (!strcmp(a, "-verify")) verify = 1;
		else if (!strcmp(a, "-dump") && i + 2 < argc) { dump_k = atol(argv[++i]); dump_pfx = argv[++i]; }
		else if (!strcmp(a, "-pcm") && i + 3 < argc) {
			pcm_path = argv[++i]; pcm_off = atoll(argv[++i]); counts_path = argv[++i];
		}
		else usage();
	}
	if (!out_path || frames <= 0 || w <= 0 || h <= 0 || threads < 1) usage();
	if (h % 2 || crop_y % 2) die("height and crop_y must be even (whole frames, first field on even rows)%s", "");
	if (w % 3) die("width must be a multiple of 3 (DSC groups; slice_width == pic_width)%s", "");
#ifdef _WIN32
	_setmode(_fileno(stdin), _O_BINARY);
#endif

	char err[256];
	dsc_pps p;
	int bpp16 = (int)lround(bpp * 16);
	if (dsc_pps_init(&p, w, h, h / 2, bpp16, err, sizeof err)) die("DSC setup: %s", err);
	size_t frame_bytes = dsc_picture_bytes(&p);
	size_t audio_off = pcm_path ? (frame_bytes + 7) & ~(size_t)7 : 0;
	size_t audio_block = 8 + 4 * AUDIO_MAX;
	uint32_t stride = (uint32_t)(((pcm_path ? audio_off + audio_block : frame_bytes) + 511) & ~(size_t)511);
	uint32_t *counts = NULL;
	FILE *pcm = NULL;
	if (pcm_path) {
		FILE *cf = fopen(counts_path, "rb");
		if (!cf) die("cannot open %s", counts_path);
		counts = malloc(sizeof(uint32_t) * (size_t)frames);
		if (fread(counts, 4, (size_t)frames, cf) != (size_t)frames) die("%s is shorter than 4 bytes per frame", counts_path);
		fclose(cf);
		for (long i = 0; i < frames; i++)
			if (counts[i] > AUDIO_MAX) die("a frame has more samples than an audio block holds%s", "");
		pcm = fopen(pcm_path, "rb");
		if (!pcm || fseek64(pcm, pcm_off, SEEK_SET)) die("cannot open %s at its offset", pcm_path);
	}
	uint64_t frames_off = (DSCV_HEADER_SIZE + (uint64_t)frames * DSCV_VBI_ENTRY + 4095) & ~(uint64_t)4095;

	dscv_header H;
	memset(&H, 0, sizeof H);
	H.version = 1;
	H.src_width = src_w; H.src_height = src_h;
	H.crop_x = crop_x; H.crop_y = crop_y;
	H.width = w; H.height = h;
	H.field0_row = 0; H.field0_rows = h / 2;
	H.field1_row = h / 2; H.field1_rows = h / 2;
	H.frame_count = (uint32_t)frames;
	H.frame_duration_us = (uint32_t)fdur;
	H.frame_bytes = (uint32_t)frame_bytes;
	H.frame_stride = stride;
	H.frames_offset = frames_off;
	H.vbi_offset = vbi_path ? DSCV_HEADER_SIZE : 0;
	H.vbi_entry_size = vbi_path ? DSCV_VBI_ENTRY : 0;
	H.slices_per_frame = (uint32_t)p.slices_per_picture;
	dsc_pps_pack(&p, H.pps);

	uint8_t *head = calloc(1, (size_t)frames_off);
	dscv_pack(&H, head);
	if (pcm_path) {
		wr32(head + 72, (uint32_t)audio_off);
		wr32(head + 76, 44100);
		head[80] = 2; head[81] = 0; head[82] = 16; head[83] = 0;
		wr32(head + 84, AUDIO_MAX);
	}
	if (vbi_path) {
		FILE *vf = fopen(vbi_path, "rb");
		if (!vf) die("cannot open %s", vbi_path);
		if (fread(head + DSCV_HEADER_SIZE, DSCV_VBI_ENTRY, (size_t)frames, vf) != (size_t)frames)
			die("%s is shorter than 16 bytes per frame", vbi_path);
		fclose(vf);
	}
	FILE *of = fopen(out_path, "wb");
	if (!of) die("cannot create %s", out_path);
	if (fwrite(head, 1, (size_t)frames_off, of) != (size_t)frames_off) die("write failed: %s", strerror(errno));

	fprintf(stderr, "%dx%d, %.4g bpp, %d slices of %d rows, %zu bytes/frame (stride %u) = %.2f MB/s, %.2f GB\n", w, h,
	        bpp16 / 16.0, p.slices_per_picture, p.slice_height, frame_bytes, stride, stride * (1e6 / fdur) / 1e6,
	        (frames_off + (double)frames * stride) / 1e9);

	size_t in_bytes = (size_t)w * h * 6, pic_bytes = (size_t)w * h * 3;
	uint16_t *in = malloc(in_bytes);
	frame_job *jobs = calloc((size_t)threads, sizeof *jobs);
	pthread_t *th = malloc(sizeof(pthread_t) * (size_t)threads);
	dsc_enc_opts opts = { 0 };
	for (int t = 0; t < threads; t++) {
		jobs[t].p = &p; jobs[t].opts = &opts;
		jobs[t].w = w; jobs[t].h = h; jobs[t].verify = verify || dump_pfx;
		jobs[t].frame_bytes = frame_bytes;
		jobs[t].pic = malloc(pic_bytes);
		jobs[t].out = calloc(1, stride);
		jobs[t].dec = malloc(pic_bytes);
	}
	long failures = 0, fallbacks = 0, worst_frame = -1;
	double psnr_sum = 0, psnr_min = 99;
	int max_err = 0;
	for (long base = 0; base < frames; base += threads) {
		int n = (int)(frames - base < threads ? frames - base : threads);
		for (int t = 0; t < n; t++) {
			if (fread(in, 1, in_bytes, stdin) != in_bytes) {
				fprintf(stderr, "\ntbc2dscv: input ended at frame %ld of %ld\n", base + t, frames);
				exit(1);
			}
			/* 16 -> 8 bits with rounding; frame row r goes to field (r & 1), row r >> 1 */
			uint8_t *pic = jobs[t].pic;
			for (int r = 0; r < h; r++) {
				const uint16_t *s = in + (size_t)r * w * 3;
				uint8_t *d = pic + ((size_t)(r & 1) * (h / 2) + (r >> 1)) * w * 3;
				for (int i = 0; i < w * 3; i++) d[i] = (uint8_t)(((uint32_t)s[i] * 255 + 32767) / 65535);
			}
		}
		for (int t = 0; t < n; t++) pthread_create(&th[t], NULL, encode_worker, &jobs[t]);
		for (int t = 0; t < n; t++) pthread_join(th[t], NULL);
		for (int t = 0; t < n; t++) {
			long k = base + t;
			frame_job *J = &jobs[t];
			memset(J->out + frame_bytes, 0, stride - frame_bytes);
			if (pcm) {
				uint8_t *blk = J->out + audio_off;
				wr32(blk, counts[k]);
				if (fread(blk + 8, 4, counts[k], pcm) != counts[k]) die("%s ended early", pcm_path);
			}
			if (fwrite(J->out, 1, stride, of) != stride) die("write failed: %s", strerror(errno));
			if (J->fail) failures++;
			fallbacks += J->fallback;
			if (J->verify && !J->fail) {
				psnr_sum += J->psnr;
				if (J->psnr < psnr_min) { psnr_min = J->psnr; worst_frame = k; }
				if (J->max_err > max_err) max_err = J->max_err;
			}
			if (k == dump_k) {
				char path[1024];
				snprintf(path, sizeof path, "%s_src.ppm", dump_pfx);
				write_ppm(path, J->pic, w, h);
				snprintf(path, sizeof path, "%s_dsc.ppm", dump_pfx);
				write_ppm(path, J->dec, w, h);
			}
		}
		fprintf(stderr, "\r  %ld / %ld frames", base + n, frames);
	}
	fprintf(stderr, "\n");
	fclose(of);
	if (fallbacks) fprintf(stderr, "%ld frame(s) needed a fallback encode to fit the DSC budget\n", fallbacks);
	if (failures) fprintf(stderr, "WARNING: %ld frame(s) failed to encode or decode\n", failures);
	if (verify && frames > failures)
		fprintf(stderr, "verify: mean PSNR %.2f dB, min %.2f dB (frame %ld), max abs error %d\n",
		        psnr_sum / (double)(frames - failures), psnr_min, worst_frame, max_err);
	return failures ? 1 : 0;
}
