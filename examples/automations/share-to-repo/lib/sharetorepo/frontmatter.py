"""The small part of YAML frontmatter that AutoNote writes: one `key: value` per line."""
import re

_KEY = re.compile(r"^([A-Za-z0-9_]+):(.*)$")


def split_document(text):
    """Returns (frontmatter lines without the --- fences, body). No frontmatter: ([], text)."""
    text = text.replace("\r\n", "\n")
    if not text.startswith("---\n"):
        return [], text
    end = text.find("\n---\n", 3)
    if end < 0:
        if text.endswith("\n---"):
            end = len(text) - 4
        else:
            return [], text
    fm = text[4:end].split("\n") if end > 4 else []
    body = text[end + 5:]
    return fm, body


def unquote(value):
    v = value.strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        out, i, inner = [], 0, v[1:-1]
        while i < len(inner):
            c = inner[i]
            if c == "\\" and i + 1 < len(inner):
                nxt = inner[i + 1]
                out.append({"n": "\n", "t": "\t"}.get(nxt, nxt))
                i += 2
                continue
            out.append(c)
            i += 1
        return "".join(out)
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        return v[1:-1].replace("''", "'")
    return v


def quote(value):
    v = (value or "").replace("\r", " ").replace("\n", " ")
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'


def parse(lines):
    values = {}
    for line in lines:
        m = _KEY.match(line)
        if m and m.group(1) not in values:
            values[m.group(1)] = unquote(m.group(2))
    return values


def raw_line(lines, key):
    for line in lines:
        m = _KEY.match(line)
        if m and m.group(1) == key:
            return line
    return None


def without_keys(lines, keys):
    out = []
    for line in lines:
        m = _KEY.match(line)
        if m and m.group(1) in keys:
            continue
        out.append(line)
    return out


def read_file(path):
    with open(path, encoding="utf-8") as f:
        fm, _ = split_document(f.read())
    return parse(fm)


def set_value(text, key, rendered):
    """Replaces `key: …` inside the frontmatter of text (rendered is the value as it should be written)."""
    fm, body = split_document(text)
    if not fm:
        return text
    lines = []
    found = False
    for line in fm:
        m = _KEY.match(line)
        if m and m.group(1) == key:
            lines.append("%s: %s" % (key, rendered))
            found = True
        else:
            lines.append(line)
    if not found:
        lines.append("%s: %s" % (key, rendered))
    return "---\n" + "\n".join(lines) + "\n---\n" + body
