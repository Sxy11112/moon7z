// signature_wbtest.mbt
//
// F1 判据：起始头定位 + CRC-32 校验。
//
// 差分来源（独立于本实现）：
// - 已知答案来自标准 CRC-32 检查值（Python zlib 的 `crc32`）：
//   "" -> 0x00000000、"A" -> 0xD3D99E8B、"123456789" -> 0xCBF43926；
// - 真实归档 `tools/corpus/two_text.7z`（bsdtar / libarchive 生成，208 字节），
//   StartHeaderCRC 与 NextHeaderCRC 由 Python zlib 独立算出：
//   crc32(bytes[12..32)) = 0x3CEA5476，crc32(next header) = 0x38642CAD。
// 语料可随时用 `python tools/gen_fixtures.py` 重新生成（脚本会打印同样的 hex）。

///|
/// 十六进制字符 -> 0..15。
fn hex_nibble(b : Byte) -> Int32 {
  let v = b.to_int()
  if v >= 0x30 && v <= 0x39 {
    v - 0x30
  } else if v >= 0x61 && v <= 0x66 {
    v - 0x61 + 10
  } else if v >= 0x41 && v <= 0x46 {
    v - 0x41 + 10
  } else {
    abort("非法十六进制字符")
  }
}

///|
/// 十六进制字符串 -> Bytes（测试基座用，库代码不导出）。
fn bytes_from_hex(text : String) -> Bytes {
  let src = @utf8.encode(text)
  let buf = @buffer.Buffer()
  let mut i = 0
  while i < src.length() {
    let hi = hex_nibble(src.unsafe_get(i))
    let lo = hex_nibble(src.unsafe_get(i + 1))
    buf.write_byte(((hi * 16 + lo) & 0xFF).to_byte())
    i += 2
  }
  buf.to_bytes()
}

///|
/// 复制 `data`，并把 `[offset, offset + width)` 换成 `value` 的小端编码。
fn patch_le(
  data : Bytes,
  offset : Int32,
  width : Int32,
  value : Int64,
) -> Bytes {
  let buf = @buffer.Buffer()
  for i in 0..<data.length() {
    if i >= offset && i < offset + width {
      buf.write_byte(((value >> ((i - offset) * 8)) & 0xFFL).to_int().to_byte())
    } else {
      buf.write_byte(data.unsafe_get(i))
    }
  }
  buf.to_bytes()
}

///|
/// 取前 `n` 字节（构造截断样本）。
fn prefix(data : Bytes, n : Int32) -> Bytes {
  let buf = @buffer.Buffer()
  for i in 0..<n {
    buf.write_byte(data.unsafe_get(i))
  }
  buf.to_bytes()
}

///|
/// 真实语料：bsdtar 生成的 two_text.7z（215 字节，LZMA 数据 + 编码头）。
/// 归档里带文件时间戳，重新生成不会逐字节相同，故以仓库中提交的字节为准：
/// sha256 = 5634fc366ddebe9595550811b4e7d6d91e4cd1a41048043c1f8d13a0189bcabb
let fixture_two_text : Bytes = bytes_from_hex(
  "377abcaf271c00030d152f6c96000000" +
  "0000000021000000000000000f532813" +
  "0020ef6668329bdc9d8fb4ea602abaad" +
  "793085390eec17941565ec6f4ffffe94" +
  "58000000813307ae0fd02cf4bc9f3f47" +
  "4165c5d8afe40b970a72f631f834659c" +
  "e55e23363cfb758e00464471f2bd7bdd" +
  "caa63b455325017958871de6f0e6d562" +
  "a0d063fe106144dd6928cf1c02ece13d" +
  "14bc5c34c1273ace3383464f9210a4f0" +
  "983814a9ede337a7f12062ef4acb1e30" +
  "0bfffac2d80017062201097400070b01" +
  "000123030101055d000080000c80940a" +
  "019ae6bdab0000",
)

///|
test "crc32 已知答案向量（zlib 标准检查值）" {
  @test.assert_eq(crc32(b"", 0, 0), 0L)
  @test.assert_eq(crc32(b"Axxx", 0, 1), 0xD3D99E8BL)
  @test.assert_eq(crc32(b"123456789xxx", 0, 9), 0xCBF43926L)
  // 区间语义：只算 [start, end)
  @test.assert_eq(crc32(b"xx123456789", 2, 11), 0xCBF43926L)
}

