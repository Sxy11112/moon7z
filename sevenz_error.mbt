// sevenz_error.mbt
//
// 7z 归档是外部不可信输入：截断、非法字段、校验失败都必须落到结构化错误上，
// 绝不能 panic。所有错误都携带足够定位问题的字段。

///|
/// 解析 / 解包 7z 归档时可能出现的错误。
pub suberror SevenZError {
  /// 数据长度不足（归档被截断）。
  Truncated(offset~ : Int64, need~ : Int64, actual~ : Int64)
  /// 文件开头不是 7z 签名 `37 7A BC AF 27 1C`。
  BadSignature(found~ : String)
  /// 主版本号不为 0（本实现只支持 0.x 归档）。
  UnsupportedVersion(major~ : Int32, minor~ : Int32)
  /// 校验和与数据不符。
  BadCrc(what~ : String, expected~ : Int64, actual~ : Int64)
  /// 头部字段自相矛盾或越界。
  Malformed(reason~ : String)
  /// 结构合法但当前实现尚未支持。
  Unsupported(what~ : String)
}
