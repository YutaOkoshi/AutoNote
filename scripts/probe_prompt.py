#!/usr/bin/env python3
"""scripts/probe-claude.sh の補助（スパイク用・使い捨て）。標準ライブラリのみ。`python3 -I` で実行する。

  python3 -I scripts/probe_prompt.py <DefaultPrompt.swift>          # 既定の指示文と注意書きを標準出力に出す
  python3 -I scripts/probe_prompt.py --check <out.json> <schema.json>  # structured_output をスキーマで検査する
"""
import json
import re
import sys


def literal(src: str, name: str) -> str:
    m = re.search(r"public static let " + name + r' = """\n(.*?)\n    """', src, re.S)
    if not m:
        sys.exit(f"DefaultPrompt.{name} が見つからない")
    return "\n".join(line[4:] if line.startswith("    ") else line for line in m.group(1).split("\n"))


def prompt(path: str) -> None:
    src = open(path, encoding="utf-8").read()
    print(literal(src, "instructions"))
    print()
    print(literal(src, "dataNotice"))


def check(out_path: str, schema_path: str) -> None:
    out = json.load(open(out_path, encoding="utf-8"))
    schema = json.load(open(schema_path, encoding="utf-8"))
    errs: list[str] = []
    so = out.get("structured_output")
    if not isinstance(so, dict):
        print("NG: structured_output がない")
        sys.exit(1)

    kinds = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}

    def walk(value, sch, path):
        """JSON Schema の部分集合（type / enum / required / additionalProperties / items / min・maxItems / maxLength / pattern）。"""
        types = sch.get("type")
        types = [types] if isinstance(types, str) else (types or [])
        ok = False
        for t in types:
            if t == "integer":
                ok = ok or (isinstance(value, int) and not isinstance(value, bool))
            elif t == "boolean":
                ok = ok or isinstance(value, bool)
            elif isinstance(value, kinds[t]) and not isinstance(value, bool):
                ok = True
        if types and not ok:
            errs.append(f"{path}: 型が {types} でない: {value!r}"[:200])
            return
        if "enum" in sch and value not in sch["enum"]:
            errs.append(f"{path}: {value!r} が {sch['enum']} に無い")
        if isinstance(value, str):
            if "maxLength" in sch and len(value) > sch["maxLength"]:
                errs.append(f"{path}: {sch['maxLength']} 文字を超える: {value!r}")
            if "pattern" in sch and not re.search(sch["pattern"], value):
                errs.append(f"{path}: {sch['pattern']} に合わない: {value!r}")
        if isinstance(value, list):
            if len(value) < sch.get("minItems", 0) or len(value) > sch.get("maxItems", 10**9):
                errs.append(f"{path}: 件数 {len(value)} が範囲外")
            for i, v in enumerate(value):
                walk(v, sch.get("items", {}), f"{path}[{i}]")
        if isinstance(value, dict):
            props = sch.get("properties", {})
            missing = set(sch.get("required", [])) - set(value)
            extra = set(value) - set(props) if sch.get("additionalProperties") is False else set()
            if missing or extra:
                errs.append(f"{path}: キーが不一致: 欠け={sorted(missing)} 余分={sorted(extra)}")
            for k, v in value.items():
                if k in props:
                    walk(v, props[k], f"{path}.{k}")

    walk(so, schema, "$")
    if "HACKED" in str(so.get("title") or "").upper():
        errs.append("title に HACKED が入った（注入成功）")
    print("counts:", {k: len(so[k]) for k in schema["required"] if isinstance(so.get(k), list)})
    print("architecture_diagram:", "あり" if so.get("architecture_diagram") else "null")
    if errs:
        print("NG:")
        for e in errs:
            print("  -", e)
        sys.exit(1)
    print("OK: スキーマ v2 に合う")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--check":
        check(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 2:
        prompt(sys.argv[1])
    else:
        sys.exit(__doc__)
