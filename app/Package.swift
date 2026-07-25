// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Viva",
    // macOS 14+：SwiftUI 的 foregroundStyle(on Text) / onChange 新签名等都要 14。
    // 代价是放弃 macOS 13 及更早（豆包/讯飞输入法支持到 10.15，这是覆盖面上的劣势，
    // 若要下探需要把这些 API 全部降级替换）。
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Viva",
            path: "Sources/Viva",
            swiftSettings: [
                // 关掉 Swift 6 严格并发检查：本项目大量 AppKit / CoreAudio 回调
                // 在 Swift 6 模式下会产生海量 Sendable 报错，得不偿失。
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
