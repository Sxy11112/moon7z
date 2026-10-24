// header.mbt
//
// 明文头数据库（kHeader）解析：属性树 → StreamsInfo（PackInfo / UnpackInfo /
// SubStreamsInfo）+ FilesInfo。
//
// 依据 py7zr《.7z format specification》"Header" 一节：
//   Header       := kHeader(0x01) [MainStreamsInfo] [FilesInfo] kEnd(0x00)
//   StreamsInfo  := kPackInfo(0x06) [kUnpackInfo(0x07)] [kSubStreamsInfo(0x08)] kEnd
//   FilesInfo    := kFilesInfo(0x05) numFiles 属性列表 kEnd
//   FilesInfo 的每个属性都是 `<ID> <size NUMBER> <content: size 字节>`
//
// 与 libarchive 的一处兼容差异（实测 bsdtar 写出的归档）：
// kName 块的内容比"所有名字的 UTF-16LE 字节数"多一个前导 0x00 字节。
// 因此这里先按规范的偏移 0 严格解析，名字个数不符时再按偏移 1 重试。

///|
/// 归档中的一个条目。
pub struct Entry {
  /// 归档内路径（kName 解码后的字符串）。
  name : String
  /// 解包后大小（字节）；目录为 0。
  size : Int64
  /// 内容 CRC-32；归档未声明时为 `None`，目录恒为 `None`。
  crc : Int64?
  /// 是否为目录（无数据流且不属于"空文件"）。
  is_dir : Bool
}

///|
/// 单个 coder（解压 / 过滤算子）。
pub struct Coder {
  /// coder 标识：COPY=0x00、LZMA=0x030101、LZMA2=0x21、BCJ=0x04 等。
  id : Int64
  /// coder 属性（LZMA 为 5 字节 props，LZMA2 为 1 字节字典大小）。
  props : Bytes
  num_in : Int32
  num_out : Int32
}

///|
/// Folder：一组 coder 组成的解压单元，也是 Solid 压缩的边界。
pub struct Folder {
  coders : Array[Coder]
  /// 每个输出流的解压大小。
  unpack_sizes : Array[Int64]
  num_sub_streams : Int32
  sub_sizes : Array[Int64]
  sub_crcs : Array[Int64?]
}

///|
/// 归档的流信息（PackInfo + UnpackInfo + SubStreamsInfo）。
pub struct Streams {
  /// 打包数据区相对签名头末尾的偏移（绝对位置 = 32 + pack_pos）。
  pack_pos : Int64
  pack_sizes : Array[Int64]
  pack_crcs : Array[Int64?]
  folder_crcs : Array[Int64?]
  folders : Array[Folder]
}

///|
/// 文件表（与流信息合并前）。
priv struct FileTable {
  names : Array[String]
  empty_stream : Array[Bool]
  empty_file : Array[Bool]
}

///|
/// 空的流信息（归档没有 kMainStreamsInfo 时使用）。
fn empty_streams() -> Streams {
  { pack_pos: 0L, pack_sizes: [], pack_crcs: [], folder_crcs: [], folders: [], }
}

///|
/// 解析头数据库，返回归档中的条目列表。
///
/// 输入：`SevenZ`（起始头已校验）。
/// 输出：条目数组，顺序与归档内文件表一致。
/// 失败：编码头（F5 尚未实现）/ 属性树非法 / 截断 / 名字数与文件数不符。
pub fn SevenZ::entries(self : SevenZ) -> Array[Entry] raise SevenZError {
  let (entries, _) = self.parse_header_db()
  entries
}

///|
/// 归档的流信息（打包位置与大小、Folder / coder 链、子流大小与 CRC）。
///
/// 输入：`SevenZ`（起始头已校验）。
/// 输出：`Streams`，供解压（后续增量）与压缩方式检查使用。
pub fn SevenZ::streams(self : SevenZ) -> Streams raise SevenZError {
  let (_, streams) = self.parse_header_db()
  streams
}

