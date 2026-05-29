#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

try:
    from pycparser import c_ast, c_generator, parse_file
except ImportError as exc:
    print(
        "error: pycparser is required. Install in a venv, e.g.:\n"
        "  python3 -m venv .venv\n"
        "  . .venv/bin/activate\n"
        "  pip install pycparser",
        file=sys.stderr,
    )
    raise SystemExit(2) from exc


@dataclass
class RenameStats:
    functions: int = 0
    variables: int = 0
    params: int = 0
    labels: int = 0


class LabelCollector(c_ast.NodeVisitor):
    def __init__(self) -> None:
        self.labels: List[str] = []

    def visit_Label(self, node: c_ast.Label) -> None:
        self.labels.append(node.name)
        self.generic_visit(node)


class Renamer(c_ast.NodeVisitor):
    def __init__(self, prefix: str, rename_nonstatic: bool, explicit_map: Dict[str, str]) -> None:
        self.prefix = prefix
        self.rename_nonstatic = rename_nonstatic
        self.counter = 0
        self.stats = RenameStats()
        self.global_map: Dict[str, str] = {}
        self.scope_stack: List[Dict[str, str]] = []
        self.label_map: Dict[str, str] = {}
        self.explicit_map = explicit_map

    def _next(self, kind: str) -> str:
        self.counter += 1
        return f"{self.prefix}{kind}_{self.counter}"

    def _name_for(self, old: str, kind: str) -> str:
        return self.explicit_map.get(old, self._next(kind))

    @staticmethod
    def _is_typedef_decl(decl: c_ast.Decl) -> bool:
        return "typedef" in (decl.storage or [])

    @staticmethod
    def _is_func_decl(decl: c_ast.Decl) -> bool:
        t = decl.type
        return isinstance(t, c_ast.FuncDecl)

    @staticmethod
    def _set_decl_name(t: c_ast.Node, new_name: str) -> None:
        cur = t
        while True:
            if isinstance(cur, c_ast.TypeDecl):
                cur.declname = new_name
                return
            if hasattr(cur, "type"):
                cur = cur.type
                continue
            return

    def _push_scope(self) -> None:
        self.scope_stack.append({})

    def _pop_scope(self) -> None:
        self.scope_stack.pop()

    def _bind_local(self, old: str, new: str) -> None:
        self.scope_stack[-1][old] = new

    def _lookup(self, name: str) -> Optional[str]:
        for scope in reversed(self.scope_stack):
            if name in scope:
                return scope[name]
        return self.global_map.get(name)

    def _should_rename_global_decl(self, decl: c_ast.Decl) -> bool:
        if self._is_typedef_decl(decl) or not decl.name:
            return False
        st = set(decl.storage or [])
        if "extern" in st:
            return False
        if self.rename_nonstatic:
            return True
        return "static" in st

    def build_global_map(self, ast: c_ast.FileAST) -> None:
        for ext in ast.ext:
            if isinstance(ext, c_ast.FuncDef):
                d = ext.decl
                if d.name and self._should_rename_global_decl(d):
                    if d.name not in self.global_map:
                        self.global_map[d.name] = self._name_for(d.name, "fn")
                        self.stats.functions += 1
            elif isinstance(ext, c_ast.Decl):
                if not ext.name:
                    continue
                if self._is_func_decl(ext):
                    if self._should_rename_global_decl(ext):
                        if ext.name not in self.global_map:
                            self.global_map[ext.name] = self._name_for(ext.name, "fn")
                            self.stats.functions += 1
                else:
                    if self._should_rename_global_decl(ext):
                        if ext.name not in self.global_map:
                            self.global_map[ext.name] = self._name_for(ext.name, "gv")
                            self.stats.variables += 1

    def rename(self, ast: c_ast.FileAST) -> c_ast.FileAST:
        self._push_scope()
        self.visit(ast)
        self._pop_scope()
        return ast

    def visit_FileAST(self, node: c_ast.FileAST) -> None:
        for ext in node.ext:
            self.visit(ext)

    def visit_Compound(self, node: c_ast.Compound) -> None:
        self._push_scope()
        if node.block_items:
            for stmt in node.block_items:
                self.visit(stmt)
        self._pop_scope()

    def visit_FuncDef(self, node: c_ast.FuncDef) -> None:
        old_name = node.decl.name
        if old_name in self.global_map:
            new_name = self.global_map[old_name]
            node.decl.name = new_name
            self._set_decl_name(node.decl.type, new_name)

        collector = LabelCollector()
        collector.visit(node.body)
        self.label_map = {name: self._name_for(name, "lbl") for name in collector.labels}
        self.stats.labels += len(self.label_map)

        self._push_scope()

        fdecl = node.decl.type
        if isinstance(fdecl, c_ast.FuncDecl) and fdecl.args and fdecl.args.params:
            for p in fdecl.args.params:
                if isinstance(p, c_ast.Decl) and p.name:
                    old = p.name
                    new = self._name_for(old, "arg")
                    p.name = new
                    self._set_decl_name(p.type, new)
                    self._bind_local(old, new)
                    self.stats.params += 1

        self.visit(node.body)
        self._pop_scope()
        self.label_map = {}

    def visit_Decl(self, node: c_ast.Decl) -> None:
        if not node.name:
            self.generic_visit(node)
            return

        if self._is_typedef_decl(node):
            self.generic_visit(node)
            return

        if self._is_func_decl(node):
            if node.name in self.global_map:
                new_name = self.global_map[node.name]
                node.name = new_name
                self._set_decl_name(node.type, new_name)
            self.generic_visit(node)
            return

        if len(self.scope_stack) == 1:
            if node.name in self.global_map:
                new_name = self.global_map[node.name]
                node.name = new_name
                self._set_decl_name(node.type, new_name)
        else:
            old = node.name
            new = self._name_for(old, "lv")
            node.name = new
            self._set_decl_name(node.type, new)
            self._bind_local(old, new)
            self.stats.variables += 1

        self.generic_visit(node)

    def visit_ID(self, node: c_ast.ID) -> None:
        repl = self._lookup(node.name)
        if repl:
            node.name = repl

    def visit_Label(self, node: c_ast.Label) -> None:
        if node.name in self.label_map:
            node.name = self.label_map[node.name]
        self.visit(node.stmt)

    def visit_Goto(self, node: c_ast.Goto) -> None:
        if node.name in self.label_map:
            node.name = self.label_map[node.name]


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def run_cmd(cmd: str, cwd: Optional[str]) -> None:
    proc = subprocess.run(cmd, shell=True, cwd=cwd)
    if proc.returncode != 0:
        raise RuntimeError(f"command failed ({proc.returncode}): {cmd}")


