# pickup-box

一个自己部署的**文件/照片快传**服务（开发中）：手机浏览器上传照片、视频或文件，拿到短链接和取件码发给家人朋友，对方点开就能预览、下载，到期自动清理。

技术栈：**OpenResty（Nginx + LuaJIT）**，图片预览由 **libvips（C）** 通过 LuaJIT FFI 实时生成，元数据存 **SQLite**（同样走 FFI），大文件用 **tus 1.0** 协议断点续传。

> **当前状态**：已有的是“上传 + 存储 + 实时图片处理”的基线，分享链接、取件码、过期这些快传功能还在开发中。路线图见 [`PROGRESS.md`](PROGRESS.md)。

## 已有能力

- `POST /upload`：multipart 上传，需要 API Key；按 magic bytes 识别格式，上传后剥离 EXIF
- `/files/`：tus 1.0 断点续传（create / HEAD / PATCH / DELETE）
- 内容寻址存储（SHA-256，相同内容自动去重），原子落盘
- `GET /i/<hash>?w=&h=&fit=&fmt=&q=`：实时缩放、裁剪、转码（WebP/AVIF 按 `Accept` 自动协商），结果先进内存 L1 缓存再落磁盘缓存，同一变换并发只处理一次
- 每个 Key 有配额和上传频率限制；下载侧有按 IP 限流和带宽计量
- `/healthz`、`/readyz`、`/metrics`（Prometheus）
- 管理页 `/admin`，个人页 `/me`

## 本地运行

```bash
cp .env.example .env
# 编辑 .env，至少设置 IMAGE_API_KEYS=名字:至少16位随机串:upload
docker compose up -d --build
./tools/smoke_image.sh
```

浏览器打开 `http://127.0.0.1/upload` 即可上传。完整的 API、配置和部署说明见 [`docs/USAGE.md`](docs/USAGE.md)。

## 目录结构

```text
conf/nginx.conf     路由表与 nginx 配置
lua/common/         logger / metrics / circuit_breaker / rate_limit
lua/image/          上传、存储、元数据、图片处理、运维端点
c/                  libvips 封装，编译为 image_vips.so
tools/              冒烟测试、备份/恢复脚本
spec/unit/          busted 单元测试
deploy/             Caddy / nginx TLS / logrotate 示例
```

## License

MIT
