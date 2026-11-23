/*
 * image_vips.c — C helper for the image hosting gateway.
 *
 * Wraps libvips for the heavy image-processing path (decode/autorot/resize/
 * crop/colour/blur/watermark/encode) behind a simple buffer-in / buffer-out
 * ABI consumed by LuaJIT FFI. Doing this in C rather than FFI varargs keeps
 * GObject option marshalling and memory ownership explicit and auditable.
 *
 * Build (see Dockerfile):
 *   gcc -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIC -shared \
 *       -o image_vips.so image_vips.c $(pkg-config --cflags --libs vips)
 *
 * Image correctness is handled here once, centrally:
 *   - EXIF orientation is applied (vips_autorot)
 *   - everything is normalised to sRGB
 *   - decoded pixel count is capped (pixel-bomb guard)
 *   - alpha is flattened onto white for formats without alpha (jpeg)
 *   - all EXIF/metadata are stripped on encode for privacy
 *
 * Text watermark (P2): rendered on demand via vips_text (Pango/fontconfig).
 * Use iv_set_font_path() at init time to register a runtime-mounted font
 * file; the gateway itself carries zero fonts in the image.
 */
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <sys/stat.h>

#include <vips/vips.h>
#include <fontconfig/fontconfig.h>

#include "image_vips.h"

/* Built-in decoded-pixel cap if the caller passes max_pixels <= 0. */
#define IV_DEFAULT_MAX_PIXELS (50LL * 1000 * 1000)  /* 50 MP */

/* Defaults for watermark params when opts provides 0. */
#define IV_DEFAULT_WM_MARGIN      16
#define IV_DEFAULT_WM_IMAGE_SCALE 0.2
#define IV_DEFAULT_WM_TEXT_SCALE  0.04
#define IV_DEFAULT_WM_FONT_SIZE   32
#define IV_DEFAULT_WM_OPACITY     0.3

/* ---- one-time libvips initialization ---- */
static void iv_init_once(void) {
    static volatile gsize inited = 0;
    if (g_once_init_enter(&inited)) {
        if (VIPS_INIT("image_vips") != 0) {
            /* If init fails we still mark initialized; subsequent calls will
               return errors rather than crash. */
        }
        /* Keep the operation cache small — these are short-lived requests. */
        vips_cache_set_max(16);
        vips_concurrency_set(1);
        /* Bound the operation cache's memory. Decode size is bounded
           separately by the Lua-side pixel limit (IMAGE_MAX_PIXELS). */
        vips_cache_set_max_mem(64UL * 1024 * 1024);  /* 64 MiB */
        g_once_init_leave(&inited, 1);
    }
}

/* Copy the vips error thread-local buffer into the caller's error slot. */
static void iv_capture_error(char *err, size_t errlen) {
    if (!err || errlen == 0) return;
    const char *e = vips_error_buffer();
    if (e && *e) {
        strncpy(err, e, errlen - 1);
        err[errlen - 1] = '\0';
    } else {
        strncpy(err, "unknown vips error", errlen - 1);
        err[errlen - 1] = '\0';
    }
    vips_error_clear();
}

static void iv_set_error(char *err, size_t errlen, const char *msg) {
    if (!err || errlen == 0) return;
    strncpy(err, msg, errlen - 1);
    err[errlen - 1] = '\0';
}

/* Register a font file with the system fontconfig at runtime. */
int iv_set_font_path(const char *path) {
    iv_init_once();
    if (!path || path[0] == '\0') return 0;
    FcBool ok = FcConfigAppFontAddFile(FcConfigGetCurrent(), (const FcChar8 *)path);
    return (ok == FcTrue) ? 0 : -1;
}

/* Pixel-bomb guard: reject images whose decoded dimensions are implausible. */
static int iv_check_pixels(VipsImage *im, int max_pixels, char *err, size_t errlen) {
    long long cap = (max_pixels > 0) ? (long long)max_pixels : IV_DEFAULT_MAX_PIXELS;
    long long pixels = (long long)im->Xsize * (long long)im->Ysize;
    if (pixels > cap) {
        iv_set_error(err, errlen, "image exceeds maximum pixel budget");
        return -1;
    }
    return 0;
}