///|
/// 解析头数据库，一次得到条目表与流信息。
fn SevenZ::parse_header_db(
  self : SevenZ,
) -> (Array[Entry], Streams) raise SevenZError {
  let sh = self.start_header
  let header = copy_range(
    self.data,
    sh.absolute_offset().to_int(),
    sh.absolute_end().to_int(),
  )
  if header.length() == 0 {
    raise Malformed(reason="头数据库为空")
  }
  if header.unsafe_get(0) == 0x17 {
    raise Unsupported(what="编码头（kEncodedHeader）")
  }
  let r = ByteReader::new(header)
  let first = r.read_byte()
  if first != 0x01 {
    raise Malformed(
      reason="明文头应以 kHeader(0x01) 开头，实际 " + hex_byte(first),
    )
  }
  let mut streams = empty_streams()
  let mut table : FileTable? = None
  while true {
    let pid = r.read_byte()
    if pid == 0x00 {
      break
    }
    if pid == 0x04 {
      streams = parse_streams(r)
    } else if pid == 0x05 {
      table = Some(parse_files(r))
    } else if pid == 0x02 {
      // kArchiveProperties：本实现用不到，按声明长度整段跳过
      let size = r.read_number()
      r.skip(size.to_int())
    } else {
      raise Malformed(reason="Header 中出现未知属性 " + hex_byte(pid))
    }
  }
  match table {
    Some(t) => (build_entries(t, streams), streams)
    None => raise Malformed(reason="缺少 kFilesInfo(0x05)")
  }
}

///|
/// 解析 StreamsInfo。
fn parse_streams(r : ByteReader) -> Streams raise SevenZError {
  let pid = r.read_byte()
  if pid != 0x06 {
    raise Malformed(
      reason="StreamsInfo 应以 kPackInfo(0x06) 开头，实际 " +
        hex_byte(pid),
    )
  }
  let pack_pos = r.read_number()
  let num_pack = r.read_number().to_int()
  if num_pack < 0 {
    raise Malformed(reason="kPackInfo 的打包流个数为负")
  }
  let pack_sizes : Array[Int64] = []
  let mut pack_crcs : Array[Int64?] = []
  while true {
    let p = r.read_byte()
    if p == 0x00 {
      break
    }
    if p == 0x09 {
      for _ in 0..<num_pack {
        pack_sizes.push(r.read_number())
      }
    } else if p == 0x0A {
      pack_crcs = r.read_digests(num_pack)
    } else {
      raise Malformed(reason="kPackInfo 中出现未知属性 " + hex_byte(p))
    }
  }
  let mut folders : Array[Folder] = []
  let mut folder_crcs : Array[Int64?] = []
  let mut pid2 = r.read_byte()
  if pid2 == 0x07 {
    let parsed = parse_unpack_info(r)
    folders = parsed.0
    folder_crcs = parsed.1
    pid2 = r.read_byte()
  }
  if pid2 == 0x08 {
    folders = parse_substreams(r, folders, folder_crcs)
    pid2 = r.read_byte()
  }
  if pid2 != 0x00 {
    raise Malformed(
      reason="kStreamsInfo 应以 kEnd(0x00) 结束，实际 " + hex_byte(pid2),
    )
  }
  { pack_pos, pack_sizes, pack_crcs, folder_crcs, folders, }
}

///|
/// 解析 UnpackInfo，返回（Folder 列表, 每个 Folder 的 CRC）。
fn parse_unpack_info(
  r : ByteReader,
) -> (Array[Folder], Array[Int64?]) raise SevenZError {
  let folders : Array[Folder] = []
  let mut folder_crcs : Array[Int64?] = []
  let mut sizes : Array[Array[Int64]] = []
  while true {
    let p = r.read_byte()
    if p == 0x00 {
      break
    }
    if p == 0x0B {
      let num = r.read_number().to_int()
      if num < 0 {
        raise Malformed(reason="Folder 个数为负")
      }
      let external = r.read_byte()
      if external != 0 {
        raise Unsupported(what="外部 Folder 定义（kFolder external=1）")
      }
      for _ in 0..<num {
        folders.push(parse_folder(r))
      }
    } else if p == 0x0C {
      let parsed : Array[Array[Int64]] = []
      for f in folders {
        let per : Array[Int64] = []
        for _ in 0..<f.out_count() {
          per.push(r.read_number())
        }
        parsed.push(per)
      }
      sizes = parsed
    } else if p == 0x0A {
      folder_crcs = r.read_digests(folders.length())
    } else {
      raise Malformed(reason="kUnpackInfo 中出现未知属性 " + hex_byte(p))
    }
  }
  let out : Array[Folder] = []
  for i in 0..<folders.length() {
    let f = folders[i]
    let per = if i < sizes.length() { sizes[i] } else { [] }
    out.push({
      coders: f.coders,
      unpack_sizes: per,
      num_sub_streams: 1,
      sub_sizes: [],
      sub_crcs: [],
    })
  }
  (out, folder_crcs)
}

