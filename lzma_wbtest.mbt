// lzma_wbtest.mbt
//
// F4 判据：LZMA1 / LZMA2 解码内核。
//
// 所有 packed 字节与期望明文都由 Python 的 liblzma 独立产出/复核（脚本在 `_research/`，
// 不进仓库），不是本实现的自我循环：
//   向量 1 / 3  LZMA1：props = 5d00008000（lc=3 lp=0 pb=2，字典 8 MiB）
//   向量 2 / 4  LZMA2：props = 16（字典 8 MiB）
//   向量 5      LZMA2 未压缩块（ctrl 0x01，liblzma 对随机数据的选择）
//   向量 6      0x01 未压缩块 + 0xC0 LZMA 块（state reset、字典保留 → 首个字面值
//               的 prev 取"最后一个原文字节"，该字节布局经 liblzma 判决）
//   向量 7      LZMA2 多分块（0xFF 起始块 + 0x84 续块，载荷 2.4 MB，续块覆盖
//               "不复位任何状态"的代码路径）
//
// 截断阈值是**实测值**，不是规范保证：LZMA1 尾部砍 1..5 字节仍能解出正确结果
// （那几个字节属于区间编码器的 flush，解码器用不到），砍 >= 6 才报 LzmaCorrupt；
// LZMA2 尾部砍 1 字节（结束标记 0x00）仍正确，砍 >= 2 报"分块数据被截断"。
// 因此负例统一砍 8 字节，确保落在必须报错的区间里。

///|
/// 载荷 1 / 2 的明文：200 个 'A' 后接 50 遍 "hello 7z world "。
fn lzma_want950() -> Bytes {
  let want : Array[Byte] = []
  for _ in 0..<200 {
    want.push(b'A')
  }
  for _ in 0..<50 {
    for c in b"hello 7z world " {
      want.push(c)
    }
  }
  Bytes::from_array(want[:])
}

///|
/// 字节比较：失败时把实际值与期望值都渲染成十六进制（与其他 wbtest 的助手不重名）。
fn lzma_assert_bytes(actual : Bytes, expected : Bytes, what : String) -> Unit {
  if !actual.equal(expected) {
    abort(
      what +
      " 不符：实际长度 " +
      actual.length().to_string() +
      "，期望长度 " +
      expected.length().to_string() +
      "；实际 " +
      hex_string(actual) +
      "，期望 " +
      hex_string(expected),
    )
  }
}

///|
/// 负例统一写法：解码必须抛出 LzmaCorrupt / Truncated，而不是成功或 panic。
/// 直接内联 try/catch，不用闭包（避免 `fn` 效果推断的弃用告警）。

///|
test "向量 1：LZMA1 数据流逐字节一致" {
  let props = bytes_from_hex("5d00008000")
  let packed = bytes_from_hex(
    "0020ef6668329bdc9d8fb4ea602abaad793085390eec17941565ec6f4ffffe94" + "5800",
  )
  let got = lzma1_decode(props, packed, 950L)
  lzma_assert_bytes(got, lzma_want950(), "向量 1")
}

///|
test "向量 2：LZMA2 数据流逐字节一致" {
  let props = bytes_from_hex("16")
  let packed = bytes_from_hex(
    "e003b5001c5d0020ef6668329bdc9d8fb4ea602abaad793085390eec17941562" +
    "cead0000",
  )
  let got = lzma2_decode(props, packed, 950L)
  lzma_assert_bytes(got, lzma_want950(), "向量 2")
}

