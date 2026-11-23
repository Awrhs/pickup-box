# syntax=docker/dockerfile:1

# ---------- build stage ----------
FROM openresty/openresty:1.21.4.1-alpine-fat AS builder

# Build toolchain + dev headers needed to compile c/image_vips.c and install
# OPM Lua rocks. None of these ship in the runtime image.
RUN apk add --no-cache \
        gcc musl-dev make pkgconfig \
        vips-dev vips-heif \
        sqlite-dev \
        pango-dev fontconfig-dev \
    && opm get ledgetech/lua-resty-http

WORKDIR /opt/pickup-box
COPY c/ /opt/pickup-box/c/

# Assert that libvips was built with pango so vips_text supports text watermark.
RUN nm -D $(pkg-config --variable=libdir vips)/libvips.so | grep -q ' T vips_text' \
    || { echo "ERROR: libvips was built without pango support; vips_text missing."; exit 1; }

# Hardened build: stack protector, FORTIFY_SOURCE, full RELRO, PIE, plus
# warnings so dubious C is caught at build time.
RUN gcc -O2 -Wall -Wextra \
        -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
        -fPIC -shared \
        -Wl,-z,relro,-z,now \
        -o /opt/pickup-box/c/image_vips.so \
        /opt/pickup-box/c/image_vips.c \
        $(pkg-config --cflags --libs vips fontconfig) \
    && strip /opt/pickup-box/c/image_vips.so

# ---------- runtime stage ----------
FROM openresty/openresty:1.21.4.1-alpine

# Only runtime shared libraries; no compiler, no dev headers.
#   - vips / vips-heif: image processing runtime (AVIF via vips-heif)
#   - sqlite-libs:      metadata store runtime
# tini is not needed (openresty reaps children); curl kept for healthchecks.
RUN apk add --no-cache \
        vips vips-heif \
        sqlite-libs \
        pango fontconfig

# Copy the OPM Lua libraries installed in the builder.
COPY --from=builder /usr/local/openresty/site/lualib /usr/local/openresty/site/lualib
COPY --from=builder /usr/local/openresty/lualib      /usr/local/openresty/lualib

WORKDIR /opt/pickup-box

# Compiled C helper (dynamically links against the runtime libvips).
COPY --from=builder /opt/pickup-box/c/image_vips.so /opt/pickup-box/c/image_vips.so

# Lua sources and nginx config are bind-mounted in dev; COPY gives a working
# default image for production.
COPY lua/ /opt/pickup-box/lua/
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

RUN mkdir -p /data/images/orig /data/images/cache /data/images/tmp \
    && chown -R nginx:nobody /data \
    && chmod -R 0755 /data

# Build-time version metadata. Pass --build-arg GIT_SHA=$(git rev-parse HEAD)
# when building; /healthz will report it.
ARG GIT_SHA=dev
ARG BUILD_DATE=unknown
RUN echo "${GIT_SHA} ${BUILD_DATE}" > /opt/pickup-box/VERSION

# Run as the unprivileged nginx user. The OpenResty base image already
# creates this uid.
USER nginx
