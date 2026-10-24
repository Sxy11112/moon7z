// byte_reader.mbt
//
// 带边界检查的小端字节游标。7z 头部里既有定长整数（UINT32 / UINT64），
// 也有可变长 NUMBER 与嵌套属性树，所以"先证明区间存在、再读取"必须写成
// 可复用的原语，而不是在每个解析分支里各写一遍下标判断。

///|
/// 顺序读取字节的小端游标。
pub struct ByteReader {
  data : Bytes
  mut pos : Int32
}

///|
/// 在 `data` 上建立游标。
pub fn ByteReader::new(data : Bytes) -> ByteReader {
  { data, pos: 0, }
}

///|
/// 当前读取位置。
pub fn ByteReader::position(self : ByteReader) -> Int32 {
  self.pos
}

///|
/// 剩余字节数。
pub fn ByteReader::remaining(self : ByteReader) -> Int32 {
  self.data.length() - self.pos
}

///|
/// 要求剩余至少 `need` 字节；不足时抛出 `Truncated`。
pub fn ByteReader::require(
  self : ByteReader,
  need : Int32,
) -> Unit raise SevenZError {
  if need < 0 || self.pos + need > self.data.length() {
    raise Truncated(
      offset=self.pos.to_int64(),
      need=need.to_int64(),
      actual=self.remaining().to_int64(),
    )
  }
}

///|
/// 读 1 字节（0 .. 255）。
pub fn ByteReader::read_byte(self : ByteReader) -> Int32 raise SevenZError {
  self.require(1)
  let b = self.data.unsafe_get(self.pos).to_int()
  self.pos += 1
  b
}

///|
/// 读小端 UINT32（以 Int64 返回，值域 0 .. 2^32-1）。
pub fn ByteReader::read_u32(self : ByteReader) -> Int64 raise SevenZError {
  self.require(4)
  let mut v = 0L
  let mut i = 0
  while i < 4 {
    v = v | (self.data.unsafe_get(self.pos + i).to_int().to_int64() << (8 * i))
    i += 1
  }
  self.pos += 4
  v
}

///|
/// 读小端 UINT64（以 Int64 返回；7z 的实际字段远小于 2^63）。
pub fn ByteReader::read_u64(self : ByteReader) -> Int64 raise SevenZError {
  self.require(8)
  let mut v = 0L
  let mut i = 0
  while i < 8 {
    v = v | (self.data.unsafe_get(self.pos + i).to_int().to_int64() << (8 * i))
    i += 1
  }
  self.pos += 8
  v
}

///|
/// 读 `n` 字节并复制成新的 `Bytes`。
pub fn ByteReader::read_bytes(
  self : ByteReader,
  n : Int32,
) -> Bytes raise SevenZError {
  self.require(n)
  let buf = @buffer.Buffer()
  let mut i = 0
  while i < n {
    buf.write_byte(self.data.unsafe_get(self.pos + i))
    i += 1
  }
  self.pos += n
  buf.to_bytes()
}

///|
/// 跳过 `n` 字节。
pub fn ByteReader::skip(self : ByteReader, n : Int32) -> Unit raise SevenZError {
  self.require(n)
  self.pos += n
}

///|
/// 复制 `data[start, end)` 成新的 `Bytes`（区间自动裁剪到数据长度内）。
pub fn copy_range(data : Bytes, start : Int32, end : Int32) -> Bytes {
  let buf = @buffer.Buffer()
  let lo = if start > 0 { start } else { 0 }
  let hi = if end < data.length() { end } else { data.length() }
  let mut i = lo
  while i < hi {
    buf.write_byte(data.unsafe_get(i))
    i += 1
  }
  buf.to_bytes()
}
