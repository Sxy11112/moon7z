// lzma.mbt
//
// LZMA1 / LZMA2 解码内核（纯 MoonBit，零依赖）。
//
// 语义与语料来源（对拍脚本：`_research/lzma_final_proto.py`，oracle 为 Python 的 liblzma）：
//
// LZMA1（7z 的 0x030101 coder）：
//   props = 5 字节：首字节 = (pb * 5 + lp) * 9 + lc，其后 4 字节 = 小端字典大小。
//   裸流没有 ALONE 头、没有 EOS 标记；区间解码器读 5 字节初始化（首字节被 32 位移出，
//   等价于"跳过"），输出长度完全由容器给出的 unpack_size 决定。
//   尾部可能剩下未被消费的 flush 字节（实测：向量 1 用掉 29/34，向量 3 用掉 111/116）。
//
// LZMA2（7z 的 0x21 coder）：
//   props = 1 字节字典大小编码（(2 | (p & 1)) << (p / 2 + 11)，p <= 40）。
//   分块头：
//     ctrl 0x00           结束标记
//     ctrl 0x01 / 0x02    未压缩块（0x02 带字典复位），后随 2 字节 size-1（大端）
//     ctrl 0x03-0x7F      保留（报错）
//     ctrl 0x80-0xFF      LZMA 块：
//         unpack-1 ：2 字节大端，高 5 位在 ctrl 的 bit0-4
//         packed-1 ：2 字节大端
//         ctrl >= 0xC0 时再跟 1 字节 props（lc / lp / pb）
//         reset 语义：0x80-0x9F 无复位；0xA0-0xBF state reset（无 props 字节）；
//                     0xC0-0xDF state reset + 新 props；0xE0-0xFF 再叠加字典复位
//   注意：语料里 LZMA 块数据以 `1c5d` / `695d` 开头，头两个字节其实是 packed-1，
//   第三个字节 0x5d 才是 props（lc=3 / lp=0 / pb=2，与同一载荷的 LZMA1 props 相同），
//   这也是"LZMA2 块数据看起来是 2 个额外字节 + LZMA1 码流"的真正原因。
//   以上分块头布局由 `_research/probe_ctrl4.py` 用自建 range encoder 造流、
//   交给 liblzma 判决（四种布局里只有一种被接受），不是推测。
//
// 错误处理：所有越界都在读取点检查，抛 SevenZError，绝不 panic；
// 尾部多余的输入字节被容忍（合法归档里 LZMA2 结束标记可能被省略）。

///|
/// 概率模型初值（kBitModelTotal / 2 = 1024）。
const PROB_INIT : Int32 = 1024

///|
/// 概率自适应步长（kNumMoveBits）。
const MOVE_BITS : Int32 = 5

///|
/// 区间解码器归一化阈值（kTopValue = 1 << 24）。
const TOP_VALUE : Int64 = 0x1000000L

///|
/// 32 位掩码：`range` / `code` 始终保持在 [0, 2^32)。
const MASK32 : Int64 = 0xFFFFFFFFL

///|
/// LZMA 状态机状态数。
const NUM_STATES : Int32 = 12

///|
/// posSlot 位树深度。
const NUM_POS_SLOT_BITS : Int32 = 6

///|
/// "长度 → posSlot" 的状态数。
const NUM_LEN_TO_POS_STATES : Int32 = 4

///|
/// 对齐位树深度。
const NUM_ALIGN_BITS : Int32 = 4

///|
/// posSlot 中改用位树编码高位的临界值（此后走 direct bits + align）。
const END_POS_MODEL_INDEX : Int32 = 14

///|
/// 距离高位概率表长度。LZMA SDK 用 `1 + kNumFullDistances - kEndPosModelIndex` = 115，
/// 最大下标 114；这里留一点余量到 128，避免任何下标推导差错导致 panic。
const NUM_POS_MODELS : Int32 = 128

///|
/// 长度解码器概率数：choice + choice2 + low[16][8] + mid[16][8] + high[256] = 514。
const LEN_PROBS : Int32 = 514

