#!/usr/bin/env python3
"""兼容性对拍：本实现（CLI）与第三方 7z 实现（libarchive/bsdtar、7-Zip）比对。

两种模式：
1. 默认（list 模式，不需要建任何目录，Windows 沙箱下也能跑）：
   - 本实现 `list` 输出的名字 / 大小 vs oracle 的列目录结果；
   - 本实现报告的文件 CRC-32 vs oracle 实际解出的内容 CRC-32（`tar -xO` 走 stdout）。
2. `--full-extract`（CI 用）：本实现 `extract` 到临时目录，oracle 也解一份，
   逐文件比 SHA-256。

退出码：0 = 无 DIFF 且 OK 数 >= --min-ok；1 = 出现 DIFF 或 OK 数不足。

**临时目录必须在 moon 模块之外**：moon 的包发现会扫描模块内所有目录，
残留的临时目录会让 `moon run/check` 直接失败。
"""

import argparse
import hashlib
import pathlib
import shutil
import subprocess
import sys
import tempfile
import zlib

sys.stdout.reconfigure(encoding="utf-8")

# oracle 名称 -> 实际命令行（Windows 自带 tar.exe，Linux 上是 bsdtar）
ORACLE_CMDS = {
    "bsdtar": ["bsdtar"],
    "tar": ["tar.exe"] if sys.platform.startswith("win") else ["tar"],
    "7z": ["7z"],
}


def oracle_cmd(oracle: str) -> list[str]:
    cmd = ORACLE_CMDS[oracle]
    if shutil.which(cmd[0]) is None:
        raise SystemExit(f"找不到对拍工具：{cmd[0]}（Windows 可用 --oracle tar，Linux 用 bsdtar）")
    return cmd


def run(cmd: list[str], cwd: pathlib.Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        cwd=cwd,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )


def run_raw(cmd: list[str]) -> subprocess.CompletedProcess:
    """拿原始字节（列目录要自己判编码）。"""
    return subprocess.run(cmd, capture_output=True)


def decode_oracle(raw: bytes) -> str:
    """oracle 输出解码：优先 UTF-8，其次 GBK（Windows 控制台代码页），最后替换。"""
    for enc in ("utf-8", "gbk"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "replace")


def oracle_list(oracle: str, archive: pathlib.Path) -> dict[str, int]:
    """返回 {相对路径: 大小}（只统计普通文件）。"""
    cmd = oracle_cmd(oracle)
    if oracle in ("bsdtar", "tar"):
        r = run_raw(cmd + ["-tvf", str(archive)])
        if r.returncode != 0:
            raise RuntimeError(
                f"{oracle} 列目录失败: {decode_oracle(r.stderr).strip()}"
            )
        # 注意：Windows 上 tar.exe 会把非 ASCII 名字按控制台代码页吐出（GBK），
        # 因此这里按"UTF-8 → GBK"顺序解码，避免把编码差异误判成实现差异。
        out: dict[str, int] = {}
        for line in decode_oracle(r.stdout).splitlines():
            parts = line.split()
            if len(parts) < 9 or line.startswith("d"):
                continue
            out[" ".join(parts[8:])] = int(parts[4])
        return out
    r = run(cmd + ["l", "-slt", str(archive)])
    if r.returncode != 0:
        raise RuntimeError(f"7z 列目录失败: {r.stderr.strip()}")
    out = {}
    name = None
    for line in r.stdout.splitlines():
        if line.startswith("Path = "):
            name = line[7:]
        elif line.startswith("Size = ") and name is not None:
            out[name] = int(line[7:])
            name = None
    return out


