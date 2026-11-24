# 部署指南

把快传部署到一台公网服务器，大约需要 15 分钟。按顺序做完下面 4 步即可。

## 准备

- 一台有公网 IP 的 Linux 服务器（x86 或 ARM 均可）。512 MB 内存可以运行，建议另有 1–2 GB 交换分区。
- 一个域名（下文以 `files.example.com` 为例），以及服务器的公网 IP（下文写作 `服务器IP`）。
- 云服务商的安全组 / 防火墙放行 TCP 80、443（以及 UDP 443，可选）。

## 第 1 步：域名解析

在域名的 DNS 服务商处添加一条记录，让域名指向服务器。以 Cloudflare 为例：

1. 登录 Cloudflare，进入你的域名 → **DNS** → **Records** → **Add record**。
2. 类型 **A**，名称 `files`（得到 `files.example.com`），IPv4 地址填 `服务器IP`。
3. **代理状态关闭**（灰色云朵，“DNS only”），然后保存。

为什么要关闭 Cloudflare 代理：证书由服务器上的 Caddy 直接向 Let's Encrypt 申请，需要直连；另外 Cloudflare 代理会把单次上传限制在 100 MB，并且会隐藏访客的真实 IP。

几分钟后在服务器上检查，看到的应当是服务器 IP：

```bash
getent hosts files.example.com
```

## 第 2 步：安装 Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo docker compose version      # 能显示版本号即可
```

> 中国大陆的服务器可能无法访问 Docker Hub，ghcr.io 也不稳定。可以按服务商的说明配置 Docker 镜像加速，并在第 3 步的命令前加上 `PICKUP_IMAGE=…`、`CADDY_IMAGE=…`，指定镜像加速地址（见 README 的“常见问题”）。

## 第 3 步：安装快传

先确认服务器上 80/443 端口有没有被别的程序占用：

```bash
sudo ss -ltnp | grep -E ':(80|443) '
```

### 情况 A：没有输出（端口空闲，全新服务器）

```bash
curl -fsSL https://raw.githubusercontent.com/Awrhs/pickup-box/main/deploy/install.sh \
  | sudo PICKUP_DOMAIN=files.example.com sh
```

脚本会启动快传和 Caddy，Caddy 自动申请 HTTPS 证书，最后打印上传密码。

### 情况 B：已有 Caddy / nginx 在用 80/443（例如面板或代理一键脚本）

快传只监听本机 `127.0.0.1:18080`，由你现有的 Web 服务器转发过来，不会改动现有站点：

```bash
curl -fsSL https://raw.githubusercontent.com/Awrhs/pickup-box/main/deploy/install.sh \
  | sudo PICKUP_MODE=proxy PICKUP_DOMAIN=files.example.com sh
```

脚本会在 `pickup-box/` 目录里生成 `caddy-site.conf` 和 `nginx-site.conf` 两个配置文件，并打印上传密码。然后按你现有的 Web 服务器，执行下面对应的操作。

**Caddy，且有 `/etc/caddy/sites/` 目录**（很多一键脚本的 Caddyfile 末尾都有 `import /etc/caddy/sites/*.conf`）：

```bash
sudo cp pickup-box/caddy-site.conf /etc/caddy/sites/files.example.com.conf
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile   # 必须显示 Valid configuration
sudo systemctl restart caddy
```

如果 `validate` 报错，先删掉刚复制的文件（`sudo rm /etc/caddy/sites/files.example.com.conf`），不要重启。

如果 Caddyfile 里写了 `admin off`，`systemctl reload` 不会生效，必须用 `restart`；重启时经过这个 Caddy 的其他连接（例如代理）会中断几秒。

**其他 Caddy**：把 `caddy-site.conf` 的内容追加到你的 Caddyfile，然后同样先 `validate` 再重启或重载。

**nginx**：在 `files.example.com` 的 HTTPS `server { }` 块里加入 `nginx-site.conf` 的内容（证书照你平时的方式配置，例如 certbot），然后执行：

```bash
sudo nginx -t && sudo nginx -s reload
```

## 第 4 步：验证

```bash
curl https://files.example.com/healthz          # 应返回 {"status":"ok",...}
```

然后用手机打开 `https://files.example.com`：

1. 在“发送文件”处输入上传密码（安装时打印过，也保存在 `pickup-box/.env` 的 `PICKUP_PASSWORD`）。
2. 选一张照片发送，得到 6 位取件码。
3. 换另一台手机（最好用流量而不是同一个 Wi-Fi），在首页输入取件码，能看到照片、能下载，就说明部署成功了。

## 日常维护

以下命令都在安装目录（默认 `./pickup-box`）中执行：

| 操作 | 命令 |
| --- | --- |
| 查看日志 | `sudo docker compose logs -f` |
| 升级到最新版 | `sudo docker compose pull && sudo docker compose up -d` |
| 修改设置（密码、大小上限等） | 编辑 `.env`，然后 `sudo docker compose up -d` |
| 停止 | `sudo docker compose down` |
| 备份 | 见 README 的“运维” |

卸载：先执行 `sudo docker compose down -v`（会删除所有已上传的文件）。如果是情况 B，再删掉添加的站点配置，然后重启或重载 Web 服务器。

## 常见问题

- **打不开 / 证书错误**：检查第 1 步的解析是否生效、80/443 是否放行、Cloudflare 代理是否已关闭。查看 Caddy 日志：情况 A 用 `sudo docker compose logs caddy`，情况 B 用 `sudo journalctl -u caddy -n 50`。
- **502 / 503**：快传容器没在运行。检查 `sudo docker compose ps` 和 `curl http://127.0.0.1:18080/healthz`（情况 B）。
- **上传很大的文件中断**：网页端会自动断点续传；如果你的 nginx 有 `client_max_body_size` 限制，要用 `nginx-site.conf` 里的设置覆盖它。
- **内存很小的服务器**：情况 B 默认限制快传最多使用 512 MB 内存（`.env` 里的 `PICKUP_MEM_LIMIT` 可调），即使处理大图片也不会挤占其他服务。
