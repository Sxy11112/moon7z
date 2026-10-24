// extract.mbt
//
// 解包流水线：Folder 解码 → 子流切分 → 逐级 CRC 校验 → 按条目表取文件。
//
// F3 只实现 COPY（stored）coder。7z 允许一个 Folder 里串联多个 coder
// （BCJ/delta 之类的前置过滤）以及一个 Folder 对应多个 pack stream，
// 这两种情况都显式报 `Unsupported`，留到 LZMA/LZMA2 之外的后续增量。

///|
/// 解包出的一个文件。
pub struct ArchiveFile {
  /// 归档内路径。
  name : String
  /// 文件内容。
  data : Bytes
}

///|
/// 解出归档中的所有文件。
///
/// 目录条目会被跳过；"空文件"条目产出长度 0 的 `Bytes`。
/// 每个 Folder 与子流声明的 CRC-32 都会被校验，不符即报 `BadCrc`。
pub fn SevenZ::extract_all(
  self : SevenZ,
) -> Array[ArchiveFile] raise SevenZError {
  let plan = self.parse_plan()
  let streams = plan.streams
  if streams.pack_sizes.length() != streams.folders.length() {
    raise Unsupported(what="一个 Folder 对应多个 pack stream")
  }
  // 1) 解码每个 Folder（含 folder 级 CRC 校验）
  let decoded : Array[Bytes] = []
  let mut cursor = 32L + streams.pack_pos
  for i in 0..<streams.folders.length() {
    let folder = streams.folders[i]
    let packed_size = streams.pack_sizes[i]
    let data = self.decode_folder(folder, cursor, packed_size)
    if i < streams.folder_crcs.length() {
      match streams.folder_crcs[i] {
        Some(expected) => {
          let actual = crc32(data, 0, data.length())
          if actual != expected {
            raise BadCrc(what="folder " + i.to_string(), expected~, actual~)
          }
        }
        None => ()
      }
    }
    decoded.push(data)
    cursor += packed_size
  }
  // 2) 按声明的子流大小切分，并校验子流 CRC
  let sub_data : Array[Bytes] = []
  for i in 0..<streams.folders.length() {
    let folder = streams.folders[i]
    let data = decoded[i]
    let mut pos = 0
    for j in 0..<folder.num_sub_streams {
      let size = if j < folder.sub_sizes.length() {
        folder.sub_sizes[j]
      } else {
        0L
      }
      let end = pos + size.to_int()
      if size < 0L || end > data.length() {
        raise Malformed(
          reason="子流大小超出 Folder 解压数据（folder " +
            i.to_string() +
            "，子流 " +
            j.to_string() +
            "）",
        )
      }
      let piece = copy_range(data, pos, end)
      if j < folder.sub_crcs.length() {
        match folder.sub_crcs[j] {
          Some(expected) => {
            let actual = crc32(piece, 0, piece.length())
            if actual != expected {
              raise BadCrc(
                what="substream " + i.to_string() + "/" + j.to_string(),
                expected~,
                actual~,
              )
            }
          }
          None => ()
        }
      }
      sub_data.push(piece)
      pos = end
    }
    if pos != data.length() {
      raise Malformed(reason="子流大小之和与 Folder 解压大小不符")
    }
  }
  // 3) 按条目表装配（目录跳过）
  let out : Array[ArchiveFile] = []
  for i in 0..<plan.entries.length() {
    match plan.mapping[i] {
      None => ()
      Some(owner) => {
        let flat = flat_index(streams, owner.0, owner.1)
        out.push({ name: plan.entries[i].name, data: sub_data[flat], })
      }
    }
  }
  out
}

///|
/// 解出指定名字的文件。找不到时报 `Malformed`。
pub fn SevenZ::extract(self : SevenZ, name : String) -> Bytes raise SevenZError {
  for file in self.extract_all() {
    if file.name == name {
      return file.data
    }
  }
  raise Malformed(reason="归档中没有文件 " + name)
}

///|
/// 解码一个 Folder（F3 只支持单个 COPY coder）。
///
/// 输入：`cursor` 是该 Folder 的 packed 数据在文件中的绝对起点。
fn SevenZ::decode_folder(
  self : SevenZ,
  folder : Folder,
  cursor : Int64,
  packed_size : Int64,
) -> Bytes raise SevenZError {
  if folder.coders.length() != 1 {
    raise Unsupported(
      what="由多个 coder 串联组成的 Folder（过滤器链）",
    )
  }
  let coder = folder.coders[0]
  if coder.id != 0L {
    raise Unsupported(what="coder " + hex_id(coder.id))
  }
  if folder.unpack_sizes.length() != 1 {
    raise Unsupported(what="Folder 有多个输出流")
  }
  let start = cursor.to_int()
  let end = start + packed_size.to_int()
  if packed_size < 0L || end > self.data.length() {
    raise Malformed(reason="packed 数据区间越界")
  }
  let out = copy_range(self.data, start, end)
  if out.length().to_int64() != folder.unpack_sizes[0] {
    raise Malformed(reason="COPY coder 的打包大小与解压大小不一致")
  }
  out
}

///|
/// `(folder, 子流)` → 展平后的子流下标（与条目映射同序）。
fn flat_index(streams : Streams, folder : Int32, sub : Int32) -> Int32 {
  let mut n = 0
  for k in 0..<folder {
    n += streams.folders[k].num_sub_streams
  }
  n + sub
}
