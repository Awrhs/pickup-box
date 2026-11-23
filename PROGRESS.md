# PROGRESS.md — pickup-box 快传改造

> 本文件是项目的活任务清单。每完成一项勾选 `[x]`；范围变化或做出技术决策时更新文末「决策记录」。
> 配套工作流见 `CLAUDE.md` 的 "Workflow for non-trivial changes"。
>
> 验证以 GitHub Actions 为准（`.github/workflows/ci.yml`），每次 CI 结论记录在文末「CI 记录」。

## 目标

做一个自己和身边普通人都能用的**自建快传**：

1. 用手机浏览器打开网页，选择照片、视频或文件后上传（弱网下可断点续传）。
2. 上传完成后得到**短链接 + 取件码 + 二维码**，可以直接发到微信。
3. 对方点开链接或输入取件码，不用注册、不用装 App，就能看到**缩略图网格**，视频可以在线播放，也可以逐个下载或**全部打包下载**。
4. 分享会**到期自动失效**（例如 1 天或 7 天），也可以设置**下载 N 次后作废**；过期的文件会自动清理。
5. 只有持有**上传口令**的人能上传，拿到链接或取件码的任何人都能取件。

**非目标**：公开图床、长期相册（这类需求用 Immich）、多节点 CDN。

## 现有模块复用映射

| 现有模块 | 在快传中的用途 | 处置 |
| --- | --- | --- |
| `image/tus.lua` + `upload_spool.lua` | 大文件断点续传 | 保留；finalize 改为接受任意文件类型 |
| `image/upload.lua` | multipart 小文件上传、magic bytes 识别 | 保留；图片识别只用于决定是否生成预览，不再拒绝非图片 |
| `image/storage_local.lua` | 按内容寻址落盘、原子写、去重 | 保留，作为 blob 存储 |
| `image/metadata_sqlite.lua` + `sqlite_ffi.lua` | 元数据 | 保留；新增 shares/share_files 表 |
| `image/transform.lua` + `vips_ffi.lua` + `c/` | 缩略图、预览图转 WebP | 保留，只服务预览 |
| `image/apikey.lua` | 上传口令 | 保留；前端改为“输入一次口令，记在 cookie” |
| `image/download_guard.lua` | 下载限流、带宽计量 | 保留；去掉 Referer/公开签名 URL 逻辑 |
| `image/gc.lua` | 孤儿文件对账 | 改造为“过期分享 → blob 引用计数 → 删除” |
| `image/i18n.lua`、`errors.lua`、`util.lua`、`fs_ffi.lua` | 通用 | 保留 |
| `common/logger`、`metrics`、`circuit_breaker`、`rate_limit` | 日志、指标、熔断、上传限流 | 已就位 |
| pHash、文字/图片水印、`/admin/analytics` | 图床特性 | 代码可保留但不暴露入口；后续再清理 |

---

## Phase 0：待确认决策（开工前需定下来）

> 每一项都给了推荐默认值。确认后把结论移到「决策记录」，再把本项勾上。

- [ ] **D1 取件码格式**：推荐 **6 位数字**（100 万种组合），并且每个 IP 每小时最多失败 10 次。4 位只有 1 万种组合，即使限流也容易被遍历；如果坚持用 4 位，需要再加全局失败计数和临时封禁。
- [ ] **D2 下载次数语义**：推荐“**打开取件页算 1 次**”，也就是按访问次数计。另一种是按文件下载次数计，但这样同一页里的缩略图、视频 Range 请求都会被误计。
- [ ] **D3 容量上限**：推荐单文件 **2 GiB**（走 tus 上传），单个分享最多 **200 个文件**，每个上传口令总配额 **20 GiB**，磁盘剩余低于 **10%** 时拒绝新上传。
- [x] **D4 S3/备份**：删除（已执行）
- [x] **D5 产品名**：`pickup-box`，MIT 许可证

---

## Phase 1：清理与重构（只做减法）

- [x] 公共模块迁移到 `lua/common/`，删除无关子系统、多节点（`nodes`/`/near/`/PG）、S3/备份
- [x] `/healthz`、`/readyz`、`/metrics` 迁到 `lua/image/ops.lua`；`/readyz` 只检查 vips、SQLite、目录、磁盘
- [x] 指标前缀统一为 `pickupbox_`，Grafana/告警规则同步
- [x] 修复 `nginx.conf` 结构错误：`limit_*_zone`/`lua_package_path`/`init_by_lua_block` 移入 `http {}`；`http {}` 内的 `--` 注释改为 `#`；不存在的 `lua_thread_pool` 改为 main 段 `thread_pool`
- [x] 补齐 `env` 声明（如 `IMAGE_ALLOW_ORIGINAL_FORMAT` 此前未声明，会被 nginx 隐藏）
- [x] CI：syntax + luacheck + 旧名残留检查、busted、docker build + `openresty -t`、compose 冒烟
- [x] **CI 全绿**（2026-11-23，第 10 次运行；过程见文末 CI 记录）