///|
test "向量 3：LZMA1 头流逐字节一致且 CRC-32 相符" {
  let props = bytes_from_hex("5d00008000")
  let packed = bytes_from_hex(
    "0000813307ae0fd02cf4bc9f3f474165c5d8afe40b970a72f631f834659ce55e" +
    "23363cfb758e00464471f2bd7bddcaa63b455325017958871de6f0e6d562a0d0" +
    "63fe106144dd6928cf1c02ece13d14bc5c55ad0f594c5c087ad4511926ef1d89" +
    "c718bbb90d64adfd767c9e497738cffffb8a2800",
  )
  let got = lzma1_decode(props, packed, 148L)
  lzma_assert_bytes(
    got,
    bytes_from_hex(
      "0104060001092200070b01000123030101055d000080000c83b600080d020980" +
      "c80a01983dbb28055c7b4e0000050211190061002e0074007800740000006200" +
      "2e007400780074000000141201000080a621c989d6010080a621c989d6011212" +
      "0100b6c3079a8563dd018ced079a8563dd01131201000080a621c989d6010080" +
      "a621c989d601150a01002080b6812080b6810000",
    ),
    "向量 3",
  )
  // 期望值里的 CRC-32 = 0xbb6ebf72（题目给出，python zlib 独立复核）
  @test.assert_eq(crc32(got, 0, got.length()), 0xbb6ebf72L)
}

///|
test "向量 4：LZMA2 头流逐字节一致且 CRC-32 相符" {
  let props = bytes_from_hex("16")
  let packed = bytes_from_hex(
    "e0008d00695d0000813307ae0fd04b393c9f3f4741057bee1d0eee921a51b9b6" +
    "a8a2dd5f3cd1b6b26b3ddcdca112c6804d7b5c5d2c9de1ed98ee72af421222d3" +
    "2e125f649457c52d1f2a12984833d36cbb2be6efc3d7a3388c9c156799240527" +
    "744141050676aa813241fa890000000000",
  )
  let got = lzma2_decode(props, packed, 142L)
  lzma_assert_bytes(
    got,
    bytes_from_hex(
      "0104060001092400070b010001212101160c83b600080d020980c80a01983dbb" +
      "28055c7b4e0000050211190061002e00740078007400000062002e0074007800" +
      "74000000141201000080a621c989d6010080a621c989d601121201000ef7139a" +
      "8563dd01601e149a8563dd01131201000080a621c989d6010080a621c989d601" +
      "150a01002080b6812080b6810000",
    ),
    "向量 4",
  )
  // 期望值里的 CRC-32 = 0xcafa3561（题目给出，python zlib 独立复核）
  @test.assert_eq(crc32(got, 0, got.length()), 0xcafa3561L)
}

///|
test "向量 5：LZMA2 未压缩块（ctrl 0x01）" {
  let props = bytes_from_hex("00")
  let packed = bytes_from_hex(
    "01012be13b032e112a32b579080f08b1f7ed4c2e5d3a07f97f21ee232d178a20" +
    "9af6b5887f66e8092402aa49f2c1551b27fe53266e490db138489ce814d58d14" +
    "5a8b4f994fed15c5b2fdaeeff317f157e1e0978c3f5fd5df3d34f8c08262b037" +
    "50894fa5e42428ca6d189213702ca29ceb218325da6733cb63eb78b869d75968" +
    "9a1eb44efff1aa474318544a23a657001f2c4b6f14ddc8a66ac38f9bd8a34d2f" +
    "858ed2cc8d3ac08c6d98cb1ab2e177fb54c29d0125f5ca98dbf55fcdf45090bd" +
    "b16956eaf20eef350dbbf32147a9b29498a996638e2568adaba4ea882b3d7d83" +
    "be460eca13166a4fa0b5de239c85f870b22a09a97553f4ff47224a7c54c9a742" +
    "e414be23bcd11624a07465b1c2fc1a0fe52996daae4bf87b0fb6bed45926096c" +
    "6448438219efb9be93cbd0bc77920400",
  )
  let got = lzma2_decode(props, packed, 300L)
  lzma_assert_bytes(
    got,
    bytes_from_hex(
      "e13b032e112a32b579080f08b1f7ed4c2e5d3a07f97f21ee232d178a209af6b5" +
      "887f66e8092402aa49f2c1551b27fe53266e490db138489ce814d58d145a8b4f" +
      "994fed15c5b2fdaeeff317f157e1e0978c3f5fd5df3d34f8c08262b03750894f" +
      "a5e42428ca6d189213702ca29ceb218325da6733cb63eb78b869d759689a1eb4" +
      "4efff1aa474318544a23a657001f2c4b6f14ddc8a66ac38f9bd8a34d2f858ed2" +
      "cc8d3ac08c6d98cb1ab2e177fb54c29d0125f5ca98dbf55fcdf45090bdb16956" +
      "eaf20eef350dbbf32147a9b29498a996638e2568adaba4ea882b3d7d83be460e" +
      "ca13166a4fa0b5de239c85f870b22a09a97553f4ff47224a7c54c9a742e414be" +
      "23bcd11624a07465b1c2fc1a0fe52996daae4bf87b0fb6bed45926096c644843" +
      "8219efb9be93cbd0bc779204",
    ),
    "向量 5",
  )
}

