#!/usr/bin/env python3
"""生成 moon7z 的测试语料（真实 7z 归档）。

用途：测试需要真实的 7z 字节。测试在 wasm-gc 后端运行、不能读文件，
因此测试里以十六进制常量内嵌；本脚本负责重新生成语料并打印这些常量。

本机没有 7-Zip 官方命令，但 Windows 自带 `tar.exe`（bsdtar / libarchive）
既能创建也能列出 7z，实测可用（见 README「验证方式」）。

注意：libarchive 会在头里写入文件时间戳，即使本脚本固定了 mtime，
同一份输入多次生成也**不会逐字节相同**。因此：
- `tools/corpus/*.7z` 一旦提交即视为"基准字节"，测试内嵌的 hex 以它为准；
- 重新生成本脚本只用于**新增**语料或复核语义（列目录、解包内容是否一致），
  拿新字节替换旧基准前必须同步更新测试里的常量与 sha256 注释。

用法：
    python tools/gen_fixtures.py            # 生成 tools/corpus/*.7z 并打印 hex 常量
    python tools/gen_fixtures.py --hex-only # 只打印 hex（要求语料已存在）
"""

import argparse
import hashlib
import os
import pathlib
import subprocess
import sys
import tarfile

sys.stdout.reconfigure(encoding="utf-8")

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORPUS = ROOT / "tools" / "corpus"

# 固定 mtime（2020-09-13T12:26:40Z），减少不必要的变化；但归档里仍会有
# 无法固定的时间字段，故生成结果不逐字节可复现（见文件头说明）。
FIXED_MTIME = 1_600_000_000

# 语料名 -> {归档内文件名: 内容}
FILES: dict[str, bytes] = {
    "a.txt": b"A" * 200,
    "b.txt": b"hello 7z world " * 50,
}

# 语料名 -> bsdtar 压缩选项（None = 默认，即 LZMA 压缩的数据 + 编码头）
# 实测：copy 档的 NextHeader 以 0x01(kHeader) 开头（明文头）；
#       lzma1/lzma2 档以 0x17(kEncodedHeader) 开头（头也被压缩）。
FIXTURES: dict[str, str | None] = {
    "two_text": None,
    "two_text_copy": "7zip:compression=copy",
    "two_text_lzma1": "7zip:compression=lzma1",
    "two_text_lzma2": "7zip:compression=lzma2",
}


def build(name: str, option: str | None) -> pathlib.Path:
    """用 bsdtar（libarchive）生成一个 7z 归档。

    归档里会写入文件 mtime，因此把 mtime 固定到一个常量，保证同样的输入
    每次都产出逐字节相同的归档（测试里内嵌的 hex 才能复现）。
    """
    CORPUS.mkdir(parents=True, exist_ok=True)
    stage = CORPUS / f"_{name}.stage"
    if stage.exists():
        for p in sorted(stage.rglob("*"), reverse=True):
            p.unlink() if p.is_file() else p.rmdir()
    stage.mkdir(parents=True, exist_ok=True)
    for fname, data in FILES.items():
        path = stage / fname
        path.write_bytes(data)
        os.utime(path, (FIXED_MTIME, FIXED_MTIME))
    out = CORPUS / f"{name}.7z"
    if out.exists():
        out.unlink()
    cmd = ["tar.exe"]
    if option is not None:
        cmd += ["--options", option]
    cmd += ["-a", "-cf", str(out)] + sorted(FILES.keys())
    subprocess.run(cmd, cwd=stage, check=True)
    # 归档文件本身也固定 mtime，避免无关差异
    os.utime(out, (FIXED_MTIME, FIXED_MTIME))
    # 用 libarchive 自己复核：列目录必须成功
    listing = subprocess.run(
        ["tar.exe", "-tf", str(out)], capture_output=True, check=True
    ).stdout.decode("utf-8", "replace")
    for p in sorted(stage.rglob("*"), reverse=True):
        p.unlink() if p.is_file() else p.rmdir()
    stage.rmdir()
    nh_first = None
    data = out.read_bytes()
    if len(data) >= 32:
        off = int.from_bytes(data[12:20], "little")
        if 32 + off < len(data):
            nh_first = data[32 + off]
    print(
        f"[{name}] {out.name}: {out.stat().st_size} bytes; "
        f"next-header first byte = {nh_first:#04x}; listing: {listing.split()}"
    )
    return out


def hex_const(path: pathlib.Path) -> str:
    data = path.read_bytes()
    return "".join(f"\\x{b:02X}" for b in data)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hex-only", action="store_true")
    args = ap.parse_args()

    for name, option in FIXTURES.items():
        out = CORPUS / f"{name}.7z"
        if not args.hex_only:
            out = build(name, option)
        if not out.exists():
            print(f"missing {out}; run without --hex-only first")
            return 1
        data = out.read_bytes()
        print(
            f"--- {name}.7z  size={len(data)}  "
            f"sha256={hashlib.sha256(data).hexdigest()}"
        )
        # 每行 16 字节，便于粘贴到 _wbtest.mbt
        for off in range(0, len(data), 16):
            chunk = data[off : off + 16]
            print(f"  {off:04X}  " + "".join(f"\\x{b:02X}" for b in chunk))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