///|
/// 字面子编码器概率数上限：0x300 << (lc + lp)，lc + lp <= 4。
const LITERAL_PROBS : Int32 = 0x300 << 4

///|
/// 单次解码允许的最大输出长度（Int 在 wasm-gc 上是 32 位，超过即无法寻址）。
const MAX_UNPACK_SIZE : Int64 = 0x7FFFFFFFL

///|
/// LZMA 区间解码器。
///
/// `range` / `code` 用 Int64 承载但始终掩到 32 位：MoonBit 的 `Int` 是 32 位有符号，
/// 拿它做 LZMA 的无符号比较（`code < bound`）会在符号位上出错，因此这里统一用
/// Int64 + `& 0xFFFFFFFFL`，让算术与比较的语义和 C 里的 `uint32_t` 一致。
priv struct RangeDecoder {
  data : Bytes
  end : Int32
  mut pos : Int32
  mut range : Int64
  mut code : Int64
}

///|
/// 在 `data[pos, end)` 上建立区间解码器并读入 5 字节初始化。
///
/// LZMA1/LZMA2 都读 5 字节：第一个字节是编码器的 cache 字节，左移 32 位后自然丢弃，
/// 于是 `code` 由紧随其后的 4 字节构成。两个格式都不检查该字节是否为 0。
fn RangeDecoder::new(
  data : Bytes,
  pos : Int32,
  end : Int32,
) -> RangeDecoder raise SevenZError {
  let limit = if end < data.length() { end } else { data.length() }
  let decoder : RangeDecoder = {
    data,
    end: limit,
    pos,
    range: MASK32,
    code: 0L,
  }
  let mut i = 0
  while i < 5 {
    decoder.code = ((decoder.code << 8) | decoder.next_byte().to_int64()) &
      MASK32
    i += 1
  }
  decoder
}

///|
/// 读下一个码流字节；越过可用区间（LZMA2 里就是分块声明的 packed 边界）即报错。
fn RangeDecoder::next_byte(self : RangeDecoder) -> Int32 raise SevenZError {
  if self.pos >= self.end {
    raise LzmaCorrupt(
      reason="LZMA 码流越界：区间解码器需要第 " +
        self.pos.to_string() +
        " 字节，但可用区间只到 " +
        self.end.to_string(),
    )
  }
  let b = self.data.unsafe_get(self.pos).to_int()
  self.pos += 1
  b
}

///|
/// 归一化：`range` 掉到 2^24 以下时补入一个字节。
fn RangeDecoder::normalize(self : RangeDecoder) -> Unit raise SevenZError {
  if self.range < TOP_VALUE {
    self.range = (self.range << 8) & MASK32
    self.code = ((self.code << 8) | self.next_byte().to_int64()) & MASK32
  }
}

///|
/// 解一个自适应二进制位，并按下标更新概率。
fn RangeDecoder::bit(
  self : RangeDecoder,
  probs : Array[Int32],
  index : Int32,
) -> Int32 raise SevenZError {
  let prob = probs[index]
  let bound = (self.range >> 11) * prob.to_int64()
  if self.code < bound {
    self.range = bound
    probs[index] = prob + ((PROB_INIT * 2 - prob) >> MOVE_BITS)
    self.normalize()
    0
  } else {
    self.range = self.range - bound
    self.code = self.code - bound
    probs[index] = prob - (prob >> MOVE_BITS)
    self.normalize()
    1
  }
}

///|
/// 解 `count` 个"直写位"（概率各半，不走概率模型）。
fn RangeDecoder::direct_bits(
  self : RangeDecoder,
  count : Int32,
) -> Int32 raise SevenZError {
  let mut result = 0
  let mut i = 0
  while i < count {
    self.range = self.range >> 1
    self.code = (self.code - self.range) & MASK32
    let t = (0L - (self.code >> 31)) & MASK32
    self.code = (self.code + (self.range & t)) & MASK32
    result = (result << 1) + ((t + 1L) & 1L).to_int()
    self.normalize()
    i += 1
  }
  result
}

