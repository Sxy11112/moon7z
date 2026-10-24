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
test "负例：编码头归档暂不支持解包" {
  try {
    let _ = SevenZ::open(fixture_two_text).extract_all()
    abort("应当 Unsupported")
  } catch {
    SevenZError::Unsupported(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "负例：非 COPY coder 报 Unsupported" {
  // 最小语料的 folder coder 是 COPY（flag=0x01, id=0x00）：头内偏移 15
  // （头起点 37 + 15 = 文件偏移 52）。改成 1 字节 id=0x21（LZMA2）并重签 CRC。
  // 只测"未支持 coder 的分支"，因此不要求 packed 数据可解。
  let coder_pos = 37 + 15
  let bad = resign(
    patch_le(fixture_minimal_two_copy, coder_pos, 1, 0x21L),
    37,
    104,
  )
  try {
    let _ = SevenZ::open(bad).extract_all()
    abort("应当 Unsupported(coder)")
  } catch {
    SevenZError::Unsupported(what~) => @test.assert_eq(what, "coder 0x21")
    _ => abort("错误类型不对")
  }
}
