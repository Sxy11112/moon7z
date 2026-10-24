#!/usr/bin/env python3
"""生成演示视频：真实运行 moon7z 的命令行，把实际输出渲染成 MP4 / GIF。

原则：**不摆拍**——每一屏的内容都是本脚本现场执行命令后捕获的真实 stdout/stderr，
脚本只负责"打字 + 逐行显示"的呈现（含 `moon test`、`cmd/main list/extract`、
`tar -tvf` 对拍、`check_compat.py` 汇总）。

用法：
    python tools/make_demo.py                # 生成 docs/demo.mp4 + docs/demo.gif
    python tools/make_demo.py --fps 12 --keep-frames

依赖：Pillow、ffmpeg（用 --ffmpeg 指定；默认会找开发机上 imageio 自带的那个）。
注意：帧临时目录固定在工作区根 `_tmp_demo/frames`（**必须在 moon 模块之外**：
Python 的 `mkdtemp` 在 Windows 沙箱下建出的目录无法写入/删除，模块内残留目录
还会让 moon 的包发现直接失败）。
"""

import argparse
import pathlib
import shutil
import subprocess
import sys
from datetime import datetime

from PIL import Image, ImageDraw, ImageFont

sys.stdout.reconfigure(encoding="utf-8")

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
FONT_BODY = "C:/Windows/Fonts/simsun.ttc"
FONT_TITLE = "C:/Windows/Fonts/msyhbd.ttc"

W, H = 1280, 720
BG = (16, 20, 24)
FG = (214, 219, 224)
DIM = (130, 140, 150)
PROMPT = (126, 200, 130)
TITLE = (122, 180, 255)
OK = (140, 220, 150)
BAR = (28, 34, 40)

FFMPEG_CANDIDATES = [
    pathlib.Path.home() / "Desktop/moon/_ffmpeg/_bin/imageio_ffmpeg/binaries/ffmpeg-win-x86_64-v7.1.exe",
    pathlib.Path("C:/Users/1510/Desktop/moon/_ffmpeg/_bin/imageio_ffmpeg/binaries/ffmpeg-win-x86_64-v7.1.exe"),
]


def find_ffmpeg(explicit: str | None) -> str:
    if explicit:
        return explicit
    for cand in FFMPEG_CANDIDATES:
        if cand.exists():
            return str(cand)
    found = shutil.which("ffmpeg")
    if found:
        return found
    raise SystemExit("找不到 ffmpeg，请用 --ffmpeg 指定")


def run_capture(cmd: list[str], cwd: pathlib.Path) -> list[str]:
    """真实执行命令并返回输出行（最多 20 行，避免视频里溢出）。"""
    r = subprocess.run(
        cmd, cwd=cwd, capture_output=True, encoding="utf-8", errors="replace"
    )
    text = (r.stdout or "") + (r.stderr or "")
    lines = [ln.rstrip() for ln in text.splitlines() if ln.strip()]
    if not lines:
        lines = [f"(无输出，退出码 {r.returncode})"]
    if len(lines) > 20:
        lines = lines[:10] + ["…（略）"] + lines[-6:]
    return lines


def scenes() -> list[tuple[str, list[str], list[str]]]:
    """返回 (标题, 命令展示文本, 输出行)。所有输出都是现场捕获的真实结果。"""
    py = "python" if sys.platform.startswith("win") else "python3"
    specs = [
        (
            "1/6 单元测试（wasm-gc 后端）",
            "moon test --target wasm-gc",
            ["moon", "test", "--target", "wasm-gc"],
        ),
        (
            "2/6 列目录：默认档（编码头 + LZMA1 数据）",
            "moon run --target js cmd/main -- list tools/corpus/two_text.7z",
            ["moon", "run", "--target", "js", "cmd/main", "--", "list",
             "tools/corpus/two_text.7z"],
        ),
        (
            "3/6 列目录：含目录与嵌套路径（目录的 size/crc 显示为 -）",
            "moon run --target js cmd/main -- list tools/corpus/tree_copy.7z",
            ["moon", "run", "--target", "js", "cmd/main", "--", "list",
             "tools/corpus/tree_copy.7z"],
        ),
        (
            "4/6 解包落盘（自动创建子目录）",
            "moon run --target js cmd/main -- extract tools/corpus/tree_copy.7z demo_out",
            ["moon", "run", "--target", "js", "cmd/main", "--", "extract",
             "tools/corpus/tree_copy.7z", "../_tmp_demo/demo_out"],
        ),
        (
            "5/6 第三方对拍：libarchive(tar) 列目录（同一归档）",
            "tar -tvf tools/corpus/two_text_copy.7z",
            ["tar.exe" if sys.platform.startswith("win") else "tar", "-tvf",
             "tools/corpus/two_text_copy.7z"],
        ),
        (
            "6/6 兼容性对拍汇总：10 个真实归档逐一比对",
            f"{py} tools/check_compat.py --runner \"moon run --target js cmd/main --\" "
            "--oracle tar --min-ok 10",
            [py, "tools/check_compat.py", "--runner", "moon run --target js cmd/main --",
             "--oracle", "tar", "--min-ok", "10"],
        ),
    ]
    out = []
    for title, shown, cmd in specs:
        lines = run_capture(cmd, ROOT)
        out.append((title, shown, lines))
    return out


