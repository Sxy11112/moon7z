// extract_wbtest.mbt
//
// F3 判据：COPY 流的端到端解包与 CRC 校验。
//
// 期望值全部来自独立来源：
// - 内容字节由 `tar -xf` 解出的文件（`tools/gen_fixtures.py` 生成时已复核），
//   也是构造语料时写进去的原始字节；
// - 子流/文件 CRC 由 Python zlib 计算，写进归档时使用同一批值。

///|
/// 语料：bsdtar 生成、单文件 copy 档（内容 "hello moon7z\n"）。
/// sha256 = 42760038e4e1772a0261d1674aeedf39894aa6cfa35fdf39d540853cef047ab4
let fixture_one_file_copy : Bytes = bytes_from_hex(
  "377abcaf271c0003bb74c4530d000000" +
  "000000006200000000000000c049fffc" +
  "68656c6c6f206d6f6f6e377a0a010406" +
  "0001090d00070b01000101000c0d0008" +
  "0a01fae3b5c700000501111500680065" +
  "006c006c006f002e0074007800740000" +
  "00140a01000080a621c989d601120a01" +
  "00b697209a8563dd01130a01000080a6" +
  "21c989d601150601002080b6810000",
)

///|
/// 语料：bsdtar 生成、含一个 0 字节文件的归档（data.txt 在前，empty.txt 在后）。
/// sha256 = f55213d4fcff7be253235bf78fa67e616c2830ee1296574f947bff4f398d3bc7
let fixture_empty_file_copy : Bytes = bytes_from_hex(
  "377abcaf271c00039975cf3e05000000" +
  "000000009600000000000000ac5f4a12" +
  "646174610a0104060001090500070b01" +
  "000101000c0500080a0182c5c1e60000" +
  "05020e01400f01801127006400610074" +
  "0061002e00740078007400000065006d" +
  "007000740079002e0074007800740000" +
  "00141201000080a621c989d6010080a6" +
  "21c989d601121201000dec240f8f63dd" +
  "01a6b4240f8f63dd01131201000080a6" +
  "21c989d6010080a621c989d601150a01" +
  "002080b6812080b6810000",
)

///|
/// 语料：bsdtar 生成、LZMA2 压缩（头流与数据流都用 LZMA2）的归档。
/// sha256 = abeff955d4446548db12aa75dcf2d7ae946ca849fef6620713176e6a9ece654a
let fixture_two_text_lzma2 : Bytes = bytes_from_hex(
  "377abcaf271c000339afce5095000000" +
  "000000001b00000000000000139badfb" +
  "e003b5001c5d0020ef6668329bdc9d8f" +
  "b4ea602abaad793085390eec17941562" +
  "cead0000e0008d00695d0000813307ae" +
  "0fd04b393c9f3f4741057bee1d0eee92" +
  "1a51b9b6a8a2dd5f3cd1b6b26b3ddcdc" +
  "a112c6804d7b5c5d2c9de1ed98ee72af" +
  "421222d32e125f649457c52d1f2a1298" +
  "4833d36cbb2be6efc3d7a3388c9c1567" +
  "99240527744141050676aa813241fa89" +
  "000000000017062401097100070b0100" +
  "01212101160c808e0a016135faca0000",
)

///|
/// `two_text` 系列语料的 a.txt 内容：200 个 'A'。
fn expected_a_txt() -> Bytes {
  let buf = @buffer.Buffer()
  for _ in 0..<200 {
    buf.write_byte(b'A')
  }
  buf.to_bytes()
}

///|
/// `two_text` 系列语料的 b.txt 内容：15 字节模式重复 50 次 = 750 字节。
fn expected_b_txt() -> Bytes {
  let buf = @buffer.Buffer()
  for _ in 0..<50 {
    for b in b"hello 7z world " {
      buf.write_byte(b)
    }
  }
  buf.to_bytes()
}

///|
/// 字节比较：失败时把实际值与期望值都渲染成十六进制（可打印、可解析）。
fn assert_bytes_eq(actual : Bytes, expected : Bytes, what : String) -> Unit {
  if !actual.equal(expected) {
    abort(
      what +
      " 不符：实际 " +
      hex_string(actual) +
      "，期望 " +
      hex_string(expected),
    )
  }
}

///|
test "COPY 解包：手工构造的两文件归档" {
  let files = SevenZ::open(fixture_minimal_two_copy).extract_all()
  @test.assert_eq(files.length(), 2)
  @test.assert_eq(files[0].name, "a.txt")
  assert_bytes_eq(files[0].data, b"AAA", "a.txt")
  @test.assert_eq(files[1].name, "b.txt")
  assert_bytes_eq(files[1].data, b"BB", "b.txt")
}

///|
test "COPY 解包：含目录条目时目录被跳过" {
  let files = SevenZ::open(fixture_tree_copy).extract_all()
  @test.assert_eq(files.length(), 2)
  @test.assert_eq(files[0].name, "top.txt")
  assert_bytes_eq(files[0].data, b"top\n", "top.txt")
  @test.assert_eq(files[1].name, "dir/inner.txt")
  assert_bytes_eq(files[1].data, b"inner\n", "dir/inner.txt")
}

