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

# 用来读写 7z 的 libarchive 前端：Windows 自带 `tar.exe`，Linux 上是 `bsdtar`
# （apt install libarchive-tools）。可用 --tar 覆盖。
TAR = "tar.exe" if sys.platform.startswith("win") else "bsdtar"

# 语料定义：名字 -> (压缩选项, {归档内文件名: 内容})
# 选项 None = bsdtar 默认（LZMA 数据 + 编码头）；
# copy / lzma1 / lzma2 为 libarchive 7z 写入器的压缩选项。
# 实测：copy 档的 NextHeader 以 0x01(kHeader) 开头（明文头），
#       lzma1/lzma2/默认档以 0x17(kEncodedHeader) 开头（头也被压缩）。
FIXTURES: dict[str, tuple[str | None, dict[str, bytes]]] = {
    "two_text": (
        None,
        {"a.txt": b"A" * 200, "b.txt": b"hello 7z world " * 50},
    ),
    "two_text_copy": (
        "7zip:compression=copy",
        {"a.txt": b"A" * 200, "b.txt": b"hello 7z world " * 50},
    ),
    "two_text_lzma1": (
        "7zip:compression=lzma1",
        {"a.txt": b"A" * 200, "b.txt": b"hello 7z world " * 50},
    ),
    "two_text_lzma2": (
        "7zip:compression=lzma2",
        {"a.txt": b"A" * 200, "b.txt": b"hello 7z world " * 50},
    ),
    # 单文件小语料：字节数少，便于把真实归档内嵌进单元测试（_wbtest.mbt）
    "one_file_copy": (
        "7zip:compression=copy",
        {"hello.txt": b"hello moon7z\n"},
    ),
    # 含目录的语料：覆盖 kEmptyStream / kEmptyFile 与 is_dir 判定。
    # 注意：只有把目录名本身作为参数传给 bsdtar，才会写出目录条目。
    "tree_copy": (
        "7zip:compression=copy",
        {"top.txt": b"top\n", "dir/inner.txt": b"inner\n"},
    ),
    # 空文件：覆盖"有数据流但长度为 0"与 kEmptyFile 的区别
    "empty_file_copy": (
        "7zip:compression=copy",
        {"empty.txt": b"", "data.txt": b"data\n"},
    ),
    # 嵌套目录 + 非 ASCII 名字：覆盖 UTF-16 名字解码与多级路径
    "nested_copy": (
        "7zip:compression=copy",
        {
            "top.txt": b"top\n",
            "a/b/deep.txt": b"deep\n",
            "中文名.txt": "中文内容\n".encode("utf-8"),
        },
    ),
    # 20 KB 文件：覆盖较大 packed 数据下的切片与 CRC（不是多分块，分块要 >2MiB，交给 CI 现场生成）
    "big_copy": (
        "7zip:compression=copy",
        {"big.bin": bytes((i * 7 + 13) & 0xFF for i in range(20 * 1024))},
    ),
}

# 语料 -> 传给 bsdtar 的条目列表（默认按文件名排序；含目录的语料需显式给出）
ENTRIES: dict[str, list[str]] = {
    "tree_copy": ["top.txt", "dir"],
}


