#!/usr/bin/env python3
"""Turn the LaTeX math in a Markdown reply into images Qt can show.

Every $…$, \\(…\\), $$…$$ and \\[…\\] span becomes an image; code spans and
fenced blocks are left alone. Output on stdout is a format line ("html" or
"md") followed by the document.

Pipeline: one `latex` run for the whole reply (a page per formula), then
`dvisvgm --exact-bbox` crops each page to its ink, then ImageMagick's rsvg
delegate rasterises it. The Qt build DMS runs in ships no SVG image plugin,
hence PNG. Files are named by a hash of (source, mode, colour, size), so a
formula is only ever rendered once.

SHARPNESS. Each PNG is rendered at --scale times its display size and
placed as <img width=… height=…> at display size, so Qt downsamples it on
any output scale up to --scale. That needs HTML: Qt's Markdown importer
has no image size, and shows an image at its pixel size in logical pixels,
i.e. upscaled (blurry) on a 1.5x output -- @2x variants are not consulted.
So the Markdown, with the images inlined as raw HTML, goes through
cmark-gfm (--cmark) to HTML for a RichText TextEdit. Without cmark-gfm it
falls back to ![math](…) Markdown: right size only at scale 1, blurry above.
(Qt also drops a Markdown image whose alt text is empty.)

ALIGNMENT. Qt can put an inline image's centre on the text's middle
(vertical-align: middle) but cannot offset it by a formula's depth. So each
inline image is padded, top or bottom, until its centre sits on TeX's math
axis (the fraction-bar height), which is about where a UI font's middle
is. That needs each formula's baseline inside its cropped image: every
page starts with an invisible 50pt strut, which pins the baseline at a
known y, and the log reports that y and the axis height.

If the batch fails to compile, formulas are compiled one by one and any
that still fail stay as `inline code` showing their source, so one bad
formula never costs the whole reply.

Usage: render-math.py --out DIR --color '#rrggbb' --px 14 --max-width 420
                      [--scale 3] [--cmark cmark-gfm] TEXT
"""

import argparse
import hashlib
import os
import html
import re
import shutil
import struct
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


STRUT = 50  # pt; taller than any formula, so it alone decides the baseline


def body(tex, display):
    # A zero-width rule is not shipped to the DVI, so it adds no ink.
    return r"\noindent\rule{0pt}{%dpt}" % STRUT + (r"$\displaystyle " if display else "$") + tex + "$"


PT_TO_BP = 72 / 72.27


def metrics(log):
    """(baseline y, axis height) in bp from the \\typeout lines of a run."""
    m = dict(re.findall(r"^CHM-(\w+)=([\d.]+)pt", log, re.M))
    return (float(m["TOP"]) + STRUT) * PT_TO_BP, float(m["AXIS"]) * PT_TO_BP


def compile_pages(items, color, work, stem):
    """Render items [(tex, display)] as pages of one document -> [svg path | None]."""
    doc = PREAMBLE + "\\color[HTML]{%s}\n" % color
    # Top of the text area as dvisvgm places it (DVI origin at the page
    # corner, so no 1in offset), and the axis.
    doc += (r"\typeout{CHM-TOP=\the\dimexpr\voffset+\topmargin+\headheight+\headsep\relax}"
            r"\sbox0{$\typeout{CHM-AXIS=\the\fontdimen22\textfont2}$}" "\n")
    doc += "\n\\newpage\n".join(body(t, d) for t, d in items) + "\n\\end{document}\n"
    with open(os.path.join(work, stem + ".tex"), "w") as f:
        f.write(doc)
    r = run(["latex", "-no-shell-escape", "-interaction=nonstopmode", "-halt-on-error", stem + ".tex"], work)
    if r.returncode != 0:
        return None
    with open(os.path.join(work, stem + ".log"), errors="replace") as f:
        baseline, axis = metrics(f.read())
    r = run(["dvisvgm", "--exact-bbox", "--no-fonts", "--page=1-", "-o", stem + "-%p.svg", stem + ".dvi"], work)
    if r.returncode != 0:
        return None
    pages = []
    for i in range(1, len(items) + 1):
        # dvisvgm pads %p to the width of the page count.
        cands = [os.path.join(work, "%s-%s.svg" % (stem, str(i).zfill(w))) for w in (1, 2, 3)]
        pages.append(next((c for c in cands if os.path.exists(c)), None))
    return [(p, baseline, axis) if p else None for p in pages]


def axis_padding(svg, baseline, axis):
    """(top, bottom) bp to add so the image's centre lies on the math axis."""
    with open(svg) as f:
        vb = re.search(r"viewBox=['\"]([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+)", f.read())
    y, h = float(vb.group(2)), float(vb.group(4))
    above = (baseline - y) - axis      # ink above the axis
    below = (y + h - baseline) + axis  # ink below it
    return (below - above, 0) if below > above else (0, above - below)


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return struct.unpack(">II", head[16:24])  # IHDR width, height


def rasterise(svg, png, density, max_w, pad=(0, 0)):
    px = [round(bp * density / 72) for bp in pad]
    r = subprocess.run(
        ["magick", "-background", "none", "-density", str(density), svg,
         "-gravity", "north", "-splice", "0x%d" % px[0],
         "-gravity", "south", "-splice", "0x%d" % px[1],
         "-resize", "%dx>" % max_w, png],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
    )
    return r.returncode == 0 and os.path.exists(png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--color", default="#e6e1e5")
    ap.add_argument("--px", type=float, default=14)
    ap.add_argument("--max-width", type=int, default=420)
    ap.add_argument("--scale", type=float, default=3)
    ap.add_argument("--cmark", default="cmark-gfm")
    ap.add_argument("text")
    a = ap.parse_args()

    color = a.color.lstrip("#")[-6:].upper()  # Qt may hand over #aarrggbb
    os.makedirs(a.out, exist_ok=True)
    cmark = shutil.which(a.cmark)
    scale = a.scale if cmark else 1  # the Markdown fallback cannot downsample
    # 12pt TeX at D dpi is D/6 px tall, so D = 6 * display px * scale.
    # Computer Modern reads small beside a UI sans, hence the 1.2.
    density = round(6 * 1.2 * a.px * scale)

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
        key = hashlib.sha1(("v2|%s|%d|%s|%s" % (tex, display, color, density)).encode()).hexdigest()[:16]
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
            for item, page in zip(todo, pages):
                png = names[item]
                pad = (0, 0)
                if page and not item[1]:  # inline: centre on the axis
                    pad = axis_padding(*page)
                if not page or not rasterise(page[0], png, density, round(a.max_width * scale), pad):
                    names.pop(item)

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
        elif not cmark:
            img = "![math](file://%s)" % png
            out.append("\n\n%s\n\n" % img if display else img)
        else:
            w, h = png_size(png)
            img = '<img src="file://%s" alt="%s" width="%d" height="%d"%s />' % (
                png, html.escape(tex), round(w / scale), round(h / scale),
                "" if display else ' style="vertical-align: middle"')
            # A raw HTML block must start a line and end at a blank one. div, not
            # p: Qt's rich text ignores align on a <p> holding only an image.
            out.append('\n\n<div align="center">%s</div>\n\n' % img if display else img)
    out.append(a.text[pos:])
    doc = "".join(out)

    if cmark:
        r = subprocess.run(
            [cmark, "--unsafe", "-e", "table", "-e", "strikethrough", "-e", "autolink"],
            input=doc.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
        )
        if r.returncode == 0:
            sys.stdout.write("html\n" + r.stdout.decode())
            return
    sys.stdout.write("md\n" + doc)


if __name__ == "__main__":
    main()