///|
test "向量 6：未压缩块 + 0xC0 LZMA 块（字典保留，prev 取实际前字节）" {
  let props = bytes_from_hex("00")
  let packed = bytes_from_hex(
    "0100c881a6657b623a95f3794a018f0efe5861c65da9a43c2c85f06873622429" +
    "66e027336ca82c30ec28368be33eb31cce7e70f1ce46c406111afd14b7dd3c83" +
    "fa1cf1304b982f08f8b4d4001ff64a0d047a2dee3ac7f334457a856b2c52544c" +
    "0c1977c2d5fa8934f1d4978d93e86009f924120948042e37682ad95437c491eb" +
    "facd63db80912ca5a1638fbcf4c9cd82c19e288c344a46b8196c1d0b3d418a52" +
    "af1ec02c9928b8e80218e64cfdcf27dc023810c040138582592c2317c6245bf6" +
    "68a5a6f07561f8dfc564cd31c0018f01a25d003627512ad710a7c6411b849067" +
    "a251b9cbb9c951f1b27bbd32532a32c22813aa2e39a7330202c22c6838a0e136" +
    "82fd0b5749b23f41f903fb698ed65eef380f93005bd6f672a59d196af1a95080" +
    "8935bcae35fbe349256b336723a8e8bf716bbab141ced832c738c38bfaca37e6" +
    "f70ffcca4b09433a986aa0d3478d8b27aeb828f74e3dd7e6585777ddc35d2ec0" +
    "c669705632957403199a9ab6332c285bcb854de414ae502da8285658273012b4" +
    "63a555e0386558f7a27addf012b1959a874464ed181ab2d39cd60e7e3ae17937" +
    "133c54fd1d024cc83c1b0d9bbc71ace22a5296655d1331841057e38afab84d01" +
    "f3ac20cf20fa256880fbbd58db0d772805518a4b6126d4e030f507666bb88af0" +
    "b92cdb8f2171f444b6c3dc447258feb80ff88048f2a87430da34e0ad303002f8" +
    "f1789e77d986133ca6699bfa5464d8ab653c30dff53075ef546daf8dacccec19" +
    "cc6436a1c5d2d7cfd13ba9229b22a03af750dcc0b0b9ca19b5f9f8477096d526" +
    "eee3a5f4d74d424830405668039d08b76eb368081c5d6d118a303d395bfd5b56" +
    "b906b93cf302667d37b2737b19ef05dc1f6f8a069100",
  )
  let got = lzma2_decode(props, packed, 601L)
  lzma_assert_bytes(
    got,
    bytes_from_hex(
      "81a6657b623a95f3794a018f0efe5861c65da9a43c2c85f0687362242966e027" +
      "336ca82c30ec28368be33eb31cce7e70f1ce46c406111afd14b7dd3c83fa1cf1" +
      "304b982f08f8b4d4001ff64a0d047a2dee3ac7f334457a856b2c52544c0c1977" +
      "c2d5fa8934f1d4978d93e86009f924120948042e37682ad95437c491ebfacd63" +
      "db80912ca5a1638fbcf4c9cd82c19e288c344a46b8196c1d0b3d418a52af1ec0" +
      "2c9928b8e80218e64cfdcf27dc023810c040138582592c2317c6245bf668a5a6" +
      "f07561f8dfc564cd316c9da9addb61b46d82b57350b04a87e4959afc7a30f522" +
      "8e94580497d6ddd8cc34e1b6f2fac356c5c6db850c9c91e0e20a27c6a9bf8838" +
      "b3b64a3fe4495418fc96afb62f834658a8da0cf233dd766612f736d90b2e0f1d" +
      "b7f9ef8ecf2763b97610545b6d8eb39b1a2c60bbe6f57d3af5e5c4d2ec31bd56" +
      "3efe7791a086a8f4bba1750f160d7f0cd82e69da74f97e9ca9783baafafe5ccc" +
      "f7d14d5f0f12195708bbfb82ef2e8fd831ef1245bcec5d355389973abc830751" +
      "9489e272d381ae5803f75f100fdfc56cca423f9e36ad9e6fee7e8bc935410d3b" +
      "0e469dd738e68c427a4dfd2cac73ddccc2cb0c666b1369c9da38304eb74e549a" +
      "e74622202400d489c9974a76e808d1e9d0ce82b8143d769e1d319a9530e1de6f" +
      "dca2260e91dba294980e9c8eb72b6709fef33eafc51fc19e79527006c8f811dc" +
      "cebf9b2a150a75c392047fc8bdebafcd0bd7d8df61041b372ff29667adae8b70" +
      "ef5baa42bdb41f51d644d8c2ce5f1432d8456c5542cd3e4f08b26378c70a1afa" +
      "f1fbf138139f51f48c081e3258f43dba9c2fc30474462338f5",
    ),
    "向量 6",
  )
}

