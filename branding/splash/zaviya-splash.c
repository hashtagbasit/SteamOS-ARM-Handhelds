/*
 * Boot animation: draws the logo on the built-in panel from early boot until
 * the session is about to start, then gives up the display and leaves the
 * picture up so there's no black gap before gamescope.
 *
 *   zaviya-splash                  run on the panel
 *   zaviya-splash --movie DIR      write the Steam startup movie frames
 *
 * SIGUSR1 means the session is starting. No libdrm, so it can start before
 * anything else is up. It never decides whether the boot worked: any failure
 * just exits, and the boot carries on without it.
 */
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "logo_masks.h"

#define INTRO_S 1.6
#define PULSE_S 0.75
#define GLOW_R_DIV 22	/* how far the glow reaches, as a share of the width */
#define FPS_WAITING 24
#define GOLD_R 0xC9
#define GOLD_G 0xA2
#define GOLD_B 0x4D
#define TAG_GREY 0xB5

enum { FRAME, GOLD, NAME, TAG, LAYERS };

struct picture {
	int w, h;
	uint8_t *layer[LAYERS];
	uint8_t *halo;	/* the gold layer, blurred: the glow around the bar */
};

static uint8_t *unpack(const unsigned char *rle, size_t len)
{
	uint8_t *out = malloc(MASK_W * MASK_H), *p = out;

	if (!out)
		return NULL;
	for (size_t i = 0; i + 2 < len; i += 3) {
		int n = rle[i] | rle[i + 1] << 8;

		memset(p, rle[i + 2], n);
		p += n;
	}
	return out;
}

/* Bilinear, or the box average of the source when shrinking far enough to alias. */
static uint8_t *scale(const uint8_t *src, int w, int h)
{
	uint8_t *out = malloc(w * h);
	float sx = (float)MASK_W / w, sy = (float)MASK_H / h;
	int box = sx > 1.5f ? (int)ceilf(sx) : 1;

	if (!out)
		return NULL;
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			float fx = (x + 0.5f) * sx - 0.5f, fy = (y + 0.5f) * sy - 0.5f;
			float sum = 0;

			for (int b = 0; b < box * box; b++) {
				float gx = fx + (b % box - (box - 1) / 2.0f) * sx / box;
				float gy = fy + (b / box - (box - 1) / 2.0f) * sy / box;
				int x0 = gx < 0 ? 0 : (int)gx, y0 = gy < 0 ? 0 : (int)gy;
				int x1 = x0 + 1 < MASK_W ? x0 + 1 : x0;
				int y1 = y0 + 1 < MASK_H ? y0 + 1 : y0;
				float ax = gx < 0 ? 0 : gx - x0, ay = gy < 0 ? 0 : gy - y0;
				const uint8_t *r0 = src + y0 * MASK_W, *r1 = src + y1 * MASK_W;

				sum += (r0[x0] * (1 - ax) + r0[x1] * ax) * (1 - ay) +
				       (r1[x0] * (1 - ax) + r1[x1] * ax) * ay;
			}
			out[y * w + x] = (uint8_t)(sum / (box * box) + 0.5f);
		}
	}
	return out;
}

/*
 * The glow's strength from the distance to the nearest part of the bar, so the
 * thin ends shine as much as the thick middle. Two-pass chamfer distance.
 */
static uint8_t *make_halo(const uint8_t *mask, int w, int h)
{
	float *d = malloc(sizeof(float) * w * h);
	uint8_t *out = malloc(w * h);
	float reach = (float)w / GLOW_R_DIV;

	if (!d || !out)
		return NULL;
	for (int i = 0; i < w * h; i++)
		d[i] = mask[i] > 96 ? 0 : 1e9f;
#define RELAX(i, j, cost) do { if (d[j] + (cost) < d[i]) d[i] = d[j] + (cost); } while (0)
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			int i = y * w + x;

			if (x > 0)
				RELAX(i, i - 1, 1.0f);
			if (y > 0)
				RELAX(i, i - w, 1.0f);
			if (x > 0 && y > 0)
				RELAX(i, i - w - 1, 1.414f);
			if (x < w - 1 && y > 0)
				RELAX(i, i - w + 1, 1.414f);
		}
	}
	for (int y = h - 1; y >= 0; y--) {
		for (int x = w - 1; x >= 0; x--) {
			int i = y * w + x;

			if (x < w - 1)
				RELAX(i, i + 1, 1.0f);
			if (y < h - 1)
				RELAX(i, i + w, 1.0f);
			if (x < w - 1 && y < h - 1)
				RELAX(i, i + w + 1, 1.414f);
			if (x > 0 && y < h - 1)
				RELAX(i, i + w - 1, 1.414f);
		}
	}
