// hex.mbt
//
// 十六进制渲染。错误消息里会带上从文件读到的原始字节（签名、头部片段），
// 其中可能含 NUL 或其它不可打印字节——直接拼进字符串会让日志、CI 输出与
// 测试驱动无法解析（历史教训：错误消息里的原始字节同样要净化），
// 因此统一渲染成两位十六进制。

///|
/// 把字节序列渲染成小写十六进制字符串。
pub fn hex_string(bytes : Bytes) -> String {
  let digits : Array[String] = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
  ]
  let mut out = ""
  for i in 0..<bytes.length() {
    let v = bytes.unsafe_get(i).to_int()
    out = out + digits[v >> 4] + digits[v & 0xF]
  }
  out
}

///|
/// 一个字节的十六进制渲染（错误消息里标识属性 ID / 首字节）。
pub fn hex_byte(value : Int32) -> String {
  let digits : Array[String] = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
  ]
  "0x" + digits[(value >> 4) & 0xF] + digits[value & 0xF]
}
