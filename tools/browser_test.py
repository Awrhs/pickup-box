#!/usr/bin/env python3
"""Browser end-to-end test of the web UI with Playwright (Chromium).

Sender on an emulated iPhone logs in, picks files (one larger than the 8 MiB
upload chunk), sends them; recipient on an emulated Android phone enters the
pickup code, sees previews, downloads the zip; sender revokes from /me.

  pip install playwright && python -m playwright install --with-deps chromium
  python3 tools/browser_test.py --base http://127.0.0.1 --password PW
"""
import argparse
import os
import re
import struct
import sys
import tempfile
import zipfile
import zlib

from playwright.sync_api import expect, sync_playwright


def png(path, w=64, h=48):
    raw = b"".join(b"\x00" + b"".join(bytes([x * 4 % 256, y * 5 % 256, 200]) for x in range(w)) for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1")
    ap.add_argument("--password", required=True)
    ap.add_argument("--shots", default="browser-shots")
    args = ap.parse_args()
    os.makedirs(args.shots, exist_ok=True)

    tmp = tempfile.mkdtemp()
    photo = os.path.join(tmp, "家庭照片.png")
    note = os.path.join(tmp, "note.txt")
    big = os.path.join(tmp, "video-backup.bin")
    png(photo)
    with open(note, "w", encoding="utf-8") as f:
        f.write("记得带伞\n")
    with open(big, "wb") as f:
        f.write(os.urandom(9 * 1024 * 1024 + 4321))

    with sync_playwright() as p:
        browser = p.chromium.launch()
        sender_ctx = browser.new_context(**p.devices["iPhone 13"], accept_downloads=True)
        page = sender_ctx.new_page()
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.on("console", lambda m: m.type == "error" and errors.append(m.text))

        # ---- sender: log in --------------------------------------------
        page.goto(args.base + "/")
        expect(page.locator("#login")).to_be_visible()
        page.fill("#password", "not-the-password-123")
        page.click("#login button[type=submit]")
        expect(page.locator("#login-error")).to_contain_text("密码不正确")
        page.fill("#password", args.password)
        page.click("#login button[type=submit]")
        expect(page.locator("#composer")).to_be_visible()
        page.screenshot(path=f"{args.shots}/1-composer.png", full_page=True)

        # ---- sender: pick files and send ----------------------------------
        page.set_input_files("#files", [photo, note, big])
        expect(page.locator("#queue li")).to_have_count(3)
        expect(page.locator("#start")).to_be_enabled()
        page.select_option("#expiry", "86400")
        page.fill("#title", "周末照片")
        page.click("#start")
        expect(page.locator(".result .code")).to_be_visible(timeout=120_000)
        code = page.inner_text(".result .code").strip()
        link = page.get_attribute(".result .link a", "href")
        assert re.fullmatch(r"\d{6}", code), code
        assert "/p/" in link, link
        page.wait_for_function("() => { const i = document.querySelector('.result img.qr');"
                               " return i && i.complete && i.naturalWidth > 0; }")
        page.screenshot(path=f"{args.shots}/2-sent.png", full_page=True)
        print("sent: code", code, "link", link)

        # ---- recipient: pickup code on another phone ----------------------
        rec_ctx = browser.new_context(**p.devices["Pixel 7"], accept_downloads=True)
        rp = rec_ctx.new_page()
        rp.on("pageerror", lambda e: errors.append(str(e)))
        rp.goto(args.base + "/")
        rp.fill("input[name=code]", code)
        rp.click("#pickup button")
        expect(rp).to_have_url(re.compile(r"/p/[A-Za-z0-9]+\?t="))
        expect(rp.locator("h1")).to_have_text("周末照片")
        expect(rp.locator(".grid li")).to_have_count(3)
        expect(rp.locator(".grid")).to_contain_text("家庭照片.png")
        rp.wait_for_function("() => [...document.querySelectorAll('.grid img')]"
                             ".every(i => i.complete && i.naturalWidth > 0)")
        rp.screenshot(path=f"{args.shots}/3-pickup.png", full_page=True)

        with rp.expect_download() as dl:
            rp.click("text=全部下载")
        zpath = dl.value.path()
        z = zipfile.ZipFile(zpath)
        assert z.testzip() is None
        names = sorted(z.namelist())
        assert names == sorted(["家庭照片.png", "note.txt", "video-backup.bin"]), names
        assert z.read("video-backup.bin") == open(big, "rb").read()
        assert z.read("note.txt").decode("utf-8") == "记得带伞\n"
        print("zip ok:", names)

        # Single-file download keeps the UTF-8 name.
        with rp.expect_download() as dl2:
            rp.locator(".tile", has_text="note.txt").locator("a.dl").click()
        assert dl2.value.suggested_filename == "note.txt", dl2.value.suggested_filename

        # ---- sender: manage the share on /me ------------------------------
        page.goto(args.base + "/me")
        item = page.locator(".share-list li", has_text="周末照片").first
        expect(item).to_be_visible()
        expect(item).to_contain_text(code)
        page.screenshot(path=f"{args.shots}/4-me.png", full_page=True)
        page.once("dialog", lambda d: d.accept())
        item.locator("text=撤回").click()
        expect(page.locator(".share-list li", has_text="周末照片").first).to_contain_text("已撤回")

        # Recipient reloads: the share is gone.
        rp.reload()
        expect(rp.locator("h1")).to_have_text("分享已撤回")
        rp.screenshot(path=f"{args.shots}/5-revoked.png", full_page=True)

        # Wrong code shows a friendly error.
        rp.goto(args.base + "/")
        rp.fill("input[name=code]", "000000" if code != "000000" else "111111")
        rp.click("#pickup button")
        expect(rp.locator("#pickup .error")).to_be_visible()

        browser.close()

    if errors:
        print("JavaScript errors:", errors)
        sys.exit(1)
    print("browser test passed")


if __name__ == "__main__":
    main()