/* Compute (x,y) anchor for a watermark of size wm_w x wm_h inside base. */
static void iv_wm_anchor(const char *position, int base_w, int base_h,
                         int wm_w, int wm_h, int margin,
                         int *out_x, int *out_y) {
    int x = base_w - wm_w - margin;
    int y = base_h - wm_h - margin;
    if (!position) position = "southeast";

    if (!strcmp(position, "northwest") || !strcmp(position, "topleft")) {
        x = margin; y = margin;
    } else if (!strcmp(position, "north") || !strcmp(position, "top")) {
        x = (base_w - wm_w) / 2; y = margin;
    } else if (!strcmp(position, "northeast") || !strcmp(position, "topright")) {
        x = base_w - wm_w - margin; y = margin;
    } else if (!strcmp(position, "west") || !strcmp(position, "left")) {
        x = margin; y = (base_h - wm_h) / 2;
    } else if (!strcmp(position, "center")) {
        x = (base_w - wm_w) / 2; y = (base_h - wm_h) / 2;
    } else if (!strcmp(position, "east") || !strcmp(position, "right")) {
        x = base_w - wm_w - margin; y = (base_h - wm_h) / 2;
    } else { /* southeast / bottomright / default */
        x = base_w - wm_w - margin; y = base_h - wm_h - margin;
    }
    *out_x = x < 0 ? 0 : x;
    *out_y = y < 0 ? 0 : y;
}

/* Ensure an image is 8-bit sRGB with optional alpha. Returns a new ref. */
static VipsImage *iv_to_srgb(VipsImage *src, gboolean with_alpha) {
    VipsImage *rgb = NULL;

    if (src->Type != VIPS_INTERPRETATION_sRGB && src->Type != VIPS_INTERPRETATION_RGB) {
        if (vips_colourspace(src, &rgb, VIPS_INTERPRETATION_sRGB, NULL) != 0) {
            return NULL;
        }
    } else {
        rgb = src;
        g_object_ref(rgb);
    }

    /* Cast 16-bit HDR down to 8-bit after colourspace conversion. */
    if (rgb->BandFmt != VIPS_FORMAT_USHORT && rgb->BandFmt != VIPS_FORMAT_UCHAR) {
        VipsImage *cast = NULL;
        if (vips_cast(rgb, &cast, VIPS_FORMAT_UCHAR, NULL) == 0) {
            g_object_unref(rgb);
            rgb = cast;
        }
    } else if (rgb->BandFmt == VIPS_FORMAT_USHORT) {
        VipsImage *cast = NULL;
        if (vips_cast(rgb, &cast, VIPS_FORMAT_UCHAR, NULL) == 0) {
            g_object_unref(rgb);
            rgb = cast;
        }
    }

    if (with_alpha && rgb->Bands < 4) {
        VipsImage *with_alpha = NULL;
        if (vips_bandjoin_const1(rgb, &with_alpha, 255.0, NULL) == 0) {
            g_object_unref(rgb);
            rgb = with_alpha;
        }
    } else if (!with_alpha && rgb->Bands == 4) {
        VipsImage *opaque = NULL;
        if (vips_flatten(rgb, &opaque, "background", (double[]){255,255,255}, NULL) == 0) {
            g_object_unref(rgb);
            rgb = opaque;
        }
    }

    return rgb;
}

/*
 * Render a text overlay via vips_text, colorize it, and composite onto the
 * base image. The entire operation is non-fatal: if any step fails we return
 * -1 and let the caller fall through to encode without the watermark.
 *
 * Position, margin, and opacity come from the common wm_position /
 * wm_margin / wm_opacity fields in iv_options.
 */
