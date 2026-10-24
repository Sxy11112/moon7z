// header_wbtest.mbt
//
// F2 判据：明文头数据库解析。
//
// 语料（`tools/corpus/`，由 bsdtar/libarchive 生成，用 `tar -tf` 复核过）：
// - minimal_two_copy.7z（104 字节）：两个小文件，2 个 Folder / 2 个子流；
// - tree_copy.7z（240 字节）：两个文件 + 一个目录条目（kEmptyStream 位域）；
// - one_file_copy.7z（143 字节）：单文件，最早用于打通解析路径。
// 期望值（名字 / 大小 / CRC）均由 `tar -tvf` 与 Python zlib 独立给出：
//   top.txt = 4 字节 crc 0x4978F422、dir/inner.txt = 6 字节 crc 0xD0024D8C、
//   a.txt = 3 字节 crc 0x66A031A7、b.txt = 2 字节 crc 0x1B441FC4。

///|
/// 语料：手工构造的最小两文件 7z（COPY，明文头）。
/// sha256 = e74dd140bd812692f5a6963a8fe998f4388e107e6040a47e20b70247005468be
let fixture_minimal_two_copy : Bytes = bytes_from_hex(
  "377abcaf271c00045c38439c05000000" +
  "000000004300000000000000a81cac9f" +
  "4141414242010406000209030200070b" +
  "02000101000101000c030200080a01a7" +
  "31a066c41f441b000005021119006100" +
  "2e00740078007400000062002e007400" +
  "7800740000000000",
)

///|
/// 语料：bsdtar 生成、含目录条目的归档。
/// sha256 = a1e5f21b19a8b85c379a0b20e46863925d49cc433656cb2e10bd45de1e45993a
let fixture_tree_copy : Bytes = bytes_from_hex(
  "377abcaf271c00032b106b990a000000" +
  "00000000c60000000000000006a9dd76" +
  "746f700a696e6e65720a010406000209" +
  "040600070b02000101000101000c0406" +
  "00080a0122f478498c4d02d000000503" +
  "0e012011350074006f0070002e007400" +
  "7800740000006400690072002f006900" +
  "6e006e00650072002e00740078007400" +
  "00006400690072000000141a01000080" +
  "a621c989d6010080a621c989d601cee0" +
  "5a248663dd01121a0100cee05a248663" +
  "dd01cee05a248663dd01cee05a248663" +
  "dd01131a01000080a621c989d6010080" +
  "a621c989d601cee05a248663dd01150e" +
  "01002080b6812080b6811080ff410000",
)

///|
/// 把归档的下一头 CRC 与 StartHeaderCRC 重算一遍。
///
/// 负例要落在"结构非法"这条规则上，就不能让 F1 的 CRC 判据先拦住，
/// 因此篡改结构后必须同步重签（否则测到的是 F1 而不是 F2）。
/// `start` / `end` 是下一头在文件中的**绝对**区间。
fn resign(data : Bytes, start : Int32, end : Int32) -> Bytes {
  let with_nh_crc = patch_le(data, 28, 4, crc32(data, start, end))
  patch_le(with_nh_crc, 8, 4, crc32(with_nh_crc, 12, 32))
}

///|
test "最小两文件归档：条目名 / 大小 / CRC 与 tar 一致" {
  let z = SevenZ::open(fixture_minimal_two_copy)
  let entries = z.entries()
  @test.assert_eq(entries.length(), 2)
  @test.assert_eq(entries[0].name, "a.txt")
  @test.assert_eq(entries[0].size, 3L)
  @test.assert_eq(entries[0].crc, Some(0x66A031A7L))
  @test.assert_eq(entries[0].is_dir, false)
  @test.assert_eq(entries[1].name, "b.txt")
  @test.assert_eq(entries[1].size, 2L)
  @test.assert_eq(entries[1].crc, Some(0x1B441FC4L))
  @test.assert_eq(entries[1].is_dir, false)
}

///|
test "最小两文件归档：流信息（pack / folder / 子流）" {
  let z = SevenZ::open(fixture_minimal_two_copy)
  let s = z.streams()
  @test.assert_eq(s.pack_pos, 0L)
  @test.assert_eq(s.pack_sizes.length(), 2)
  @test.assert_eq(s.pack_sizes[0], 3L)
  @test.assert_eq(s.pack_sizes[1], 2L)
  @test.assert_eq(s.folders.length(), 2)
  // COPY coder，且每个 folder 一个子流
  @test.assert_eq(s.folders[0].coders.length(), 1)
  @test.assert_eq(s.folders[0].coders[0].id, 0L)
  @test.assert_eq(s.folders[0].num_sub_streams, 1)
  @test.assert_eq(s.folders[0].sub_sizes[0], 3L)
  @test.assert_eq(s.folders[1].sub_sizes[0], 2L)
}

///|
test "含目录归档：目录条目 is_dir=true，且不占用子流" {
  let z = SevenZ::open(fixture_tree_copy)
  let entries = z.entries()
  @test.assert_eq(entries.length(), 3)
  @test.assert_eq(entries[0].name, "top.txt")
  @test.assert_eq(entries[0].size, 4L)
  @test.assert_eq(entries[0].crc, Some(0x4978F422L))
  @test.assert_eq(entries[0].is_dir, false)
  @test.assert_eq(entries[1].name, "dir/inner.txt")
  @test.assert_eq(entries[1].size, 6L)
  @test.assert_eq(entries[1].crc, Some(0xD0024D8CL))
  @test.assert_eq(entries[1].is_dir, false)
  // bsdtar 在 kName 里写的是 "dir"（尾斜杠只是 tar 列表的显示约定）
  @test.assert_eq(entries[2].name, "dir")
  @test.assert_eq(entries[2].size, 0L)
  @test.assert_eq(entries[2].crc, None)
  @test.assert_eq(entries[2].is_dir, true)
}

