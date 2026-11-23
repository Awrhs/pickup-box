# 使用说明（当前基线：上传 + 实时图片处理）

OpenResty + LuaJIT + libvips 实现的个人/小圈子图床。上传走 API Key，原图按 SHA-256 内容寻址存盘，`/i/<hash>` 提供原图与 URL 参数实时变换；C 层用 libvips 处理（解码/方向/色彩空间/缩放/水印/编码），并通过 `ngx.run_worker_thread` 丢到 OS 线程池避免阻塞事件循环。

## 运行

```bash
cp .env.example .env
# 在 .env 里至少配置：
#   IMAGE_API_KEYS=alice:<alice-secret>:upload,bob:<bob-secret>:admin
docker compose up -d --build
./tools/smoke_image.sh
```

浏览器打开 `http://server/upload` 上传；管理面板 `http://server/admin?api_key=<bob-secret>`（生产请用 `Authorization: Bearer` 头，把 `?api_key=` 只留作临时调试）。

## 配置（环境变量）

### 存储
| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `IMAGE_DATA_DIR` | `/data/images` | 持久化根目录（orig/cache/tmp） |
| `IMAGE_DB_PATH` | `$DATA_DIR/image.db` | SQLite 元数据 |

### 上传 / 配额
| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `IMAGE_API_KEYS` | | 逗号分隔的 `name:secret[:role[:quota_bytes]]`；也支持裸 secret |
| `IMAGE_API_KEY_FILE` | | 换行分隔的 key 文件，10s 节流热加载 |
| `IMAGE_DEFAULT_QUOTA_BYTES` | `0` | 每 key 滚动窗口配额（0 关闭），可被单 key 的 quota 覆盖 |
| `IMAGE_QUOTA_WINDOW_DAYS` | `30` | 配额窗口（滚动，非自然月） |
| `IMAGE_MAX_UPLOAD_BYTES` | `20971520` | Lua 层单文件上限（20 MiB） |
| `IMAGE_MAX_PIXELS` | `40000000` | 像素炸弹防护（约 40 MP） |
| `UPLOAD_MAX_REQUESTS` / `UPLOAD_WINDOW` | `30` / `60` | 每 key hash 的上传频率 |

### 处理 / 缓存
| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `IMAGE_ENABLE_PROCESSING` | `true` | 关掉则只返回原图 |
| `IMAGE_CACHE_SECONDS` | `31536000` | 派生图 `Cache-Control: immutable` 秒数 |
| `IMAGE_L1_MAX_BYTES` | `262144` | L1 shared dict 单条上限（256 KiB） |
| `IMAGE_CACHE_MAX_BYTES` | `5368709120` | 派生图磁盘缓存上限（5 GiB，LRU 淘汰） |
| `IMAGE_MAX_CONCURRENCY` | `2` | 每 worker 同时进行的 libvips 操作数 |
| `IMAGE_THREAD_POOL` | `default` | `thread_pool` 名（在 nginx.conf main 段声明） |
| `IMAGE_PREGENERATE_SIZES` | `320,640,1024,1920` | 上传后异步预生成宽度 |
| `IMAGE_PREGENERATE_FORMAT` | `webp` | 预生成格式，`original` 保留源格式 |
| `IMAGE_WATERMARK_PATH` / `_OPACITY` / `_POSITION` | | 水印 PNG 路径 / 0–1 透明度 / 位置 |

### 公开访问防护
| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `IMAGE_DOWNLOAD_RPM` | `600` | 每 IP 每分钟请求上限（Lua 滑动窗口） |
| `IMAGE_DOWNLOAD_RATE_WINDOW` | `60` | 限流窗口（秒） |
| `IMAGE_DOWNLOAD_REFERER_MODE` | `off` | `allow` / `deny` / `off` |
| `IMAGE_DOWNLOAD_REFERER_LIST` | | 逗号分隔 host 列表（含子域后缀匹配） |
| `IMAGE_DOWNLOAD_REFERER_ALLOW_EMPTY` | `false` | 空 Referer 是否放行 |
| `IMAGE_DOWNLOAD_SIGNED_URLS` | `false` | 强制 HMAC 签名 URL |
| `IMAGE_DOWNLOAD_SECRET` | | 签名密钥（≥32 字符） |
| `IMAGE_DOWNLOAD_SIGN_TTL` | `3600` | 签名有效期（秒） |
| `IMAGE_DOWNLOAD_METER` | `true` | 在 shared dict 记录按小时带宽/请求计量 |

nginx 层还配了 `limit_req` / `limit_conn`（`dl_rps 50r/s burst=100`，`upload_rps 5r/s`）作为慢速攻击的兜底。

### GC
| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `IMAGE_GC_INTERVAL` | `21600`（6h） | 孤儿文件 + 软删除原图的对账周期 |

## API