static int iv_apply_text_watermark(VipsImage *base, const iv_options *opts,
                                    VipsImage **out, char *err, size_t errlen) {
    const char *text = opts->wm_text;
    if (!text || text[0] == '\0') return -1;

    VipsImage *base_rgba = NULL;
    VipsImage *text_img = NULL;
    VipsImage *colored = NULL;
    VipsImage *resized = NULL;
    VipsImage *result = NULL;
    int rc = -1;

    int font_size = (opts->wm_font_size > 0) ? opts->wm_font_size : IV_DEFAULT_WM_FONT_SIZE;
    double text_scale = (opts->wm_text_scale > 0.0) ? opts->wm_text_scale : IV_DEFAULT_WM_TEXT_SCALE;
    int margin = (opts->wm_margin > 0) ? opts->wm_margin : IV_DEFAULT_WM_MARGIN;

    base_rgba = iv_to_srgb(base, TRUE);
    if (!base_rgba) { iv_capture_error(err, errlen); goto done; }

    /* Build the fontconfig pattern with size. */
    char font_str[512];
    if (opts->wm_font_desc && opts->wm_font_desc[0]) {
        snprintf(font_str, sizeof(font_str), "%s %d", opts->wm_font_desc, font_size);
    } else {
        snprintf(font_str, sizeof(font_str), "sans %d", font_size);
    }

    /* Render the text (transparent background, white text). vips_text sets
     * the background transparent by default; text is white-on-transparent. */
    if (vips_text(&text_img, text, "font", font_str, "DPI", 72, NULL) != 0) {
        iv_capture_error(err, errlen);
        goto done;
    }

    /* Colorize: linear multiply each band by the requested color. Text RGBA
     * = (R, G, B, A) where R=G=B=1 for white text; multiplied by color
     * keeps alpha untouched. */
    double a[4] = {opts->wm_text_color[0], opts->wm_text_color[1],
                   opts->wm_text_color[2], 1.0};
    double b[4] = {0.0, 0.0, 0.0, 0.0};
    if (vips_linear(text_img, &colored, a, b, 4, NULL) != 0) {
        iv_capture_error(err, errlen);
        goto done;
    }

    /* Scale text to target width (text_scale * base_width), preserving
     * aspect. Clamp to not exceed base width and minimum 32 px. */
    int target_w = (int)((double)base_rgba->Xsize * text_scale);
    if (target_w < 32) target_w = 32;
    if (target_w > base_rgba->Xsize) target_w = base_rgba->Xsize;
    double scale = (double)target_w / (double)colored->Xsize;
    if (scale < 1.0) {
        if (vips_resize(colored, &resized, scale, NULL) != 0) {
            iv_capture_error(err, errlen);
            goto done;
        }
    } else {
        resized = colored;
        g_object_ref(resized);
    }

    int x, y;
    iv_wm_anchor(opts->wm_position, base_rgba->Xsize, base_rgba->Ysize,
                 resized->Xsize, resized->Ysize, margin, &x, &y);

    if (vips_composite2(base_rgba, resized, &result, VIPS_BLEND_MODE_OVER,
            "x", x, "y", y, NULL) != 0) {
        iv_capture_error(err, errlen);
        goto done;
    }

    *out = result;
    result = NULL;
    rc = 0;

done:
    if (base_rgba) g_object_unref(base_rgba);
    if (text_img) g_object_unref(text_img);
    if (colored) g_object_unref(colored);
    if (resized) g_object_unref(resized);
    if (result) g_object_unref(result);
    return rc;
}

/*
 * Apply an image watermark overlay onto `base`. Returns a new VipsImage in
 * *out. Opacity (0..1) scales the watermark alpha before compositing.
 *
 * The scale and margin come from opts (wm_image_scale and wm_margin).
 * If the scale/margin are <= 0 we fall back to built-in defaults.
 */
static int iv_apply_watermark(VipsImage *base, const iv_options *opts,
                              VipsImage **out, char *err, size_t errlen) {
    VipsImage *wm = NULL;
    VipsImage *base_rgba = NULL;
    VipsImage *wm_rgba = NULL;
    VipsImage *wm_resized = NULL;
    VipsImage *wm_faded = NULL;
    VipsImage *result = NULL;
    int rc = -1;
    const char *wm_path = opts->wm_path;

    if (!wm_path || wm_path[0] == '\0') return -1;

    if (!(wm = vips_image_new_from_file(wm_path,
            "access", VIPS_ACCESS_SEQUENTIAL, NULL))) {
        iv_capture_error(err, errlen);
        goto done;
    }

    /* Normalize base and watermark to sRGB RGBA. */
    base_rgba = iv_to_srgb(base, TRUE);
    if (!base_rgba) { iv_capture_error(err, errlen); goto done; }

    wm_rgba = iv_to_srgb(wm, TRUE);
    if (!wm_rgba) { iv_capture_error(err, errlen); goto done; }

    /* Scale watermark to wm_image_scale * base width, preserving aspect. */
    double img_scale = (opts->wm_image_scale > 0.0) ? opts->wm_image_scale : IV_DEFAULT_WM_IMAGE_SCALE;
    int target_w = (int)((double)base_rgba->Xsize * img_scale);
    if (target_w < 16) target_w = 16;
    if (target_w > base_rgba->Xsize) target_w = base_rgba->Xsize;
    double scale = (double)target_w / (double)wm_rgba->Xsize;
    if (scale < 1.0) {
        if (vips_resize(wm_rgba, &wm_resized, scale, NULL) != 0) {
            iv_capture_error(err, errlen);
            goto done;
        }
    } else {
        wm_resized = wm_rgba;
        g_object_ref(wm_resized);
    }

    /* Reduce opacity by scaling the alpha band. */
    double opacity = (opts->wm_opacity >= 0.0) ? opts->wm_opacity : IV_DEFAULT_WM_OPACITY;
    if (opacity > 1.0) opacity = 1.0;
    if (wm_resized->Bands == 4) {
        double a[4] = {1.0, 1.0, 1.0, opacity};
        double b[4] = {0.0, 0.0, 0.0, 0.0};
        if (vips_linear(wm_resized, &wm_faded, a, b, 4, NULL) != 0) {
            iv_capture_error(err, errlen);
            goto done;
        }
    } else {
        wm_faded = wm_resized;
        g_object_ref(wm_faded);
    }

    int margin = (opts->wm_margin > 0) ? opts->wm_margin : IV_DEFAULT_WM_MARGIN;
    int x, y;
    iv_wm_anchor(opts->wm_position, base_rgba->Xsize, base_rgba->Ysize,
                 wm_faded->Xsize, wm_faded->Ysize, margin, &x, &y);

    if (vips_composite2(base_rgba, wm_faded, &result, VIPS_BLEND_MODE_OVER,
            "x", x, "y", y, NULL) != 0) {
        iv_capture_error(err, errlen);
        goto done;
    }

    *out = result;
    result = NULL;
    rc = 0;

done:
    if (wm) g_object_unref(wm);
    if (base_rgba) g_object_unref(base_rgba);
    if (wm_rgba) g_object_unref(wm_rgba);
    if (wm_resized) g_object_unref(wm_resized);
    if (wm_faded) g_object_unref(wm_faded);
    if (result) g_object_unref(result);
    return rc;
}