#undef RELAX
	for (int i = 0; i < w * h; i++) {
		float t = 1 - d[i] / reach;

		out[i] = t > 0 ? (uint8_t)(255 * t * t) : 0;
	}
	free(d);
	return out;
}

static int load_picture(struct picture *pic, int w, int h)
{
	static const struct { const unsigned char *rle; size_t len; } src[LAYERS] = {
		{ rle_frame, sizeof(rle_frame) }, { rle_gold, sizeof(rle_gold) },
		{ rle_name, sizeof(rle_name) }, { rle_tag, sizeof(rle_tag) },
	};

	pic->w = w;
	pic->h = h;
	for (int i = 0; i < LAYERS; i++) {
		uint8_t *full = unpack(src[i].rle, src[i].len);

		if (!full)
			return -1;
		pic->layer[i] = scale(full, w, h);
		free(full);
		if (!pic->layer[i])
			return -1;
	}
	pic->halo = make_halo(pic->layer[GOLD], w, h);
	return pic->halo ? 0 : -1;
}

static float ramp(float t, float start, float end)
{
	t = (t - start) / (end - start);
	t = t < 0 ? 0 : t > 1 ? 1 : t;
	return t * t * (3 - 2 * t);
}

/* What a moment of the animation looks like. */
struct look {
	float wipe;	/* the frame's soft edge, 0 at its left, 1 past its right */
	float frame, gold, gold_shift;
	float glow;	/* 0 no halo, 1 full halo and a white-hot bar */
	float name, tag;
};

static struct look intro_look(float t)
{
	struct look l = {
		.wipe = ramp(t, 0, 0.9f),
		.frame = 1,
		.gold = ramp(t, 0.6f, 1.15f),
		.gold_shift = 1 - ramp(t, 0.6f, 1.15f),
		.name = ramp(t, 0.9f, 1.4f),
		.tag = ramp(t, 1.1f, INTRO_S),
	};
	return l;
}

/* The bar glows while we wait: fast, and sharper at the peak than a plain wave. */
static float pulse(float t)
{
	float wave = 0.5f + 0.5f * cosf(2 * (float)M_PI * t / PULSE_S);

	return wave * wave;
}

/*
 * One row, as 0xRRGGBB. Black where the layers are empty, so only the row's
 * coverage costs anything worth caring about.
 */
static void compose_row(const struct picture *pic, const struct look *l, int y, uint32_t *row)
{
	const uint8_t *frame = pic->layer[FRAME] + y * pic->w;
	const uint8_t *gold = pic->layer[GOLD] + y * pic->w;
	const uint8_t *name = pic->layer[NAME] + y * pic->w;
	const uint8_t *tag = pic->layer[TAG] + y * pic->w;
	int shift = (int)(l->gold_shift * pic->w * 0.05f);
	float soft = pic->w * 0.18f;
	float edge = l->wipe * (pic->w + soft);

	for (int x = 0; x < pic->w; x++) {
		float wipe = (edge - x) / soft;
		float a;
		int r, g, b, gx = x - shift;

		wipe = wipe < 0 ? 0 : wipe > 1 ? 1 : wipe;
		a = frame[x] * wipe * l->frame + name[x] * l->name;
		r = g = b = (int)a;
		a = tag[x] * l->tag * TAG_GREY / 255.0f;
		r += (int)a;
		g += (int)a;
		b += (int)a;
		if (gx >= 0 && gold[gx]) {
			a = gold[gx] * l->gold / 255.0f;
			r += (int)((GOLD_R + (255 - GOLD_R) * l->glow) * a);
			g += (int)((GOLD_G + (255 - GOLD_G) * l->glow * 0.8f) * a);
			b += (int)((GOLD_B + (255 - GOLD_B) * l->glow * 0.5f) * a);
		}
		if (l->glow > 0 && pic->halo[y * pic->w + x]) {
			a = pic->halo[y * pic->w + x] * l->glow / 255.0f;
			r += (int)(GOLD_R * a);
			g += (int)(GOLD_G * a);
			b += (int)(GOLD_B * a);
		}
		row[x] = (uint32_t)(r > 255 ? 255 : r) << 16 | (g > 255 ? 255 : g) << 8 | (b > 255 ? 255 : b);
	}
}

