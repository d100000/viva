#!/usr/bin/env swift
//
// 生成 App 图标。用 CoreGraphics 直接画，不依赖任何设计工具。
//
//   swift tools/make_icon.swift
//   → 产出 Resources/AppIcon.icns
//
// 设计：圆角方（squircle）+ 靛紫渐变底 + 白色粗笔 V。
// 刻意只留一个字母 —— 16pt 的菜单栏和 Dock 里都要能被瞬间认出。

import AppKit
import Foundation

// MARK: - 参数

let outDir = "Resources"
let iconsetDir = "\(outDir)/AppIcon.iconset"
let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

// 靛 → 紫。冷色显得像专业工具，也和豆包自己的蓝拉开距离。
let c1 = NSColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 1)   // #6366F1
let c2 = NSColor(srgbRed: 0.659, green: 0.333, blue: 0.969, alpha: 1)   // #A855F7

// MARK: - 绘制

func drawIcon(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let S = CGFloat(px)
    // macOS 图标惯例：内容不铺满画布，四周留白给阴影和视觉呼吸
    let inset = S * 0.094
    let box = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius = box.width * 0.225        // 接近 Apple squircle 的观感

    // ── 底：渐变圆角方 ──
    let shape = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
    ctx.saveGState()
    shape.addClip()
    let grad = NSGradient(colors: [c1, c2])!
    grad.draw(in: box, angle: -55)

    // 顶部一层很淡的高光，制造一点体积感（Apple 风格）
    let hi = NSGradient(colors: [NSColor.white.withAlphaComponent(0.20),
                                 NSColor.white.withAlphaComponent(0.0)])!
    hi.draw(in: CGRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2),
            angle: -90)
    ctx.restoreGState()

    // ── 图形：粗笔 V ──
    //
    // 为什么不带声波尾：32px 下声波会糊成一坨，反而像贴了个「信号格」，
    // 「V」的识别度被拖低。品牌 mark 的第一要务是任何尺寸都能被瞬间认出，
    // 「声音」这层语义交给产品名和 slogan 去承担。
    let g = box.insetBy(dx: box.width * 0.245, dy: box.height * 0.255)
    let lw = g.width * 0.215

    NSColor.white.setStroke()
    let v = NSBezierPath()
    v.lineWidth = lw
    v.lineCapStyle = .round
    v.lineJoinStyle = .round
    v.move(to: CGPoint(x: g.minX + lw / 2, y: g.maxY))
    v.line(to: CGPoint(x: g.midX, y: g.minY + lw / 2))
    v.line(to: CGPoint(x: g.maxX - lw / 2, y: g.maxY))
    v.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - 输出

let fm = FileManager.default
try? fm.removeItem(atPath: iconsetDir)
try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for (px, name) in sizes {
    let rep = drawIcon(px: px)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("✖ \(name) 编码失败\n".utf8)); exit(1)
    }
    try data.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(name).png"))
}
print("✅ 已生成 \(sizes.count) 个尺寸 → \(iconsetDir)")

// iconutil 打包成 .icns
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconsetDir, "-o", "\(outDir)/AppIcon.icns"]
try p.run()
p.waitUntilExit()
if p.terminationStatus == 0 {
    print("✅ \(outDir)/AppIcon.icns")
} else {
    FileHandle.standardError.write(Data("✖ iconutil 失败\n".utf8)); exit(1)
}