/* Does this output suffix support an alpha channel? */
static gboolean iv_suffix_supports_alpha(const char *suffix) {
    if (!suffix) return FALSE;
    return (!strcmp(suffix, ".png") || !strcmp(suffix, ".webp") ||
            !strcmp(suffix, ".avif") || !strcmp(suffix, ".gif"));
}

/* Core pipeline shared by buffer and file entry points. */
static int iv_process_internal(VipsImage *source, const char *target_suffix,
                               const iv_options *opts,
                               void **out_buf, size_t *out_len,
                               char *err, size_t errlen) {
    VipsImage *normalized = NULL;
    VipsImage *scaled = NULL;
    VipsImage *processed = NULL;
    VipsImage *watermarked = NULL;
    VipsImage *final = NULL;
    void *result_buf = NULL;
    size_t result_len = 0;
    int rc = -1;

    if (out_buf) *out_buf = NULL;
    if (out_len) *out_len = 0;

    int max_pixels = opts ? opts->max_pixels : 0;
    if (iv_check_pixels(source, max_pixels, err, errlen) != 0) goto cleanup;

    /* 1. Auto-orient from EXIF, then normalize to sRGB. */
    if (opts && opts->auto_orient) {
        if (vips_autorot(source, &normalized, NULL) != 0) {
            iv_capture_error(err, errlen);
            goto cleanup;
        }
    } else {
        normalized = source;
        g_object_ref(normalized);
    }

    if (normalized->Type != VIPS_INTERPRETATION_sRGB &&
        normalized->Type != VIPS_INTERPRETATION_RGB) {
        VipsImage *srgb = NULL;
        if (vips_colourspace(normalized, &srgb, VIPS_INTERPRETATION_sRGB, NULL) != 0) {
            iv_capture_error(err, errlen);
            goto cleanup;
        }
        g_object_unref(normalized);
        normalized = srgb;
    }

    if (iv_check_pixels(normalized, max_pixels, err, errlen) != 0) goto cleanup;

    int width = (opts && opts->width > 0) ? opts->width : normalized->Xsize;
    int height = (opts && opts->height > 0) ? opts->height : normalized->Ysize;
    int crop = opts ? opts->crop : 0;

    /* 2. Resize/crop. */
    if (width != normalized->Xsize || height != normalized->Ysize || crop) {
        if (crop) {
            if (vips_thumbnail_image(normalized, &scaled, width,
                    "height", height,
                    "crop", VIPS_INTERESTING_CENTRE,
                    "size", VIPS_SIZE_BOTH,
                    NULL) != 0) {
                iv_capture_error(err, errlen);
                goto cleanup;
            }
        } else {
            if (vips_thumbnail_image(normalized, &scaled, width,
                    "height", height,
                    "size", VIPS_SIZE_DOWN,
                    NULL) != 0) {
                iv_capture_error(err, errlen);
                goto cleanup;
            }
        }
    } else {
        scaled = normalized;
        g_object_ref(scaled);
    }

    processed = scaled;

    /* 3. Optional grayscale. */
    if (opts && opts->grayscale) {
        VipsImage *gray = NULL;
        if (vips_colourspace(scaled, &gray, VIPS_INTERPRETATION_B_W, NULL) == 0) {
            processed = gray;
        }
        /* failure is non-fatal: keep `scaled` */
    }

    /* 4. Optional gaussian blur. */
    if (opts && opts->blur_sigma > 0.0) {
        VipsImage *blurred = NULL;
        if (vips_gaussblur(processed, &blurred, opts->blur_sigma, NULL) == 0) {
            if (processed != scaled) g_object_unref(processed);
            processed = blurred;
        }
    }

    /* 5. Watermarks (both can be active simultaneously, text first). */
    VipsImage *to_encode = processed;

    /* 5a. Text watermark (vips_text). */
    if (opts && opts->wm_text && opts->wm_text[0] != '\0') {
        VipsImage *twm = NULL;
        if (iv_apply_text_watermark(processed, opts, &twm, err, errlen) == 0) {
            to_encode = twm;
            if (watermarked) g_object_unref(watermarked);
            watermarked = twm;
        } else {
            vips_error_clear();
        }
    }

    /* 5b. Image watermark (PNG overlay). */
    if (opts && opts->wm_path && opts->wm_path[0] != '\0') {
        VipsImage *iwm = NULL;
        if (iv_apply_watermark(to_encode, opts, &iwm, err, errlen) == 0) {
            if (watermarked) g_object_unref(watermarked);
            watermarked = iwm;
            to_encode = iwm;
        } else {
            vips_error_clear();
        }
    }

    /* 6. Flatten alpha for formats that cannot represent it (e.g. jpeg). */
    if (!iv_suffix_supports_alpha(target_suffix)) {
        if (vips_flatten(to_encode, &final,
                "background", (double[]){255.0, 255.0, 255.0}, NULL) != 0) {
            /* flatten may fail if there is no alpha; that's fine. */
            vips_error_clear();
            final = to_encode;
            g_object_ref(final);
        }
    } else {
        final = to_encode;
        g_object_ref(final);
    }

    int quality = opts ? opts->quality : 82;
    if (quality < 1) quality = 1;
    if (quality > 100) quality = 100;

    /* 7. Encode. Savers reject options they do not define, so pass only
     * what each format supports. All savers accept "strip" (drop EXIF and
     * other metadata for privacy). */
    int enc_rc;
    if (!strcmp(target_suffix, ".jpg") || !strcmp(target_suffix, ".jpeg")) {
        enc_rc = vips_image_write_to_buffer(final, target_suffix,
                &result_buf, &result_len,
                "Q", quality, "strip", TRUE,
                "interlace", TRUE,   /* progressive JPEG */
                NULL);
    } else if (!strcmp(target_suffix, ".png")) {
        enc_rc = vips_image_write_to_buffer(final, target_suffix,
                &result_buf, &result_len,
                "strip", TRUE, "interlace", TRUE,
                NULL);
    } else if (!strcmp(target_suffix, ".webp") || !strcmp(target_suffix, ".avif")) {
        enc_rc = vips_image_write_to_buffer(final, target_suffix,
                &result_buf, &result_len,
                "Q", quality, "strip", TRUE,
                NULL);
    } else {
        enc_rc = vips_image_write_to_buffer(final, target_suffix,
                &result_buf, &result_len,
                "strip", TRUE,
                NULL);
    }
    if (enc_rc != 0) {
        iv_capture_error(err, errlen);
        goto cleanup;
    }

    *out_buf = result_buf;
    *out_len = result_len;
    result_buf = NULL;
    rc = 0;

cleanup:
    if (normalized) g_object_unref(normalized);
    if (scaled) g_object_unref(scaled);
    if (processed && processed != scaled) g_object_unref(processed);
    if (watermarked) g_object_unref(watermarked);
    if (final) g_object_unref(final);
    if (result_buf) g_free(result_buf);
    return rc;
}