///|
test "COPY 解包：真实单文件归档" {
  let files = SevenZ::open(fixture_one_file_copy).extract_all()
  @test.assert_eq(files.length(), 1)
  @test.assert_eq(files[0].name, "hello.txt")
  assert_bytes_eq(files[0].data, b"hello moon7z\n", "hello.txt")
}

///|
test "按名字取单个文件" {
  let z = SevenZ::open(fixture_minimal_two_copy)
  assert_bytes_eq(z.extract("b.txt"), b"BB", "b.txt")
  try {
    let _ = z.extract("nope.txt")
    abort("应当 Malformed")
  } catch {
    SevenZError::Malformed(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "负例：packed 数据被篡改 → 子流 CRC 不符" {
  // 第一个文件的数据在 32 + pack_pos(=0) 处；改一个字节，头 CRC 不受影响
  let bad = patch_le(fixture_minimal_two_copy, 32, 1, 0x42L)
  try {
    let _ = SevenZ::open(bad).extract_all()
    abort("应当 BadCrc")
  } catch {
    SevenZError::BadCrc(what~, ..) => @test.assert_eq(what, "substream 0/0")
    _ => abort("错误类型不对")
  }
}

///|
test "LZMA1 端到端解包（默认档：编码头 + LZMA 数据流）" {
  let z = SevenZ::open(fixture_two_text)
  let files = z.extract_all()
  @test.assert_eq(files.length(), 2)
  @test.assert_eq(files[0].name, "a.txt")
  assert_bytes_eq(files[0].data, expected_a_txt(), "a.txt")
  @test.assert_eq(files[1].name, "b.txt")
  assert_bytes_eq(files[1].data, expected_b_txt(), "b.txt")
}

///|
test "LZMA2 端到端解包（编码头与数据流都用 LZMA2）" {
  let z = SevenZ::open(fixture_two_text_lzma2)
  let files = z.extract_all()
  @test.assert_eq(files.length(), 2)
  @test.assert_eq(files[0].name, "a.txt")
  assert_bytes_eq(files[0].data, expected_a_txt(), "a.txt")
  @test.assert_eq(files[1].name, "b.txt")
  assert_bytes_eq(files[1].data, expected_b_txt(), "b.txt")
}

///|
test "负例：LZMA 数据流被篡改 → LzmaCorrupt 或 BadCrc" {
  // two_text.7z 的 packed 数据流在 32..66（LZMA1，34 字节）；翻转中间一个字节。
  // 允许两种结局：码流本身错（LzmaCorrupt）或解出来但 CRC 不符（BadCrc）——
  // 二者都必须是结构化错误，绝不能 panic 或静默返回错误数据。
  let bad = patch_le(fixture_two_text, 50, 1, 0xFFL)
  try {
    let _ = SevenZ::open(bad).extract_all()
    abort("应当报错")
  } catch {
    SevenZError::LzmaCorrupt(..) => ()
    SevenZError::BadCrc(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "负例：不支持的 coder 报 Unsupported" {
  // 最小语料的 folder coder 是 COPY（flag=0x01, id=0x00）：头内偏移 15
  // （头起点 37 + 15 = 文件偏移 52）。改成 1 字节 id=0x03（DELTA）并重签 CRC：
  // DELTA 本实现未支持，但解析必须正常走到 "coder 不支持" 这条分支。
  // 注意不要改成 0x21（LZMA2）——那已经支持了，测不到这条分支。
  let coder_pos = 37 + 15
  let bad = resign(
    patch_le(fixture_minimal_two_copy, coder_pos, 1, 0x03L),
    37,
    104,
  )
  try {
    let _ = SevenZ::open(bad).extract_all()
    abort("应当 Unsupported(coder)")
  } catch {
    SevenZError::Unsupported(what~) => @test.assert_eq(what, "coder 0x3")
    _ => abort("错误类型不对")
  }
}

///|
test "空文件条目：is_dir=false、产出空 Bytes（不被当成目录跳过）" {
  let z = SevenZ::open(fixture_empty_file_copy)
  let entries = z.entries()
  @test.assert_eq(entries.length(), 2)
  @test.assert_eq(entries[0].name, "data.txt")
  @test.assert_eq(entries[0].size, 5L)
  @test.assert_eq(entries[0].is_dir, false)
  @test.assert_eq(entries[1].name, "empty.txt")
  @test.assert_eq(entries[1].size, 0L)
  @test.assert_eq(entries[1].crc, None)
  @test.assert_eq(entries[1].is_dir, false)
  let files = z.extract_all()
  @test.assert_eq(files.length(), 2)
  assert_bytes_eq(files[0].data, b"data\n", "data.txt")
  @test.assert_eq(files[1].name, "empty.txt")
  @test.assert_eq(files[1].data.length(), 0)
}
