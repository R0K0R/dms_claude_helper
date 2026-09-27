#!/usr/bin/env python3
"""Turn the LaTeX math in a Markdown reply into images Qt can show.

Qt's MarkdownText has no math support but does render local images, so
every $…$, \\(…\\), $$…$$ and \\[…\\] span becomes ![math](file:///….png), and the
rewritten Markdown is printed on stdout. Code spans and fenced blocks are
left alone.

Pipeline: one `latex` run for the whole reply (a page per formula), then
`dvisvgm --exact-bbox` crops each page to its ink, then ImageMagick's rsvg
delegate rasterises it. The Qt build DMS runs in ships no SVG image plugin,
hence PNG. Each formula is written at 1x and as name@2x.png, which Qt's
pixmap loader picks on HiDPI outputs. The alt text must not be empty: Qt's
Markdown importer silently drops images with an empty alt. Files are named by a hash of
(source, mode, colour, size), so a formula is only ever rendered once.

If the batch fails to compile, formulas are compiled one by one and any
that still fail stay as `inline code` showing their source, so one bad
formula never costs the whole reply.

Usage: render-math.py --out DIR --color '#rrggbb' --px 14 --max-width 420 TEXT
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys
import tempfile

PREAMBLE = r"""\documentclass[12pt]{article}
\usepackage{amsmath,amssymb,mathtools,bm,xcolor}
\pagestyle{empty}
\begin{document}
"""

# Model-written TeX is derived from whatever was on screen, so treat it as
# untrusted: no file or shell access, no catcode games.
FORBIDDEN = re.compile(
    r"\\(input|include|openin|openout|read|write|immediate|catcode|csname|"
    r"special|usepackage|documentclass|def|let|newcommand|renewcommand|"
    r"directlua|pdfprimitive|scantokens|jobname|endinput|loop)\b"
)

MATH = re.compile(
    r"""
      (?P<fence>^[ \t]*(?P<fc>```|~~~).*?^[ \t]*(?P=fc)[ \t]*$)   # fenced code block
    | (?P<code>(?P<tk>`+)(?:.|\n)*?(?<!`)(?P=tk)(?!`))            # inline code span
    | (?P<esc>\\\$)                                   # escaped dollar
    | \$\$(?P<d1>.+?)\$\$                             # $$ display $$
    | \\\[(?P<d2>.+?)\\\]                             # \[ display \]
    | \\\((?P<i1>.+?)\\\)                             # \( inline \)
    | (?<![\\$\w])\$(?P<i2>[^\s$](?:[^$\n]*?[^\s$\\])?)\$(?![\d$])   # $ inline $
    """,
    re.DOTALL | re.MULTILINE | re.VERBOSE,
)


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)


def body(tex, display):
    return (r"$\displaystyle " if display else "$") + tex + "$"


def compile_pages(items, color, work, stem):
    """Render items [(tex, display)] as pages of one document -> [svg path | None]."""
    doc = PREAMBLE + "\\color[HTML]{%s}\n" % color
    doc += "\n\\newpage\n".join(body(t, d) for t, d in items) + "\n\\end{document}\n"
    with open(os.path.join(work, stem + ".tex"), "w") as f:
        f.write(doc)
    r = run(["latex", "-no-shell-escape", "-interaction=nonstopmode", "-halt-on-error", stem + ".tex"], work)
    if r.returncode != 0:
        return None
    r = run(["dvisvgm", "--exact-bbox", "--no-fonts", "--page=1-", "-o", stem + "-%p.svg", stem + ".dvi"], work)
    if r.returncode != 0:
        return None
    pages = []
    for i in range(1, len(items) + 1):
        # dvisvgm pads %p to the width of the page count.
        cands = [os.path.join(work, "%s-%s.svg" % (stem, str(i).zfill(w))) for w in (1, 2, 3)]
        pages.append(next((c for c in cands if os.path.exists(c)), None))
    return pages


def rasterise(svg, png, density, max_w):
    r = subprocess.run(
        ["magick", "-background", "none", "-density", str(density), svg, "-resize", "%dx>" % max_w, png],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
    )
    return r.returncode == 0 and os.path.exists(png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--color", default="#e6e1e5")
    ap.add_argument("--px", type=float, default=14)
    ap.add_argument("--max-width", type=int, default=420)
    ap.add_argument("text")
    a = ap.parse_args()

    color = a.color.lstrip("#")[-6:].upper()  # Qt may hand over #aarrggbb
    os.makedirs(a.out, exist_ok=True)
    # 12pt TeX at D dpi is D/6 px tall, so D = 6 * target px (and 2x for @2x).
    # Computer Modern reads small and thin beside a UI sans, hence the 1.5.
    density = round(6 * 1.5 * a.px)

    spans = []  # (match, tex, display) for every math match, in order
    for m in MATH.finditer(a.text):
        for key, display in (("d1", True), ("d2", True), ("i1", False), ("i2", False)):
            if m.group(key) is not None:
                spans.append((m, m.group(key).strip(), display))

    names = {}
    todo = []
    for _, tex, display in spans:
        if not tex or FORBIDDEN.search(tex):
            continue
        key = hashlib.sha1(("%s|%d|%s|%s" % (tex, display, color, density)).encode()).hexdigest()[:16]
        png = os.path.join(a.out, key + ".png")
        names[(tex, display)] = png
        if not os.path.exists(png) and (tex, display) not in todo:
            todo.append((tex, display))

    if todo:
        with tempfile.TemporaryDirectory() as work:
            pages = compile_pages(todo, color, work, "all")
            if pages is None:  # find the culprit(s) the slow way
                pages = []
                for i, item in enumerate(todo):
                    p = compile_pages([item], color, work, "one%d" % i)
                    pages.append(p[0] if p else None)
            for item, svg in zip(todo, pages):
                png = names[item]
                if not svg or not rasterise(svg, png, density, a.max_width):
                    names.pop(item)
                    continue
                rasterise(svg, png[:-4] + "@2x.png", density * 2, a.max_width * 2)

    out, pos = [], 0
    for m in MATH.finditer(a.text):
        out.append(a.text[pos:m.start()])
        pos = m.end()
        if m.group("fence") or m.group("code"):
            out.append(m.group(0))
            continue
        if m.group("esc"):
            out.append(m.group(0))  # Markdown turns \$ into $
            continue
        display = m.group("d1") is not None or m.group("d2") is not None
        tex = next(m.group(k) for k in ("d1", "d2", "i1", "i2") if m.group(k) is not None).strip()
        png = names.get((tex, display))
        if not png:
            out.append("`%s`" % m.group(0).replace("`", "'"))
        elif display:
            out.append("\n\n![math](file://%s)\n\n" % png)
        else:
            out.append("![math](file://%s)" % png)
    out.append(a.text[pos:])
    sys.stdout.write("".join(out))


if __name__ == "__main__":
    main()