int iv_process_buffer(const void *in_buf, size_t in_len,
                      const char *target_suffix,
                      const iv_options *opts,
                      void **out_buf, size_t *out_len,
                      char *err, size_t errlen) {
    iv_init_once();

    if (err && errlen) err[0] = '\0';
    if (!in_buf || in_len == 0 || !target_suffix || !out_buf || !out_len) {
        iv_set_error(err, errlen, "invalid argument");
        return -1;
    }

    VipsImage *source = vips_image_new_from_buffer(in_buf, in_len, "",
            "access", VIPS_ACCESS_SEQUENTIAL, NULL);
    if (!source) {
        iv_capture_error(err, errlen);
        return -1;
    }

    int rc = iv_process_internal(source, target_suffix, opts,
                                out_buf, out_len, err, errlen);
    g_object_unref(source);
    return rc;
}

int iv_process_file(const char *in_path,
                    const char *target_suffix,
                    const iv_options *opts,
                    void **out_buf, size_t *out_len,
                    char *err, size_t errlen) {
    iv_init_once();

    if (err && errlen) err[0] = '\0';
    if (!in_path || !target_suffix || !out_buf || !out_len) {
        iv_set_error(err, errlen, "invalid argument");
        return -1;
    }

    VipsImage *source = vips_image_new_from_file(in_path,
            "access", VIPS_ACCESS_SEQUENTIAL, NULL);
    if (!source) {
        iv_capture_error(err, errlen);
        return -1;
    }

    int rc = iv_process_internal(source, target_suffix, opts,
                                out_buf, out_len, err, errlen);
    g_object_unref(source);
    return rc;
}