///|
test "向量 7：LZMA2 多分块（起始块 + 续块）" {
  let props = bytes_from_hex("08")
  let packed = bytes_from_hex(
    "ffff12016e5d002090abfc1dfff7ffd4810a9f747384fa3011a669a78f910be4" +
    "45a443bddf6ab016701e562d0beab8271d9b25023fa8ff5a72a995a2c2c5aa34" +
    "1906768c766965a12ec886186560b2ff4d8ff2058b68f491488c870094129a24" +
    "367f664290130eff1093f8717859f80bcdff9528460fa9fc7cdefb9a302e56c0" +
    "8f85f38381c065c42553f8f591363105a5b0ee6fc1704d470cd19111aaad601d" +
    "baceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd" +
    "1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290" +
    "130eff1093f8717859f80bcdff9528460fa9fc7cdefb9a302e56c08f85f38381" +
    "c065c42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb12718" +
    "5c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9" +
    "dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093" +
    "f8717859f80bcdff9528460fa9fc7cdefb9817fd48849fec003000ec7353a7fd" +
    "beae7c311a9fb78d316e709ea7235fec28cb85d195988a7e2a91f22775f719c0" +
    "06984d98fdd5374979800000",
  )
  let got = lzma2_decode(props, packed, 2400000L)
  lzma_assert_bytes(got, b"AB".repeat(1200000), "向量 7")
}

///|
/// 向量 8 的明文：200 遍 "hello 7z world " 后接 600 个 (i * 37 + 11) & 0xFF。
fn lzma_vec8_want() -> Bytes {
  let want : Array[Byte] = []
  for _ in 0..<200 {
    for c in b"hello 7z world " {
      want.push(c)
    }
  }
  for i in 0..<600 {
    want.push(((i * 37 + 11) & 0xFF).to_byte())
  }
  Bytes::from_array(want[:])
}