def parse_rename_pairs(pairs: List[str], map_file: Optional[str]) -> Dict[str, str]:
    mapping: Dict[str, str] = {}
    for p in pairs:
        if ":" not in p:
            raise ValueError(f"invalid --rename pair '{p}', expected old:new")
        old, new = p.split(":", 1)
        old = old.strip()
        new = new.strip()
        if not old or not new:
            raise ValueError(f"invalid --rename pair '{p}', empty side")
        mapping[old] = new

    if map_file:
        with open(map_file, "r", encoding="utf-8") as f:
            obj = json.load(f)
        if not isinstance(obj, dict):
            raise ValueError("rename-map file must contain a JSON object of old->new")
        for k, v in obj.items():
            if not isinstance(k, str) or not isinstance(v, str):
                raise ValueError("rename-map keys/values must be strings")
            mapping[k] = v
    return mapping


def rewrite_source_preserve_directives(source: str, mapping: Dict[str, str]) -> str:
    """Replace identifiers in-place while preserving all original formatting,
    comments and preprocessor directives.
    """
    out: List[str] = []
    i = 0
    n = len(source)
    at_line_start = True
    while i < n:
        c = source[i]

        # preserve preprocessor directives verbatim (# as first non-space char)
        if at_line_start:
            k = i
            while k < n and source[k] in " \t":
                k += 1
            if k < n and source[k] == "#":
                j = k
                while j < n:
                    while j < n and source[j] != "\n":
                        j += 1
                    if j > 0 and source[j - 1] == "\\" and j < n:
                        j += 1
                        continue
                    break
                if j < n and source[j] == "\n":
                    j += 1
                out.append(source[i:j])
                at_line_start = True
                i = j
                continue

        # line comment
        if c == "/" and i + 1 < n and source[i + 1] == "/":
            j = i + 2
            while j < n and source[j] != "\n":
                j += 1
            out.append(source[i:j])
            i = j
            at_line_start = (j == 0) or (j <= n and source[j - 1:j] == "\n")
            continue

        # block comment
        if c == "/" and i + 1 < n and source[i + 1] == "*":
            j = i + 2
            while j + 1 < n and not (source[j] == "*" and source[j + 1] == "/"):
                j += 1
            j = min(j + 2, n)
            out.append(source[i:j])
            i = j
            at_line_start = False
            continue

        # string literal
        if c == '"':
            j = i + 1
            while j < n:
                if source[j] == "\\":
                    j += 2
                    continue
                if source[j] == '"':
                    j += 1
                    break
                j += 1
            out.append(source[i:j])
            i = j
            at_line_start = False
            continue

        # char literal
        if c == "'":
            j = i + 1
            while j < n:
                if source[j] == "\\":
                    j += 2
                    continue
                if source[j] == "'":
                    j += 1
                    break
                j += 1
            out.append(source[i:j])
            i = j
            at_line_start = False
            continue

        # identifier token
        if c == "_" or c.isalpha():
            j = i + 1
            while j < n and (source[j] == "_" or source[j].isalnum()):
                j += 1
            tok = source[i:j]
            out.append(mapping.get(tok, tok))
            i = j
            at_line_start = False
            continue

        out.append(c)
        at_line_start = (c == "\n")
        i += 1

    return "".join(out)


