import Foundation

/// 火山引擎 sauc 流式语音识别二进制协议编解码。
///
/// 帧结构（所有整数大端）：
///   [header 4B][可选 sequence 4B][payload size 4B][payload]
///
/// header 布局：
///   byte0: 高4位 = protocol version(1), 低4位 = header size(1，×4=4字节)
///   byte1: 高4位 = message type,        低4位 = type specific flags
///   byte2: 高4位 = serialization,       低4位 = compression
///   byte3: reserved(0)
enum Sauc {

    // MARK: - 常量

    static let protocolVersion: UInt8 = 0b0001
    static let headerSizeUnits: UInt8 = 0b0001   // ×4 = 4 bytes

    enum MessageType: UInt8 {
        case fullClientRequest = 0b0001
        case audioOnlyRequest  = 0b0010
        case fullServerResponse = 0b1001
        case serverError       = 0b1111
    }

    /// Message type specific flags。
    ///
    /// ⚠️ 这里选用「无序号路线」：首包与音频包都用 `.none`，末包用 `.lastNoSequence`。
    /// 这是 typeflux / type4me / Chauncy-Guo 等已上线 macOS 工具验证过的组合。
    /// 另一条「正序号路线」（`.positiveSequence` + 末包 `.negativeSequence` 带负序号）
    /// 也能跑通，但两条路线**绝对不能混用**，否则服务端按位置解析会错位。
    enum Flags: UInt8 {
        case none             = 0b0000   // header 后直接跟 payload size
        case positiveSequence = 0b0001   // header 后跟 4B 正序号
        case lastNoSequence   = 0b0010   // 最后一包，不带序号
        case negativeSequence = 0b0011   // 最后一包，带负序号
        case asyncFinal       = 0b0100   // bigmodel_async 的最终帧（不在官方 flags 表内）
    }

    enum Serialization: UInt8 {
        case raw  = 0b0000    // 裸字节（音频）
        case json = 0b0001
    }

    enum Compression: UInt8 {
        case none = 0b0000
        case gzip = 0b0001
    }

    // MARK: - 编码

    static func buildHeader(_ type: MessageType,
                            _ flags: Flags,
                            _ ser: Serialization,
                            _ comp: Compression) -> [UInt8] {
        [
            (protocolVersion << 4) | headerSizeUnits,
            (type.rawValue << 4) | flags.rawValue,
            (ser.rawValue << 4) | comp.rawValue,
            0x00,
        ]
    }

