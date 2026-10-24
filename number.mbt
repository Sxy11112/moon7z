// number.mbt
//
// 7z 头里的两种复合编码：
// - NUMBER：可变长无符号整数（首字节前导 1 的个数 = 后续小端字节数 0..8）；
// - BooleanList：`allDefined` 字节 + 可选位域（每字节 8 项，MSB 在前）。
//
// 依据 py7zr《.7z format specification》"Integers" / "BooleanList" 两节。
// 两者都只被头部解析使用，但后续增量的 FilesInfo 时间/属性字段也要用，
// 因此抽成独立原语，而不是塞在某个解析分支里。

///|
/// 读一个 7z NUMBER（0 .. 2^64-1）。
pub fn ByteReader::read_number(self : ByteReader) -> Int64 raise SevenZError {
  let first = self.read_byte()
  let mut extra = 0
  let mut mask = 0x80
  while extra < 8 && (first & mask) != 0 {
    extra += 1
    mask = mask >> 1
  }
  if extra == 8 {
    // 11111111 + 8 字节小端
    return self.read_u64()
  }
  // extra < 7 时首字节还带 (7-extra) 个有效位；extra == 7 时首字节无有效位
  let hi = if extra < 7 { first & (mask - 1) } else { 0 }
  let mut lo = 0L
  let mut i = 0
  while i < extra {
    lo = lo | (self.read_byte().to_int64() << (8 * i))
    i += 1
  }
  (hi.to_int64() << (8 * extra)) + lo
}

///|
/// 读 `count` 个布尔值（BooleanList）。
pub fn ByteReader::read_booleans(
  self : ByteReader,
  count : Int32,
) -> Array[Bool] raise SevenZError {
  let all_defined = self.read_byte()
  let out : Array[Bool] = []
  if all_defined != 0 {
    for _ in 0..<count {
      out.push(true)
    }
    return out
  }
  push_bits(out, self.read_bytes((count + 7) / 8), count)
  out
}

///|
/// 读 `count` 个布尔值（裸位域：每字节 8 项、MSB 在前，无 allDefined 前缀）。
///
/// FilesInfo 的 kEmptyStream / kEmptyFile / kAnti 用这种形式：它们的 `size`
/// 字段就是位域字节数（实测 bsdtar 归档：3 个文件 → size=1、内容 0x20）。
pub fn ByteReader::read_bitfield(
  self : ByteReader,
  count : Int32,
) -> Array[Bool] raise SevenZError {
  let out : Array[Bool] = []
  push_bits(out, self.read_bytes((count + 7) / 8), count)
  out
}

///|
/// 按 MSB 在前把位域展开成布尔数组。
fn push_bits(out : Array[Bool], bits : Bytes, count : Int32) -> Unit {
  for i in 0..<count {
    let byte = bits.unsafe_get(i / 8).to_int()
    out.push((byte & (0x80 >> (i % 8))) != 0)
  }
}

///|
/// 读 `count` 个 CRC-32 摘要（BooleanList 决定哪些位置有值）。
pub fn ByteReader::read_digests(
  self : ByteReader,
  count : Int32,
) -> Array[Int64?] raise SevenZError {
  let defined = self.read_booleans(count)
  let out : Array[Int64?] = []
  for i in 0..<count {
    if defined[i] {
      out.push(Some(self.read_u32()))
    } else {
      out.push(None)
    }
  }
  out
}