def run_rename_with_gate(
    src_in: str,
    out_path: str,
    prefix: str,
    rename_nonstatic: bool,
    cpp: str,
    cpp_args_raw: str,
    gate_cmd: str,
    gate_cwd: Optional[str],
    keep_temp: bool,
    explicit_map: Dict[str, str],
) -> Dict[str, Any]:
    src_in = os.path.abspath(src_in)
    out_path = os.path.abspath(out_path)

    with open(src_in, "r", encoding="utf-8", errors="ignore") as f:
        original_source = f.read()

    if not explicit_map:
        raise RuntimeError("explicit rename map required: provide --rename or --rename-map")

    # Explicit rename mode: preserve all directives/comments/formatting by
    # rewriting tokens in the original source text.
    rewritten = rewrite_source_preserve_directives(original_source, explicit_map)
    stats: Dict[str, int] = {"functions": 0, "variables": 0, "params": 0, "labels": 0}

    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="rename_gate_") as td:
        orig_tmp = os.path.join(td, "orig.c")
        ren_tmp = os.path.join(td, "renamed.c")
        out_orig = os.path.join(td, "orig.bin")
        out_ren = os.path.join(td, "renamed.bin")

        shutil.copyfile(src_in, orig_tmp)
        with open(ren_tmp, "w", encoding="utf-8", newline="\n") as f:
            f.write(rewritten)

        cmd1 = gate_cmd.format(src=orig_tmp, out=out_orig)
        cmd2 = gate_cmd.format(src=ren_tmp, out=out_ren)

        run_cmd(cmd1, gate_cwd)
        run_cmd(cmd2, gate_cwd)

        if not os.path.exists(out_orig) or not os.path.exists(out_ren):
            raise RuntimeError("gate command did not produce output binaries")

        h1 = sha256_file(out_orig)
        h2 = sha256_file(out_ren)

        if h1 != h2:
            if keep_temp:
                kept = os.path.abspath("rename_gate_failed")
                if os.path.exists(kept):
                    shutil.rmtree(kept)
                shutil.copytree(td, kept)
                print(f"quality gate failed: binary mismatch (kept artifacts in {kept})", file=sys.stderr)
            raise RuntimeError(f"quality gate failed: binary mismatch\norig={h1}\nren ={h2}")

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(rewritten)

    return {
        "ok": True,
        "output": out_path,
        "stats": stats,
    }


