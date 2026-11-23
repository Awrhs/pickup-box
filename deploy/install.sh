#!/bin/sh
# pickup-box one-step installer for a Linux server with Docker.
#
#   curl -fsSL https://raw.githubusercontent.com/Awrhs/pickup-box/main/deploy/install.sh | sh
#
# Default mode: pickup-box plus Caddy, which takes ports 80/443 and gets the
# HTTPS certificate automatically.
#
# PICKUP_MODE=proxy: for servers that already run a web server or proxy on
# 80/443 (Caddy, nginx, panels, proxy scripts). pickup-box then listens on
# 127.0.0.1:${PICKUP_PORT:-18080} only, and the installer writes a site file
# for Caddy and a snippet for nginx that you add to your existing server.
#
# Environment overrides: PICKUP_MODE, PICKUP_DIR (install directory),
# PICKUP_DOMAIN, PICKUP_PASSWORD, PICKUP_PORT, PICKUP_VERSION (image tag),
# PICKUP_IMAGE / CADDY_IMAGE (registry mirrors), PICKUP_RAW_BASE (where to
# fetch the compose files from).
set -eu

MODE="${PICKUP_MODE:-standalone}"
DIR="${PICKUP_DIR:-$PWD/pickup-box}"
RAW="${PICKUP_RAW_BASE:-https://raw.githubusercontent.com/Awrhs/pickup-box/main/deploy}"
PORT="${PICKUP_PORT:-18080}"

say() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "没有找到 Docker。请先安装：curl -fsSL https://get.docker.com | sudo sh"
docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2（docker compose 命令）。"
command -v curl >/dev/null 2>&1 || die "需要 curl。"

port_busy() {
    command -v ss >/dev/null 2>&1 || return 1
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
}

have_tty() {
    # In a subshell: a failed redirection on a special builtin such as ":"
    # would terminate a POSIX shell script outright.
    (true < /dev/tty) 2>/dev/null
}

ask() {  # ask VAR "prompt": only when a terminal is available
    if have_tty; then
        printf '%s' "$2" > /dev/tty
        read -r answer < /dev/tty || answer=""
        eval "$1=\$answer"
    fi
}

mkdir -p "$DIR"
cd "$DIR"
say "安装目录: $DIR"

case "$MODE" in
    standalone)
        if [ ! -f docker-compose.yml ] && { port_busy 80 || port_busy 443; }; then
            say "端口 80/443 已被其他程序占用（服务器上可能已有 Caddy、nginx 或代理脚本）。"
            say "为了不影响它们，请改用“接入已有反向代理”模式重新运行："
            say "  curl -fsSL $RAW/install.sh | PICKUP_MODE=proxy PICKUP_DOMAIN=你的域名 sh"
            exit 1
        fi
        curl -fsSL "$RAW/docker-compose.yml" -o docker-compose.yml
        curl -fsSL "$RAW/Caddyfile" -o Caddyfile
        ;;
    proxy)
        curl -fsSL "$RAW/docker-compose.proxy.yml" -o docker-compose.yml
        ;;
    *)
        die "未知的 PICKUP_MODE: $MODE（可选 standalone 或 proxy）"
        ;;
esac

generated=""
if [ -f .env ]; then
    say "沿用已有的 .env（如需修改请直接编辑它）。"
else
    domain="${PICKUP_DOMAIN:-}"
    if [ "$MODE" = proxy ]; then
        [ -n "$domain" ] || ask domain '用于快传的域名（需已解析到本机，例如 files.example.com）: '
        [ -n "$domain" ] || die "接入已有反向代理模式需要 PICKUP_DOMAIN。"
    else
        # Ask only when PICKUP_DOMAIN was not given at all (an explicitly
        # empty value means "HTTP only") and a terminal is really available.
        if [ -z "${PICKUP_DOMAIN+x}" ]; then
            ask domain '你的域名（已解析到本机，例如 files.example.com；直接回车则先用 http://服务器IP 测试）: '
        fi
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
        if [ "$MODE" = proxy ]; then
            echo "PICKUP_PUBLIC_URL=https://$domain"
            echo "PICKUP_PORT=$PORT"
        fi
        if [ -n "${PICKUP_VERSION:-}" ]; then echo "PICKUP_VERSION=$PICKUP_VERSION"; fi
        if [ -n "${PICKUP_IMAGE:-}" ]; then echo "PICKUP_IMAGE=$PICKUP_IMAGE"; fi
        if [ -n "${CADDY_IMAGE:-}" ]; then echo "CADDY_IMAGE=$CADDY_IMAGE"; fi
        if [ -n "${PICKUP_MEM_LIMIT:-}" ]; then echo "PICKUP_MEM_LIMIT=$PICKUP_MEM_LIMIT"; fi
    } > .env
fi

say "正在启动（首次需要下载镜像，约 1 分钟）…"
docker compose up -d

domain=$(sed -n 's/^PICKUP_DOMAIN=//p' .env | head -n 1)
say ""
if [ "$MODE" = proxy ]; then
    port=$(sed -n 's/^PICKUP_PORT=//p' .env | head -n 1)
    port="${port:-$PORT}"
    cat > caddy-site.conf <<CONF
# pickup-box: add to your Caddy configuration (e.g. /etc/caddy/sites/).
$domain {
	@internal path /metrics /__blob/*
	respond @internal 404
	reverse_proxy 127.0.0.1:$port {
		flush_interval -1
	}
}
CONF
    cat > nginx-site.conf <<CONF
# pickup-box: add inside the server { } block that serves $domain over HTTPS.
location / {
    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_pass http://127.0.0.1:$port;
}
location = /metrics { return 404; }
CONF
    say "pickup-box 已在 127.0.0.1:$port 运行。还差一步：让你现有的 Web 服务器把 $domain 转发过来。"
    if [ -d /etc/caddy/sites ]; then
        say "检测到 /etc/caddy/sites/，执行："
        say "  sudo cp $DIR/caddy-site.conf /etc/caddy/sites/$domain.conf && sudo systemctl restart caddy"
    else
        say "Caddy：把 $DIR/caddy-site.conf 的内容加入 Caddyfile 后重载。"
        say "nginx：把 $DIR/nginx-site.conf 加进 $domain 的 server 块后执行 sudo nginx -s reload。"
    fi
    say "然后打开 https://$domain"
else
    if [ -n "$domain" ]; then url="https://$domain"; else url="http://<服务器IP>"; fi
    say "完成！打开 $url"
fi
if [ -n "$generated" ]; then
    say "上传密码（已保存在 $DIR/.env）: $(sed -n 's/^PICKUP_PASSWORD=//p' .env)"
fi
say "查看日志: cd $DIR && docker compose logs -f"
say "升级:     cd $DIR && docker compose pull && docker compose up -d"
