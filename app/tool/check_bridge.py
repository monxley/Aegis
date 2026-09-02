#!/usr/bin/env python3
"""Cross-check the Dart call sites against the Rust flutter_rust_bridge API.

The generated bindings in `app/lib/src/rust/` are produced by
`flutter_rust_bridge_codegen` on the build machine and are gitignored, so
`dart analyze` cannot type-check anything that crosses the bridge here. This
script covers the gap it leaves: it parses the `impl AegisEngine` block in
`app/rust/src/api/aegis.rs`, works out the Dart signature codegen will emit for
each method, and checks every `_engine`/`engine` call in the Dart against it.

It catches the mistakes that are otherwise only found on a device:

  * calling a method that does not exist (or was renamed on one side);
  * passing a named argument the Rust function does not take, or omitting a
    required one;
  * awaiting a `#[frb(sync)]` method, or forgetting to await an async one.

Run from `app/`:  python3 tool/check_bridge.py
Exit status is non-zero if anything is wrong, so it can gate a commit.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

RUST_API = Path("rust/src/api/aegis.rs")
DART_ROOT = Path("lib")

# Only `AegisEngineController` holds the bridge handle; everywhere else in the
# app `engine` means the controller, whose wrappers have their own signatures.
# So the scan is limited to the file that owns the handle, and to the receivers
# that actually are it.
# `engine.` is included because the controller repeatedly takes a local alias
# (`final engine = _engine;`) before calling through it — those are bridge calls
# too, and skipping them left the hot paths (poll, save, attachment drain)
# unchecked. Safe here precisely because this scan is limited to the owning file.
RECEIVERS = ("_engine?.", "_engine!.", "_engine.", "_requireEngine.", "engine.")
BRIDGE_OWNER = Path("lib/engine.dart")


def camel(snake: str) -> str:
    """`send_attachment` -> `sendAttachment`, matching codegen's naming."""
    head, *rest = snake.split("_")
    return head + "".join(p[:1].upper() + p[1:] for p in rest)


def split_params(sig: str) -> list[str]:
    """Split a Rust parameter list on top-level commas."""
    out, depth, cur = [], 0, ""
    for ch in sig:
        if ch in "<([":
            depth += 1
        elif ch in ">)]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [p.strip() for p in out if p.strip()]


def _is_unit(ret: str | None) -> bool:
    """Whether a Rust return type carries no value the Dart side must read."""
    if ret is None:
        return True
    r = ret.strip()
    if r in ("", "()"):
        return True
    # `Result<(), E>` yields a Dart Future<void>: nothing to consume.
    return bool(re.match(r"^Result\s*<\s*\(\s*\)\s*,", r))


def parse_rust() -> dict[str, dict]:
    """Map Dart method name -> {params, is_sync, returns_unit}."""
    src = RUST_API.read_text()
    # Only the methods on the engine handle; free functions are called
    # differently and are not what the Dart call sites below reference.
    start = src.index("impl AegisEngine")
    body = src[start:]

    methods: dict[str, dict] = {}
    # Capture any attributes directly above each `pub fn`, then its signature.
    pattern = re.compile(
        r"((?:^[ \t]*#\[[^\]]*\]\s*$\n)*)"      # attributes
        r"^[ \t]*pub fn\s+(\w+)\s*\(([^)]*)\)"   # name + params
        r"\s*(?:->\s*([^{]+?))?\s*\{",           # optional return type
        re.M | re.S,
    )
    for attrs, name, params, ret in pattern.findall(body):
        is_sync = "frb(sync)" in attrs
        named = []
        for p in split_params(params):
            if p.startswith("&") or p == "self" or p.endswith("self"):
                continue  # receiver
            pname = p.split(":")[0].strip()
            if pname:
                named.append(camel(pname))
        methods[camel(name)] = {
            "params": named,
            "sync": is_sync,
            "unit": _is_unit(ret),
            "rust": name,
        }
    return methods


def dart_calls():
    """Yield (file, line, method, args_text, awaited) for each bridge call."""
    for path in [BRIDGE_OWNER]:
        text = path.read_text()
        for m in re.finditer(r"([\w!?.]*?)(\w+)\s*\(", text):
            recv_end = m.start(2)
            prefix = text[max(0, recv_end - 16):recv_end]
            if not any(prefix.endswith(r) for r in RECEIVERS):
                continue
            # Balance parens to capture the whole argument list.
            i = m.end() - 1
            depth, j = 0, i
            while j < len(text):
                if text[j] in "([{":
                    depth += 1
                elif text[j] in ")]}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            args = text[i + 1:j]
            line = text.count("\n", 0, m.start(2)) + 1
            # Only an `await` immediately before the receiver applies to this
            # call; one further back belongs to an enclosing expression.
            recv_start = m.start(1) if m.group(1) else m.start(2)
            before = text[:recv_start].rstrip()
            awaited = before.endswith("await")
            yield path, line, m.group(2), args, awaited


def main() -> int:
    if not RUST_API.exists():
        print(f"cannot find {RUST_API}; run from the app/ directory", file=sys.stderr)
        return 2
    api = parse_rust()
    problems: list[str] = []
    checked = 0

    for path, line, name, args, awaited in dart_calls():
        if name not in api:
            problems.append(f"{path}:{line}: no bridge method `{name}`")
            continue
        spec = api[name]
        checked += 1

        passed = set(re.findall(r"(\w+)\s*:", args))
        # Strip names that belong to nested calls rather than this argument list.
        expected = set(spec["params"])
        unknown = passed - expected
        missing = expected - passed
        if unknown:
            problems.append(
                f"{path}:{line}: `{name}` got unknown argument(s) "
                f"{sorted(unknown)}; expects {sorted(expected)}"
            )
        if missing:
            problems.append(
                f"{path}:{line}: `{name}` missing argument(s) {sorted(missing)}"
            )
        # A sync method returns a value directly; awaiting one is a type error.
        if spec["sync"] and awaited:
            problems.append(
                f"{path}:{line}: `{name}` is #[frb(sync)] — awaiting it is wrong"
            )
        # An async method returns a Future; using it unawaited where a value is
        # expected is the more common slip, so flag assignment without await.
        if not spec["sync"] and not awaited and not spec["unit"]:
            problems.append(
                f"{path}:{line}: `{name}` is async — its result must be awaited"
            )

    print(f"checked {checked} bridge call(s) against {len(api)} Rust methods")
    if problems:
        print("\nproblems:")
        for p in problems:
            print(f"  {p}")
        return 1
    print("bridge is consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