///|
test "向量 8：不同 lc/lp/pb 组合（覆盖 lp > 0、pb = 0、lc = 0 的字面值上下文）" {
  // liblzma 生成：同一载荷分别用 (lc=0,lp=0,pb=0)、(lc=1,lp=3,pb=0) 的 LZMA1，
  // (lc=2,lp=2,pb=2)、(lc=0,lp=0,pb=0) 的 LZMA2（字典 8 MiB）。
  let want = lzma_vec8_want()
  let d1 = bytes_from_hex(
    "00341a726172043d1859d0a928baa440cc9235e7936d4cc97de4298170bb42d4" +
    "812b47459af8fe7c1d20b79e5e9c414d692e3cb1edf17fe5f745d987abc850ea" +
    "e80a28c9537983899d5a1c1f25db0addf1448c8b553def1cbba0450b3a00fff0" +
    "7a8fc93ec647285d49c44ee595d3792cc174d7d961321ef785378b6947ce79f9" +
    "2e592ab205a790e11555e03ac4c42d19d18c18e5b0d2d2dbae0803d9a63b0edd" +
    "49f17e3684b12bd68b0ee290d9dbe19a67834a6b35cff878cb955bd92ce28ca0" +
    "085ebe76cebf7553f63caa8dd86e1cbc8d56dbda523d1651f4ac9cfb76bbb10d" +
    "1e784e944301d802aa3b943f89545106befa0affe05d0acdbbb60df3170a95dd" +
    "5faf29c765b17922fc7a37222e6ecf8aba21508aede3e72b57b4902a7b55bb55" +
    "48984cbd54defbc92b99468a5b306c94064adf8ffffa1ad520",
  )
  lzma_assert_bytes(
    lzma1_decode(bytes_from_hex("0000008000"), d1, 3600L),
    want,
    "向量 8a lc=0 lp=0 pb=0",
  )
  let d2 = bytes_from_hex(
    "00341a14e2c4276e7f84d4134570ac1af26fb58938ca3f1fbe89b4033fa17acd" +
    "d794618f8029e2fd25923bce7a109c1566c3c3b134424f219750b4b94b8091be" +
    "9f436ee080f39c6d2f80912320b6d0da474c436a0527813bf971dcd7b50c1c6e" +
    "d2179846cab407f99895d98abb905d66c3ac57d02486fc390fded7c705607d3e" +
    "1083b648ebb094d822b4b989ea5f0233a78edc430403c1a99f461bc1d09c1adb" +
    "8fe54548ef1ee6543706da8260594c0302403eb895e7f2d9602cd5fa87f5c220" +
    "528e529706dcd18bdc0685096afc9f4ad5a94d0873f0716df929f0fb255179e1" +
    "6dfe0897dc0a9bf9609a5c36980ae2eff6324016de5eb111b269cb83595809e5" +
    "b5287d8601b435cb5382acb5b12e12ac2b7c9738536a332fe57e2aebe0d35192" +
    "9de4e42592d71a473d5bcae8a7ffff82a81380",
  )
  lzma_assert_bytes(
    lzma1_decode(bytes_from_hex("1c00008000"), d2, 3600L),
    want,
    "向量 8b lc=1 lp=3 pb=0",
  )
  let d3 = bytes_from_hex(
    "e00e0f012f6e00341949986f1009cb544fd9b86d65c48efe443545dcaf6dfa6f" +
    "33541d0ef1a36ae966958a063ce533e42684ddd801271499e9385d92f9f33ccc" +
    "dbb976c0d04a6801e7f0b8090586bd8ea02053447f0307adeaa55fd9fdc5e2a6" +
    "1b5eefa3841681c82f71c003b07a20c01495997ffc3374d1de6ee6d88a4be4a1" +
    "2201cb78d247ed4f35a593b01a469aba4ee5b2816a3960d8403e8d34c525348a" +
    "b632d420277979fb187f5719250d3a444a6769fc27e351488162f0687baa988b" +
    "50929c53ad77bd8c674c8de05c4ab2fd0c30b07da99025fcafcc8be1406af795" +
    "981483bb44d71a60d2e59fd34ae0e864c27ad5db2e49d3690031695d40dd8651" +
    "ebdc23a0f4cd5286962d1a8efd9d594d3272026426b89df9d0e19a682fa2b1a9" +
    "094287e37e8139c0b6b67fcc9745da3413111c4c000000",
  )
  lzma_assert_bytes(
    lzma2_decode(bytes_from_hex("16"), d3, 3600L),
    want,
    "向量 8c lzma2 lc=2 lp=2 pb=2",
  )
  let d4 = bytes_from_hex(
    "e00e0f01330000341a726172043d1859d0a928baa440cc9235e7936d4cc97de4" +
    "298170bb42d4812b47459af8fe7c1d20b79e5e9c414d692e3cb1edf17fe5f745" +
    "d987abc850eae80a28c9537983899d5a1c1f25db0addf1448c8b553def1cbba0" +
    "450b3a00fff07a8fc93ec647285d49c44ee595d3792cc174d7d961321ef78537" +
    "8b6947ce79f92e592ab205a790e11555e03ac4c42d19d18c18e5b0d2d2dbae08" +
    "03d9a63b0edd49f17e3684b12bd68b0ee290d9dbe19a67834a6b35cff878cb95" +
    "5bd92ce28ca0085ebe76cebf7553f63caa8dd86e1cbc8d56dbda523d1651f4ac" +
    "9cfb76bbb10d1e784e944301d802aa3b943f89545106befa0affe05d0acdbbb6" +
    "0df3170a95dd5faf29c765b17922fc7a37222e6ecf8aba21508aede3e72b57b4" +
    "902a7b55bb5548984cbd54defbc92b99468a5b306c93fc4e480000",
  )
  lzma_assert_bytes(
    lzma2_decode(bytes_from_hex("16"), d4, 3600L),
    want,
    "向量 8d lzma2 lc=0 lp=0 pb=0",
  )
}