///|
/// 解析单个 Folder：coder 列表 + BindPairs + PackedStreams。
fn parse_folder(r : ByteReader) -> Folder raise SevenZError {
  let num_coders = r.read_number().to_int()
  if num_coders <= 0 || num_coders > 64 {
    raise Malformed(reason="coder 个数非法：" + num_coders.to_string())
  }
  let coders : Array[Coder] = []
  let mut total_in = 0
  let mut total_out = 0
  for _ in 0..<num_coders {
    let flag = r.read_byte()
    let id_size = flag & 0x0F
    let is_complex = (flag & 0x10) != 0
    let has_attrs = (flag & 0x20) != 0
    if id_size == 0 || id_size > 8 {
      raise Malformed(
        reason="coder 标识长度非法：" + id_size.to_string(),
      )
    }
    let id_bytes = r.read_bytes(id_size)
    let mut id = 0L
    for i in 0..<id_size {
      id = (id << 8) | id_bytes.unsafe_get(i).to_int().to_int64()
    }
    let mut num_in = 1
    let mut num_out = 1
    if is_complex {
      num_in = r.read_number().to_int()
      num_out = r.read_number().to_int()
      if num_in < 0 || num_out < 0 {
        raise Malformed(reason="复数 coder 的输入/输出流个数为负")
      }
    }
    let mut props = b""
    if has_attrs {
      props = r.read_bytes(r.read_number().to_int())
    }
    total_in += num_in
    total_out += num_out
    coders.push({ id, props, num_in, num_out, })
  }
  let num_bind = total_out - 1
  for _ in 0..<num_bind {
    let _ = r.read_number()
    let _ = r.read_number()
  }
  let num_packed = total_in - num_bind
  if num_packed > 1 {
    for _ in 0..<num_packed {
      let _ = r.read_number()
    }
  }
  { coders, unpack_sizes: [], num_sub_streams: 1, sub_sizes: [], sub_crcs: [], }
}

///|
/// 解析 SubStreamsInfo，并把子流大小 / CRC 合并进 Folder。
fn parse_substreams(
  r : ByteReader,
  folders : Array[Folder],
  folder_crcs : Array[Int64?],
) -> Array[Folder] raise SevenZError {
  let n = folders.length()
  let num_sub : Array[Int32] = []
  let sizes : Array[Array[Int64]] = []
  let crcs : Array[Array[Int64?]] = []
  for _ in 0..<n {
    num_sub.push(1)
    sizes.push([])
    crcs.push([])
  }
  while true {
    let p = r.read_byte()
    if p == 0x00 {
      break
    }
    if p == 0x0D {
      for i in 0..<n {
        let k = r.read_number().to_int()
        if k < 0 {
          raise Malformed(reason="kNumUnpackStream 为负")
        }
        num_sub[i] = k
      }
    } else if p == 0x09 {
      for i in 0..<n {
        let k = num_sub[i]
        if k <= 0 {
          continue
        }
        let total = if folders[i].unpack_sizes.length() > 0 {
          folders[i].unpack_sizes[0]
        } else {
          0L
        }
        let mut acc = 0L
        for _ in 0..<(k - 1) {
          let s = r.read_number()
          sizes[i].push(s)
          acc += s
        }
        sizes[i].push(total - acc)
      }
    } else if p == 0x0A {
      // 只为"文件夹级 CRC 未覆盖"的子流读摘要：
      // 当 folder 只有一个子流且 folder CRC 已定义时，该子流的 CRC 就是 folder CRC。
      let needs : Array[(Int32, Int32)] = []
      for i in 0..<n {
        for j in 0..<num_sub[i] {
          let covered = num_sub[i] == 1 &&
            i < folder_crcs.length() &&
            is_some(folder_crcs[i])
          if !covered {
            needs.push((i, j))
          }
        }
      }
      let defined = r.read_booleans(needs.length())
      for t in 0..<needs.length() {
        let (i, _) = needs[t]
        if defined[t] {
          crcs[i].push(Some(r.read_u32()))
        } else {
          crcs[i].push(None)
        }
      }
    } else {
      raise Malformed(
        reason="kSubStreamsInfo 中出现未知属性 " + hex_byte(p),
      )
    }
  }
  assemble_folders(folders, folder_crcs, num_sub, sizes, crcs)
}