/* Return the width/height of an encoded image without fully decoding it. */
int iv_image_dimensions(const void *in_buf, size_t in_len,
                        int *out_width, int *out_height,
                        char *err, size_t errlen) {
    iv_init_once();
    if (err && errlen) err[0] = '\0';
    if (!in_buf || in_len == 0) {
        iv_set_error(err, errlen, "invalid argument");
        return -1;
    }
    VipsImage *im = vips_image_new_from_buffer(in_buf, in_len, "", NULL);
    if (!im) {
        iv_capture_error(err, errlen);
        return -1;
    }
    if (out_width)  *out_width  = im->Xsize;
    if (out_height) *out_height = im->Ysize;
    g_object_unref(im);
    return 0;
}

int iv_image_dimensions_file(const char *in_path,
                             int *out_width, int *out_height,
                             char *err, size_t errlen) {
    iv_init_once();
    if (err && errlen) err[0] = '\0';
    if (!in_path) {
        iv_set_error(err, errlen, "invalid argument");
        return -1;
    }
    VipsImage *im = vips_image_new_from_file(in_path, NULL);
    if (!im) {
        iv_capture_error(err, errlen);
        return -1;
    }
    if (out_width)  *out_width  = im->Xsize;
    if (out_height) *out_height = im->Ysize;
    g_object_unref(im);
    return 0;
}

/* Probe whether an output format's encoder works at runtime. */
int iv_probe_encode(const char *target_suffix) {
    iv_init_once();
    if (!target_suffix) return 0;
    /* Build a tiny 1x1 black image in memory and try to encode. */
    VipsImage *test = vips_image_new_from_memory(
            (unsigned char[3]){0,0,0}, 3, 1, 1, 3, VIPS_FORMAT_UCHAR);
    if (!test) return 0;
    void *buf = NULL;
    size_t len = 0;
    int ok = 0;
    if (vips_image_write_to_buffer(test, target_suffix, &buf, &len,
                                   "Q", 10, NULL) == 0) {
        ok = 1;
        g_free(buf);
    }
    g_object_unref(test);
    vips_error_clear();  /* discard any probe error messages */
    return ok;
}

/* Free a buffer returned in *out_buf by the process functions. */
void iv_free(void *p) {
    if (p) g_free(p);
}

/* ---- Cache directory helpers ---- */

struct iv_entry {
    char *path;
    time_t mtime;
    long long size;
};

static void iv_free_entries(struct iv_entry *entries, int count) {
    for (int i = 0; i < count; i++) free(entries[i].path);
    free(entries);
}

static int iv_entry_cmp(const void *a, const void *b) {
    const struct iv_entry *ea = (const struct iv_entry *)a;
    const struct iv_entry *eb = (const struct iv_entry *)b;
    if (ea->mtime < eb->mtime) return -1;
    if (ea->mtime > eb->mtime) return 1;
    return 0;
}

/* Collect all regular files from a single directory into an entries array. */
static int iv_collect_dir(const char *dir_path, struct iv_entry **entries,
                           int *count, int *cap, long long *total_bytes) {
    GDir *dir = g_dir_open(dir_path, 0, NULL);
    if (!dir) return 0;
    const char *name;
    while ((name = g_dir_read_name(dir)) != NULL) {
        char *full = g_build_filename(dir_path, name, NULL);
        struct stat st;
        if (stat(full, &st) == 0 && S_ISREG(st.st_mode)) {
            if (*count >= *cap) {
                *cap = (*cap == 0) ? 256 : (*cap * 2);
                struct iv_entry *tmp = (struct iv_entry *)realloc(
                        *entries, (size_t)(*cap) * sizeof(struct iv_entry));
                if (!tmp) { free(full); g_dir_close(dir); return -1; }
                *entries = tmp;
            }
            (*entries)[*count].path = strdup(full);
            (*entries)[*count].mtime = st.st_mtime;
            (*entries)[*count].size = (long long)st.st_size;
            *total_bytes += (long long)st.st_size;
            (*count)++;
        } else {
            free(full);
        }
    }
    g_dir_close(dir);
    return 0;
}

