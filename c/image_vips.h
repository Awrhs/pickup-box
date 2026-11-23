#ifndef IMAGE_VIPS_H
#define IMAGE_VIPS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Processing options for iv_process_buffer / iv_process_file.
 *
 * A struct (rather than a long argument list) makes the ABI stable as options
 * are added and is straightforward to populate from LuaJIT FFI.
 *
 * Text watermark fields: when wm_text is non-NULL and non-empty the C
 * pipeline renders the text via vips_text (Pango), colorizes it, scales it
 * to fit within wm_text_scale * base-width, and composites it at the
 * configured wm_position with wm_margin padding.
 *
 * Image watermark fields: when wm_path is non-NULL and non-empty the image
 * is loaded, scaled to wm_image_scale * base-width, and composited.
 * Both watermark types can be active simultaneously (text over image).
 */
typedef struct {
    int    width;         /* target width; 0 = auto */
    int    height;        /* target height; 0 = auto */
    int    crop;          /* 0 = fit (downscale, whole image), 1 = cover (center-crop to fill) */
    int    quality;       /* encoder quality 1..100 (ignored by png/gif) */
    int    max_pixels;    /* safety cap on decoded pixels (w*h); 0 = use built-in default (50 MP) */
    int    grayscale;     /* 1 = convert to grayscale before encode */
    int    auto_orient;   /* 1 = apply EXIF orientation (vips_autorot) */
    int    flatten;       /* 1 = flatten alpha onto white (forced for jpeg) */
    int    preserve_iptc; /* reserved (strip is always on for privacy) */
    double blur_sigma;    /* > 0 = gaussian blur radius */

    /* Image watermark (PNG overlay) */
    const char *wm_path;      /* watermark PNG path; NULL/"" = none */
    double      wm_opacity;   /* 0..1 */
    const char *wm_position;  /* "northwest".."southeast", "center" */

    /* Text watermark (vips_text over Pango); rendered when wm_text is set */
    const char *wm_text;       /* UTF-8 overlay text; NULL/"" = none */
    const char *wm_font_desc;  /* fontconfig pattern WITHOUT size, e.g. "sans" */
    double wm_text_color[3];   /* RGB 0..1 (default {1,1,1} white) */
    double wm_text_scale;      /* fraction of base width for text (default 0.04) */
    int    wm_margin;          /* pixels from edge (default 16) */
    int    wm_font_size;       /* points (0 = default 32) */
    double wm_image_scale;     /* image watermark scale (default 0.2) */
} iv_options;

/*
 * Process an encoded input image buffer into an encoded output image.
 *
 * target_suffix: ".jpg" | ".png" | ".webp" | ".avif" | ".gif"
 *
 * Returns 0 on success; on success *out_buf must be released with iv_free().
 * On error returns negative and fills `err` (up to errlen-1 bytes).
 *
 * Image-correctness guarantees:
 *   - EXIF orientation is applied when opts->auto_orient is set
 *   - non-sRGB images are converted to sRGB
 *   - decoded pixel count is capped by opts->max_pixels (pixel-bomb guard)
 *   - alpha is flattened onto white for formats without alpha (jpeg)
 */
int iv_process_buffer(const void *in_buf, size_t in_len,
                      const char *target_suffix,
                      const iv_options *opts,
                      void **out_buf, size_t *out_len,
                      char *err, size_t errlen);

/*
 * Same as iv_process_buffer but reads the source from a file path. This lets
 * the caller keep large originals on disk instead of copying them through the
 * Lua heap. Returns 0 on success (caller iv_free's *out_buf) or negative.
 */
int iv_process_file(const char *in_path,
                    const char *target_suffix,
                    const iv_options *opts,
                    void **out_buf, size_t *out_len,
                    char *err, size_t errlen);

/* Read image width/height from an encoded buffer without a full decode. */
int iv_image_dimensions(const void *in_buf, size_t in_len,
                        int *out_width, int *out_height,
                        char *err, size_t errlen);

/* Test whether an output format/encoder is available at runtime. Creates a
 * tiny 1x1 black image in memory and tries vips_image_write_to_buffer with
 * the given target suffix. Returns 1 on success, 0 on failure. */
int iv_probe_encode(const char *target_suffix);

/* File-based variant: reads only the image header (no full decode). */
int iv_image_dimensions_file(const char *in_path,
                             int *out_width, int *out_height,
                             char *err, size_t errlen);

/* Free a buffer returned in *out_buf by the process functions. */
void iv_free(void *p);

/*
 * Walk a cache directory (root -> shard -> files) and enforce a size quota by
 * deleting least-recently-modified regular files until the total is <=
 * target_bytes. Returns total bytes after eviction (>= 0), or -1 on error.
 * *deleted receives the number of files removed (may be NULL).
 */
long long iv_cache_enforce_quota(const char *dir, long long target_bytes,
                                 int *deleted, char *err, size_t errlen);

/* Total size in bytes of all regular files under a dir (two levels deep). */
long long iv_cache_dir_size(const char *dir, char *err, size_t errlen);

/*
 * Perceptual hash (pHash) of an image file: 32×32 center-cropped grayscale
 * → 2D DCT-II → top-left 8×8 coefficients → median threshold → 64-bit hash.
 * The hash is written to `out_hex` as a 16-character null-terminated hex
 * string (caller must provide at least 17 bytes of storage). Returns 0 on
 * success, or negative on error.
 */
int iv_phash_file(const char *path, char *out_hex, char *err, size_t errlen);

/*
 * Register a font file with the system fontconfig at runtime.
 * The font is available for vips_text rendering until the process exits.
 * Returns 0 on success, -1 on error.
 */
int iv_set_font_path(const char *path);

#ifdef __cplusplus
}
#endif

#endif /* IMAGE_VIPS_H */