def run_cli(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Rename C identifiers with pycparser and enforce binary-identity quality gate.")
    ap.add_argument("input", help="Input .C/.c file")
    ap.add_argument("--output", required=True, help="Output rewritten C file")
    ap.add_argument("--prefix", default="rz_", help="Renamed identifier prefix")
    ap.add_argument("--rename-nonstatic", action="store_true", help="Also rename non-static globals/functions")
    ap.add_argument("--rename", action="append", default=[], help="Explicit rename pair: old:new (repeatable)")
    ap.add_argument("--rename-map", default=None, help="JSON file with {\"old\":\"new\"} mappings")
    ap.add_argument("--cpp", default="gcc", help="Preprocessor executable (default: gcc)")
    ap.add_argument("--cpp-args", default="-E -P", help="Arguments passed to preprocessor")
    ap.add_argument("--gate-cmd", required=True, help="Quality-gate compile command template. Must use placeholders {src} and {out}.")
    ap.add_argument("--gate-cwd", default=None, help="Working directory for gate command")
    ap.add_argument("--keep-temp", action="store_true", help="Keep temp files when gate fails")
    args = ap.parse_args(argv)

    explicit_map = parse_rename_pairs(args.rename, args.rename_map)
    res = run_rename_with_gate(
        src_in=args.input,
        out_path=args.output,
        prefix=args.prefix,
        rename_nonstatic=args.rename_nonstatic,
        cpp=args.cpp,
        cpp_args_raw=args.cpp_args,
        gate_cmd=args.gate_cmd,
        gate_cwd=args.gate_cwd,
        keep_temp=args.keep_temp,
        explicit_map=explicit_map,
    )

    st = res["stats"]
    print(
        f"OK: binary identical; wrote {res['output']} "
        f"(functions={st['functions']}, vars={st['variables']}, args={st['params']}, labels={st['labels']})"
    )
    return 0


def _mcp_write(msg: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def run_mcp_server() -> int:
    tool_schema = {
        "name": "rename_with_quality_gate",
        "description": "Rename identifiers in a C file and enforce binary identity gate.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "input": {"type": "string"},
                "output": {"type": "string"},
                "prefix": {"type": "string", "default": "rz_"},
                "rename_nonstatic": {"type": "boolean", "default": False},
                "rename": {"type": "array", "items": {"type": "string"}},
                "rename_map": {"type": "string"},
                "cpp": {"type": "string", "default": "gcc"},
                "cpp_args": {"type": "string", "default": "-E -P"},
                "gate_cmd": {"type": "string"},
                "gate_cwd": {"type": "string"},
                "keep_temp": {"type": "boolean", "default": False},
            },
            "required": ["input", "output", "gate_cmd"],
        },
    }

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            rid = req.get("id")
            method = req.get("method")
            params = req.get("params", {})

            if method == "initialize":
                _mcp_write({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": "2024-11-05", "serverInfo": {"name": "rename-c-gate", "version": "1.0.0"}, "capabilities": {"tools": {}}}})
            elif method == "tools/list":
                _mcp_write({"jsonrpc": "2.0", "id": rid, "result": {"tools": [tool_schema]}})
            elif method == "tools/call":
                name = params.get("name")
                if name != "rename_with_quality_gate":
                    raise ValueError(f"unknown tool: {name}")
                args = params.get("arguments", {})
                explicit_map = parse_rename_pairs(args.get("rename", []) or [], args.get("rename_map"))
                res = run_rename_with_gate(
                    src_in=args["input"],
                    out_path=args["output"],
                    prefix=args.get("prefix", "rz_"),
                    rename_nonstatic=bool(args.get("rename_nonstatic", False)),
                    cpp=args.get("cpp", "gcc"),
                    cpp_args_raw=args.get("cpp_args", "-E -P"),
                    gate_cmd=args["gate_cmd"],
                    gate_cwd=args.get("gate_cwd"),
                    keep_temp=bool(args.get("keep_temp", False)),
                    explicit_map=explicit_map,
                )
                _mcp_write({"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": json.dumps(res)}]}})
            elif method == "shutdown":
                _mcp_write({"jsonrpc": "2.0", "id": rid, "result": {}})
            elif method == "exit":
                break
            else:
                _mcp_write({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"method not found: {method}"}})
        except Exception as e:
            rid = None
            try:
                rid = req.get("id")  # type: ignore[name-defined]
            except Exception:
                pass
            _mcp_write({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": str(e)}})
    return 0


if __name__ == "__main__":
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "--mcp-server":
            raise SystemExit(run_mcp_server())
        raise SystemExit(run_cli())
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        raise SystemExit(1)