///|
test "kEmptyStream 是裸位域：只有第 3 个条目无数据流" {
  let z = SevenZ::open(fixture_tree_copy)
  let s = z.streams()
  // 两个文件 → 两个子流；目录不产生子流
  @test.assert_eq(s.folders.length(), 2)
  @test.assert_eq(s.pack_sizes[0], 4L)
  @test.assert_eq(s.pack_sizes[1], 6L)
}

///|
test "编码头（默认档）：解出被压缩的头，条目表与 copy 档一致" {
  // two_text.7z 的下一头是 kEncodedHeader(0x17)：其中的 StreamsInfo 指向
  // 文件偏移 66..184 的 packed 头流（LZMA1，props=5d00008000，解压 148 字节）。
  let z = SevenZ::open(fixture_two_text)
  let entries = z.entries()
  @test.assert_eq(entries.length(), 2)
  @test.assert_eq(entries[0].name, "a.txt")
  @test.assert_eq(entries[0].size, 200L)
  @test.assert_eq(entries[0].crc, Some(0x28BB3D98L))
  @test.assert_eq(entries[1].name, "b.txt")
  @test.assert_eq(entries[1].size, 750L)
  @test.assert_eq(entries[1].crc, Some(0x4E7B5C05L))
  // 数据流同样是 LZMA1（coder 0x030101）
  let s = z.streams()
  @test.assert_eq(s.folders.length(), 1)
  @test.assert_eq(s.folders[0].coders.length(), 1)
  @test.assert_eq(s.folders[0].coders[0].id, 0x030101L)
}

///|
test "负例：编码头 packed 数据损坏 → 结构化错误" {
  // 翻转 packed 头流靠前的一个字节（绝对偏移 72，位于 66..184 之间、
  // 紧跟 5 字节 range coder 初始化之后）。它不在 StartHeaderCRC /
  // NextHeaderCRC 的覆盖范围内，所以必须由"解码头"这条路径抓住。
  //
  // 两种结局都合法：码流本身被破坏（LzmaCorrupt），或解出来但 CRC 不符
  // （BadCrc("encoded header")）。用靠后的字节可能落在"未被消费的 flush
  // 尾部"里而毫无影响，所以这里刻意选靠前的位置。
  let bad = patch_le(fixture_two_text, 72, 1, 0xFFL)
  try {
    let _ = SevenZ::open(bad).entries()
    abort("应当报结构化错误")
  } catch {
    SevenZError::BadCrc(what~, ..) => @test.assert_eq(what, "encoded header")
    SevenZError::LzmaCorrupt(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "负例：编码头声明的 CRC 与实际不符 → BadCrc(encoded header)" {
  // EncodedHeader 的布局（fixture 实测）：
  //   184=0x17 kEncodedHeader，185..190 PackInfo，191.. kUnpackInfo，
  //   209=0x0a kCRC，210=0x01 allDefined，211..214 = 解出头的 CRC-32。
  // 改掉这 4 字节并重签下一头/起始头 CRC，判据就只可能落在
  // "解出头的 CRC 与声明不符"这条规则上。
  let bad = resign(patch_le(fixture_two_text, 211, 4, 0x12345678L), 184, 217)
  try {
    let _ = SevenZ::open(bad).entries()
    abort("应当 BadCrc(encoded header)")
  } catch {
    SevenZError::BadCrc(what~, ..) => @test.assert_eq(what, "encoded header")
    _ => abort("错误类型不对")
  }
}

///|
test "编码头尾部未被消费的字节不影响结果" {
  // 与上一条互补：LZMA1 裸流的尾部可能有编码器 flush 但解码器用不到的字节
  // （内核向量里实测 29/34 被消费）。改动这类字节必须仍然解出正确条目表，
  // 否则说明我们把"合法归档"误判成损坏。
  let tail = patch_le(fixture_two_text, 183, 1, 0x00L)
  let entries = SevenZ::open(tail).entries()
  @test.assert_eq(entries.length(), 2)
  @test.assert_eq(entries[0].name, "a.txt")
  @test.assert_eq(entries[1].name, "b.txt")
}

///|
test "负例：Header 中出现未知属性" {
  // 明文头第 2 个字节是 kMainStreamsInfo(0x04)：改成 0x7f 并重签 CRC
  let bad = resign(
    patch_le(fixture_minimal_two_copy, 37 + 1, 1, 0x7FL),
    37,
    104,
  )
  try {
    let _ = SevenZ::open(bad).entries()
    abort("应当 Malformed")
  } catch {
    SevenZError::Malformed(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "负例：kName 块长度非法" {
  // kName 的 size 字段在文件偏移 76（= 头起点 37 + 39）：改成 3，长度对不上
  let bad = resign(patch_le(fixture_minimal_two_copy, 76, 1, 3L), 37, 104)
  try {
    let _ = SevenZ::open(bad).entries()
    abort("应当 Malformed")
  } catch {
    SevenZError::Malformed(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "负例：numFiles 与实际名字数不符" {
  // kFilesInfo 的 numFiles 在文件偏移 74（= 73 + 1）：改成 9，名字只有 2 个
  let bad = resign(patch_le(fixture_minimal_two_copy, 74, 1, 9L), 37, 104)
  try {
    let _ = SevenZ::open(bad).entries()
    abort("应当 Malformed")
  } catch {
    SevenZError::Malformed(..) => ()
    _ => abort("错误类型不对")
  }
}
