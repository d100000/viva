import Foundation
import Compression

extension Data {

    /// 解 gzip。
    ///
    /// 本项目请求端一律不压缩（`Compression.none`），服务端理应也回不压缩的包，
    /// 所以这个方法是安全网 —— 万一服务端仍然回了 gzip，不至于直接崩。
    ///
    /// 实现：手工跳过 gzip 头（Apple 的 Compression 框架只吃裸 DEFLATE），
    /// 再用 `COMPRESSION_ZLIB` 做 raw inflate。
    func gunzipped() -> Data? {
        let bytes = [UInt8](self)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else {
            return nil
        }

        let flg = bytes[3]
        var pos = 10                                    // 固定头 10 字节

        if flg & 0x04 != 0 {                            // FEXTRA
            guard pos + 2 <= bytes.count else { return nil }
            let xlen = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
            pos += 2 + xlen
        }
        if flg & 0x08 != 0 {                            // FNAME，零结尾
            while pos < bytes.count, bytes[pos] != 0 { pos += 1 }
            pos += 1
        }
        if flg & 0x10 != 0 {                            // FCOMMENT，零结尾
            while pos < bytes.count, bytes[pos] != 0 { pos += 1 }
            pos += 1
        }
        if flg & 0x02 != 0 { pos += 2 }                 // FHCRC

        guard pos < bytes.count - 8 else { return nil }

        // gzip 尾部 8 字节是 CRC32 + ISIZE，ISIZE 就是解压后大小（mod 2^32）
        let n = bytes.count
        // gzip 尾部是 CRC32(小端 4B) + ISIZE(小端 4B)，ISIZE 的四个字节是
        // n-4(最低位) … n-1(最高位)。原来写成 n-4/n-5/n-6/n-7，把 CRC32 的三个
        // 字节当高位读了进来 → isize 可达 ~4.28e9 → allocate 直接 trap 进程消失。
        let isize = Int(bytes[n - 4]) | (Int(bytes[n - 3]) << 8)
                  | (Int(bytes[n - 2]) << 16) | (Int(bytes[n - 1]) << 24)

        let deflateBody = Array(bytes[pos..<(n - 8)])
        // 再加一道保险：损坏的包可能给出荒谬的 ISIZE。
        // 语音识别的单帧 JSON 不可能超过几 MB，超了就退回倍数增长策略。
        var capacity = (isize > 0 && isize <= 32 * 1024 * 1024)
            ? isize : deflateBody.count * 8
        capacity = Swift.max(capacity, 1024)   // Data 自带 max()，这里要的是全局函数

        for _ in 0..<4 {                                // 容量不够就翻倍重试
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }

            let written = deflateBody.withUnsafeBufferPointer { src -> Int in
                compression_decode_buffer(dst, capacity,
                                          src.baseAddress!, src.count,
                                          nil, COMPRESSION_ZLIB)
            }
            if written > 0 && written < capacity { return Data(bytes: dst, count: written) }
            if written == capacity { return Data(bytes: dst, count: written) }
            capacity *= 4
        }
        return nil
    }
}