///|
/// 把子流信息合并进 Folder（SubStreamsInfo 缺失时也要走同一路径）。
fn assemble_folders(
  folders : Array[Folder],
  folder_crcs : Array[Int64?],
  num_sub : Array[Int32],
  sizes : Array[Array[Int64]],
  crcs : Array[Array[Int64?]],
) -> Array[Folder] {
  let out : Array[Folder] = []
  for i in 0..<folders.length() {
    let f = folders[i]
    let k = num_sub[i]
    let mut sub_sizes = sizes[i]
    let mut sub_crcs = crcs[i]
    if k == 1 {
      sub_sizes = []
      sub_sizes.push(
        if f.unpack_sizes.length() > 0 {
          f.unpack_sizes[0]
        } else {
          0L
        },
      )
      // SubStreamsInfo 已给出 CRC 时以它为准；否则回落到 folder 级 CRC
      // （folder 只有一个子流时，规范允许把 CRC 写在 UnpackInfo 里）。
      if sub_crcs.length() == 0 {
        sub_crcs = []
        sub_crcs.push(
          if i < folder_crcs.length() {
            folder_crcs[i]
          } else {
            None
          },
        )
      }
    }
    out.push({
      coders: f.coders,
      unpack_sizes: f.unpack_sizes,
      num_sub_streams: k,
      sub_sizes,
      sub_crcs,
    })
  }
  out
}

///|
/// 解析 FilesInfo（文件名 / 空流 / 空文件标志）。
fn parse_files(r : ByteReader) -> FileTable raise SevenZError {
  let num_files = r.read_number().to_int()
  if num_files < 0 {
    raise Malformed(reason="kFilesInfo 的文件数为负")
  }
  let mut empty_stream : Array[Bool] = []
  for _ in 0..<num_files {
    empty_stream.push(false)
  }
  let mut empty_file : Array[Bool] = []
  let mut names : Array[String] = []
  while true {
    let p = r.read_byte()
    if p == 0x00 {
      break
    }
    let size = r.read_number().to_int()
    if size < 0 {
      raise Malformed(reason="FilesInfo 属性长度为负")
    }
    let content = r.read_bytes(size)
    if p == 0x11 {
      names = parse_names(content, num_files)
    } else if p == 0x0E {
      let cr = ByteReader::new(content)
      empty_stream = cr.read_bitfield(num_files)
    } else if p == 0x0F {
      let cr = ByteReader::new(content)
      empty_file = cr.read_bitfield(count_true(empty_stream))
    } else {
      // kAnti(0x10) / kCTime(0x12) / kATime(0x13) / kMTime(0x14) /
      // kWinAttributes(0x15) / kStartPos(0x18) / kDummy(0x19)：
      // 内容已按声明长度取出，本增量不解释（时间戳与属性后续按需补）
    }
  }
  if names.length() != num_files {
    raise Malformed(
      reason="kName 条目数(" +
        names.length().to_string() +
        ")与 numFiles(" +
        num_files.to_string() +
        ")不符",
    )
  }
  { names, empty_stream, empty_file, }
}

