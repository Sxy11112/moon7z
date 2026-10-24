// signature.mbt
//
// 7z 起始头是定长 32 字节：
//
//   offset  长度  字段
//   0       6     签名 37 7A BC AF 27 1C
//   6       1     主版本号（规范要求 0）
//   7       1     次版本号
//   8       4     StartHeaderCRC（覆盖 12..32）
//   12      8     下一头偏移（相对签名头末尾；绝对位置 = 32 + offset）
//   20      8     下一头长度（可能已被编码/压缩，故是编码后的长度）
//   28      4     下一头 CRC-32
//
// 依据：py7zr《.7z format specification》"Signature Header" 一节
// （https://py7zr.readthedocs.io/en/latest/archive_format.html）。
// 实测 bsdtar/libarchive 把次版本写作 0.3、官方 7-Zip 写作 0.4，
// 因此这里只要求主版本为 0，次版本仅记录、不做限制。
//
// 本增量（F1）只做"证明头数据库真的存在且完整"这件事：定位 + 边界 + CRC。
// 头数据库的内容解析属于 F2/F3。

///|
/// 7z 文件签名（6 字节）。
pub let sevenz_signature : Bytes = b"\x37\x7A\xBC\xAF\x27\x1C"

///|
/// 起始头的定长字节数。
pub let sevenz_start_header_size : Int32 = 32

///|
/// 已校验的起始头字段。
pub struct StartHeader {
  /// 主版本号（本实现要求为 0）。
  major : Int32
  /// 次版本号（仅记录）。
  minor : Int32
  /// 下一头相对签名头末尾的偏移。
  next_header_offset : Int64
  /// 下一头长度（编码后的字节数）。
  next_header_size : Int64
  /// 下一头 CRC-32（以无符号 32 位值存放）。
  next_header_crc : Int64
}

///|
/// 下一头在归档中的绝对起点。
pub fn StartHeader::absolute_offset(self : StartHeader) -> Int64 {
  self.next_header_offset + sevenz_start_header_size.to_int64()
}

///|
/// 下一头在归档中的绝对终点（不含）。
pub fn StartHeader::absolute_end(self : StartHeader) -> Int64 {
  self.absolute_offset() + self.next_header_size
}

///|
/// 已打开的 7z 归档。F1 保证起始头与下一头区间可用；条目列表与解压在后续增量补充。
pub struct SevenZ {
  start_header : StartHeader
  data : Bytes
}

///|
/// 起始头。
pub fn SevenZ::start_header(self : SevenZ) -> StartHeader {
  self.start_header
}

///|
/// 归档总字节数。
pub fn SevenZ::size(self : SevenZ) -> Int32 {
  self.data.length()
}

///|
/// 原始归档字节。
pub fn SevenZ::bytes(self : SevenZ) -> Bytes {
  self.data
}

///|
/// 解析并校验 32 字节起始头，并证明下一头数据库完整落在文件内、CRC 正确。
///
/// 输入：完整归档字节（至少 32 字节）。
/// 输出：`SevenZ`，其起始头字段已全部校验通过。
/// 失败：截断 / 签名不符 / 主版本非 0 / 两处 CRC 不符 / 下一头区间越界。
pub fn SevenZ::open(data : Bytes) -> SevenZ raise SevenZError {
  let r = ByteReader::new(data)
  r.require(sevenz_start_header_size)
  let signature = r.read_bytes(6)
  if !signature.equal(sevenz_signature) {
    raise BadSignature(found=hex_string(signature))
  }
  let major = r.read_byte()
  let minor = r.read_byte()
  if major != 0 {
    raise UnsupportedVersion(major~, minor~)
  }
  let start_header_crc = r.read_u32()
  let next_header_offset = r.read_u64()
  let next_header_size = r.read_u64()
  let next_header_crc = r.read_u32()
  let actual_start_crc = crc32(data, 12, sevenz_start_header_size)
  if actual_start_crc != start_header_crc {
    raise BadCrc(
      what="start header",
      expected=start_header_crc,
      actual=actual_start_crc,
    )
  }
  let header_start = next_header_offset + sevenz_start_header_size.to_int64()
  let header_end = header_start + next_header_size
  if header_start < sevenz_start_header_size.to_int64() ||
    header_end > data.length().to_int64() {
    raise Malformed(
      reason="下一头区间越界（offset=" +
        next_header_offset.to_string() +
        ", size=" +
        next_header_size.to_string() +
        ", file=" +
        data.length().to_string() +
        "）",
    )
  }
  let actual_header_crc = crc32(
    data,
    header_start.to_int(),
    header_end.to_int(),
  )
  if actual_header_crc != next_header_crc {
    raise BadCrc(
      what="next header",
      expected=next_header_crc,
      actual=actual_header_crc,
    )
  }
  {
    start_header: {
      major,
      minor,
      next_header_offset,
      next_header_size,
      next_header_crc,
    },
    data,
  }
}