def build(
    name: str,
    option: str | None,
    files: dict[str, bytes],
    entries: list[str] | None = None,
) -> pathlib.Path:
    """用 bsdtar（libarchive）生成一个 7z 归档。

    归档里会写入文件时间戳，因此把 mtime 固定到一个常量以减少变化；
    但仍有无法固定的时间字段，故生成结果不逐字节可复现（见文件头说明）。
    """
    CORPUS.mkdir(parents=True, exist_ok=True)
    stage = CORPUS / f"_{name}.stage"
    if stage.exists():
        for p in sorted(stage.rglob("*"), reverse=True):
            p.unlink() if p.is_file() else p.rmdir()
    stage.mkdir(parents=True, exist_ok=True)
    for fname, data in files.items():
        path = stage / fname
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        os.utime(path, (FIXED_MTIME, FIXED_MTIME))
    out = CORPUS / f"{name}.7z"
    if out.exists():
        out.unlink()
    cmd = [TAR]
    if option is not None:
        cmd += ["--options", option]
    cmd += ["-a", "-cf", str(out)] + (entries if entries else sorted(files.keys()))
    subprocess.run(cmd, cwd=stage, check=True)
    # 归档文件本身也固定 mtime，避免无关差异
    os.utime(out, (FIXED_MTIME, FIXED_MTIME))
    # 用 libarchive 自己复核：列目录必须成功
    listing = subprocess.run(
        [TAR, "-tf", str(out)], capture_output=True, check=True
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


def build_minimal_two_copy() -> pathlib.Path:
    """手工构造一个"规范形态"的两文件 7z（COPY 压缩），并用 libarchive 复核。

    与 bsdtar 写出的归档互补：
    - 名字块严格按规范（UTF-16LE、无前导杂字节）——覆盖 kName 的偏移 0 路径；
    - 两个 Folder / 两个子流 + SubStreamsInfo CRC——覆盖多文件映射。
    生成后立刻用 `tar -tf` / `tar -xf` 验证 libarchive 能读，确保不是"自说自话"。
    """
    import zlib

    files = [("a.txt", b"AAA"), ("b.txt", b"BB")]

    def number(value: int) -> bytes:
        if value < 0x80:
            return bytes([value])
        raise ValueError("本构造器只支持 < 128 的 NUMBER")

    # PackedStreams：两个文件的原始字节依次排布
    packed = b"".join(data for _, data in files)

    # --- Header ---
    body = bytearray()
    body += b"\x01"  # kHeader
    body += b"\x04"  # kMainStreamsInfo
    # PackInfo
    body += b"\x06" + number(0) + number(len(files))  # pack_pos, numPackStreams
    body += b"\x09" + b"".join(number(len(d)) for _, d in files)  # kSize
    body += b"\x00"  # kEnd (PackInfo)
    # UnpackInfo
    body += b"\x07"
    body += b"\x0b" + number(len(files)) + b"\x00"  # kFolder, numFolders, external=0
    for _ in files:
        body += number(1) + b"\x01\x00"  # 1 个 coder：flag=0x01（id 长 1 字节）, id=0x00 COPY
    body += b"\x0c" + b"".join(number(len(d)) for _, d in files)  # kCodersUnpackSize
    body += b"\x00"  # kEnd (UnpackInfo)
    # SubStreamsInfo：每个子流一个 CRC
    body += b"\x08"
    body += b"\x0a\x01" + b"".join(
        zlib.crc32(d).to_bytes(4, "little") for _, d in files
    )
    body += b"\x00"  # kEnd (SubStreamsInfo)
    body += b"\x00"  # kEnd (StreamsInfo)
    # FilesInfo
    # 注意：名字块前面补一个 0x00 字节——libarchive 只接受这种形态
    # （实测：去掉该字节后 `tar -tf` 报 Damaged；解析器两种形态都支持）。
    names = (
        b"\x00"
        + b"".join(name.encode("utf-16-le") + b"\x00\x00" for name, _ in files)
    )
    body += b"\x05" + number(len(files))
    body += b"\x11" + number(len(names)) + names
    body += b"\x00"  # kEnd (FilesInfo)
    body += b"\x00"  # kEnd (Header)
    header = bytes(body)

    # --- Signature header ---
    start = bytearray()
    start += b"7z\xbc\xaf\x27\x1c"
    start += bytes([0, 4])  # 版本 0.4
    start += b"\x00\x00\x00\x00"  # StartHeaderCRC 占位
    start += len(packed).to_bytes(8, "little")
    start += len(header).to_bytes(8, "little")
    start += zlib.crc32(header).to_bytes(4, "little")
    start[8:12] = zlib.crc32(bytes(start[12:32])).to_bytes(4, "little")

    CORPUS.mkdir(parents=True, exist_ok=True)
    out = CORPUS / "minimal_two_copy.7z"
    out.write_bytes(bytes(start) + packed + header)

    # --- 用 libarchive 复核 ---
    listing = subprocess.run(
        [TAR, "-tf", str(out)], capture_output=True, check=True
    ).stdout.decode("utf-8", "replace")
    stage = CORPUS / "_minimal.stage"
    if stage.exists():
        for p in sorted(stage.rglob("*"), reverse=True):
            p.unlink() if p.is_file() else p.rmdir()
    stage.mkdir(parents=True, exist_ok=True)
    subprocess.run([TAR, "-xf", str(out), "-C", str(stage)], check=True)
    got = {p.name: p.read_bytes() for p in stage.iterdir()}
    for p in sorted(stage.rglob("*"), reverse=True):
        p.unlink() if p.is_file() else p.rmdir()
    stage.rmdir()
    expect = dict(files)
    if got != expect:
        raise SystemExit(f"libarchive 解出的内容不符：{got!r} != {expect!r}")
    print(
        f"[minimal_two_copy] {out.name}: {out.stat().st_size} bytes; "
        f"listing: {listing.split()}; 内容与预期一致"
    )
    return out


def hex_const(path: pathlib.Path) -> str:
    data = path.read_bytes()
    return "".join(f"\\x{b:02X}" for b in data)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hex-only", action="store_true")
    ap.add_argument(
        "--force",
        action="store_true",
        help="重新生成已存在的语料（默认保留仓库里已提交的字节）",
    )
    ap.add_argument("--only", help="只处理指定语料（配合 --force 用于新增单个语料）")
    ap.add_argument(
        "--tar",
        help="libarchive 前端可执行文件（默认 Windows 用 tar.exe，其它平台用 bsdtar）",
    )
    args = ap.parse_args()

    global TAR
    if args.tar:
        TAR = args.tar
    print(f"libarchive 前端: {TAR}")

    extra: list[pathlib.Path] = []
    if not args.hex_only and (args.only in (None, "minimal_two_copy")):
        minimal = CORPUS / "minimal_two_copy.7z"
        if args.force or not minimal.exists():
            extra.append(build_minimal_two_copy())
        else:
            print(f"[minimal_two_copy] 保留已提交的 {minimal.name}")

    for name, (option, files) in FIXTURES.items():
        if args.only is not None and args.only != name:
            continue
        out = CORPUS / f"{name}.7z"
        if not args.hex_only and (args.force or not out.exists()):
            out = build(name, option, files, ENTRIES.get(name))
        elif not args.hex_only:
            print(f"[{name}] 保留已提交的 {out.name}")
        if not out.exists():
            print(f"missing {out}; run without --hex-only first")
            return 1
        data = out.read_bytes()
        print(
            f"--- {name}.7z  size={len(data)}  "
            f"sha256={hashlib.sha256(data).hexdigest()}"
        )
        if args.hex_only:
            # 每行 32 个 hex 字符（16 字节），便于粘贴到 _wbtest.mbt 的字符串拼接
            h = data.hex()
            for off in range(0, len(h), 32):
                print('  "' + h[off : off + 32] + '" +')
    for out in extra:
        data = out.read_bytes()
        print(
            f"--- {out.name}  size={len(data)}  "
            f"sha256={hashlib.sha256(data).hexdigest()}"
        )
        h = data.hex()
        for off in range(0, len(h), 32):
            print('  "' + h[off : off + 32] + '" +')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