///|
/// 位树解码（高位在前）。
fn RangeDecoder::tree(
  self : RangeDecoder,
  probs : Array[Int32],
  base : Int32,
  bits : Int32,
) -> Int32 raise SevenZError {
  let mut symbol = 1
  let mut i = 0
  while i < bits {
    symbol = (symbol << 1) | self.bit(probs, base + symbol)
    i += 1
  }
  symbol - (1 << bits)
}

///|
/// 反向位树解码（先出的位是低位）。
fn RangeDecoder::reverse_tree(
  self : RangeDecoder,
  probs : Array[Int32],
  base : Int32,
  bits : Int32,
) -> Int32 raise SevenZError {
  let mut symbol = 1
  let mut result = 0
  let mut i = 0
  while i < bits {
    let b = self.bit(probs, base + symbol)
    symbol = (symbol << 1) | b
    result = result | (b << i)
    i += 1
  }
  result
}

///|
/// 一次 LZMA 解码的全部状态：概率模型 + 状态机 + 重复距离（reps）。
///
/// 概率数组与 LZMA SDK / xz 的 `CLzmaDec` 逐项对齐，便于出现差异时对着规范定位：
/// `is_match[state * 16 + pos_state]`、`is_rep[state]`、`is_rep_g0/g1/g2[state]`、
/// `is_rep0_long[state * 16 + pos_state]`、`pos_slot[4 * 64]`（按 (len-2) 截到 0..3 索引）、
/// `pos_special[115]`、`align[16]`、`len` / `rep_len` =
/// choice + choice2 + low[16][8] + mid[16][8] + high[256]（low/mid 按 pos_state 索引）、
/// `literal[0x300 << (lc + lp)]`：每个上下文 3 个 0x100 半区
/// （0x000 普通或已失配、0x100 仍在匹配且提示位为 0、0x200 仍在匹配且提示位为 1）。
///
/// 字面值数组固定按 lc + lp <= 4 的上限分配，因此切换 props 不需要重新分配，
/// state reset 就是把所有概率填回 1024 并清空状态机。
priv struct LzmaState {
  mut lc : Int32
  mut lp : Int32
  mut pb : Int32
  mut state : Int32
  mut rep0 : Int32
  mut rep1 : Int32
  mut rep2 : Int32
  mut rep3 : Int32
  is_match : Array[Int32]
  is_rep : Array[Int32]
  is_rep_g0 : Array[Int32]
  is_rep_g1 : Array[Int32]
  is_rep_g2 : Array[Int32]
  is_rep0_long : Array[Int32]
  pos_slot : Array[Int32]
  pos_special : Array[Int32]
  align : Array[Int32]
  len : Array[Int32]
  rep_len : Array[Int32]
  literal : Array[Int32]
}

///|
/// 新建状态（概率全为 1024）。
fn LzmaState::new(lc : Int32, lp : Int32, pb : Int32) -> LzmaState {
  let state : LzmaState = {
    lc,
    lp,
    pb,
    state: 0,
    rep0: 0,
    rep1: 0,
    rep2: 0,
    rep3: 0,
    is_match: Array::make(NUM_STATES * 16, PROB_INIT),
    is_rep: Array::make(NUM_STATES, PROB_INIT),
    is_rep_g0: Array::make(NUM_STATES, PROB_INIT),
    is_rep_g1: Array::make(NUM_STATES, PROB_INIT),
    is_rep_g2: Array::make(NUM_STATES, PROB_INIT),
    is_rep0_long: Array::make(NUM_STATES * 16, PROB_INIT),
    pos_slot: Array::make(
      NUM_LEN_TO_POS_STATES * (1 << NUM_POS_SLOT_BITS),
      PROB_INIT,
    ),
    pos_special: Array::make(NUM_POS_MODELS, PROB_INIT),
    align: Array::make(1 << NUM_ALIGN_BITS, PROB_INIT),
    len: Array::make(LEN_PROBS, PROB_INIT),
    rep_len: Array::make(LEN_PROBS, PROB_INIT),
    literal: Array::make(LITERAL_PROBS, PROB_INIT),
  }
  state
}

