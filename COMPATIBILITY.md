# 兼容性对拍报告（脚本生成，请勿手改）

- 本实现：`moon run --target js cmd/main --`
- 对照实现：`tar`（bsdtar/tar = libarchive；7z = 7-Zip）
- 模式：list + 内容 CRC
- 平台：win32
- 语料：10 个归档（`tools\corpus`）

复现：

```bash
python3 tools/check_compat.py --runner "moon run --target js cmd/main --" --oracle tar --out COMPATIBILITY.md --min-ok 10
```

| 归档 | 列目录 | 内容 CRC | 解包字节 | 说明 |
|---|---|---|---|---|
| `big_copy.7z` | OK | OK（1 个文件） | 未做（默认模式） | - |
| `empty_file_copy.7z` | OK | OK（1 个文件） | 未做（默认模式） | - |
| `minimal_two_copy.7z` | OK | OK（2 个文件） | 未做（默认模式） | - |
| `nested_copy.7z` | OK | OK（2 个文件，1 个非 ASCII 名字留给 CI） | 未做（默认模式） | - |
| `one_file_copy.7z` | OK | OK（1 个文件） | 未做（默认模式） | - |
| `tree_copy.7z` | OK | OK（2 个文件） | 未做（默认模式） | - |
| `two_text.7z` | OK | OK（2 个文件） | 未做（默认模式） | - |
| `two_text_copy.7z` | OK | OK（2 个文件） | 未做（默认模式） | - |
| `two_text_lzma1.7z` | OK | OK（2 个文件） | 未做（默认模式） | - |
| `two_text_lzma2.7z` | OK | OK（2 个文件） | 未做（默认模式） | - |

**汇总**：一致 10，DIFF 0，跳过 0（要求一致数 ≥ 10）
