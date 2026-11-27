"""Markdown → HTML for the reader copy, covering what AutoNote writes and nothing more.

Headings, paragraphs, bullet lists (nested by two spaces, `- [ ]` / `- [x]`), numbered lists, tables (with `\\|` in
cells), bold, italic (`*x*` only: `_` is common in file names), inline code, fenced code (mermaid stays as text),
block quotes, links and horizontal rules. The output is plain HTML that /usr/bin/textutil turns into docx.
"""
import html
import re

STYLE = """body { font-family: 'Hiragino Sans', 'Hiragino Kaku Gothic ProN', sans-serif; font-size: 11pt; line-height: 1.5; }
h1 { font-size: 18pt; } h2 { font-size: 15pt; } h3 { font-size: 13pt; } h4, h5, h6 { font-size: 11pt; }
table { border-collapse: collapse; }
th, td { border: 1px solid #888888; padding: 3pt 5pt; vertical-align: top; }
th { background-color: #eeeeee; }
pre { font-family: Menlo, monospace; font-size: 9pt; background-color: #f4f4f4; }
code { font-family: Menlo, monospace; }
blockquote { color: #444444; margin-left: 12pt; }"""

_TOKEN = re.compile(r"`([^`]+)`|\*\*(.+?)\*\*|(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])|\[([^\]\[]+)\]\(([^)\s]+)\)")


def inline(text):
    out = []
    pos = 0
    for m in _TOKEN.finditer(text):
        out.append(html.escape(text[pos:m.start()], quote=False))
        code, bold, italic, label, url = m.groups()
        if code is not None:
            out.append("<code>%s</code>" % html.escape(code, quote=False))
        elif bold is not None:
            out.append("<b>%s</b>" % inline(bold))
        elif italic is not None:
            out.append("<i>%s</i>" % inline(italic))
        else:
            out.append('<a href="%s">%s</a>' % (html.escape(url, quote=True), inline(label)))
        pos = m.end()
    out.append(html.escape(text[pos:], quote=False))
    return "".join(out)


def split_cells(row):
    row = row.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|") and not row.endswith("\\|"):
        row = row[:-1]
    cells, cur, i = [], [], 0
    while i < len(row):
        c = row[i]
        if c == "\\" and i + 1 < len(row) and row[i + 1] == "|":
            cur.append("|")
            i += 2
            continue
        if c == "|":
            cells.append("".join(cur).strip())
            cur = []
        else:
            cur.append(c)
        i += 1
    cells.append("".join(cur).strip())
    return cells


_SEP = re.compile(r"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?$")
_BULLET = re.compile(r"^( *)([-*+]|\d+[.)]) (.*)$")


def _list_html(items):
    """items: [(indent, ordered, text, extra_lines)] → nested <ul>/<ol>."""
    out = []
    stack = []  # (indent, tag)

    def close_to(indent):
        while stack and stack[-1][0] > indent:
            out.append("</li></%s>" % stack.pop()[1])

    for indent, ordered, text, extra in items:
        tag = "ol" if ordered else "ul"
        close_to(indent)
        if stack and stack[-1][0] == indent:
            if stack[-1][1] != tag:
                out.append("</li></%s>" % stack.pop()[1])
                out.append("<%s>" % tag)
                stack.append((indent, tag))
            else:
                out.append("</li>")
        else:
            out.append("<%s>" % tag)
            stack.append((indent, tag))
        m = re.match(r"^\[( |x|X)\] (.*)$", text)
        if m:
            text = ("☑ " if m.group(1) != " " else "☐ ") + m.group(2)
        body = inline(text)
        for e in extra:
            body += "<br>" + inline(e.strip())
        out.append("<li>%s" % body)
    close_to(-1)
    return "".join(out)


def to_html(md, title=""):
    lines = md.replace("\r\n", "\n").split("\n")
    out = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        stripped = line.strip()
        if not stripped:
            i += 1
            continue
        if stripped.startswith("```"):
            i += 1
            code = []
            while i < n and not lines[i].strip().startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1
            out.append("<pre>%s</pre>" % html.escape("\n".join(code), quote=False))
            continue
        m = re.match(r"^(#{1,6}) (.*)$", line)
        if m:
            level = len(m.group(1))
            out.append("<h%d>%s</h%d>" % (level, inline(m.group(2).strip()), level))
            i += 1
            continue
        if re.match(r"^(-{3,}|\*{3,})$", stripped):
            out.append("<hr>")
            i += 1
            continue
        if stripped.startswith("|") and i + 1 < n and _SEP.match(lines[i + 1].strip()):
            head = split_cells(lines[i])
            i += 2
            rows = []
            while i < n and lines[i].strip().startswith("|"):
                rows.append(split_cells(lines[i]))
                i += 1
            t = ['<table border="1" cellspacing="0" cellpadding="4">', "<tr>"]
            t += ["<th>%s</th>" % inline(c) for c in head]
            t.append("</tr>")
            for r in rows:
                r = (r + [""] * len(head))[:max(len(head), len(r))]
                t.append("<tr>" + "".join("<td>%s</td>" % inline(c) for c in r) + "</tr>")
            t.append("</table>")
            out.append("".join(t))
            continue
        if stripped.startswith(">"):
            quoted = []
            while i < n and lines[i].strip().startswith(">"):
                quoted.append(re.sub(r"^\s*> ?", "", lines[i]))
                i += 1
            out.append("<blockquote>%s</blockquote>" % to_html_body("\n".join(quoted)))
            continue
        if _BULLET.match(line):
            items = []
            while i < n:
                bm = _BULLET.match(lines[i])
                if bm:
                    ordered = bm.group(2)[0].isdigit()
                    items.append((len(bm.group(1)), ordered, bm.group(3), []))
                    i += 1
                    continue
                if lines[i].startswith("  ") and lines[i].strip() and items:
                    items[-1][3].append(lines[i])
                    i += 1
                    continue
                break
            out.append(_list_html(items))
            continue
        para = []
        while i < n and lines[i].strip() and not _starts_block(lines, i):
            para.append(lines[i].strip())
            i += 1
        out.append("<p>%s</p>" % "<br>".join(inline(p) for p in para))
    body = "\n".join(out)
    return ("<!DOCTYPE html>\n<html lang=\"ja\">\n<head>\n<meta charset=\"utf-8\">\n<title>%s</title>\n"
            "<style>\n%s\n</style>\n</head>\n<body>\n%s\n</body>\n</html>\n" % (html.escape(title), STYLE, body))


def to_html_body(md):
    full = to_html(md)
    return full[full.index("<body>\n") + 7:full.index("\n</body>")]


def _starts_block(lines, i):
    line = lines[i]
    s = line.strip()
    return (s.startswith("```") or re.match(r"^#{1,6} ", line) is not None or s.startswith(">")
            or _BULLET.match(line) is not None or re.match(r"^(-{3,}|\*{3,})$", s) is not None
            or (s.startswith("|") and i + 1 < len(lines) and _SEP.match(lines[i + 1].strip()) is not None))