def wrap(draw: ImageDraw.ImageDraw, text: str, font, width: int) -> list[str]:
    """按像素宽度折行（中英文混排够用）。"""
    lines, cur = [], ""
    for ch in text:
        if draw.textlength(cur + ch, font=font) > width:
            lines.append(cur)
            cur = ch
        else:
            cur += ch
    if cur:
        lines.append(cur)
    return lines or [""]


def render(
    title: str,
    cmd_text: str,
    typed: int,
    shown_lines: list[str],
    footer: str,
    font_body,
    font_title,
) -> Image.Image:
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 46], fill=BAR)
    d.text((20, 12), title, font=font_title, fill=TITLE)
    d.text((W - 240, 14), footer, font=font_body, fill=DIM)

    # 命令行（带提示符与打字光标）
    y = 78
    d.text((24, y), "$", font=font_body, fill=PROMPT)
    visible = cmd_text[:typed]
    d.text((44, y), visible, font=font_body, fill=FG)
    if typed < len(cmd_text):
        x = 44 + d.textlength(visible, font=font_body)
        d.rectangle([x + 1, y + 2, x + 11, y + 22], fill=(200, 200, 200))
    y += 42

    # 输出区
    for line in shown_lines:
        color = OK if line.startswith(("Total tests", "OK", "a.txt", "b.txt", "top.txt")) else FG
        if line.startswith("$"):
            color = PROMPT
        for sub in wrap(d, line, font_body, W - 70)[:2]:
            if y > H - 50:
                return img
            d.text((44, y), sub, font=font_body, fill=color)
            y += 26
        y += 4
    return img


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fps", type=int, default=10)
    ap.add_argument("--ffmpeg")
    ap.add_argument("--keep-frames", action="store_true")
    args = ap.parse_args()
    ffmpeg = find_ffmpeg(args.ffmpeg)

    DOCS.mkdir(exist_ok=True)
    # 帧目录：放在 **模块之外** 的固定路径，用 mkdir(parents=True) 而不是 mkdtemp
    # —— 实测（2026-10-24）Python 的 mkdtemp 在 Windows 沙箱下建出的目录
    #    无法写入、也无法删除（PermissionError / 拒绝访问），还会污染工作区。
    frame_root = ROOT.parent / "_tmp_demo" / "frames"
    if frame_root.exists():
        shutil.rmtree(frame_root, ignore_errors=True)
    frame_root.mkdir(parents=True, exist_ok=True)
    print(f"帧目录：{frame_root}")

    font_body = ImageFont.truetype(FONT_BODY, 22)
    font_title = ImageFont.truetype(FONT_TITLE, 22)
    version = run_capture(["moon", "version"], ROOT)[0]
    footer = f"moon7z · {datetime.now().strftime('%Y-%m-%d')}"

    data = scenes()
    frames: list[Image.Image] = []
    for title, cmd_text, lines in data:
        # 打字：每次 2 个字符
        for typed in range(2, len(cmd_text) + 1, 2):
            frames.append(render(title, cmd_text, typed, [], footer, font_body, font_title))
        frames.append(render(title, cmd_text, len(cmd_text), [], footer, font_body, font_title))
        # 输出逐行出现
        for i in range(1, len(lines) + 1):
            frames.append(
                render(title, cmd_text, len(cmd_text), lines[:i], footer, font_body, font_title)
            )
        # 每屏停留约 1.4 秒
        for _ in range(int(args.fps * 1.4)):
            frames.append(
                render(title, cmd_text, len(cmd_text), lines, footer, font_body, font_title)
            )
    print(f"共 {len(frames)} 帧（约 {len(frames) / args.fps:.1f} 秒）")

    # 写帧
    for i, img in enumerate(frames):
        img.save(frame_root / f"f{i:05d}.png")

    mp4 = DOCS / "demo.mp4"
    gif = DOCS / "demo.gif"
    common = [
        ffmpeg,
        "-y",
        "-framerate",
        str(args.fps),
        "-i",
        str(frame_root / "f%05d.png"),
    ]
    r = subprocess.run(
        common + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "24",
                  "-movflags", "+faststart", str(mp4)],
        capture_output=True,
    )
    if r.returncode != 0:
        print(r.stderr.decode("utf-8", "replace")[-800:])
        raise SystemExit("ffmpeg 生成 MP4 失败")
    print(f"MP4: {mp4} ({mp4.stat().st_size / 1024:.0f} KB)")

    r = subprocess.run(
        common
        + ["-vf", f"fps={min(args.fps, 8)},scale=880:-1:flags=lanczos,split[a][b];"
                  f"[a]palettegen[p];[b][p]paletteuse", str(gif)],
        capture_output=True,
    )
    if r.returncode != 0:
        print(r.stderr.decode("utf-8", "replace")[-800:])
        raise SystemExit("ffmpeg 生成 GIF 失败")
    print(f"GIF: {gif} ({gif.stat().st_size / 1024:.0f} KB)")

    if not args.keep_frames:
        shutil.rmtree(frame_root, ignore_errors=True)
    print("完成")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
