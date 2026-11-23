#!/bin/sh
# pickup-box one-step installer for a Linux server with Docker.
#
#   curl -fsSL https://raw.githubusercontent.com/Awrhs/pickup-box/main/deploy/install.sh | sh
#
# Asks for your domain (or reads PICKUP_DOMAIN), generates an upload
# password unless PICKUP_PASSWORD is set, writes ./pickup-box/.env and starts
# the app plus Caddy (automatic HTTPS). Re-running keeps an existing .env.
#
# Environment overrides: PICKUP_DIR (install directory), PICKUP_DOMAIN,
# PICKUP_PASSWORD, PICKUP_VERSION (image tag), PICKUP_IMAGE / CADDY_IMAGE
# (registry mirrors), PICKUP_RAW_BASE (where to fetch docker-compose.yml and
# Caddyfile from).
set -eu

DIR="${PICKUP_DIR:-$PWD/pickup-box}"
RAW="${PICKUP_RAW_BASE:-https://raw.githubusercontent.com/Awrhs/pickup-box/main/deploy}"

say() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "没有找到 Docker。请先安装：https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2（docker compose 命令）。"
command -v curl >/dev/null 2>&1 || die "需要 curl。"

mkdir -p "$DIR"
cd "$DIR"
say "安装目录: $DIR"
curl -fsSL "$RAW/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$RAW/Caddyfile" -o Caddyfile

generated=""
if [ -f .env ]; then
    say "沿用已有的 .env（如需修改请直接编辑它）。"
else
    domain="${PICKUP_DOMAIN:-}"
    # Ask only when PICKUP_DOMAIN was not given at all (an explicitly empty
    # value means "HTTP only") and a terminal is really available.
    if [ -z "${PICKUP_DOMAIN+x}" ] && { : < /dev/tty; } 2>/dev/null; then
        printf '你的域名（已解析到本机，例如 files.example.com；直接回车则先用 http://服务器IP 测试）: ' > /dev/tty
        read -r domain < /dev/tty || domain=""
    fi
    password="${PICKUP_PASSWORD:-}"
    if [ -z "$password" ]; then
        password=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
        generated=1
    fi
    umask 077
    {
        echo "# pickup-box settings; see README for all options."
        echo "PICKUP_DOMAIN=$domain"
        echo "PICKUP_PASSWORD=$password"
        if [ -n "${PICKUP_VERSION:-}" ]; then echo "PICKUP_VERSION=$PICKUP_VERSION"; fi
        if [ -n "${PICKUP_IMAGE:-}" ]; then echo "PICKUP_IMAGE=$PICKUP_IMAGE"; fi
        if [ -n "${CADDY_IMAGE:-}" ]; then echo "CADDY_IMAGE=$CADDY_IMAGE"; fi
    } > .env
fi

say "正在启动（首次需要下载镜像，约 1 分钟）…"
docker compose up -d

domain=$(sed -n 's/^PICKUP_DOMAIN=//p' .env | head -n 1)
if [ -n "$domain" ]; then
    url="https://$domain"
else
    url="http://<服务器IP>"
fi
say ""
say "完成！打开 $url"
if [ -n "$generated" ]; then
    say "上传密码（已保存在 $DIR/.env）: $(sed -n 's/^PICKUP_PASSWORD=//p' .env)"
fi
say "查看日志: cd $DIR && docker compose logs -f"
say "升级:     cd $DIR && docker compose pull && docker compose up -d"