| Method | Path | 鉴权 | 说明 |
| --- | --- | --- | --- |
| `GET`/`POST` | `/upload` | POST 需要 | 浏览器表单（GET）/ 上传（POST） |
| `GET`/`HEAD` | `/i/<hash>[.ext]` | 公开（受下载防护） | 原图或变换 |
| `DELETE` | `/i/<hash>` | key；admin 可删任意，uploader 只能删自己 | 软删除 + 删原图 |
| `GET` | `/i/<hash>/info` | 公开 | JSON：mime/尺寸/大小/上传时间 |
| `GET` | `/me/images` | key | 自己上传的图片列表 |
| `GET` | `/sign?path=...&w=...&ttl=...` | key | 生成签名 URL |
| `GET` | `/gallery` | admin | 最近图片 JSON |
| `GET` | `/admin` | admin | HTML 管理面板（分页/筛选/批量删除） |
| `GET` | `/admin/stats` | admin | JSON 统计（含 24h 下载量） |
| `GET` | `/admin/usage` | admin | 每 key 用量榜 |

### 变换参数

`/i/<hash>.jpg?w=800&h=600&fit=cover&q=75&fmt=webp&wm=1&gray=1&blur=2&download=1`

- `w` / `h`：0 表示按比例自适应。
- `fit=cover|crop`：居中裁剪填满；缺省为等比缩放。
- `q`：1–100，默认 82。
- `fmt`：jpeg/png/webp/avif/gif；若未指定且 Accept 包含 avif/webp 则自动协商。
- `wm=1`：叠加配置的水印。
- `gray=1`：灰度；`blur=<sigma>`（0–50）：高斯模糊。
- `download=1`：`Content-Disposition: attachment`。
- 若 AVIF 编码失败会自动回退 WebP→JPEG；每种输出格式有独立熔断器。

### 签名 URL

当 `IMAGE_DOWNLOAD_SIGNED_URLS=true` 时，`/i/...?...` 必须带 `e=<expiry>&s=<sig>`；签名覆盖 path + 过期时间 + 所有变换参数，防止把缩略图签名拿去拉 4K。生成方式：

```bash
curl -H "Authorization: Bearer $KEY" \
  "http://server/sign?path=/i/$hash.jpg&w=1000&fmt=webp&ttl=3600"
```

返回 `{ "url": "..." }`。

## 安全模型

- **密钥不落地**：内存里只存 `sha256(secret)`，SQLite `uploaded_by` 字段也是这个 hash。
- **恒定时间比较**：API Key 校验对所有配置的 key 哈希线性扫描，不按存在性短路。
- **内容寻址 + magic-byte 校验**：上传文件按 SHA-256 存盘，类型只认文件头不认扩展名。
- **EXIF 清理**：所有派生发 `strip=TRUE`，原图保留（你上传的就是你得到的）。
- **安全响应头**：所有响应 `X-Content-Type-Options: nosniff`、`Referrer-Policy: no-referrer`；图片响应附 CSP `default-src 'none'; img-src 'self'; sandbox` 和 `Cross-Origin-Resource-Policy: cross-origin`。
- **动画图**：GIF/animated WebP 带变换参数时直接返回原图（附 `X-Image-Animated: 1`），不会悄悄变成静帧。

## 备份

数据有两份：`/data/images/orig/`（原图）与 `/data/images/image.db`（SQLite 元数据）。推荐两种方式：

用自带脚本做一致性快照（SQLite `.backup` + 原图目录打包）：

```bash
BACKUP_DIR=/var/backups/pickup-box ./tools/backup.sh
./tools/restore.sh /var/backups/pickup-box/pickup-box-<时间戳>.tar.zst
```

SQLite 已开 WAL + `wal_autocheckpoint=1000`，运行时直接备份安全。

## 反代 TLS（Caddy 示例）

```caddyfile
i.example.com {
    reverse_proxy pickup-box:80
    encode zstd br gzip
    # Caddy 自动获取 Let's Encrypt 证书
}
```

或 nginx：
```nginx
server {
    listen 443 ssl http2;
    server_name i.example.com;
    ssl_certificate     /etc/ssl/certs/i.crt;
    ssl_certificate_key /etc/ssl/private/i.key;
    client_max_body_size 32m;
    location / { proxy_pass http://127.0.0.1:80; proxy_set_header Host $host;
                 proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; }
}
```

## 日志

- `./logs/access.log`：默认主格式（含 query）。
- 图床 `/upload`、`/i/`、`/admin`、`/sign`、`/me/images` 使用脱敏的 `img` 格式（**不含 query string**，所以 `api_key=`/签名 token 不会落盘）。
- 结构化事件日志在 `error.log`，由 `common.logger` 以 JSON 输出，带 `trace_id`。

## 监控

`/metrics` 暴露：

- `pickupbox_image_uploads_total`
- `pickupbox_image_cache_hits_total` / `_misses_total`
- `pickupbox_image_processed_total` / `_errors_total`
- `pickupbox_image_process_duration_seconds`（直方图）
- `pickupbox_download_bytes_total` / `_requests_total`
- `pickupbox_download_ratelimited_total` / `_referer_blocked_total` / `_signature_blocked_total`
- `pickupbox_owner_bytes_used{key="<前 12 hex>"}` / `pickupbox_owner_uploads`
- 所有 shared dict 的容量/已用量

`/readyz` 检查 vips、SQLite、目录可访问性、磁盘剩余空间。

## 已知限制

- 只支持单节点、本地磁盘 + SQLite。
- 不做多帧 GIF/animated WebP 转码（会原样返回）。
- 没有内置鉴黄/病毒扫描；对外开放前请只发上传口令给信任的人。
- 下一步改造方向（分享链接、取件码、过期）见 `PROGRESS.md`。