///|
/// state reset：清空概率模型、状态机与 reps（字典内容保留，由调用方维护 dict_base）。
fn LzmaState::reset(self : LzmaState) -> Unit {
  self.is_match.fill(PROB_INIT)
  self.is_rep.fill(PROB_INIT)
  self.is_rep_g0.fill(PROB_INIT)
  self.is_rep_g1.fill(PROB_INIT)
  self.is_rep_g2.fill(PROB_INIT)
  self.is_rep0_long.fill(PROB_INIT)
  self.pos_slot.fill(PROB_INIT)
  self.pos_special.fill(PROB_INIT)
  self.align.fill(PROB_INIT)
  self.len.fill(PROB_INIT)
  self.rep_len.fill(PROB_INIT)
  self.literal.fill(PROB_INIT)
  self.state = 0
  self.rep0 = 0
  self.rep1 = 0
  self.rep2 = 0
  self.rep3 = 0
}

///|
/// 换一组 lc / lp / pb 并做 state reset。
fn LzmaState::set_props(
  self : LzmaState,
  lc : Int32,
  lp : Int32,
  pb : Int32,
) -> Unit {
  self.lc = lc
  self.lp = lp
  self.pb = pb
  self.reset()
}

///|
/// 解一个字面值，追加到 `out`。
///
/// 字面值上下文的"位置"是**自上次字典复位以来的字节数**（LZMA SDK 的 `processedPos`
/// 在字典复位时归零，xz 的 `dict.pos` 同理），前一个字节在字典复位后的第一个字面值
/// 处取 0。实测依据：`_research/probe_dictreset_pos.py`（自建流交给 liblzma 判决，
/// prev=0 被接受、prev=实际前一字节被拒）。
fn LzmaState::decode_literal(
  self : LzmaState,
  rc : RangeDecoder,
  out : Array[Byte],
  dict_base : Int32,
) -> Unit raise SevenZError {
  let produced = out.length() - dict_base
  let prev = if produced > 0 {
    out.unsafe_get(out.length() - 1).to_int()
  } else {
    0
  }
  let prev_pos = produced & ((1 << self.lp) - 1)
  let base = 0x300 * (((prev_pos << 8) + prev) >> (8 - self.lc))
  let mut symbol = 1
  if self.state >= 7 {
    // 上一个符号是匹配：用字典里距离 rep0 处的字节做上下文。
    if self.rep0 >= produced {
      raise LzmaCorrupt(
        reason="字面值的 match byte 越出字典窗口：距离 " +
          (self.rep0 + 1).to_string() +
          "，窗口 " +
          produced.to_string(),
      )
    }
    let mut match_byte = out.unsafe_get(out.length() - self.rep0 - 1).to_int()
    while symbol < 0x100 {
      let match_bit = (match_byte >> 7) & 1
      match_byte = (match_byte << 1) & 0xFF
      // 三个半区：0x100 提示位 0 / 0x200 提示位 1；分岔后改走 0x000 半区（下面的普通树）。
      let idx = base + 0x100 + (if match_bit == 1 { 0x100 } else { 0 }) + symbol
      let b = rc.bit(self.literal, idx)
      symbol = (symbol << 1) | b
      if match_bit != b {
        break
      }
    }
  }
  while symbol < 0x100 {
    symbol = (symbol << 1) | rc.bit(self.literal, base + symbol)
  }
  out.push((symbol & 0xFF).to_byte())
}

///|
/// 解一个长度符号。返回值就是拷贝字节数（>= 2，规范里已经含 kMatchMinLen，
/// 调用方不要再加 2）。
///
/// 长度解码器布局：choice / choice2 两个选择位，然后 low[16][8]（长度 2..9）、
/// mid[16][8]（10..17）、high[256]（18..273），low / mid 按 pos_state 索引。
fn lzma_decode_len(
  rc : RangeDecoder,
  probs : Array[Int32],
  pos_state : Int32,
) -> Int32 raise SevenZError {
  if rc.bit(probs, 0) == 0 {
    return 2 + rc.tree(probs, 2 + pos_state * 8, 3)
  }
  if rc.bit(probs, 1) == 0 {
    return 10 + rc.tree(probs, 2 + 16 * 8 + pos_state * 8, 3)
  }
  18 + rc.tree(probs, 2 + 16 * 8 + 16 * 8, 8)
}