def oracle_bytes(oracle: str, archive: pathlib.Path, name: str) -> bytes:
    """把归档里某个文件解到 stdout（不落盘）。"""
    cmd = oracle_cmd(oracle)
    if oracle in ("bsdtar", "tar"):
        r = subprocess.run(
            cmd + ["-xOf", str(archive), name], capture_output=True
        )
    else:
        r = subprocess.run(cmd + ["x", "-so", str(archive), name], capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(
            f"{oracle} 解 {name} 失败: {r.stderr.decode('utf-8', 'replace').strip()}"
        )
    return r.stdout


def cli_list(runner: list[str], archive: pathlib.Path) -> tuple[str, dict[str, tuple[int, str]]]:
    """跑本实现的 list；返回 (状态, {名字: (大小, crc)})。

    CLI 契约：成功时每行 "<name>\\t<size>\\t<crc>"（目录的 size/crc 为 "-"）；
    失败时打印 "UNSUPPORTED\\t<原因>" 或 "ERROR\\t<原因>"（退出码恒为 0，跨后端一致）。
    """
    r = run(runner + ["list", str(archive)])
    text = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0:
        raise RuntimeError(f"list 退出码 {r.returncode}: {text.strip()[:200]}")
    out: dict[str, tuple[int, str]] = {}
    for line in r.stdout.splitlines():
        if line.startswith("UNSUPPORTED\t"):
            return "skip", {}
        if line.startswith("ERROR\t"):
            raise RuntimeError(f"list 报错: {line[6:].strip()}")
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        name, size, crc = parts
        if size == "-":
            continue
        out[name] = (int(size), crc)
    return "ok", out


def tree_hashes(root: pathlib.Path) -> dict[str, str]:
    return {
        str(p.relative_to(root)).replace("\\", "/"): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(root.rglob("*"))
        if p.is_file()
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--runner",
        default="moon run --target js cmd/main --",
        help="CLI 启动命令（后面接 list/extract）",
    )
    ap.add_argument("--corpus", default="tools/corpus")
    ap.add_argument("--oracle", default="bsdtar", choices=["bsdtar", "tar", "7z"])
    ap.add_argument("--out", default="COMPATIBILITY.md")
    ap.add_argument("--min-ok", type=int, default=1, help="至少需要多少个归档完全一致")
    ap.add_argument(
        "--full-extract",
        action="store_true",
        help="额外做字节级比对（需要能建临时目录；CI 用）",
    )
    ap.add_argument(
        "--tmp-root",
        default=str(pathlib.Path(__file__).resolve().parent.parent.parent / "_tmp_compat"),
        help="full-extract 模式的临时目录（必须在 moon 模块之外）",
    )
    args = ap.parse_args()

    runner = args.runner.split()
    corpus = pathlib.Path(args.corpus)
    archives = sorted(corpus.glob("*.7z"))
    if not archives:
        print(f"没有找到语料：{corpus}")
        return 1

    lines = [
        "# 兼容性对拍报告（脚本生成，请勿手改）",
        "",
        f"- 本实现：`{' '.join(runner)}`",
        f"- 对照实现：`{args.oracle}`（bsdtar/tar = libarchive；7z = 7-Zip）",
        f"- 模式：{'list + 内容 CRC + 解包字节 SHA-256' if args.full_extract else 'list + 内容 CRC'}",
        f"- 平台：{sys.platform}",
        f"- 语料：{len(archives)} 个归档（`{corpus}`）",
        "",
        "复现：",
        "",
        "```bash",
        f"python3 tools/check_compat.py --runner \"{args.runner}\" --oracle {args.oracle} "
        f"{'--full-extract ' if args.full_extract else ''}--out {args.out} --min-ok {args.min_ok}",
        "```",
        "",
        "| 归档 | 列目录 | 内容 CRC | 解包字节 | 说明 |",
        "|---|---|---|---|---|",
    ]
    ok = diff = skip = 0
    failed = False
    tmp_root = pathlib.Path(args.tmp_root)
    if args.full_extract:
        tmp_root.mkdir(parents=True, exist_ok=True)
        print(f"临时目录：{tmp_root}")

    for archive in archives:
        name = archive.name
        try:
            status, ours = cli_list(runner, archive)
        except Exception as e:  # noqa: BLE001
            lines.append(f"| `{name}` | 失败 | - | - | {e} |")
            failed = True
            continue
        if status == "skip":
            skip += 1
            lines.append(f"| `{name}` | 跳过 | 跳过 | 跳过 | 本实现报 UNSUPPORTED |")
            continue

        # 1) 列目录（名字集合 + 大小）
        their_sizes = oracle_list(args.oracle, archive)
        if set(ours) != set(their_sizes):
            lines.append(
                f"| `{name}` | DIFF | - | - | 名字集合不同：我方 {sorted(ours)} vs 对照 {sorted(their_sizes)} |"
            )
            diff += 1
            failed = True
            continue
        size_bad = [k for k in their_sizes if ours[k][0] != their_sizes[k]]
        if size_bad:
            lines.append(f"| `{name}` | DIFF | - | - | 大小不同：{size_bad} |")
            diff += 1
            failed = True
            continue

        # 2) 内容 CRC：本实现报告的 CRC vs oracle 解出内容的 CRC
        crc_bad = []
        checked = 0
        skipped_non_ascii = 0
        for fname, (size, crc) in sorted(ours.items()):
            if crc == "-":
                continue
            if not fname.isascii():
                # Windows 上把非 ASCII 名字作为 argv 传给 tar.exe 会被代码页转换，
                # 名字对不上不是实现差异；这类名字的内容比对交给 CI（Linux，UTF-8）。
                skipped_non_ascii += 1
                continue
            try:
                data = oracle_bytes(args.oracle, archive, fname)
            except Exception as e:  # noqa: BLE001
                crc_bad.append(f"{fname}(oracle 解不出: {e})")
                continue
            checked += 1
            if len(data) != size or f"{zlib.crc32(data):08x}" != crc:
                crc_bad.append(
                    f"{fname}(我方 {size}B/{crc} vs 对照 {len(data)}B/{zlib.crc32(data):08x})"
                )
        if crc_bad:
            lines.append(f"| `{name}` | OK | DIFF | - | {crc_bad} |")
            diff += 1
            failed = True
            continue

        # 3) 可选：字节级解包比对
        if args.full_extract:
            tmpdir = pathlib.Path(tempfile.mkdtemp(dir=tmp_root, prefix=f"{name}."))
            try:
                mine_dir = tmpdir / "mine"
                theirs_dir = tmpdir / "theirs"
                mine_dir.mkdir()
                theirs_dir.mkdir()
                r = run(runner + ["extract", str(archive), str(mine_dir)])
                if r.returncode != 0 or "ERROR\t" in (r.stdout or ""):
                    lines.append(
                        f"| `{name}` | OK | OK | 失败 | extract 报错：{(r.stdout or '').strip()[:120]} |"
                    )
                    diff += 1
                    failed = True
                    continue
                cmd = oracle_cmd(args.oracle)
                if args.oracle == "7z":
                    r = run(cmd + ["x", "-y", f"-o{theirs_dir}", str(archive)])
                else:
                    r = run(cmd + ["-xf", str(archive), "-C", str(theirs_dir)])
                if r.returncode != 0:
                    raise RuntimeError(f"{args.oracle} 解包失败: {r.stderr.strip()}")
                mine = tree_hashes(mine_dir)
                theirs = tree_hashes(theirs_dir)
                if mine != theirs:
                    changed = sorted(k for k in set(mine) & set(theirs) if mine[k] != theirs[k])
                    lines.append(
                        f"| `{name}` | OK | OK | DIFF | 我方多 {sorted(set(mine) - set(theirs))}，"
                        f"对照多 {sorted(set(theirs) - set(mine))}，内容不同 {changed} |"
                    )
                    diff += 1
                    failed = True
                    continue
                byte_note = f"{len(mine)} 个文件 SHA-256 一致"
            finally:
                shutil.rmtree(tmpdir, ignore_errors=True)
        else:
            byte_note = "未做（默认模式）"

        ok += 1
        note = f"{checked} 个文件"
        if skipped_non_ascii:
            note += f"，{skipped_non_ascii} 个非 ASCII 名字留给 CI"
        lines.append(f"| `{name}` | OK | OK（{note}） | {byte_note} | - |")

    lines += [
        "",
        f"**汇总**：一致 {ok}，DIFF {diff}，跳过 {skip}（要求一致数 ≥ {args.min_ok}）",
        "",
    ]
    pathlib.Path(args.out).write_text("\n".join(lines), encoding="utf-8")
    print("\n".join(lines))
    if failed or ok < args.min_ok:
        print(f"\n对拍未达标：ok={ok} diff={diff} skip={skip} (min-ok={args.min_ok})")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
