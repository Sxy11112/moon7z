# moon7z

纯 MoonBit 实现的 **7z 归档只读解包库**（`.7z` / 7-Zip 容器），目标后端 `wasm-gc`，
**零第三方依赖**（只用 MoonBit 标准库）。

> 状态：`0.1.0` 开发中。当前已实现 F1（起始头解析 + CRC-32 校验），
> 条目列表、编码头解码与内容解压在后续增量中补齐。

## 为什么做这个

MoonBit 生态里归档格式已经很全：`zip`、`tar`、`gzip/deflate`、`brotli`、`xz/lzma` 都有纯
MoonBit 实现，**唯独 7z 没有**——而 7z 是 Windows 上最常见的分发格式。
已有的相邻项目层次不同：

| 包 | 覆盖范围 |
|---|---|
| `TWISTY2Ynb/moonmspack` | CAB / CHM / MSZIP / LZX（Microsoft 容器族） |
| `aurora0x27/lzma-mbt`、`lin2077-zeming/moonxz` | `.xz` / `.lzma` 单流格式的编解码 |
| **moon7z（本项目）** | **7z 归档容器**：属性树、Folder/Coder 图、文件表、Solid 块与解包 |

## 当前可用的 API（F1）

```moonbit
let z = @moon7z.SevenZ::open(bytes)   // 校验签名、版本、两处 CRC-32 与偏移边界
let sh = z.start_header()
println(sh.minor)                     // 归档次版本号（bsdtar 写 0.3，官方写 0.4）
println(sh.absolute_offset())         // 头数据库在文件中的绝对起点
println(sh.next_header_crc)           // 头数据库 CRC-32
```

所有输入都当作外部不可信数据：截断、签名不符、版本不支持、CRC 不符、偏移越界
都返回结构化的 `SevenZError`，不会 panic。

## 验证方式

- 真实语料由 `bsdtar`（Windows 自带 `tar.exe` / libarchive）生成：
  `python tools/gen_fixtures.py`；
- CRC-32 用标准检查值（zlib）做已知答案比对；
- 每个判据都做变异测试（改坏实现必须变红）。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。