///|
/// 把字典里距离 `dist`（= rep0 + 1）处的 `length` 个字节拷到 `out`。
///
/// 逐字节拷贝天然处理重叠匹配（dist < length 时的 RLE），并且一旦到达
/// `limit` 就停下——匹配可以跨过分块边界，但输出长度以声明值为准。
fn lzma_copy_match(
  out : Array[Byte],
  dict_base : Int32,
  dist : Int32,
  length : Int32,
  limit : Int32,
) -> Unit raise SevenZError {
  let window = out.length() - dict_base
  if dist >= window {
    raise LzmaCorrupt(
      reason="匹配距离越出字典窗口：距离 " +
        (dist + 1).to_string() +
        "，窗口 " +
        window.to_string(),
    )
  }
  let src = out.length() - dist - 1
  let mut i = 0
  while i < length && out.length() < limit {
    out.push(out.unsafe_get(src + i))
    i += 1
  }
}

///|
/// 从 `rc` 解到 `out` 的长度达到 `limit` 为止。
///
/// 这是 LZMA 的主状态机：字面值 / 匹配 / 重复匹配三分支，其状态迁移与 LZMA SDK 一致。
fn LzmaState::decode_chunk(
  self : LzmaState,
  rc : RangeDecoder,
  out : Array[Byte],
  dict_base : Int32,
  limit : Int32,
) -> Unit raise SevenZError {
  while out.length() < limit {
    // pos_state 与字面值上下文一样，按"自上次字典复位以来的字节数"计（见 decode_literal）。
    let pos_state = (out.length() - dict_base) & ((1 << self.pb) - 1)
    if rc.bit(self.is_match, self.state * 16 + pos_state) == 0 {
      self.decode_literal(rc, out, dict_base)
      let st = self.state
      self.state = if st < 4 { 0 } else if st < 10 { st - 3 } else { st - 6 }
      continue
    }
    let mut length = 0
    if rc.bit(self.is_rep, self.state) != 0 {
      if rc.bit(self.is_rep_g0, self.state) == 0 {
        if rc.bit(self.is_rep0_long, self.state * 16 + pos_state) == 0 {
          // 短重复：拷 1 字节，不重排 reps。
          self.state = if self.state < 7 { 9 } else { 11 }
          lzma_copy_match(out, dict_base, self.rep0, 1, limit)
          continue
        }
      } else {
        let dist = if rc.bit(self.is_rep_g1, self.state) == 0 {
          self.rep1
        } else if rc.bit(self.is_rep_g2, self.state) == 0 {
          self.rep2
        } else {
          let d = self.rep3
          self.rep3 = self.rep2
          d
        }
        self.rep2 = self.rep1
        self.rep1 = self.rep0
        self.rep0 = dist
      }
      length = lzma_decode_len(rc, self.rep_len, pos_state)
      self.state = if self.state < 7 { 8 } else { 11 }
    } else {
      self.rep3 = self.rep2
      self.rep2 = self.rep1
      self.rep1 = self.rep0
      length = lzma_decode_len(rc, self.len, pos_state)
      self.state = if self.state < 7 { 7 } else { 10 }
      self.rep0 = self.decode_distance(rc, length)
    }
    lzma_copy_match(out, dict_base, self.rep0, length, limit)
  }
}

