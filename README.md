# moon7z

纯 MoonBit 实现的 **7z 归档只读解包库**（`.7z` / 7-Zip 容器），目标后端 `wasm-gc`，
**零第三方依赖**（只用 MoonBit 标准库）。

> 状态：`0.1.0` 开发中。已实现 F1（起始头 + CRC-32 校验）与 F2（明文头解析 → 条目表），
> 可读取**明文头归档**（libarchive `7zip:compression=copy` 档）的文件名、大小、CRC 与目录结构；
> 编码头（默认压缩档）与内容解包在后续增量中补齐。

## 为什么做这个

MoonBit 生态里归档格式已经很全：`zip`、`tar`、`gzip/deflate`、`brotli`、`xz/lzma` 都有纯
MoonBit 实现，**唯独 7z 没有**——而 7z 是 Windows 上最常见的分发格式。
已有的相邻项目层次不同：

| 包 | 覆盖范围 |
|---|---|
| `TWISTY2Ynb/moonmspack` | CAB / CHM / MSZIP / LZX（Microsoft 容器族） |
| `aurora0x27/lzma-mbt`、`lin2077-zeming/moonxz` | `.xz` / `.lzma` 单流格式的编解码 |
| **moon7z（本项目）** | **7z 归档容器**：属性树、Folder/Coder 图、文件表、Solid 块与解包 |

## 当前可用的 API

```moonbit
let z = @moon7z.SevenZ::open(bytes)   // 校验签名、版本、两处 CRC-32 与偏移边界

// F1：起始头
let sh = z.start_header()
println(sh.minor)                     // 归档次版本号（bsdtar 写 0.3，官方写 0.4）
println(sh.absolute_offset())         // 头数据库在文件中的绝对起点

// F2：条目表与流信息（明文头）
let entries = z.entries()             // [Entry]：name / size / crc / is_dir
let streams = z.streams()             // 打包位置与大小、Folder/coder 链、子流大小与 CRC
```

所有输入都当作外部不可信数据：截断、签名不符、版本不支持、CRC 不符、偏移越界、
属性树非法都返回结构化的 `SevenZError`，不会 panic。

### 兼容性说明：kName 块的两种形态

`kName`（文件名字块）按格式说明是 UTF-16LE、每名以 `0x0000` 结束。但实测
**libarchive（bsdtar）写出的块首多一个 `0x00` 字节**，而且 libarchive 只接受这种形态
（把该字节去掉后 `tar -tf` 报 `Damaged`，见 `tools/gen_fixtures.py` 的构造注释）。
本实现两种形态都支持：判据不是"名字个数是否等于 numFiles"（两种形态都能凑出同样的个数，
libarchive 形态会解出乱码名字），而是**整个块必须被精确消费完**，只有满足该条件的偏移才被接受。

## 验证方式

- 真实语料由 `bsdtar`（Windows 自带 `tar.exe` / libarchive）生成：
  `python tools/gen_fixtures.py`（默认保留已提交的语料，`--force` 才重生成，`--only <名字>` 只处理一个）；
- 期望值来自**独立来源**：`tar -tvf` 的列目录结果 + Python `zlib.crc32` 算出的内容 CRC；
- CRC-32 用标准检查值（zlib）做已知答案比对；
- 每个判据都做变异测试（改坏实现必须变红，并记录能抓到什么）。

语料（`tools/corpus/`）：

| 语料 | 压缩 | 说明 |
|---|---|---|
| `two_text.7z` / `two_text_lzma1/2.7z` | LZMA/LZMA2 | 编码头（0x17），供 F4/F5 |
| `two_text_copy.7z` | copy | 明文头，多文件 |
| `one_file_copy.7z` / `tree_copy.7z` | copy | 单文件；含目录条目（kEmptyStream） |
| `minimal_two_copy.7z` | copy | 手工构造的最小两文件归档（libarchive 复核可读） |

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。