## Phase 2：数据模型

- [ ] 把 `images` 表的语义改为 **blob**（一份内容只存一次）：新增 `kind`（image/video/other）和 `crc32`（打包 zip 时需要）；`orig_ext` 允许取 `bin`
- [ ] 新增 `shares` 表：`id`、`slug`（短链，base62，8 位）、`code`（取件码，唯一，只在有效期内占用）、`title`、`created_by`、`created_at`、`expires_at`、`max_visits`、`visit_count`、`revoked`
- [ ] 新增 `share_files` 表：`share_id`、`seq`、`blob_hash`、`filename`（原始文件名，展示和下载时用）、`size_bytes`、`mime`
- [ ] 写迁移（沿用 `PRAGMA user_version`）。目前没有线上数据，允许直接重建库，在决策记录里注明
- [ ] 取件码生成：用 `resty.random` 生成强随机数，与有效分享冲突时重试；生成的码不能和已过期但尚未 GC 的分享冲突

## Phase 3：上传与分享 API

- [ ] `upload.finalize` 接受任意类型：magic bytes 能识别为图片或视频时设置 `kind`，并对图片读取宽高；其他类型存为 `other`。像素上限只对图片生效
- [ ] finalize 时计算 CRC32（C 层用 zlib 的 `crc32`，或在 `c/image_vips.c` 里加一个辅助函数），写入 blob
- [ ] `POST /api/shares`（需要上传口令）：参数为一组已上传的 blob 和文件名、有效期、最大访问次数、标题；返回 `slug`、`code`、`url`、`expires_at`
- [ ] `GET /api/shares/mine`：列出自己的分享。`POST /api/shares/<id>/revoke` 撤销分享；`POST /api/shares/<id>/extend` 延期
- [ ] tus 上传完成后返回 blob hash，供前端组装分享

## Phase 4：取件与访问控制

- [ ] **关闭公开的 `/i/<hash>` 和 `/s/<slug>` 访问**。hash 会被接收方看到，如果保持公开，分享过期后仍能通过 hash 访问，过期就形同虚设
- [ ] `GET /p/<slug>`：取件页。会检查是否撤销、是否过期、访问次数是否用完；按 D2 的规则计数
- [ ] `GET /c/<code>` 和取件码输入页：取件码转换为 slug 后跳转。失败次数按 IP 计入 shared dict 并限流
- [ ] `GET /p/<slug>/<seq>`：下载单个文件，通过 X-Accel-Redirect 返回，带 `Content-Disposition: attachment; filename*=UTF-8''...`；视频依赖 nginx 静态模块的 Range 支持
- [ ] `GET /p/<slug>/<seq>/thumb?w=320`：缩略图和预览图，复用 `transform.lua` 的缓存和单飞锁
- [ ] `GET /p/<slug>/zip`：用 store 模式（不压缩）流式输出 zip，利用预先算好的 CRC32，不落临时文件，并处理 ZIP64（总大小超过 4 GiB）
- [ ] 安全头：对非图片和非视频的文件一律强制 `attachment`，并加 `X-Content-Type-Options: nosniff` 和 `CSP: sandbox`，防止上传的 HTML 或 SVG 被当成页面执行

## Phase 5：前端页面（手机优先、无构建步骤、零外部 CDN 依赖）

- [ ] **上传页 `/`**：第一次使用时输入上传口令并记住；用大按钮多选文件，或调起相机；显示每个文件和总体的进度条；弱网下断线后自动续传（自写精简 tus 客户端，或把 `tus-js-client` 的固定版本放进仓库）
- [ ] 上传完成页：显示大号取件码，提供“复制链接”“复制取件码”按钮，以及二维码（把 `qrcode-generator` 的固定版本放进仓库，在客户端生成）；可选有效期和次数
- [ ] **取件页 `/p/<slug>`**：图片以缩略图网格展示，点开看大图；视频用 `<video>` 在线播放；其他文件显示图标和大小；提供“全部下载”按钮
- [ ] 取件码输入页：一个数字键盘风格的输入框，适合老人使用
- [ ] “我的分享”页：剩余时间、访问次数，提供撤销和延期操作
- [ ] 文案与 i18n：默认中文，错误提示改成大白话（例如“这个分享已经过期了，请让对方重新发一次”）

## Phase 6：过期清理与容量保护

