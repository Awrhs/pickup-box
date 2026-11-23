#!/usr/bin/env python3
"""End-to-end test for a running pickup-box (stdlib only).

Usage:
  python3 -I tools/e2e.py --base http://127.0.0.1 --password OWNER_PW \
      [--friend friend:FRIEND_PW] [--insecure] [--short-expiry] [--gc] [--destructive]

--short-expiry  server runs with PICKUP_MIN_EXPIRY=1 (tests real expiry)
--gc            server runs with a fast GC (PICKUP_GC_INTERVAL=2,
                PICKUP_UPLOAD_GRACE=1) and blob deletion is verified
--destructive   also run the brute-force lockout tests (they block this
                client IP for code lookups and logins for a while: run last)
"""
import argparse
import base64
import hashlib
import http.client
import io
import json
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import zipfile
import zlib

BROWSER_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
BOT_UA = "TelegramBot (like TwitterBot)"

FAILURES = []
PASSES = 0


def check(name, cond, detail=""):
    global PASSES
    if cond:
        PASSES += 1
        print(f"  ok   {name}")
    else:
        FAILURES.append(name)
        print(f"  FAIL {name} {detail}")
    return cond


class Client:
    def __init__(self, base, insecure):
        u = urllib.parse.urlsplit(base)
        self.scheme, self.host = u.scheme, u.hostname
        self.port = u.port or (443 if u.scheme == "https" else 80)
        self.netloc = u.netloc
        self.ctx = None
        if self.scheme == "https":
            self.ctx = ssl.create_default_context()
            if insecure:
                self.ctx.check_hostname = False
                self.ctx.verify_mode = ssl.CERT_NONE

    def conn(self):
        if self.scheme == "https":
            return http.client.HTTPSConnection(self.host, self.port, context=self.ctx, timeout=60)
        return http.client.HTTPConnection(self.host, self.port, timeout=60)

    def req(self, method, path, body=None, headers=None):
        h = {"User-Agent": BROWSER_UA}
        h.update(headers or {})
        c = self.conn()
        try:
            c.request(method, path, body=body, headers=h)
            r = c.getresponse()
            data = r.read()
            return r.status, {k.lower(): v for k, v in r.getheaders()}, data
        finally:
            c.close()

    def raw_socket(self):
        s = socket.create_connection((self.host, self.port), timeout=30)
        if self.scheme == "https":
            s = self.ctx.wrap_socket(s, server_hostname=self.host)
        return s