static int write_bmp(const char *path, const struct picture *pic, const struct look *l)
{
	int stride = (pic->w * 3 + 3) & ~3, size = 54 + stride * pic->h;
	uint8_t *buf = calloc(1, size);
	uint32_t *row = malloc(pic->w * 4);
	FILE *f = fopen(path, "wb");

	if (!buf || !row || !f)
		return -1;
	memcpy(buf, "BM", 2);
	memcpy(buf + 2, &size, 4);
	buf[10] = 54;
	buf[14] = 40;
	memcpy(buf + 18, &pic->w, 4);
	memcpy(buf + 22, &pic->h, 4);
	buf[26] = 1;
	buf[28] = 24;
	for (int y = 0; y < pic->h; y++) {
		uint8_t *out = buf + 54 + (pic->h - 1 - y) * stride;

		compose_row(pic, l, y, row);
		for (int x = 0; x < pic->w; x++) {
			out[x * 3] = row[x];
			out[x * 3 + 1] = row[x] >> 8;
			out[x * 3 + 2] = row[x] >> 16;
		}
	}
	fwrite(buf, 1, size, f);
	fclose(f);
	free(buf);
	free(row);
	return 0;
}

/* Same size as on a 1080p panel, so the handover doesn't jump. */
#define BMP_W 740
#define BMP_H 594

/* Starts where the panel left off, breathes, and fades into Steam. */
static int write_movie(const char *dir)
{
	struct picture pic;
	char path[4096];
	const int fps = 30, frames = 90;

	if (load_picture(&pic, BMP_W, BMP_H))
		return 1;
	for (int i = 0; i < frames; i++) {
		float t = (float)i / fps, out = 1 - ramp(t, 2.2f, 3.0f);
		struct look l = { .wipe = 1, .frame = out, .gold = out, .glow = pulse(t) * out, .name = out, .tag = out };

		snprintf(path, sizeof(path), "%s/%03d.bmp", dir, i);
		if (write_bmp(path, &pic, &l))
			return 1;
	}
	return 0;
}

#ifndef NO_DRM
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

#define CARD_WAIT_S 20
#define NO_SESSION_S 120
#define HOLD_S 30

enum { UPRIGHT, BOTTOM_UP, LEFT_UP, RIGHT_UP };

struct panel {
	int fd;
	uint32_t connector, crtc, fb;
	struct drm_mode_modeinfo mode;
	int orientation;
	uint8_t *map;
	uint32_t pitch;
};

static volatile sig_atomic_t session_starting, stopping;

static void on_signal(int sig)
{
	if (sig == SIGUSR1)
		session_starting = 1;
	else
		stopping = 1;
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void nap(double s)
{
	struct timespec ts = { (time_t)s, (long)((s - (time_t)s) * 1e9) };

	nanosleep(&ts, NULL);	/* the signals end it early, which is what we want */
}

static int panel_orientation(int fd, uint32_t connector, int w, int h)
{
	struct drm_mode_obj_get_properties get = {
		.obj_id = connector, .obj_type = DRM_MODE_OBJECT_CONNECTOR,
	};
	uint32_t ids[64];
	uint64_t values[64];

	get.props_ptr = (uintptr_t)ids;
	get.prop_values_ptr = (uintptr_t)values;
	get.count_props = 64;
	if (ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &get) == 0) {
		for (uint32_t i = 0; i < get.count_props && i < 64; i++) {
			struct drm_mode_get_property prop = { .prop_id = ids[i] };

			if (ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &prop) == 0 &&
			    !strcmp(prop.name, "panel orientation") && values[i] <= RIGHT_UP)
				return (int)values[i];
		}
	}
	/* No property on a portrait panel: every handheld we know holds it sideways. */
	return w < h ? RIGHT_UP : UPRIGHT;
}

/* Same override the session uses, for panels whose device tree has no rotation. */
static int env_orientation(int fallback)
{
	static const char *const files[] = {
		"/usr/lib/environment.d/60-redmagic6-gamescope.conf",
		"/usr/lib/environment.d/60-odin3-gamescope.conf",
	};
	char line[128];

	for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
		FILE *f = fopen(files[i], "r");

		if (!f)
			continue;
		while (fgets(line, sizeof(line), f)) {
			if (strncmp(line, "GAMESCOPE_ORIENTATION=", 22))
				continue;
			fclose(f);
			if (!strncmp(line + 22, "right", 5))
				return RIGHT_UP;
			if (!strncmp(line + 22, "left", 4))
				return LEFT_UP;
			return fallback;
		}
		fclose(f);
	}
	return fallback;
}

