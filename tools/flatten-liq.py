#!/usr/bin/env python3
"""Разворачивает %include в один плоский файл.

    python3 tools/flatten-liq.py <путь к index.liq>

Нужен, чтобы рефакторинг .liq был доказуемым: разложив скрипт по lib/,
сравниваем плоский результат с тем, что был до правки. Разница должна
быть только в том, что менялось намеренно.

Комментарии и пустые строки выбрасываются — они на поведение не влияют,
а в диффе только шумят.
"""

import pathlib
import re
import sys

INCLUDE = re.compile(r'^\s*%include\s+"([^"]+)"\s*$')


def flatten(path, seen=None):
    path = path.resolve()
    seen = seen or []
    if path in seen:
        raise SystemExit(f"циклический %include: {path}")

    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        match = INCLUDE.match(line)
        if match:
            out.extend(flatten(path.parent / match.group(1), seen + [path]))
        else:
            out.append(line)
    return out


def normalize(lines):
    result = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # схлопываем внутренние пробелы: перенос кода между файлами
        # часто меняет отступ, но не смысл
        result.append(re.sub(r"\s+", " ", stripped))
    return result


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    print("\n".join(normalize(flatten(pathlib.Path(sys.argv[1])))))