def png_bytes(w=16, h=16, seed=0):
    raw = b"".join(b"\x00" + b"".join(bytes([(x * 16 + seed) % 256, (y * 16) % 256, 128]) for x in range(w))
                   for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def sha(b):
    return hashlib.sha256(b).hexdigest()


def multipart(files):
    boundary = "----pbtest" + os.urandom(8).hex()
    out = io.BytesIO()
    for name, data in files:
        out.write(f"--{boundary}\r\n".encode())
        out.write(b'Content-Disposition: form-data; name="file"; filename="' + name.encode("utf-8") + b'"\r\n')
        out.write(b"Content-Type: application/octet-stream\r\n\r\n")
        out.write(data)
        out.write(b"\r\n")
    out.write(f"--{boundary}--\r\n".encode())
    return out.getvalue(), f"multipart/form-data; boundary={boundary}"


class T:
    def __init__(self, args):
        self.c = Client(args.base, args.insecure)
        self.pw = args.password
        self.args = args

    def auth(self, pw=None):
        return {"Authorization": "Bearer " + (pw or self.pw)}

    def api(self, method, path, obj=None, pw=None):
        body = json.dumps(obj).encode() if obj is not None else None
        h = self.auth(pw)
        if body is not None:
            h["Content-Type"] = "application/json"
        st, hd, data = self.c.req(method, path, body, h)
        try:
            return st, json.loads(data or b"null")
        except ValueError:
            return st, None

    def tus_upload(self, data, name, chunk=None, pw=None):
        meta = "filename " + base64.b64encode(name.encode()).decode()
        st, hd, _ = self.c.req("POST", "/files/", b"", dict(self.auth(pw), **{
            "Tus-Resumable": "1.0.0", "Upload-Length": str(len(data)), "Upload-Metadata": meta}))
        if st != 201:
            return None, st, None
        url = hd["location"]
        if hd.get("x-blob-hash"):
            return hd["x-blob-hash"], st, url
        chunk = chunk or len(data)
        off = 0
        while off < len(data):
            part = data[off:off + chunk]
            st, hd, body = self.c.req("PATCH", url, part, dict(self.auth(pw), **{
                "Tus-Resumable": "1.0.0", "Upload-Offset": str(off),
                "Content-Type": "application/offset+octet-stream"}))
            if st != 204:
                return None, st, url
            off = int(hd["upload-offset"])
        return hd.get("x-blob-hash"), st, url

    def share(self, files, **opts):
        body = {"files": [{"hash": h, "name": n} for h, n in files]}
        body.update(opts)
        return self.api("POST", "/api/shares", body)

    def open_page(self, slug, ua=BROWSER_UA):
        """Open /p/<slug> like a browser; returns (status, token, html)."""
        st, hd, body = self.c.req("GET", f"/p/{slug}", headers={"User-Agent": ua})
        if st == 302:
            loc = hd["location"]
            tok = urllib.parse.parse_qs(urllib.parse.urlsplit(loc).query).get("t", [None])[0]
            st2, _, body2 = self.c.req("GET", loc, headers={"User-Agent": ua})
            return st2, tok, body2.decode("utf-8", "replace")
        return st, None, body.decode("utf-8", "replace")

    # ------------------------------------------------------------ tests --
    def basics(self):
        print("== basics")
        st, _, body = self.c.req("GET", "/healthz")
        check("healthz 200", st == 200)
        st, _, body = self.c.req("GET", "/readyz")
        check("readyz 200", st == 200, body[:300])
        st, _, body = self.c.req("GET", "/")
        check("home page 200", st == 200 and "取件" in body.decode())
        for asset in ("/static/app.css", "/static/common.js", "/static/app.js", "/static/me.js"):
            st, hd, _ = self.c.req("GET", asset)
            check(f"asset {asset}", st == 200 and "nosniff" in hd.get("x-content-type-options", ""))
        st, _, _ = self.c.req("GET", "/me")
        check("me page 200", st == 200)
        st, _, _ = self.c.req("GET", "/metrics")
        check("metrics hidden from outside", st == 404)
        st, _, _ = self.c.req("GET", "/__blob/images.db")
        check("internal blob location hidden", st == 404)
        st, _, _ = self.c.req("GET", "/p/../../etc/passwd")
        check("path traversal rejected", st in (400, 404))

    def auth_tests(self):
        print("== auth")
        st, _ = self.api("GET", "/api/me", pw="definitely-wrong-password")
        check("wrong password 401", st == 401)
        st, me = self.api("GET", "/api/me")
        check("owner /api/me", st == 200 and me and me.get("role") == "admin", str(me))
        if self.args.friend:
            st, me = self.api("GET", "/api/me", pw=self.friend_pw)
            check("friend /api/me", st == 200 and me.get("role") == "upload", str(me))

    def upload_tests(self):
        print("== uploads")
        self.png = png_bytes(seed=7)
        h, st, _ = self.tus_upload(self.png, "photo.png", chunk=300)
        check("tus chunked upload completes", h == sha(self.png), f"status={st} hash={h}")
        self.png_hash = h

        # Resume after a connection drop in the middle of a PATCH body.
        blob = os.urandom(3 * 1024 * 1024 + 123)
        meta = "filename " + base64.b64encode(b"random.bin").decode()
        st, hd, _ = self.c.req("POST", "/files/", b"", dict(self.auth(), **{
            "Tus-Resumable": "1.0.0", "Upload-Length": str(len(blob)), "Upload-Metadata": meta}))
        check("tus create 201", st == 201)
        url = hd.get("location", "")
        half = 512 * 1024
        s = self.c.raw_socket()
        req = (f"PATCH {url} HTTP/1.1\r\nHost: {self.c.netloc}\r\nUser-Agent: e2e\r\n"
               f"Authorization: Bearer {self.pw}\r\nTus-Resumable: 1.0.0\r\nUpload-Offset: 0\r\n"
               f"Content-Type: application/offset+octet-stream\r\nContent-Length: {1024 * 1024}\r\n"
               f"Connection: close\r\n\r\n").encode()
        s.sendall(req + blob[:half])
        time.sleep(0.5)
        s.close()
        offset = 0
        for _ in range(40):
            st, hd, _ = self.c.req("HEAD", url, headers=dict(self.auth(), **{"Tus-Resumable": "1.0.0"}))
            offset = int(hd.get("upload-offset", "0"))
            if offset > 0:
                break
            time.sleep(0.5)
        check("interrupted PATCH keeps received bytes", 0 < offset <= half, f"offset={offset}")
        off = offset
        while off < len(blob):
            part = blob[off:off + 1024 * 1024]
            st, hd, _ = self.c.req("PATCH", url, part, dict(self.auth(), **{
                "Tus-Resumable": "1.0.0", "Upload-Offset": str(off),
                "Content-Type": "application/offset+octet-stream"}))
            if st != 204:
                break
            off = int(hd["upload-offset"])
        check("resumed upload completes with correct hash", hd.get("x-blob-hash") == sha(blob))
        self.bin_hash, self.bin = sha(blob), blob
        st, hd, _ = self.c.req("HEAD", url, headers=dict(self.auth(), **{"Tus-Resumable": "1.0.0"}))
        check("HEAD on finished upload reports blob", hd.get("x-blob-hash") == self.bin_hash)

        st, hd, _ = self.c.req("PATCH", url, b"x", dict(self.auth(), **{
            "Tus-Resumable": "1.0.0", "Upload-Offset": "0", "Content-Type": "application/offset+octet-stream"}))
        check("PATCH after completion is idempotent", st == 204)

        st, _, _ = self.c.req("POST", "/files/", b"", dict(self.auth(), **{
            "Tus-Resumable": "1.0.0", "Upload-Length": str(10 * 1024 ** 4)}))
        check("oversized upload refused 413", st == 413)

        h, st, _ = self.tus_upload(b"", "empty.txt")
        check("zero-byte upload", h == sha(b""), f"st={st}")
        self.empty_hash = h

        # Checksum extension: a wrong checksum must not be accepted.
        st, hd, _ = self.c.req("POST", "/files/", b"", dict(self.auth(), **{
            "Tus-Resumable": "1.0.0", "Upload-Length": "5"}))
        u2 = hd.get("location")
        bad = base64.b64encode(hashlib.sha256(b"other").digest()).decode()
        st, hd, _ = self.c.req("PATCH", u2, b"hello", dict(self.auth(), **{
            "Tus-Resumable": "1.0.0", "Upload-Offset": "0", "Upload-Checksum": "sha256 " + bad,
            "Content-Type": "application/offset+octet-stream"}))
        check("checksum mismatch rejected (460)", st == 460)
        good = base64.b64encode(hashlib.sha256(b"hello").digest()).decode()
        st, hd, _ = self.c.req("PATCH", u2, b"hello", dict(self.auth(), **{
            "Tus-Resumable": "1.0.0", "Upload-Offset": "0", "Upload-Checksum": "sha256 " + good,
            "Content-Type": "application/offset+octet-stream"}))
        check("checksum match accepted", st == 204 and hd.get("x-blob-hash") == sha(b"hello"))

        # Multipart: several files, a Chinese name and an HTML file.
        self.html = b"<html><script>alert(1)</script></html>"
        self.txt = "你好，世界\n".encode()
        body, ct = multipart([("测试 文件.txt", self.txt), ("evil.html", self.html)])
        st, hd, data = self.c.req("POST", "/api/upload", body, dict(self.auth(), **{"Content-Type": ct}))
        res = json.loads(data or b"{}")
        files = res.get("files") or []
        check("multipart upload 201", st == 201 and len(files) == 2, data[:300])
        check("html sniffed as plain file", len(files) == 2 and files[1]["kind"] == "other")
        self.txt_hash = sha(self.txt)
        self.html_hash = sha(self.html)

        if self.args.friend:
            big = os.urandom(150 * 1024)
            h, st, _ = self.tus_upload(big, "big.bin", pw=self.friend_pw)
            check("friend quota enforced (413)", h is None and st == 413, f"st={st}")

    def share_tests(self):
        print("== shares")
        st, s = self.share([(self.png_hash, "photo.png"), (self.bin_hash, "random.bin"),
                            (self.txt_hash, "测试 文件.txt"), (self.html_hash, "evil.html"),
                            (self.empty_hash, "empty.txt")], expires_in=3600, title="e2e")
        check("create share 201", st == 201 and s and s.get("code"), str(s))
        self.s = s
        slug, code = s["slug"], s["code"]
        check("code has 6 digits", len(code) == 6 and code.isdigit())

        st, hd, _ = self.c.req("GET", f"/c/{code}")
        check("pickup code redirects to share", st == 302 and hd.get("location") == f"/p/{slug}", str(hd.get("location")))
        st, hd, _ = self.c.req("GET", f"/c?code={code}")
        check("pickup code form redirects", st == 302)

        st, tok, html = self.open_page(slug)
        check("pickup page lists files", st == 200 and "photo.png" in html and "测试 文件.txt" in html)
        check("pickup page has token", bool(tok))
        self.tok = tok
        q = "t=" + urllib.parse.quote(tok)

        st, hd, data = self.c.req("GET", f"/p/{slug}/f/1?{q}")
        check("image served inline", st == 200 and data == self.png and hd.get("content-type") == "image/png"
              and hd.get("content-disposition", "").startswith("inline"), str(hd))
        st, hd, data = self.c.req("GET", f"/p/{slug}/f/1?{q}&dl=1")
        check("dl=1 forces attachment", st == 200 and hd.get("content-disposition", "").startswith("attachment"))
        st, hd, data = self.c.req("GET", f"/p/{slug}/f/2?{q}", headers={"Range": "bytes=10-19"})
        check("range request 206", st == 206 and data == self.bin[10:20], f"st={st}")
        st, hd, data = self.c.req("GET", f"/p/{slug}/f/3?{q}")
        cd = hd.get("content-disposition", "")
        check("utf-8 file name in Content-Disposition", data == self.txt and "UTF-8''%E6%B5%8B%E8%AF%95" in cd, cd)
        st, hd, data = self.c.req("GET", f"/p/{slug}/f/4?{q}")
        check("html served as attachment", hd.get("content-disposition", "").startswith("attachment")
              and "sandbox" in hd.get("content-security-policy", ""), str(hd))
        st, hd, data = self.c.req("GET", f"/p/{slug}/f/1/thumb?{q}&s=s", headers={"Accept": "image/webp,*/*"})
        check("webp preview", st == 200 and hd.get("content-type") == "image/webp" and data[:4] == b"RIFF", f"st={st} {hd}")
        st, hd, data = self.c.req("GET", f"/p/{slug}/f/1/thumb?{q}&s=l", headers={"Accept": "image/jpeg"})
        check("jpeg preview", st == 200 and data[:3] == b"\xff\xd8\xff", f"st={st}")
        st, hd, data = self.c.req("GET", f"/p/{slug}/f/2/thumb?{q}")
        check("no preview for non-images", st == 404)

        st, hd, data = self.c.req("GET", f"/p/{slug}/zip?{q}")
        ok = st == 200 and int(hd.get("content-length", "-1")) == len(data)
        check("zip download with exact Content-Length", ok, f"st={st}")
        try:
            z = zipfile.ZipFile(io.BytesIO(data))
            names = z.namelist()
            check("zip integrity", z.testzip() is None)
            check("zip contents", z.read("photo.png") == self.png and z.read("random.bin") == self.bin
                  and z.read("测试 文件.txt") == self.txt and "empty.txt" in names, str(names))
        except zipfile.BadZipFile as e:
            check("zip readable", False, str(e))
        if shutil.which("unzip"):
            with tempfile.NamedTemporaryFile(suffix=".zip") as f:
                f.write(data)
                f.flush()
                r = subprocess.run(["unzip", "-tq", f.name], capture_output=True)
                check("unzip -t accepts archive", r.returncode == 0, r.stdout[-300:])
        st, hd, data = self.c.req("GET", f"/p/{slug}/zip?{q}&zip64=1")
        try:
            z = zipfile.ZipFile(io.BytesIO(data))
            check("zip64 archive valid", z.testzip() is None and z.read("random.bin") == self.bin)
        except zipfile.BadZipFile as e:
            check("zip64 archive readable", False, str(e))

        st, hd, data = self.c.req("GET", f"/p/{slug}/qr.svg")
        check("qr code svg", st == 200 and data.startswith(b"<svg"), f"st={st}")

        st, lst = self.api("GET", "/api/shares")
        check("list my shares", st == 200 and any(x["slug"] == slug for x in lst.get("shares", [])))
        if self.args.friend:
            st, _ = self.api("GET", f"/api/shares/{s['id']}", pw=self.friend_pw)
            check("other users cannot see my share", st == 404)
            st, _ = self.api("POST", f"/api/shares/{s['id']}/revoke", pw=self.friend_pw)
            check("other users cannot revoke my share", st == 404)

    def visit_tests(self):
        print("== visit limits")
        st, s = self.share([(self.png_hash, "once.png")], max_visits=1, expires_in=3600)
        slug = s["slug"]
        st, _, html = self.open_page(slug, ua=BOT_UA)
        check("link preview bot gets preview page", st == 200 and "有人给你发送了" in html)
        st, info = self.api("GET", f"/api/shares/{s['id']}")
        check("bot did not consume a visit", info["visit_count"] == 0, str(info))
        st, tok, html = self.open_page(slug)
        check("first open allowed", st == 200 and tok)
        st, _, html = self.open_page(slug)
        check("second open refused (410)", st == 410 and "次数" in html)
        st, hd, data = self.c.req("GET", f"/p/{slug}?t=" + urllib.parse.quote(tok))
        check("reload with token still works", st == 200)
        st, hd, data = self.c.req("GET", f"/p/{slug}/f/1?t=" + urllib.parse.quote(tok))
        check("file with token works", st == 200 and data == self.png)
        st, hd, data = self.c.req("GET", f"/p/{slug}/f/1")
        check("file without token refused", st == 403)

        st, s2 = self.share([(self.png_hash, "preview.png")], max_visits=1, expires_in=3600)
        st, pv = self.api("POST", f"/api/shares/{s2['id']}/preview")
        purl = urllib.parse.urlsplit(pv["url"])
        st, _, _ = self.c.req("GET", purl.path + "?" + purl.query)
        st2, info = self.api("GET", f"/api/shares/{s2['id']}")
        check("owner preview does not count", st == 200 and info["visit_count"] == 0)

    def lifecycle_tests(self):
        print("== lifecycle")
        st, s = self.share([(self.png_hash, "x.png")], expires_in=600)
        st, s2 = self.api("POST", f"/api/shares/{s['id']}/extend", {"expires_in": 7200})
        check("extend", st == 200 and s2["expires_in"] > 7000, str(s2))
        st, s3 = self.api("POST", f"/api/shares/{s['id']}/revoke")
        check("revoke", st == 200 and s3["state"] == "revoked")
        st, _, _ = self.open_page(s["slug"])
        check("revoked share page 410", st == 410)
        st, hd, _ = self.c.req("GET", f"/c/{s['code']}")
        check("revoked share code no longer works", st == 404)
        st, _, _ = self.c.req("GET", f"/p/{s['slug']}/f/1")
        check("revoked share files 410", st == 410)
        st, _ = self.share([(self.png_hash, "x.png")], expires_in=10 ** 9)
        check("expiry above maximum refused", st == 400)
        st, _ = self.share([("0" * 64, "x.png")], expires_in=3600)
        check("unknown blob refused", st == 409)

        # One-shot upload + share over multipart.
        body, ct = multipart([("a.txt", b"aaa"), ("b.txt", b"bbb")])
        st, hd, data = self.c.req("POST", "/api/upload?share=1&expires_in=1h&title=cli",
                                  body, dict(self.auth(), **{"Content-Type": ct}))
        res = json.loads(data or b"{}")
        check("one-shot upload and share", st == 201 and res.get("file_count") == 2 and res.get("code"), data[:200])

        if self.args.short_expiry:
            st, s = self.share([(self.png_hash, "soon.png")], expires_in=2)
            check("short share created", st == 201)
            time.sleep(3)
            st, _, html = self.open_page(s["slug"])
            check("expired share page 410", st == 410 and "过期" in html)

    def gc_tests(self):
        print("== garbage collection")
        data = os.urandom(4096)
        h, st, _ = self.tus_upload(data, "gc.bin")
        st, s = self.share([(h, "gc.bin")], expires_in=3600)
        self.api("POST", f"/api/shares/{s['id']}/revoke")
        st, _ = self.api("GET", f"/api/blobs/{h}")
        check("blob present before GC", st == 200)
        gone = False
        for _ in range(40):
            st, _ = self.api("GET", f"/api/blobs/{h}")
            if st == 404:
                gone = True
                break
            time.sleep(1)
        check("GC deletes blobs no live share references", gone)
        st, _ = self.share([(h, "gc.bin")], expires_in=3600)
        check("sharing a collected blob is refused", st == 409)
        h2, st, _ = self.tus_upload(data, "gc.bin")
        check("re-upload after GC works", h2 == h)
        st, s = self.share([(h2, "gc.bin")], expires_in=3600)
        st, tok, _ = self.open_page(s["slug"])
        st, hd, body = self.c.req("GET", f"/p/{s['slug']}/f/1?t=" + urllib.parse.quote(tok))
        check("re-uploaded file downloadable", st == 200 and body == data)

    def destructive_tests(self):
        print("== brute-force limits (blocks this IP for a while)")
        last = None
        for i in range(12):
            st, _, body = self.c.req("GET", "/c/000000" if i % 2 else "/c/999999")
            last = (st, body)
            time.sleep(0.6)
        check("pickup code guessing throttled", last[0] == 429 and "尝试次数" in last[1].decode(), str(last[0]))
        for i in range(11):
            st, _ = self.api("GET", "/api/me", pw=f"wrong-password-{i:04d}")
            time.sleep(0.15)
        st, _ = self.api("GET", "/api/me")
        check("password guessing throttled (even correct password waits)", st == 429, f"st={st}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--base", default="http://127.0.0.1")
    p.add_argument("--password", required=True)
    p.add_argument("--friend", help="name:password of an upload-role user with a small quota")
    p.add_argument("--insecure", action="store_true")
    p.add_argument("--short-expiry", action="store_true")
    p.add_argument("--gc", action="store_true")
    p.add_argument("--destructive", action="store_true")
    p.add_argument("--only", help="comma separated groups: basics,auth,uploads,shares,visits,lifecycle,gc")
    args = p.parse_args()
    t = T(args)
    if args.friend:
        t.friend_pw = args.friend.split(":", 1)[1]
    if args.only:
        groups = {"basics": t.basics, "auth": t.auth_tests, "uploads": t.upload_tests,
                  "shares": t.share_tests, "visits": t.visit_tests,
                  "lifecycle": t.lifecycle_tests, "gc": t.gc_tests}
        for g in args.only.split(","):
            groups[g.strip()]()
    else:
        t.basics()
        t.auth_tests()
        t.upload_tests()
        t.share_tests()
        t.visit_tests()
        t.lifecycle_tests()
        if args.gc:
            t.gc_tests()
        if args.destructive:
            t.destructive_tests()
    print(f"\n{PASSES} passed, {len(FAILURES)} failed")
    if FAILURES:
        print("failed: " + "; ".join(FAILURES))
        sys.exit(1)


if __name__ == "__main__":
    main()