/* Collect all regular files from the cache directory structure (two-level
 * shards under root). */
static int iv_collect_cache(const char *root,
                             struct iv_entry **entries, int *count,
                             long long *total_bytes) {
    int cap = 0;
    *count = 0;
    *total_bytes = 0;

    GDir *root_dir = g_dir_open(root, 0, NULL);
    if (!root_dir) return 0;
    const char *shard;
    while ((shard = g_dir_read_name(root_dir)) != NULL) {
        char *shard_path = g_build_filename(root, shard, NULL);
        if (g_file_test(shard_path, G_FILE_TEST_IS_DIR)) {
            struct stat stb;
            /* Check for two-level shard layout: try <shard>/<sub> */
            GDir *sub_dir = g_dir_open(shard_path, 0, NULL);
            if (sub_dir) {
                const char *sub;
                while ((sub = g_dir_read_name(sub_dir)) != NULL) {
                    char *sub_path = g_build_filename(shard_path, sub, NULL);
                    struct stat st_s;
                    if (stat(sub_path, &st_s) == 0 && S_ISREG(st_s.st_mode)) {
                        /* <shard>/<file> — one-level (orig layout fallback) */
                        if (*count >= cap) {
                            cap = (cap == 0) ? 256 : cap * 2;
                            struct iv_entry *tmp = (struct iv_entry *)realloc(
                                    *entries, (size_t)cap * sizeof(struct iv_entry));
                            if (!tmp) { free(sub_path); g_dir_close(sub_dir); g_free(shard_path); g_dir_close(root_dir); return -1; }
                            *entries = tmp;
                        }
                        (*entries)[*count].path = strdup(sub_path);
                        (*entries)[*count].mtime = st_s.st_mtime;
                        (*entries)[*count].size = (long long)st_s.st_size;
                        *total_bytes += (long long)st_s.st_size;
                        (*count)++;
                    } else {
                        /* <shard>/<sub>/ — try two-level */
                        GDir *inner_dir = g_dir_open(sub_path, 0, NULL);
                        if (inner_dir) {
                            iv_collect_dir(sub_path, entries, count, &cap, total_bytes);
                            g_dir_close(inner_dir);
                        }
                    }
                    free(sub_path);
                }
                g_dir_close(sub_dir);
            }
        }
        free(shard_path);
    }
    g_dir_close(root_dir);
    return 0;
}

long long iv_cache_enforce_quota(const char *dir, long long target_bytes,
                                 int *deleted, char *err, size_t errlen) {
    iv_init_once();
    if (!dir) {
        iv_set_error(err, errlen, "null directory");
        return -1;
    }
    if (err && errlen) err[0] = '\0';
    struct iv_entry *entries = NULL;
    int count = 0;
    long long total = 0;
    if (iv_collect_cache(dir, &entries, &count, &total) != 0) {
        iv_set_error(err, errlen, "failed to collect directory");
        return -1;
    }
    int removed = 0;
    if (total > target_bytes) {
        qsort(entries, (size_t)count, sizeof(struct iv_entry), iv_entry_cmp);
        for (int i = 0; i < count && total > target_bytes; i++) {
            if (unlink(entries[i].path) == 0) {
                total -= entries[i].size;
                removed++;
            }
        }
    }
    if (deleted) *deleted = removed;
    iv_free_entries(entries, count);
    return total >= 0 ? total : 0;
}