///|
test "crc32 增量与一次性等价" {
  let data = fixture_two_text
  let c = Crc32::new()
  c.update(data, 0, 7)
  c.update(data, 7, 100)
  c.update(data, 100, data.length())
  @test.assert_eq(c.finalize(), crc32(data, 0, data.length()))
}

///|
test "crc32 覆盖真实归档的 StartHeader 区间" {
  // Python zlib 独立算出：crc32(fixture[12..32)) == 0x6C2F150D
  @test.assert_eq(crc32(fixture_two_text, 12, 32), 0x6C2F150DL)
}

///|
test "打开真实归档：起始头字段逐项核对" {
  let z = SevenZ::open(fixture_two_text)
  let sh = z.start_header()
  @test.assert_eq(z.size(), 215)
  @test.assert_eq(sh.major, 0)
  @test.assert_eq(sh.minor, 3) // bsdtar/libarchive 写作 0.3
  @test.assert_eq(sh.next_header_offset, 150L)
  @test.assert_eq(sh.next_header_size, 33L)
  @test.assert_eq(sh.next_header_crc, 0x1328530FL)
  @test.assert_eq(sh.absolute_offset(), 182L)
  @test.assert_eq(sh.absolute_end(), 215L)
  // 下一头第一字节确实是 kEncodedHeader(0x17)
  @test.assert_eq(
    fixture_two_text.unsafe_get(sh.absolute_offset().to_int()).to_int(),
    0x17,
  )
}

///|
test "负例：截断" {
  for n in [0, 6, 31] {
    try {
      let _ = SevenZ::open(prefix(fixture_two_text, n))
      abort("应当 Truncated")
    } catch {
      SevenZError::Truncated(..) => ()
      _ => abort("错误类型不对")
    }
  }
}

///|
test "负例：签名不符" {
  try {
    let _ = SevenZ::open(patch_le(fixture_two_text, 0, 1, 0x38L))
    abort("应当 BadSignature")
  } catch {
    SevenZError::BadSignature(found~) => @test.assert_eq(found, "387abcaf271c")
    _ => abort("错误类型不对")
  }
}

///|
test "负例：主版本号非 0" {
  try {
    let _ = SevenZ::open(patch_le(fixture_two_text, 6, 1, 1L))
    abort("应当 UnsupportedVersion")
  } catch {
    SevenZError::UnsupportedVersion(major~, minor~) => {
      @test.assert_eq(major, 1)
      @test.assert_eq(minor, 3)
    }
    _ => abort("错误类型不对")
  }
}

///|
test "负例：StartHeaderCRC 被篡改" {
  try {
    let _ = SevenZ::open(patch_le(fixture_two_text, 8, 4, 0x77L))
    abort("应当 BadCrc(start header)")
  } catch {
    SevenZError::BadCrc(what~, expected~, actual~) => {
      @test.assert_eq(what, "start header")
      @test.assert_eq(actual, crc32(fixture_two_text, 12, 32))
      if expected == actual {
        abort("期望的 CRC 与实际值不同")
      }
    }
    _ => abort("错误类型不对")
  }
}

///|
test "负例：下一头内容被篡改" {
  try {
    let _ = SevenZ::open(patch_le(fixture_two_text, 182, 1, 0x18L))
    abort("应当 BadCrc(next header)")
  } catch {
    SevenZError::BadCrc(what~, ..) => @test.assert_eq(what, "next header")
    _ => abort("错误类型不对")
  }
}

///|
test "负例：下一头偏移越界（StartHeaderCRC 同步重算）" {
  // 只改 offset、不重算 StartHeaderCRC 会先触发 CRC 判据；这里把 CRC 一起
  // 重算，确保判据落在"越界"这条规则上（否则该分支永远测不到）。
  let moved = patch_le(fixture_two_text, 12, 8, 0xFFFFL)
  let consistent = patch_le(moved, 8, 4, crc32(moved, 12, 32))
  try {
    let _ = SevenZ::open(consistent)
    abort("应当 Malformed（偏移越界）")
  } catch {
    SevenZError::Malformed(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "负例：下一头长度越界（StartHeaderCRC 同步重算）" {
  let sized = patch_le(fixture_two_text, 20, 8, 4096L)
  let consistent = patch_le(sized, 8, 4, crc32(sized, 12, 32))
  try {
    let _ = SevenZ::open(consistent)
    abort("应当 Malformed（长度越界）")
  } catch {
    SevenZError::Malformed(..) => ()
    _ => abort("错误类型不对")
  }
}