///|
/// 解新匹配的距离（写入并返回 rep0）。
fn LzmaState::decode_distance(
  self : LzmaState,
  rc : RangeDecoder,
  length : Int32,
) -> Int32 raise SevenZError {
  let mut len_state = length - 2
  if len_state >= NUM_LEN_TO_POS_STATES {
    len_state = NUM_LEN_TO_POS_STATES - 1
  }
  let pos_slot = rc.tree(
    self.pos_slot,
    len_state * (1 << NUM_POS_SLOT_BITS),
    NUM_POS_SLOT_BITS,
  )
  if pos_slot < 4 {
    return pos_slot
  }
  let num_direct = (pos_slot >> 1) - 1
  let base = (2 | (pos_slot & 1)) << num_direct
  if pos_slot < END_POS_MODEL_INDEX {
    base + rc.reverse_tree(self.pos_special, base - pos_slot - 1, num_direct)
  } else {
    base +
    (rc.direct_bits(num_direct - NUM_ALIGN_BITS) << NUM_ALIGN_BITS) +
    rc.reverse_tree(self.align, 0, NUM_ALIGN_BITS)
  }
}

///|
/// 校验 props 首字节给出的 lc / lp / pb。
fn lzma_check_lclppb(value : Int32, what : String) -> Unit raise SevenZError {
  let lc = value % 9
  let lp = value / 9 % 5
  let pb = value / 45
  if pb > 4 || lc + lp > 4 {
    raise LzmaCorrupt(
      reason=what +
        " 非法 props " +
        hex_byte(value) +
        "（lc=" +
        lc.to_string() +
        " lp=" +
        lp.to_string() +
        " pb=" +
        pb.to_string() +
        "）",
    )
  }
}

///|
/// 校验 unpack_size 并转成 Int。
fn lzma_check_size(unpack_size : Int64) -> Int32 raise SevenZError {
  if unpack_size < 0L {
    raise LzmaCorrupt(
      reason="声明的解压大小为负：" + unpack_size.to_string(),
    )
  }
  if unpack_size > MAX_UNPACK_SIZE {
    raise Unsupported(
      what="解压大小超过 2 GiB：" + unpack_size.to_string(),
    )
  }
  unpack_size.to_int()
}

///|
/// 解一段 LZMA1 裸流（7z 的 0x030101 coder）。
///
/// `props` 5 字节；`data` 是裸码流（无 ALONE 头、无 EOS）；
/// 输出长度由 `unpack_size` 决定，尾部多余的输入字节被容忍。
pub fn lzma1_decode(
  props : Bytes,
  data : Bytes,
  unpack_size : Int64,
) -> Bytes raise SevenZError {
  if props.length() < 5 {
    raise LzmaCorrupt(
      reason="LZMA1 props 需要 5 字节，实际 " +
        props.length().to_string(),
    )
  }
  let d = props.unsafe_get(0).to_int()
  lzma_check_lclppb(d, "LZMA1")
  let limit = lzma_check_size(unpack_size)
  if limit == 0 {
    return Bytes::new(0)
  }
  let state = LzmaState::new(d % 9, d / 9 % 5, d / 45)
  let out : Array[Byte] = []
  let rc = RangeDecoder::new(data, 0, data.length())
  state.decode_chunk(rc, out, 0, limit)
  Bytes::from_array(out[:])
}