long long iv_cache_dir_size(const char *dir, char *err, size_t errlen) {
    iv_init_once();
    if (!dir) {
        iv_set_error(err, errlen, "null directory");
        return -1;
    }
    if (err && errlen) err[0] = '\0';
    long long total = 0;
    GDir *root_dir = g_dir_open(dir, 0, NULL);
    if (!root_dir) return 0;
    const char *shard;
    while ((shard = g_dir_read_name(root_dir)) != NULL) {
        char *shard_path = g_build_filename(dir, shard, NULL);
        struct stat st;
        if (stat(shard_path, &st) == 0 && S_ISREG(st.st_mode)) {
            total += (long long)st.st_size;
        } else if (g_file_test(shard_path, G_FILE_TEST_IS_DIR)) {
            GDir *inner_dir = g_dir_open(shard_path, 0, NULL);
            if (inner_dir) {
                const char *inner;
                while ((inner = g_dir_read_name(inner_dir)) != NULL) {
                    char *inner_path = g_build_filename(shard_path, inner, NULL);
                    struct stat ist;
                    if (stat(inner_path, &ist) == 0 && S_ISREG(ist.st_mode)) {
                        total += (long long)ist.st_size;
                    }
                    free(inner_path);
                }
                g_dir_close(inner_dir);
            }
        }
        free(shard_path);
    }
    g_dir_close(root_dir);
    return total;
}

/* ---- pHash (32×32 DCT-based perceptual hash) ---- */

static int dbl_cmp(const void *a, const void *b) {
    double da = *(const double *)a, db = *(const double *)b;
    return (da > db) - (da < db);
}

int iv_phash_file(const char *path, char *out_hex,
                  char *err, size_t errlen) {
    iv_init_once();
    if (err && errlen) err[0] = '\0';
    if (!path || !out_hex) { iv_set_error(err, errlen, "invalid argument"); return -1; }

    VipsImage *src = vips_image_new_from_file(path,
            "access", VIPS_ACCESS_SEQUENTIAL, NULL);
    if (!src) { iv_capture_error(err, errlen); return -1; }

    /* 1. Thumbnail to 32×32 centre-cropped. */
    VipsImage *thumb = NULL;
    if (vips_thumbnail_image(src, &thumb, 32,
            "height", 32,
            "crop", VIPS_INTERESTING_CENTRE,
            "size", VIPS_SIZE_BOTH,
            NULL) != 0) {
        g_object_unref(src);
        iv_capture_error(err, errlen);
        return -1;
    }
    g_object_unref(src);

    /* Convert to single-band grayscale. */
    VipsImage *gray = NULL;
    if (vips_colourspace(thumb, &gray, VIPS_INTERPRETATION_B_W, NULL) != 0) {
        g_object_unref(thumb);
        iv_capture_error(err, errlen);
        return -1;
    }
    g_object_unref(thumb);

    /* 2. Read pixel data as unsigned char values (0-255). */
    size_t pixel_bytes;
    void *mem = vips_image_write_to_memory(gray, &pixel_bytes);
    g_object_unref(gray);
    if (!mem || pixel_bytes < 1024) {
        if (mem) g_free(mem);
        iv_set_error(err, errlen, "phash: unexpected pixel buffer size");
        return -1;
    }
    unsigned char *pixels = (unsigned char *)mem;

    /* Build a 2D double array. */
    double data[32][32];
    for (int y = 0; y < 32; y++)
        for (int x = 0; x < 32; x++)
            data[y][x] = (double)pixels[y * 32 + x];
    g_free(mem);

    /* 3. 2D DCT-II: row-wise then column-wise. */
    double dct[32][32] = {{0}};

    for (int y = 0; y < 32; y++) {
        for (int k = 0; k < 32; k++) {
            double sum = 0.0;
            for (int n = 0; n < 32; n++)
                sum += data[y][n] * cos((M_PI / 32.0) * (n + 0.5) * k);
            dct[y][k] = sum;
        }
    }
    for (int x = 0; x < 32; x++) {
        double col[32];
        for (int k = 0; k < 32; k++) {
            double sum = 0.0;
            for (int n = 0; n < 32; n++)
                sum += dct[n][x] * cos((M_PI / 32.0) * (n + 0.5) * k);
            col[k] = sum;
        }
        for (int k = 0; k < 32; k++)
            dct[k][x] = col[k];
    }

    /* 4. Top-left 8×8 block (64 coefficients, including DC). */
    double coeffs[64];
    int idx = 0;
    for (int y = 0; y < 8; y++)
        for (int x = 0; x < 8; x++)
            coeffs[idx++] = dct[y][x];

    /* 5. Median of the 64 coefficients. */
    double sorted[64];
    memcpy(sorted, coeffs, sizeof(coeffs));
    qsort(sorted, 64, sizeof(double), dbl_cmp);
    double median = (sorted[31] + sorted[32]) / 2.0;

    /* 6. 64-bit hash. */
    unsigned long long hash = 0;
    for (int i = 0; i < 64; i++)
        if (coeffs[i] > median)
            hash |= (1ULL << (63 - i));

    snprintf(out_hex, 17, "%016llx", hash);
    return 0;
}