static int flipped(int orientation)
{
	static const int opposite[] = { BOTTOM_UP, UPRIGHT, RIGHT_UP, LEFT_UP };

	return access("/etc/steamos-arm/flip-screen", F_OK) ? orientation : opposite[orientation];
}

/* First connected panel on this card, the built-in one before anything else. */
static int find_panel(int fd, struct panel *p)
{
	struct drm_mode_card_res res = { 0 };
	uint32_t conns[16], crtcs[8], encs[16];
	int best = -1;

	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res))
		return -1;
	if (res.count_connectors > 16 || res.count_crtcs > 8 || !res.count_crtcs)
		return -1;
	res.connector_id_ptr = (uintptr_t)conns;
	res.crtc_id_ptr = (uintptr_t)crtcs;
	res.count_fbs = res.count_encoders = 0;
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res))
		return -1;

	for (uint32_t i = 0; i < res.count_connectors; i++) {
		struct drm_mode_modeinfo modes[64];
		struct drm_mode_get_connector c = { .connector_id = conns[i] };
		int rank;

		if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c))
			continue;
		if (c.connection != 1 || !c.count_modes || c.count_encoders > 16)
			continue;
		if (c.count_modes > 64)
			c.count_modes = 64;
		c.modes_ptr = (uintptr_t)modes;
		c.encoders_ptr = (uintptr_t)encs;
		c.count_props = 0;
		if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) || !c.count_modes)
			continue;
		rank = c.connector_type == DRM_MODE_CONNECTOR_DSI ? 2 :
		       c.connector_type == DRM_MODE_CONNECTOR_eDP ? 1 : 0;
		if (rank <= best)
			continue;
		best = rank;
		p->connector = conns[i];
		p->mode = modes[0];
		for (uint32_t m = 0; m < c.count_modes; m++) {
			if (modes[m].type & DRM_MODE_TYPE_PREFERRED) {
				p->mode = modes[m];
				break;
			}
		}
		p->crtc = 0;
		for (uint32_t e = 0; e < c.count_encoders && !p->crtc; e++) {
			struct drm_mode_get_encoder enc = { .encoder_id = encs[e] };

			if (ioctl(fd, DRM_IOCTL_MODE_GETENCODER, &enc))
				continue;
			if (enc.crtc_id) {
				p->crtc = enc.crtc_id;
				break;
			}
			for (uint32_t k = 0; k < res.count_crtcs; k++) {
				if (enc.possible_crtcs & 1u << k) {
					p->crtc = crtcs[k];
					break;
				}
			}
		}
	}
	return best >= 0 && p->crtc ? 0 : -1;
}

static int open_panel(struct panel *p)
{
	double give_up = now() + CARD_WAIT_S;

	while (!stopping && !session_starting && now() < give_up) {
		for (int i = 0; i < 4; i++) {
			char path[32];
			int fd;

			snprintf(path, sizeof(path), "/dev/dri/card%d", i);
			fd = open(path, O_RDWR | O_CLOEXEC);
			if (fd < 0)
				continue;
			if (find_panel(fd, p) == 0) {
				p->fd = fd;
				return 0;
			}
			close(fd);
		}
		nap(0.1);
	}
	return -1;
}

static int show_buffer(struct panel *p)
{
	struct drm_mode_create_dumb dumb = {
		.width = p->mode.hdisplay, .height = p->mode.vdisplay, .bpp = 32,
	};
	struct drm_mode_map_dumb map = { 0 };
	struct drm_mode_fb_cmd fb = { 0 };
	struct drm_mode_crtc crtc = { 0 };

	if (ioctl(p->fd, DRM_IOCTL_MODE_CREATE_DUMB, &dumb))
		return -1;
	fb.width = dumb.width;
	fb.height = dumb.height;
	fb.pitch = dumb.pitch;
	fb.bpp = 32;
	fb.depth = 24;
	fb.handle = dumb.handle;
	if (ioctl(p->fd, DRM_IOCTL_MODE_ADDFB, &fb))
		return -1;
	p->fb = fb.fb_id;
	p->pitch = dumb.pitch;
	map.handle = dumb.handle;
	if (ioctl(p->fd, DRM_IOCTL_MODE_MAP_DUMB, &map))
		return -1;
	p->map = mmap(NULL, dumb.size, PROT_READ | PROT_WRITE, MAP_SHARED, p->fd, map.offset);
	if (p->map == MAP_FAILED)
		return -1;
	memset(p->map, 0, dumb.size);
	crtc.crtc_id = p->crtc;
	crtc.fb_id = p->fb;
	crtc.set_connectors_ptr = (uintptr_t)&p->connector;
	crtc.count_connectors = 1;
	crtc.mode = p->mode;
	crtc.mode_valid = 1;
	return ioctl(p->fd, DRM_IOCTL_MODE_SETCRTC, &crtc);
}