///|
/// 解一段 LZMA2 流（7z 的 0x21 coder）。
///
/// `props` 1 字节字典大小编码；`data` 是含分块头的完整流。
/// 输出达到 `unpack_size` 即返回，结尾的 0x00 结束标记与尾部多余字节都可以缺失。
pub fn lzma2_decode(
  props : Bytes,
  data : Bytes,
  unpack_size : Int64,
) -> Bytes raise SevenZError {
  if props.length() < 1 {
    raise LzmaCorrupt(reason="LZMA2 props 需要 1 字节")
  }
  let dict_code = props.unsafe_get(0).to_int()
  if dict_code > 40 {
    raise LzmaCorrupt(
      reason="LZMA2 字典大小编码非法：" + hex_byte(dict_code),
    )
  }
  let limit = lzma_check_size(unpack_size)
  let out : Array[Byte] = []
  let mut pos = 0
  let mut dict_base = 0
  let mut state : LzmaState? = None
  while out.length() < limit {
    if pos >= data.length() {
      raise LzmaCorrupt(reason="LZMA2 码流提前结束：缺少分块头")
    }
    let ctrl = data.unsafe_get(pos).to_int()
    pos += 1
    if ctrl == 0 {
      raise LzmaCorrupt(reason="LZMA2 提前出现结束标记")
    }
    if ctrl < 0x80 {
      // 未压缩块：0x01 / 0x02。
      //
      // 这两个控制值里哪个表示"复位字典"各家文档与实现并不一致，实测 liblzma 只接受
      // "首块用 0x01"（用 0x02 作首块会被拒），与常见文档相反。这里刻意不对未压缩块
      // 复位窗口：窗口只影响"是否接受跨块引用"，放宽不会误拒合法归档；而真正影响
      // 解码结果的是 LZMA 块自身的字典复位（ctrl >= 0xE0，见下），它决定复位之后
      // 第一个字面值的 prev 取 0（已用 liblzma 判决实验确认）。
      if ctrl != 1 && ctrl != 2 {
        raise LzmaCorrupt(reason="LZMA2 保留控制字节 " + hex_byte(ctrl))
      }
      if pos + 2 > data.length() {
        raise LzmaCorrupt(reason="LZMA2 未压缩块头被截断")
      }
      let size = (data.unsafe_get(pos).to_int() << 8) +
        data.unsafe_get(pos + 1).to_int() +
        1
      pos += 2
      if pos + size > data.length() {
        raise LzmaCorrupt(
          reason="LZMA2 未压缩块数据被截断：需要 " +
            size.to_string() +
            " 字节，实际 " +
            (data.length() - pos).to_string(),
        )
      }
      if size > limit - out.length() {
        raise LzmaCorrupt(
          reason="LZMA2 未压缩块超出声明的解压大小",
        )
      }
      let mut i = 0
      while i < size {
        out.push(data.unsafe_get(pos + i))
        i += 1
      }
      pos += size
      continue
    }
    if pos + 4 > data.length() {
      raise LzmaCorrupt(
        reason="LZMA2 分块头被截断：剩余 " +
          (data.length() - pos).to_string() +
          " 字节（需要 4）",
      )
    }
    let unpack = ((ctrl & 0x1F) << 16) +
      (data.unsafe_get(pos).to_int() << 8) +
      data.unsafe_get(pos + 1).to_int() +
      1
    let packed = (data.unsafe_get(pos + 2).to_int() << 8) +
      data.unsafe_get(pos + 3).to_int() +
      1
    pos += 4
    if ctrl >= 0xC0 {
      if pos >= data.length() {
        raise LzmaCorrupt(reason="LZMA2 分块 props 字节缺失")
      }
      let p = data.unsafe_get(pos).to_int()
      pos += 1
      lzma_check_lclppb(p, "LZMA2 分块")
      match state {
        Some(st) => st.set_props(p % 9, p / 9 % 5, p / 45)
        None => state = Some(LzmaState::new(p % 9, p / 9 % 5, p / 45))
      }
    } else if ctrl >= 0xA0 {
      match state {
        Some(st) => st.reset()
        None =>
          raise LzmaCorrupt(
            reason="LZMA2 首个 LZMA 块既无 props 也无 state reset",
          )
      }
    }
    if ctrl >= 0xE0 {
      dict_base = out.length()
    }
    let st = match state {
      Some(st) => st
      None =>
        raise LzmaCorrupt(reason="LZMA2 首个 LZMA 块必须携带 props")
    }
    if pos + packed > data.length() {
      raise LzmaCorrupt(
        reason="LZMA2 分块数据被截断：需要 " +
          packed.to_string() +
          " 字节，实际 " +
          (data.length() - pos).to_string(),
      )
    }
    if unpack > limit - out.length() {
      raise LzmaCorrupt(
        reason="LZMA2 分块声明的解压大小超出剩余总量",
      )
    }
    let rc = RangeDecoder::new(data, pos, pos + packed)
    st.decode_chunk(rc, out, dict_base, out.length() + unpack)
    pos += packed
  }
  Bytes::from_array(out[:])
}