///|
/// 解析 kName 块：UTF-16LE、每名以 0x0000 结束。
///
/// 实际存在两种形态：
/// - 规范形态：名字从偏移 0 开始；
/// - libarchive 形态：块首多一个 0x00 字节（bsdtar 写出的归档，实测）。
///
/// 判据不能只看"名字个数 == numFiles"：libarchive 形态按偏移 0 解码同样能得到
/// 2 个（乱码）名字。因此要求**整个块被精确消费完**（含末尾结束符），
/// 只有满足该条件且名字个数相符的偏移才被接受。
fn parse_names(
  content : Bytes,
  num_files : Int32,
) -> Array[String] raise SevenZError {
  let (names_zero, used_zero) = split_names(content, 0)
  if names_zero.length() == num_files && used_zero == content.length() {
    return names_zero
  }
  let (names_one, used_one) = split_names(content, 1)
  if names_one.length() == num_files && used_one + 1 == content.length() {
    return names_one
  }
  raise Malformed(
    reason="kName 块无法解析：numFiles=" +
      num_files.to_string() +
      "，偏移 0 得到 " +
      names_zero.length().to_string() +
      " 个名字（消费 " +
      used_zero.to_string() +
      "/" +
      content.length().to_string() +
      " 字节）",
  )
}

///|
/// 从 `start` 偏移起按 UTF-16LE 切分名字，返回（名字列表, 消费字节数）。
fn split_names(content : Bytes, start : Int32) -> (Array[String], Int32) {
  let out : Array[String] = []
  let mut buf = @buffer.Buffer()
  let mut i = start
  while i + 1 < content.length() {
    if content.unsafe_get(i).to_int() == 0 &&
      content.unsafe_get(i + 1).to_int() == 0 {
      out.push(
        @utf16.decode_lossy(buf.to_bytes(), endianness=@utf16.Endian::Little),
      )
      buf = @buffer.Buffer()
    } else {
      buf.write_byte(content.unsafe_get(i))
      buf.write_byte(content.unsafe_get(i + 1))
    }
    i += 2
  }
  let rest = buf.to_bytes()
  if rest.length() > 0 {
    out.push(@utf16.decode_lossy(rest, endianness=@utf16.Endian::Little))
    i += rest.length()
  }
  (out, i - start)
}

///|
/// 把文件表与流信息合并成条目列表。
fn build_entries(
  table : FileTable,
  streams : Streams,
) -> Array[Entry] raise SevenZError {
  let sizes : Array[Int64] = []
  let crcs : Array[Int64?] = []
  for f in streams.folders {
    for j in 0..<f.num_sub_streams {
      sizes.push(if j < f.sub_sizes.length() { f.sub_sizes[j] } else { 0L })
      crcs.push(if j < f.sub_crcs.length() { f.sub_crcs[j] } else { None })
    }
  }
  let out : Array[Entry] = []
  let mut next = 0
  let mut empty_idx = 0
  for i in 0..<table.names.length() {
    if table.empty_stream[i] {
      let is_empty_file = empty_idx < table.empty_file.length() &&
        table.empty_file[empty_idx]
      empty_idx += 1
      out.push({
        name: table.names[i],
        size: 0L,
        crc: None,
        is_dir: !is_empty_file,
      })
    } else {
      if next >= sizes.length() {
        raise Malformed(
          reason="有数据流的文件数多于子流数（文件 " +
            table.names[i] +
            "）",
        )
      }
      out.push({
        name: table.names[i],
        size: sizes[next],
        crc: crcs[next],
        is_dir: false,
      })
      next += 1
    }
  }
  out
}

///|
/// `Folder` 的输出流总数（等于 kCodersUnpackSize 中该 folder 的条目数）。
fn Folder::out_count(self : Folder) -> Int32 {
  let mut total = 0
  for c in self.coders {
    total += c.num_out
  }
  total
}

///|
/// `Int64?` 是否为 `Some`。
fn is_some(value : Int64?) -> Bool {
  match value {
    Some(_) => true
    None => false
  }
}

///|
/// 统计布尔数组里 `true` 的个数。
fn count_true(values : Array[Bool]) -> Int32 {
  let mut n = 0
  for v in values {
    if v {
      n += 1
    }
  }
  n
}