static void flush_panel(struct panel *p)
{
	struct drm_mode_fb_dirty_cmd dirty = { .fb_id = p->fb };

	/* Command mode panels need it, the others say no. */
	ioctl(p->fd, DRM_IOCTL_MODE_DIRTYFB, &dirty);
}

/* False once another program's buffer is on the panel. */
static int panel_is_ours(const struct panel *p)
{
	struct drm_mode_crtc crtc = { .crtc_id = p->crtc };

	if (ioctl(p->fd, DRM_IOCTL_MODE_GETCRTC, &crtc))
		return 0;
	return crtc.fb_id == p->fb;
}

/* Upright picture position to panel position. */
static inline void to_panel(const struct panel *p, int u, int v, int *x, int *y)
{
	int w = p->mode.hdisplay, h = p->mode.vdisplay;

	switch (p->orientation) {
	case BOTTOM_UP: *x = w - 1 - u; *y = h - 1 - v; break;
	case LEFT_UP:   *x = v;         *y = h - 1 - u; break;
	case RIGHT_UP:  *x = w - 1 - v; *y = u;         break;
	default:        *x = u;         *y = v;         break;
	}
}

static void draw_rows(struct panel *p, const struct picture *pic, const struct look *l,
		      int left, int top, uint32_t *row)
{
	for (int v = 0; v < pic->h; v++) {
		compose_row(pic, l, v, row);
		for (int u = 0; u < pic->w; u++) {
			int x, y;

			to_panel(p, left + u, top + v, &x, &y);
			*(uint32_t *)(p->map + y * p->pitch + x * 4) = row[u];
		}
	}
}

static int run_on_panel(void)
{
	struct panel p = { .fd = -1 };
	struct picture pic;
	uint32_t *row;
	int view_w, view_h, left, top, pic_h;
	double start;

	if (open_panel(&p))
		return 0;
	p.orientation = panel_orientation(p.fd, p.connector, p.mode.hdisplay, p.mode.vdisplay);
	p.orientation = flipped(env_orientation(p.orientation));
	if (show_buffer(&p))
		return 0;

	view_w = p.orientation >= LEFT_UP ? p.mode.vdisplay : p.mode.hdisplay;
	view_h = p.orientation >= LEFT_UP ? p.mode.hdisplay : p.mode.vdisplay;
	pic_h = view_h * 55 / 100;
	if (pic_h * MASK_W / MASK_H > view_w * 80 / 100)
		pic_h = (view_w * 80 / 100) * MASK_H / MASK_W;
	if (load_picture(&pic, pic_h * MASK_W / MASK_H, pic_h))
		return 0;
	row = malloc(pic.w * 4);
	if (!row)
		return 0;
	left = (view_w - pic.w) / 2;
	top = (view_h - pic.h) / 2;

	start = now();
	while (!stopping && !session_starting && now() - start < NO_SESSION_S) {
		double t = now() - start;
		struct look l = intro_look((float)t);

		if (t > INTRO_S) {
			l.gold = 1;
			l.glow = pulse((float)(t - INTRO_S));
			l.gold_shift = 0;
		}
		draw_rows(&p, &pic, &l, left, top, row);
		flush_panel(&p);
		/* Once it's all up only the bar moves, and boot needs the CPU more. */
		nap(t > INTRO_S ? 1.0 / FPS_WAITING : 1.0 / 30);
	}
	/*
	 * The session needs to be master, but closing would clear the panel. Stay
	 * open and keep the bar moving, since our buffer stays on screen, until the
	 * session has put up its own.
	 */
	ioctl(p.fd, DRM_IOCTL_DROP_MASTER, 0);
	if (session_starting) {
		double held = now();

		while (!stopping && now() - held < HOLD_S && panel_is_ours(&p)) {
			struct look l = intro_look(INTRO_S);

			l.glow = pulse((float)(now() - start));
			draw_rows(&p, &pic, &l, left, top, row);
			flush_panel(&p);
			nap(1.0 / FPS_WAITING);
		}
	}
	return 0;
}
#endif /* NO_DRM */

int main(int argc, char **argv)
{
	if (argc == 3 && !strcmp(argv[1], "--movie"))
		return write_movie(argv[2]);
#ifndef NO_DRM
	signal(SIGUSR1, on_signal);
	signal(SIGTERM, on_signal);
	return run_on_panel();
#else
	return 2;
#endif
}
