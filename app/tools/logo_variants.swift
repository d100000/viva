#!/usr/bin/env swift
//
// Viva logo 三个方向，各出一张 512 预览。
//   swift tools/logo_variants.swift
//   → /tmp/viva_A.png  /tmp/viva_B.png  /tmp/viva_C.png
//
// 三个方向都必须满足：16px 下还认得出、只用一种颜色的图形（白）、
// 语义要同时挂上「声音」和「Viva 这个词」。

import AppKit
import Foundation

let c1 = NSColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 1)   // #6366F1
let c2 = NSColor(srgbRed: 0.659, green: 0.333, blue: 0.969, alpha: 1)   // #A855F7

func canvas(_ px: Int, _ draw: (CGRect, CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    let S = CGFloat(px)
    let inset = S * 0.094
    let box = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius = box.width * 0.225

    ctx.saveGState()
    NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).addClip()
    NSGradient(colors: [c1, c2])!.draw(in: box, angle: -55)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.20),
                        NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2),
              angle: -90)
    ctx.restoreGState()

    NSColor.white.setFill()
    NSColor.white.setStroke()
    draw(box, S)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    let d = rep.representation(using: .png, properties: [:])!
    try! d.write(to: URL(fileURLWithPath: path))
}

// ── A：V 形包络波形 ──
// 五根圆头柱，高度构成一个 V。既是声波，也是字母 V。
// 优点：任何尺寸都清楚，语义双关；缺点：V 不够「字母感」。
func variantA(_ box: CGRect, _ S: CGFloat) {
    let g = box.insetBy(dx: box.width * 0.20, dy: box.height * 0.24)
    let cy = g.midY
    let heights: [CGFloat] = [1.0, 0.56, 0.24, 0.56, 1.0]
    let barW = g.width * 0.118
    let gap = (g.width - barW * 5) / 4
    var x = g.minX
    for h in heights {
        let bh = g.height * h
        NSBezierPath(roundedRect: CGRect(x: x, y: cy - bh / 2, width: barW, height: bh),
                     xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
}

// ── B：粗笔 V 字 ──
// 两笔圆头粗线构成 V，右笔略长收尾上扬，带一点「说完了」的语气。
// 优点：字母识别度最高，最像一个品牌 monogram；缺点：声音语义弱。
func variantB(_ box: CGRect, _ S: CGFloat) {
    let g = box.insetBy(dx: box.width * 0.245, dy: box.height * 0.255)
    let lw = g.width * 0.215
    let p = NSBezierPath()
    p.lineWidth = lw
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    p.move(to: CGPoint(x: g.minX + lw / 2, y: g.maxY))
    p.line(to: CGPoint(x: g.midX, y: g.minY + lw / 2))
    p.line(to: CGPoint(x: g.maxX - lw / 2, y: g.maxY))
    p.stroke()
}

// ── C：V 字 + 声波尾巴 ──
// 左边是 V 的两笔，右上角三个递增圆点，像声音从 V 里发出去。
// 优点：两个语义都挂上了；缺点：小尺寸下圆点会糊。
func variantC(_ box: CGRect, _ S: CGFloat) {
    let g = box.insetBy(dx: box.width * 0.215, dy: box.height * 0.245)
    let vW = g.width * 0.62
    let lw = g.width * 0.165
    let p = NSBezierPath()
    p.lineWidth = lw
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    p.move(to: CGPoint(x: g.minX + lw / 2, y: g.maxY))
    p.line(to: CGPoint(x: g.minX + vW / 2, y: g.minY + lw / 2))
    p.line(to: CGPoint(x: g.minX + vW - lw / 2, y: g.maxY))
    p.stroke()

    // 右侧三根递增的短波形柱
    let barW = g.width * 0.088
    var x = g.minX + vW + g.width * 0.10
    let cy = g.midY
    for h in [CGFloat(0.30), 0.52, 0.78] {
        let bh = g.height * h
        NSBezierPath(roundedRect: CGRect(x: x, y: cy - bh / 2, width: barW, height: bh),
                     xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + g.width * 0.058
    }
}

for (name, fn) in [("A", variantA), ("B", variantB), ("C", variantC)]
    as [(String, (CGRect, CGFloat) -> Void)] {
    save(canvas(512, fn), "/tmp/viva_\(name).png")
    // 同时出一张 32px 放大图，检验小尺寸可读性
    let small = canvas(32, fn)
    save(small, "/tmp/viva_\(name)_32.png")
}
print("✅ /tmp/viva_A.png  viva_B.png  viva_C.png（各含 _32 小尺寸）")
