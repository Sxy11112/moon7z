// crc32.mbt
//
// 7z 全格式使用标准 CRC-32：反射多项式 0xEDB88320、初值 0xFFFFFFFF、输出取反，
// 与 zlib / libarchive / 7-Zip 的 `crc32` 完全一致。
//
// 这里做成表驱动的增量计算器：头部校验（F1）与后续解压时的数据校验（F4/F5）
// 共用同一实现，避免两处各写一份。

///|
/// 增量 CRC-32 计算器。
pub struct Crc32 {
  table : FixedArray[Int64]
  mut value : Int64
}

///|
/// 构造计算器（建立 256 项查表）。
pub fn Crc32::new() -> Crc32 {
  let table : FixedArray[Int64] = FixedArray::make(256, 0L)
  for i in 0..<256 {
    let mut c = i.to_int64()
    for _ in 0..<8 {
      c = if (c & 1L) != 0L { (c >> 1) ^ 0xEDB88320L } else { c >> 1 }
    }
    table[i] = c
  }
  { table, value: 0xFFFFFFFFL, }
}

///|
/// 送入 `data[start, end)` 区间的字节。
///
/// 区间会裁剪到 `[0, data.length())` 之内：本函数不负责报错，越界检查由
/// `ByteReader` 在读取阶段完成，这里只保证不会 panic。
pub fn Crc32::update(
  self : Crc32,
  data : Bytes,
  start : Int32,
  end : Int32,
) -> Unit {
  let hi = if end < data.length() { end } else { data.length() }
  let mut i = if start > 0 { start } else { 0 }
  let mut c = self.value
  while i < hi {
    let idx = ((c ^ data.unsafe_get(i).to_int().to_int64()) & 0xFFL).to_int()
    c = (c >> 8) ^ self.table[idx]
    i += 1
  }
  self.value = c
}

///|
/// 输出最终校验值（0 .. 2^32-1）。
pub fn Crc32::finalize(self : Crc32) -> Int64 {
  self.value ^ 0xFFFFFFFFL
}

///|
/// 一次性计算 `data[start, end)` 的 CRC-32。
pub fn crc32(data : Bytes, start : Int32, end : Int32) -> Int64 {
  let c = Crc32::new()
  c.update(data, start, end)
  c.finalize()
}