///|
test "负例：四个向量各砍掉尾部 8 字节都必须报 LzmaCorrupt" {
  let p1 = bytes_from_hex("5d00008000")
  let d1 = bytes_from_hex(
    "0020ef6668329bdc9d8fb4ea602abaad793085390eec17941565ec6f4ffffe94" + "5800",
  )
  try {
    ignore(lzma1_decode(p1, prefix(d1, d1.length() - 8), 950L))
    abort("向量 1 截断：应当报错，但成功返回")
  } catch {
    SevenZError::LzmaCorrupt(..) => ()
    SevenZError::Truncated(..) => ()
    _ => abort("向量 1 截断：错误类型不是 LzmaCorrupt / Truncated")
  }
  let p2 = bytes_from_hex("16")
  let d2 = bytes_from_hex(
    "e003b5001c5d0020ef6668329bdc9d8fb4ea602abaad793085390eec17941562" +
    "cead0000",
  )
  try {
    ignore(lzma2_decode(p2, prefix(d2, d2.length() - 8), 950L))
    abort("向量 2 截断：应当报错，但成功返回")
  } catch {
    SevenZError::LzmaCorrupt(..) => ()
    SevenZError::Truncated(..) => ()
    _ => abort("向量 2 截断：错误类型不是 LzmaCorrupt / Truncated")
  }
  let p3 = bytes_from_hex("5d00008000")
  let d3 = bytes_from_hex(
    "0000813307ae0fd02cf4bc9f3f474165c5d8afe40b970a72f631f834659ce55e" +
    "23363cfb758e00464471f2bd7bddcaa63b455325017958871de6f0e6d562a0d0" +
    "63fe106144dd6928cf1c02ece13d14bc5c55ad0f594c5c087ad4511926ef1d89" +
    "c718bbb90d64adfd767c9e497738cffffb8a2800",
  )
  try {
    ignore(lzma1_decode(p3, prefix(d3, d3.length() - 8), 148L))
    abort("向量 3 截断：应当报错，但成功返回")
  } catch {
    SevenZError::LzmaCorrupt(..) => ()
    SevenZError::Truncated(..) => ()
    _ => abort("向量 3 截断：错误类型不是 LzmaCorrupt / Truncated")
  }
  let p4 = bytes_from_hex("16")
  let d4 = bytes_from_hex(
    "e0008d00695d0000813307ae0fd04b393c9f3f4741057bee1d0eee921a51b9b6" +
    "a8a2dd5f3cd1b6b26b3ddcdca112c6804d7b5c5d2c9de1ed98ee72af421222d3" +
    "2e125f649457c52d1f2a12984833d36cbb2be6efc3d7a3388c9c156799240527" +
    "744141050676aa813241fa890000000000",
  )
  try {
    ignore(lzma2_decode(p4, prefix(d4, d4.length() - 8), 142L))
    abort("向量 4 截断：应当报错，但成功返回")
  } catch {
    SevenZError::LzmaCorrupt(..) => ()
    SevenZError::Truncated(..) => ()
    _ => abort("向量 4 截断：错误类型不是 LzmaCorrupt / Truncated")
  }
  let d5 = bytes_from_hex(
    "01012be13b032e112a32b579080f08b1f7ed4c2e5d3a07f97f21ee232d178a20" +
    "9af6b5887f66e8092402aa49f2c1551b27fe53266e490db138489ce814d58d14" +
    "5a8b4f994fed15c5b2fdaeeff317f157e1e0978c3f5fd5df3d34f8c08262b037" +
    "50894fa5e42428ca6d189213702ca29ceb218325da6733cb63eb78b869d75968" +
    "9a1eb44efff1aa474318544a23a657001f2c4b6f14ddc8a66ac38f9bd8a34d2f" +
    "858ed2cc8d3ac08c6d98cb1ab2e177fb54c29d0125f5ca98dbf55fcdf45090bd" +
    "b16956eaf20eef350dbbf32147a9b29498a996638e2568adaba4ea882b3d7d83" +
    "be460eca13166a4fa0b5de239c85f870b22a09a97553f4ff47224a7c54c9a742" +
    "e414be23bcd11624a07465b1c2fc1a0fe52996daae4bf87b0fb6bed45926096c" +
    "6448438219efb9be93cbd0bc77920400",
  )
  try {
    ignore(
      lzma2_decode(bytes_from_hex("00"), prefix(d5, d5.length() - 8), 300L),
    )
    abort("向量 5 截断：应当报错，但成功返回")
  } catch {
    SevenZError::LzmaCorrupt(..) => ()
    SevenZError::Truncated(..) => ()
    _ => abort("向量 5 截断：错误类型不是 LzmaCorrupt / Truncated")
  }
}

