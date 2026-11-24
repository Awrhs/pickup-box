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

## 当前状态（2026-11-23）

**可以部署使用了。** 在一台装了 Docker 的公网服务器上运行 `deploy/install.sh`（或手动配置 `PICKUP_DOMAIN` + `PICKUP_PASSWORD` 两个环境变量后 `docker compose up -d`），即可通过 HTTPS 对外提供服务。CI 每次提交都会：用安装脚本部署完整的 Caddy + HTTPS 生产栈并跑端到端测试；用 Playwright 在模拟 iPhone / Android 上走一遍发送与取件；发布 amd64 + arm64 镜像到 ghcr.io 并在两种架构上实际运行验证。

---

## Phase 0：待确认决策（开工前需定下来）

> 每一项都给了推荐默认值。确认后把结论移到「决策记录」，再把本项勾上。

- [x] **D1 取件码格式**：6 位数字；每个 IP 每小时最多失败 10 次，全局每小时 300 次（`PICKUP_CODE_LENGTH` 等可调）
- [x] **D2 下载次数语义**：打开取件页算 1 次；同一浏览器在令牌有效期（默认 6 小时）内刷新不重复计数；聊天软件的链接预览爬虫不计数
- [x] **D3 容量上限**：单文件 2 GiB、单分享 200 个文件、非管理员口令 30 天滚动 20 GiB、磁盘剩余低于 10% 拒绝上传（均可用 `PICKUP_*` 环境变量调整）
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

- [x] `images` 表作为 blob（内容寻址、去重），新增 `kind`、`crc32`；非图片 `orig_ext=bin`
- [x] `shares`（slug 10 位 base62、6 位取件码、过期、次数、撤回）与 `share_files` 表；取件码只在有效期内占用
- [x] 迁移沿用 `PRAGMA user_version`；`metadata.tx/write/rows` 事务辅助；`db:run` 出错即抛出
- [x] slug、取件码、上传会话 ID 全部使用 OpenSSL CSPRNG（`common.rand`）

## Phase 3：上传与分享 API

- [x] 任意文件类型，按 magic bytes 分类（image/video/audio/other），图片校验像素上限
- [x] SHA-256 + CRC-32 一次读完，C 实现、在线程池执行（`iv_digest_file`）
- [x] `/api/upload`（multipart，多文件，可 `?share=1` 一步分享）、`/api/shares` 增删改查、预览令牌、`/api/me`、`/api/config`
- [x] tus 重写：流式写盘、断线保留已收到的数据、会话锁、正确的校验和、空文件、完成时返回 `X-Blob-*`

## Phase 4：取件与访问控制

- [x] 去掉公开的 `/i/`、`/s/` 等图床接口，文件只能经由分享访问
- [x] `/p/<slug>` 取件页（无 JS 可用）、`/c/<code>` 取件码跳转、计次 + 令牌、机器人预览不计数
- [x] 单文件经 `ngx.exec` 交给 nginx sendfile（支持 Range）；固定两档预览尺寸；流式 zip（ZIP64）；服务端二维码
- [x] 非图片/视频/音频一律附件下载 + `nosniff` + `CSP sandbox`；取件码与密码防暴力破解

## Phase 5：前端页面

- [x] 首页：取件码输入 + 发送（登录一次、选择文件、有效期/次数/备注、逐文件进度、断网自动重试与续传、防息屏）
- [x] 发送结果：大号取件码、链接、二维码、复制/系统分享
- [x] 取件页：缩略图网格、视频/音频在线播放、单个下载、全部打包；微信内置浏览器提示
- [x] “我的分享”：复制、预览（不计次）、延期、撤回；管理员可看所有人

## Phase 6：过期清理与容量保护

- [x] GC（worker 0）：释放失效分享的取件码、清除过期记录、删除无引用 blob 及其缓存、清理过期 tus 会话与残留临时文件
- [x] 上传前检查磁盘水位与口令配额（管理员不受配额限制）
- [x] 业务指标：`pickupbox_shares_created_total`、`share_visits`、`pickup_code_failures`、`auth_failures`、`zip_downloads`、`file_downloads`（CI 校验非零）

## Phase 7：部署与文档

