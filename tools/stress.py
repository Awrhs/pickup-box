#!/usr/bin/env python3
"""Concurrency smoke test (stdlib only): parallel resumable uploads, then a
burst of recipients loading the pickup page, previews, single files (with
Range) and the zip at the same time. Fails on any unexpected status.

  python3 -I tools/stress.py --base http://127.0.0.1 --password PW
"""
import argparse
import concurrent.futures as cf
import hashlib
import os
import sys
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e  # noqa: E402  (reuses its HTTP client and helpers)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1")
    ap.add_argument("--password", required=True)
    ap.add_argument("--insecure", action="store_true")
    ap.add_argument("--uploads", type=int, default=12)
    ap.add_argument("--readers", type=int, default=40)
    args = ap.parse_args()

    t = e2e.T(argparse.Namespace(base=args.base, insecure=args.insecure, password=args.password,
                                 friend=None, short_expiry=False, gc=False, destructive=False))
    problems = []

    # 1. Parallel uploads: mixed sizes, chunked, some sharing identical content.
    shared_blob = os.urandom(3 * 1024 * 1024)
    payloads = []
    for i in range(args.uploads):
        if i % 4 == 0:
            payloads.append(("same-%d.bin" % i, shared_blob))
        elif i % 4 == 1:
            payloads.append(("photo-%d.png" % i, e2e.png_bytes(w=64, h=64, seed=i)))
        else:
            payloads.append(("data-%d.bin" % i, os.urandom((i % 5 + 1) * 1024 * 1024 + i)))

    started = time.time()
    with cf.ThreadPoolExecutor(max_workers=args.uploads) as pool:
        futs = {pool.submit(t.tus_upload, data, name, 512 * 1024): (name, data) for name, data in payloads}
        uploaded = []
        for fut in cf.as_completed(futs):
            name, data = futs[fut]
            h, st, _ = fut.result()
            if h != hashlib.sha256(data).hexdigest():
                problems.append(f"upload {name}: status {st}, hash {h}")
            else:
                uploaded.append((h, name))
    print(f"{len(uploaded)}/{len(payloads)} parallel uploads ok in {time.time() - started:.1f}s")

    st, share = t.share(uploaded, expires_in=3600, title="stress")
    if st != 201:
        print("share creation failed", st, share)
        sys.exit(1)
    slug = share["slug"]
    st, tok, _ = t.open_page(slug)
    q = "t=" + urllib.parse.quote(tok)
    files = sorted(share["files"], key=lambda f: f["seq"])

    # 2. Burst of readers.
    def reader(i):
        f = files[i % len(files)]
        kind = i % 5
        if kind == 0:
            st, _, body = t.c.req("GET", f"/p/{slug}?{q}")
            return st == 200, f"page {st}"
        if kind == 1 and f["kind"] == "image":
            st, hd, body = t.c.req("GET", f"/p/{slug}/f/{f['seq']}/thumb?{q}&s=s",
                                   headers={"Accept": "image/webp"})
            return st == 200 and body[:4] == b"RIFF", f"thumb {st}"
        if kind == 2:
            st, hd, body = t.c.req("GET", f"/p/{slug}/f/{f['seq']}?{q}", headers={"Range": "bytes=0-99"})
            return st == 206 and len(body) == min(100, f["size"]), f"range {st}"
        if kind == 3 and i % 10 == 3:
            st, hd, body = t.c.req("GET", f"/p/{slug}/zip?{q}")
            return st == 200 and len(body) == int(hd.get("content-length", -1)), f"zip {st}"
        st, hd, body = t.c.req("GET", f"/p/{slug}/f/{f['seq']}?{q}")
        return st == 200 and len(body) == f["size"], f"file {st}"

    started = time.time()
    with cf.ThreadPoolExecutor(max_workers=20) as pool:
        results = list(pool.map(reader, range(args.readers)))
    bad = [msg for ok, msg in results if not ok]
    print(f"{len(results) - len(bad)}/{len(results)} concurrent reads ok in {time.time() - started:.1f}s")
    problems.extend(bad)

    st, _, _ = t.c.req("GET", "/readyz")
    if st != 200:
        problems.append(f"readyz {st} after load")

    if problems:
        print("PROBLEMS:", problems)
        sys.exit(1)
    print("stress test passed")


if __name__ == "__main__":
    main()