///|
test "正向：尾部追加垃圾字节仍解出正确结果（容忍多余输入）" {
  // 7z 的 LZMA1 裸流没有 EOS，LZMA2 的结束标记也可能被省略；
  // 以"是否产出声明的 unpack_size"为准，尾部多余字节不报错。
  let garbage = bytes_from_hex("deadbeef00ff")
  let p1 = bytes_from_hex("5d00008000")
  let d1 = bytes_from_hex(
    "0020ef6668329bdc9d8fb4ea602abaad793085390eec17941565ec6f4ffffe94" + "5800",
  )
  lzma_assert_bytes(
    lzma1_decode(p1, d1.add(garbage), 950L),
    lzma_want950(),
    "向量 1 + 垃圾",
  )
  let p2 = bytes_from_hex("16")
  let d2 = bytes_from_hex(
    "e003b5001c5d0020ef6668329bdc9d8fb4ea602abaad793085390eec17941562" +
    "cead0000",
  )
  lzma_assert_bytes(
    lzma2_decode(p2, d2.add(garbage), 950L),
    lzma_want950(),
    "向量 2 + 垃圾",
  )
  let p3 = bytes_from_hex("5d00008000")
  let d3 = bytes_from_hex(
    "0000813307ae0fd02cf4bc9f3f474165c5d8afe40b970a72f631f834659ce55e" +
    "23363cfb758e00464471f2bd7bddcaa63b455325017958871de6f0e6d562a0d0" +
    "63fe106144dd6928cf1c02ece13d14bc5c55ad0f594c5c087ad4511926ef1d89" +
    "c718bbb90d64adfd767c9e497738cffffb8a2800",
  )
  @test.assert_eq(lzma1_decode(p3, d3.add(garbage), 148L).length(), 148)
  let p4 = bytes_from_hex("16")
  let d4 = bytes_from_hex(
    "e0008d00695d0000813307ae0fd04b393c9f3f4741057bee1d0eee921a51b9b6" +
    "a8a2dd5f3cd1b6b26b3ddcdca112c6804d7b5c5d2c9de1ed98ee72af421222d3" +
    "2e125f649457c52d1f2a12984833d36cbb2be6efc3d7a3388c9c156799240527" +
    "744141050676aa813241fa890000000000",
  )
  @test.assert_eq(lzma2_decode(p4, d4.add(garbage), 142L).length(), 142)
}