- [x] `deploy/docker-compose.yml` + `Caddyfile`（自动 HTTPS）+ `install.sh`（一行命令安装）
- [x] 多架构镜像发布到 ghcr.io（公开可匿名拉取），发布后在 amd64 与 arm64 上实际运行验证
- [x] README（部署 3 步、配置、使用、运维）、docs/API.md、SECURITY.md、CLAUDE.md、CONTRIBUTING.md
- [x] 无域名（纯 HTTP、用 IP 试用）模式、镜像加速地址（`PICKUP_IMAGE`/`CADDY_IMAGE`）、常见问题排查
- [x] Caddy 后面按真实客户端 IP 限流（nginx realip，仅在 `TRUST_X_FORWARDED_FOR=true` 时启用）
- [ ] 打版本标签（v0.1.0）并让 compose 默认使用固定版本（目前 `latest` 只在 main 分支全部测试通过后才发布）
- [x] **真实公网部署验证**（`.github/workflows/public-demo.yml`，手动触发）：在 GitHub 的机器上只配环境变量、用 `install.sh` 拉取 ghcr.io 发布的镜像部署，通过 Cloudflare 临时隧道获得公网 HTTPS 域名；在公网域名上跑通接口端到端测试与 Chromium/WebKit 浏览器测试；用原样的 `deploy/Caddyfile` 为另一个公网域名向 Let's Encrypt 申请到证书，并在完整证书校验下通过它访问应用
- [x] 2026-11-23 实测：从另一台机器（不同网络）对公网地址跑端到端测试 60 项全部通过；收件人用取件码取件、下载 zip 正常；check-host.net 全球 12 个探测点中 10 个 HTTP 200（其余 2 个为探测节点自身网络问题）
- [x] “接入已有反向代理”模式（`PICKUP_MODE=proxy`）：服务器上已有 Caddy/nginx/一键脚本占用 80/443 时，快传只监听 127.0.0.1 并生成站点配置；默认安装检测到端口被占用会停下而不是抢占（CI 模拟 233boy 风格的 Caddy + nginx 验证）
- [x] 部署操作文档 `docs/DEPLOY.md`（域名解析、安装 Docker、两种情况的安装、验证、维护、常见问题）
- [ ] **在自己的服务器上正式部署**——按用户决定（2026-11-23）由用户按 `docs/DEPLOY.md` 自行操作
- [ ] 家庭宽带等无公网 IP 的场景：文档化 Cloudflare Tunnel（命名隧道）部署方式，并让应用信任 `CF-Connecting-IP` 以便按真实访客限流

## Phase 8：验证

- [x] `tools/e2e.py`：约 80 项端到端检查（上传/续传/校验和/配额/分享/取件码/Range/中文文件名/HTML 附件/预览/zip 与 ZIP64/二维码/次数/机器人/撤回/延期/过期/防暴力破解/GC）
- [x] `tools/browser_test.py`：Playwright 在模拟手机上走完整发送与取件流程，截图存档
- [x] `spec/unit/`：配置解析、文件名清洗、UTF-8、CRC-32、类型识别、zip 结构（含 ZIP64）
- [x] WebKit（Safari 内核）浏览器测试：发现并修复了 Safari 单文件无法下载的问题
- [ ] 真机实测：iOS Safari、安卓微信内置浏览器（含切后台续传）——需要真人手机
- [x] 并发压力测试 `tools/stress.py`（并行分块上传含相同内容 + 并发取件页/预览/Range/zip），经 Caddy 运行，并检查日志无 worker 崩溃/锁库
- [ ] 更大规模压测（真实带宽、上百并发、GB 级文件）——需要真实服务器

---

## 决策记录

> 最新条目在最上面。

- **2026-11-23**：部署到服务器、域名解析由用户自己操作；开发侧只负责代码与部署文档（用户原话：“你完成写代码的事情即可，部署到服务和域名指向等事情，你只需要把操作步骤写在文档中，后续我来操作即可”）。
- **2026-11-23**：D1–D3 由用户确认（6 位码、按打开取件页计次、推荐容量上限）；实现时补充：令牌期内刷新不重复计数、链接预览爬虫不计数（否则“只能打开 1 次”的分享会被聊天软件的预览请求耗尽）。
- **2026-11-23**：确定方向为自建文件/照片快传；仓库名 `pickup-box`，MIT；删除 S3/备份/多节点/Postgres，只保留单节点本地磁盘 + SQLite。去掉公开图片访问前，Phase 4 必须先关闭 `/i/<hash>`、`/s/` 的公开访问。

## CI 记录

### 2026-11-23（下午）：快传功能上线到 CI 全绿（11 个 job）

当前流水线：lint（Lua/JS/Python 语法、luacheck、env 声明检查、旧名检查）→ 单元测试 → 镜像构建 → 端到端（开发栈，含过期/防暴力破解/GC、指标非零、无崩溃）→ 浏览器（Chromium + WebKit，模拟 iPhone/Android）→ 生产部署（`install.sh` + Caddy HTTPS，端到端 + 并发压测 + 无崩溃）→ 无域名 HTTP 部署 → 发布 ghcr.io 多架构镜像 → 在 amd64 与 arm64 上用安装脚本拉取发布的镜像并跑端到端。

这一阶段 CI 发现并修复的问题：

| 问题 | 后果 |
| --- | --- |
| 在 `content_by_lua` 里设置 `X-Accel-Redirect` 不会被 nginx 处理 | 原来的图片接口从未真正返回过文件内容 |
| tus PATCH 请求体被 nginx 缓冲到临时文件时被当成空 | 断点续传在真实场景下丢数据 |
| `vips_flatten` 传了裸 C 数组而不是 `VipsArrayDouble*` | 生成 JPEG 时 worker 段错误 |
| 编码器探测对 GIF 传 `Q` 参数 | GIF 一直被误判为不可用 |
| `PICKUP_*` 通过辅助函数读取，未被声明到 nginx env | 只是碰巧在 master 里加载才能工作 |
| 附件响应带 CSP `sandbox`；`text/plain` 附件被 WebKit 直接显示 | iPhone 上点“下载”没反应或显示乱码 |
| 空 `PICKUP_DOMAIN` 被原样传给 Caddy | 无域名（用 IP 测试）模式下 Caddy 无法启动 |
| 安装脚本在无终端时询问域名 | 非交互环境下安装中断 |
| GC 测试用“创建分享”探测文件是否存在 | 探测本身让文件一直被引用（测试缺陷） |

### 2026-11-23（上午）：从首次运行到全绿（共 10 轮）

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
