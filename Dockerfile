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
#   - vips / vips-heif: previews (HEIC/AVIF via libheif)
#   - sqlite-libs:      metadata store
#   - libqrencode:      QR codes for share links
RUN apk add --no-cache \
        vips vips-heif \
        sqlite-libs \
        libqrencode \
        pango fontconfig

# Copy the OPM Lua libraries installed in the builder.
COPY --from=builder /usr/local/openresty/site/lualib /usr/local/openresty/site/lualib
COPY --from=builder /usr/local/openresty/lualib      /usr/local/openresty/lualib

WORKDIR /opt/pickup-box

# Compiled C helper (dynamically links against the runtime libvips).
COPY --from=builder /opt/pickup-box/c/image_vips.so /opt/pickup-box/c/image_vips.so

# Application code, web assets and nginx config. In development these are
# bind-mounted over the image copies (see docker-compose.yml).
COPY lua/ /opt/pickup-box/lua/
COPY static/ /opt/pickup-box/static/
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Unprivileged account for nginx worker processes. The master stays root so
# it can bind :80; workers drop to this user (see `user` in nginx.conf).
# Logs go to the container's stdout/stderr (`docker logs`).
RUN addgroup -S pickup && adduser -S -D -H -G pickup pickup \
    && mkdir -p /data/images/orig /data/images/cache /data/images/tmp /var/log/nginx \
    && chown -R pickup:pickup /data \
    && touch /usr/local/openresty/nginx/conf/realip.conf \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
    && chmod 0755 /usr/local/bin/docker-entrypoint.sh

# Build-time version metadata; /healthz reports it.
ARG GIT_SHA=dev
ARG BUILD_DATE=unknown
RUN echo "${GIT_SHA} ${BUILD_DATE}" > /opt/pickup-box/VERSION

LABEL org.opencontainers.image.source="https://github.com/Awrhs/pickup-box" \
      org.opencontainers.image.description="Self-hosted file and photo pickup service" \
      org.opencontainers.image.licenses="MIT"

VOLUME ["/data"]
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD wget -qO /dev/null http://127.0.0.1/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
