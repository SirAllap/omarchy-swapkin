#!/usr/bin/env bash
# Run: bash tests/qml-dupes.test.sh [file.qml ...]
# Fails when one QML object sets the same property or signal handler twice
# ("Property value set multiple times"). qmllint does not catch this; the
# shell refuses to load the widget. Default: every *.qml in the repo root.
set -uo pipefail
ROOT="$(dirname "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)")"
if (( $# )); then files=("$@"); else files=("$ROOT"/*.qml); fi
python3 -I - "${files[@]}" <<'PY'
import re, sys
bad = 0
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    # blank out comments and strings, keep newlines so line numbers hold
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            while i < n and text[i] != "\n": i += 1
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2); j = n if j < 0 else j + 2
            out.append("".join("\n" if ch == "\n" else " " for ch in text[i:j])); i = j
        elif c in "\"'`":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            out.append(c + "".join("\n" if ch == "\n" else " " for ch in text[i+1:j]) + c); i = j + 1
        else:
            out.append(c); i += 1
    src = "".join(out)
    # stack frames: [kind, seen]; kind "obj" = QML object, "js" = anything else
    stack, line, depth_js = [], 1, 0
    lines = src.split("\n")
    stack = [("obj", {})]
    for ln, row in enumerate(lines, 1):
        k = 0
        while k < len(row):
            top = stack[-1]
            if top[0] == "obj":
                m = re.match(r"\s*(?:default\s+|readonly\s+|required\s+)*(?:property\s+(?:[\w.<>]+\s+)?)?([A-Za-z_][\w.]*)\s*:", row[k:])
                if m and (row[k:].lstrip() == row[k:] or k == 0 or True):
                    name = m.group(1)
                    # only at statement start: previous non-space char is start, ';' or '{' or '}'
                    prev = row[:k].rstrip()
                    if prev == "" or prev[-1] in ";{}":
                        if name in top[1]:
                            print(f"{path}:{ln}: '{name}' set twice in one object (first at line {top[1][name]})")
                            bad += 1
                        else:
                            top[1][name] = ln
                        # skip past the colon; a value that opens an object is handled below
                        k += m.end(); 
                        # value is JS unless it is `Type {`
                        rest = row[k:]
                        if re.match(r"\s*[A-Z][\w.]*\s*\{", rest):
                            continue
                        # a plain value: braces inside belong to JS
                        stack.append(("js", None)); stack.pop()
                        # consume braces in the value as JS blocks
                        depth = 0
                        while k < len(row) and row[k] != ";":
                            if row[k] == "{":
                                stack.append(("js", None))
                            elif row[k] == "}":
                                if stack[-1][0] == "js": stack.pop()
                                else: break
                            k += 1
                        continue
                m2 = re.match(r"\s*(?:[A-Z][\w.]*|on[A-Z]\w*|function\b[^{]*)\s*\{", row[k:]) 
            ch = row[k]
            if ch == "{":
                prevtext = "".join(lines[:ln-1] + [row[:k]]).rstrip()
                is_obj = top[0] == "obj" and re.search(r"(^|[\s:}\]{;])[A-Z][\w.]*$", prevtext) is not None
                stack.append(("obj", {}) if is_obj else ("js", None))
            elif ch == "}":
                if len(stack) > 1: stack.pop()
            k += 1
sys.exit(1 if bad else 0)
PY
rc=$?
if (( rc == 0 )); then echo "qml-dupes: ok"; else echo "qml-dupes: FAIL"; fi
exit $rc
