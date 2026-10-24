// cmd/main/main.mbt（草稿，等 LZMA 内核落地后移入仓库）
//
// 命令行：列目录 / 解包。
//   moon run cmd/main -- list <archive.7z>
//   moon run cmd/main -- extract <archive.7z> <outdir>
//
// 输出契约（tools/check_compat.py 依赖它，各后端一致、不用退出码）：
//   list 成功：每行 "<name>\t<size>\t<crc>"，目录的 size 与 crc 为 "-"
//   失败：一行 "UNSUPPORTED\t<原因>" 或 "ERROR\t<原因>"

///|
/// 32 位 CRC 的 8 位十六进制渲染。
fn crc_hex(crc : Int64) -> String {
  let digits : Array[String] = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
  ]
  let mut out = ""
  let mut i = 7
  while i >= 0 {
    out = out + digits[((crc >> (4 * i)) & 0xFL).to_int()]
    i -= 1
  }
  out
}

///|
/// 把路径按 '/' 与 '\\' 切分（UTF-8 续字节不会是 0x2F/0x5C，按字节切安全）。
fn path_parts(path : String) -> Array[String] {
  let bytes = @utf8.encode(path)
  let out : Array[String] = []
  let buf = @buffer.Buffer()
  for i in 0..<bytes.length() {
    let b = bytes.unsafe_get(i).to_int()
    if b == 0x2F || b == 0x5C {
      if buf.length() > 0 {
        out.push(@utf8.decode_lossy(buf.to_bytes()))
        buf.reset()
      }
    } else {
      buf.write_byte(bytes.unsafe_get(i))
    }
  }
  if buf.length() > 0 {
    out.push(@utf8.decode_lossy(buf.to_bytes()))
  }
  out
}

///|
/// 按需创建 `outdir` 下 `rel` 的所有父目录。
fn ensure_parent(outdir : String, rel : String) -> Unit raise {
  let parts = path_parts(rel)
  if parts.length() <= 1 {
    return
  }
  let mut acc = outdir
  for i in 0..<(parts.length() - 1) {
    acc = acc + "/" + parts[i]
    if !@fs.path_exists(acc) {
      @fs.create_dir(acc)
    }
  }
}

///|
/// 列目录。
fn cmd_list(path : String) -> Unit {
  try {
    let z = @moon7z.SevenZ::open(@fs.read_file_to_bytes(path))
    for e in z.entries() {
      let size = if e.is_dir { "-" } else { e.size.to_string() }
      let crc = match e.crc {
        Some(c) => crc_hex(c)
        None => "-"
      }
      println(e.name + "\t" + size + "\t" + crc)
    }
  } catch {
    @moon7z.SevenZError::Unsupported(what~) => println("UNSUPPORTED\t\{what}")
    @fs.IOError::IOError(msg) => println("ERROR\tI/O 错误: \{msg}")
    e => println("ERROR\t\{e}")
  }
}

///|
/// 解包到目录。
fn cmd_extract(path : String, outdir : String) -> Unit {
  try {
    let z = @moon7z.SevenZ::open(@fs.read_file_to_bytes(path))
    if !@fs.path_exists(outdir) {
      @fs.create_dir(outdir)
    }
    let files = z.extract_all()
    for f in files {
      ensure_parent(outdir, f.name)
      @fs.write_bytes_to_file(outdir + "/" + f.name, f.data)
    }
    println("OK\t\{files.length()} 个文件 → \{outdir}")
  } catch {
    @moon7z.SevenZError::Unsupported(what~) => println("UNSUPPORTED\t\{what}")
    @fs.IOError::IOError(msg) => println("ERROR\tI/O 错误: \{msg}")
    e => println("ERROR\t\{e}")
  }
}

///|
fn main {
  let args = @env.args()
  // 各后端 argv 形状不同：wasm-gc/native 是 [程序, ...]，js 是 [node, 脚本.js, ...]
  let mut base = 1
  if base < args.length() && args[base].has_suffix(".js") {
    base += 1
  }
  if base + 1 >= args.length() {
    println("用法: moon run cmd/main -- list <archive.7z>")
    println("      moon run cmd/main -- extract <archive.7z> <outdir>")
    return
  }
  let action = args[base]
  let archive = args[base + 1]
  if action == "list" {
    cmd_list(archive)
  } else if action == "extract" && base + 2 < args.length() {
    cmd_extract(archive, args[base + 2])
  } else {
    println("ERROR\t未知动作: \{action}")
  }
}