- [ ] 改造 `gc.lua`（只在 worker 0 运行）：把过期或撤销的分享标记为失效，然后释放取件码；某个 blob 不再被任何有效分享引用时，删除原文件和派生缓存
- [ ] tus 未完成的上传 24 小时后自动清理
- [ ] 上传前检查磁盘水位和口令配额（按 D3 的数值）
- [ ] 指标：在 `metrics` 中新增 `shares_created`、`shares_expired`、`pickup_code_failures`、`bytes_served`

## Phase 7：部署与文档

- [ ] 基于 `deploy/Caddyfile.example` 写一份 VPS 一键部署说明，Caddy 自动申请 HTTPS
- [ ] 文档写明现实约束：家宽通常没有公网 IP 且上行带宽小；国内 VPS 用域名需要备案，香港 VPS 免备案但速度一般
- [ ] 快传功能完成后更新 `README.md`、`CLAUDE.md`、`docs/USAGE.md`
- [ ] CI 加入 `tools/smoke_share.sh`

## Phase 8：验证

- [ ] `tools/smoke_share.sh`：覆盖上传口令错误被拒、上传图片+视频+zip、创建分享、用 slug 取件、用取件码取件、缩略图、单文件下载、全部打包下载、撤销后返回 404/410、过期后返回 410、取件码连续失败触发限流
- [ ] `spec/unit/`：覆盖取件码生成与冲突、过期判断、zip 头部构造（包括 ZIP64 边界）、文件名转义
- [ ] 手机实测：在 iOS Safari 和安卓微信内置浏览器里各走一遍上传和取件，包括切到后台再回来续传
- [ ] 压测：wrk 压取件页和缩略图，大文件下载验证 sendfile 和带宽

---

## 决策记录

> 最新条目在最上面。

- **2026-11-23**：确定方向为自建文件/照片快传；仓库名 `pickup-box`，MIT；删除 S3/备份/多节点/Postgres，只保留单节点本地磁盘 + SQLite。去掉公开图片访问前，Phase 4 必须先关闭 `/i/<hash>`、`/s/` 的公开访问。

## CI 记录

### 2026-11-23：从首次运行到全绿（共 10 轮）

首次推送时四个 job 全红。之前的代码**从未真正构建或运行过**。逐轮修掉的问题：

| 层面 | 问题 | 后果 |
| --- | --- | --- |
| 构建 | 精简版镜像里没有 `opm` | 镜像构建失败 |
| 构建 | C 代码用了 `VIPS_FORMAT_uchar`、`struct flock`（缺头文件） | `image_vips.so` 编译失败 |
| 构建 | C 代码调用了不存在的 `vips_tracked_set_limit` | 带 `-z now` 时 .so 加载失败 |
| 构建 | 镜像里没有 `nginx` 用户；非 root 进程绑不了 80 端口 | 镜像构建失败或启动失败 |
| 配置 | `limit_req_zone`/`lua_package_path`/`init_by_lua_block` 写在 `http {}` 外；`--` 注释；不存在的 `lua_thread_pool` | nginx 起不来 |
| 运行时 | 按名字 `libsqlite3.so` 加载，运行时镜像只有 `.so.0` | 元数据层整体不可用 |
| 运行时 | `SCHEMA_TUS`/`SCHEMA_STATS` 在定义前使用 | 断点续传和统计表从未创建 |
| 运行时 | `name:secret:role` 三段式 key 解析失败 | 按文档配置的 key 一律 401 |
| 运行时 | `run_worker_thread` 返回值取错 | 所有缩略图和格式转换都失败 |
| 运行时 | 编码时对所有格式都传 `interlace` | WebP/AVIF 输出全部失败 |
| 运行时 | 不指定 fmt 时输出格式为 nil | 普通缩放（curl、老浏览器）失败 |
| 运行时 | `dict:used()` 不存在；`/sign` 无密钥时出现 nil 拼接；`/admin/analytics` 调用未定义函数 | 返回 500 |
| 测试 | 冒烟测试用的 JPEG 本身是坏的；spec 里用了不存在的 `os.setenv`；断言的参数顺序不对 | 测试本身有错 |

### CI 指出的下一步（按优先级）

1. 启动日志里 GIF 编码器探测失败（`encoder unavailable: gif`），需要确认是 libvips/cgif 的问题还是探测图的问题。
2. luacheck 暂时忽略了 unused 和 shadowing 类警告（约 30 处），属于技术债，可以分批清理后取消忽略。
3. Actions 提示 Node 20 已弃用：把 `actions/checkout`、`docker/*` 升级到新的大版本。
4. 断点续传（tus）还没有被冒烟测试覆盖，而它的表此前从未创建过。**Phase 3 之前先给 tus 补一个端到端用例。**
5. 然后进入 Phase 2（数据模型），开工前需要先确定 D1–D3。