    private static func bigEndianUInt32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
         UInt8((v >> 8) & 0xFF),  UInt8(v & 0xFF)]
    }

    /// 首包：携带全部识别参数的 JSON。不压缩（服务端会用与请求相同的压缩方式回包，
    /// 不压缩可以让解包逻辑更简单，且 PCM 的 gzip 收益本来就很低）。
    static func fullClientRequest(json: Data) -> Data {
        var out = Data(buildHeader(.fullClientRequest, .none, .json, .none))
        out.append(contentsOf: bigEndianUInt32(UInt32(json.count)))
        out.append(json)
        return out
    }

    /// 音频包。`isLast` 为 true 时打上末包标志。
    static func audioRequest(pcm: Data, isLast: Bool) -> Data {
        var out = Data(buildHeader(.audioOnlyRequest,
                                   isLast ? .lastNoSequence : .none,
                                   .raw, .none))
        out.append(contentsOf: bigEndianUInt32(UInt32(pcm.count)))
        out.append(pcm)
        return out
    }

    // MARK: - 解码

    struct ServerMessage {
        var messageType: UInt8
        var flags: UInt8
        var sequence: Int32?
        var payload: Data
        /// 服务端错误帧的错误码（仅 messageType == 0b1111 时有值）
        var errorCode: UInt32?
        /// 是否为流的最终帧。只认帧头 flags，**绝不能用 payload 里的 definite 判断**
        /// （openless 实测：收到第一个 definite=true 就关连接，会丢掉用户后续说的全部内容）。
        var isFinal: Bool {
            flags == Flags.lastNoSequence.rawValue
                || flags == Flags.negativeSequence.rawValue
                || flags == Flags.asyncFinal.rawValue
        }
    }

    enum DecodeError: Error, CustomStringConvertible {
        case tooShort(Int)
        case badLength(declared: Int, available: Int)
        case gunzipFailed

        var description: String {
            switch self {
            case .tooShort(let n):      return "帧太短：\(n) 字节"
            case .badLength(let d, let a): return "payload 长度不合法：声明 \(d)，实际可用 \(a)"
            case .gunzipFailed:         return "gzip 解压失败"
            }
        }
    }

    static func parse(_ data: Data) throws -> ServerMessage {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { throw DecodeError.tooShort(bytes.count) }

        let headerSize = Int(bytes[0] & 0x0F) * 4
        let messageType = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        let compression = bytes[2] & 0x0F

        guard bytes.count > headerSize else { throw DecodeError.tooShort(bytes.count) }
        var idx = headerSize

        func readUInt32() -> UInt32? {
            guard idx + 4 <= bytes.count else { return nil }
            let v = (UInt32(bytes[idx]) << 24) | (UInt32(bytes[idx + 1]) << 16)
                  | (UInt32(bytes[idx + 2]) << 8) | UInt32(bytes[idx + 3])
            idx += 4
            return v
        }

        // ── 错误帧：布局与正常响应不同 ──
        // [header][error code 4B][message size 4B][UTF-8 message]
        // ⚠️ 官方文档是这个格式，但 typeflux / type4me 的线上实现都不按它解析。
        //    这里按官方格式解，失败时降级成「当作普通响应」再试一次。
        if messageType == MessageType.serverError.rawValue {
            let code = readUInt32() ?? 0
            if let size = readUInt32(), idx + Int(size) <= bytes.count {
                let msg = Data(bytes[idx..<(idx + Int(size))])
                return ServerMessage(messageType: messageType, flags: flags,
                                     sequence: nil, payload: msg, errorCode: code)
            }
            // 降级：把剩余字节整个当 payload
            let rest = Data(bytes[min(headerSize + 4, bytes.count)...])
            return ServerMessage(messageType: messageType, flags: flags,
                                 sequence: nil, payload: rest, errorCode: code)
        }

        // ── 正常响应 ──
        // flags 指示 header 之后的 4 字节是不是 sequence。
        var sequence: Int32?
        if flags == Flags.positiveSequence.rawValue || flags == Flags.negativeSequence.rawValue {
            if let raw = readUInt32() { sequence = Int32(bitPattern: raw) }
        }

        var payload = Data()
        if let declared = readUInt32() {
            let available = bytes.count - idx
            if Int(declared) <= available {
                payload = Data(bytes[idx..<(idx + Int(declared))])
            } else if sequence == nil, available >= 4 {
                // 防御性回退：有的服务端实现无论 flags 如何都会带 sequence。
                // 如果按「无 sequence」解出来的长度对不上，就退一步当作有 sequence 再解一次。
                let seqRaw = declared
                idx -= 4
                _ = readUInt32()                       // 把它当 sequence 吃掉
                if let d2 = readUInt32(), idx + Int(d2) <= bytes.count {
                    sequence = Int32(bitPattern: seqRaw)
                    payload = Data(bytes[idx..<(idx + Int(d2))])
                } else {
                    throw DecodeError.badLength(declared: Int(declared), available: available)
                }
            } else {
                throw DecodeError.badLength(declared: Int(declared), available: available)
            }
        }

        if compression == Compression.gzip.rawValue, !payload.isEmpty {
            guard let un = payload.gunzipped() else { throw DecodeError.gunzipFailed }
            payload = un
        }

        return ServerMessage(messageType: messageType, flags: flags,
                             sequence: sequence, payload: payload, errorCode: nil)
    }

    // MARK: - 错误码

    static func describeError(_ code: UInt32) -> String {
        switch code {
        case 20000000: return "成功"
        case 45000001: return "请求参数无效（多半是二进制协议拼错、缺 model_name，或 Request-Id 重复）"
        case 45000002: return "空音频（一个音频包都没发就发了末包，或被 VAD 全滤掉了）"
        case 45000081: return "等包超时（建连后太久没喂音频包）"
        case 45000151: return "音频格式不正确（采样率/位深/声道与首包声明不符）"
        case 55000031: return "服务器繁忙，需退避重试"
        default:
            if code >= 55000000 && code < 56000000 { return "服务内部错误（带 X-Tt-Logid 提工单）" }
            return "未知错误码 \(code)"
        }
    }
}
