#!/usr/bin/env python3
"""Regenerate the `env NAME;` block in conf/nginx.conf from every
os.getenv("NAME") used under lua/. With --check, fail if it is stale."""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
names = set()
for f in (root / "lua").rglob("*.lua"):
    text = f.read_text(encoding="utf-8")
    names.update(re.findall(r'os\.getenv\("([A-Z0-9_]+)"\)', text))
    # Helper wrappers such as env("NAME") / size_env("NAME", ...) in config modules.
    names.update(re.findall(r'\b(?:env|size_env|dur_env|int_env)\("([A-Z0-9_]+)"', text))
block = "".join(f"env {n};\n" for n in sorted(names))

conf_path = root / "conf" / "nginx.conf"
conf = conf_path.read_text(encoding="utf-8")
start, end = "#@ENV@\n", "#@END_ENV@\n"
if start in conf and end in conf:
    new = conf[:conf.index(start) + len(start)] + block + conf[conf.index(end):]
elif "#@ENV@" in conf:
    new = conf.replace("#@ENV@", start + block + end.rstrip("\n"), 1)
else:
    sys.exit("conf/nginx.conf has no #@ENV@ marker")

if "--check" in sys.argv:
    if new != conf:
        sys.exit("conf/nginx.conf env block is stale: run tools/gen_env.py")
    print(f"env block OK ({len(names)} variables)")
else:
    conf_path.write_text(new, encoding="utf-8")
    print(f"wrote {len(names)} env declarations")