///|
test "边界：unpack_size 为 0 时返回空 Bytes" {
  @test.assert_eq(
    lzma1_decode(bytes_from_hex("5d00008000"), Bytes::new(0), 0L).length(),
    0,
  )
  @test.assert_eq(
    lzma2_decode(bytes_from_hex("16"), Bytes::new(0), 0L).length(),
    0,
  )
}

///|
test "负例：非法 props 与非法的 LZMA2 控制字节" {
  // LZMA1 props 少于 5 字节
  try {
    ignore(lzma1_decode(bytes_from_hex("5d00"), Bytes::new(0), 1L))
    abort("props 过短：应当报错，但成功返回")
  } catch {
    SevenZError::LzmaCorrupt(..) => ()
    SevenZError::Truncated(..) => ()
    _ => abort("props 过短：错误类型不是 LzmaCorrupt / Truncated")
  }
  // 0xFF -> pb=5，非法（pb > 4）
  try {
    ignore(
      lzma1_decode(
        bytes_from_hex("ff00008000"),
        bytes_from_hex("0000000000"),
        1L,
      ),
    )
    abort("LZMA1 props 非法：应当报错，但成功返回")
  } catch {
    SevenZError::LzmaCorrupt(..) => ()
    SevenZError::Truncated(..) => ()
    _ =>
      abort("LZMA1 props 非法：错误类型不是 LzmaCorrupt / Truncated")
  }
  // LZMA2 字典大小编码 > 40
  try {
    ignore(lzma2_decode(bytes_from_hex("29"), bytes_from_hex("0000"), 1L))
    abort("LZMA2 props 非法：应当报错，但成功返回")
  } catch {
    SevenZError::LzmaCorrupt(..) => ()
    SevenZError::Truncated(..) => ()
    _ =>
      abort("LZMA2 props 非法：错误类型不是 LzmaCorrupt / Truncated")
  }
  // 保留控制字节 0x03
  try {
    ignore(lzma2_decode(bytes_from_hex("16"), bytes_from_hex("0300000000"), 1L))
    abort("保留控制字节：应当报错，但成功返回")
  } catch {
    SevenZError::LzmaCorrupt(..) => ()
    SevenZError::Truncated(..) => ()
    _ =>
      abort("保留控制字节：错误类型不是 LzmaCorrupt / Truncated")
  }
  // 提前结束标记
  try {
    ignore(lzma2_decode(bytes_from_hex("16"), bytes_from_hex("00"), 4L))
    abort("提前结束标记：应当报错，但成功返回")
  } catch {
    SevenZError::LzmaCorrupt(..) => ()
    SevenZError::Truncated(..) => ()
    _ =>
      abort("提前结束标记：错误类型不是 LzmaCorrupt / Truncated")
  }
}
