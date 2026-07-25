import AppKit
import SwiftUI
import ApplicationServices

/// 悬浮条的数据源
@MainActor
final class HUDModel: ObservableObject {
    enum Phase { case listening, finalizing, polishing, message }

    @Published var phase: Phase = .listening
    @Published var committed = ""
    @Published var partial = ""
    @Published var message: String?
    @Published var isError = false
    @Published var bars: [Float] = Array(repeating: 0, count: 34)

    func pushLevel(_ v: Float) {
        bars.removeFirst()
        bars.append(v)
    }

    func reset() {
        committed = ""; partial = ""; message = nil; isError = false
        phase = .listening
        bars = Array(repeating: 0, count: 34)
    }
}

/// 悬浮条。
///
/// 两条硬性要求：
/// 1. **只在识别过程中出现**。启动提示、就绪提示一类的东西一律不走这里 ——
///    平时屏幕上不该有任何浮层。
/// 2. **绝不能抢焦点**。`.nonactivatingPanel` + `ignoresMouseEvents`，
///    一旦抢了焦点，上屏目标就丢了。
@MainActor
final class HUDController {

    private var panel: NSPanel?
    private var host: NSHostingView<HUDRoot>?
    private let model = HUDModel()
    private var hideWork: DispatchWorkItem?

    // MARK: - 构建

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }

        let root = HUDRoot(model: model)
        let h = NSHostingView(rootView: root)
        h.sizingOptions = [.intrinsicContentSize]

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 148, height: 38),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false                  // 阴影由 SwiftUI 画，避免方形硬边
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = h

        panel = p
        host = h
        return p
    }

    // MARK: - 对外

    func show(state: String) {
        hideWork?.cancel()
        model.message = state
        model.isError = false
        model.phase = .listening
        present()
    }

    /// 识别中：committed 实心，partial 灰斜体
    func update(committed: String, partial: String) {
        hideWork?.cancel()
        model.message = nil
        model.isError = false
        model.committed = committed
        model.partial = partial
        if model.phase == .message { model.phase = .listening }
        present()
    }

    func setPhase(_ phase: HUDModel.Phase) {
        model.phase = phase
        if panel?.isVisible == true { layout() }
    }

    func update(level: Float) {
        guard panel?.isVisible == true else { return }
        model.pushLevel(level)
    }

    /// 一次性提示（错误 / 取消）。**只在会话相关的场景用**，不要用来做启动提示。
    func flash(message: String, isError: Bool = false, duration: TimeInterval = 2.2) {
        hideWork?.cancel()
        model.committed = ""; model.partial = ""
        model.message = message
        model.isError = isError
        model.phase = .message
        present()
        scheduleHide(after: duration)
    }

    func hide(after: TimeInterval = 0.4) { scheduleHide(after: after) }

    /// 立刻收起，不留动画尾巴
    func hideNow() {
        hideWork?.cancel(); hideWork = nil
        panel?.orderOut(nil)
        model.reset()
    }

    // MARK: - 显示与定位

    /// 淡出动画进行中的标记。present() 必须能打断它 —— 否则连续口述时，
    /// 上一句的淡出 completionHandler 会把新会话刚建立的悬浮条 orderOut + reset，
    /// 表现为浮条「闪一下没了又冒出来」，新句子的前几百毫秒毫无反馈。
    private var fadingOut = false

    private func present() {
        let p = ensurePanel()
        layout()
        fadingOut = false
        if p.isVisible, p.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.08
                p.animator().alphaValue = 1
            }
        }
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1
            }
        }
    }

    private func layout() {
        guard let p = panel, let h = host else { return }
        h.layoutSubtreeIfNeeded()
        var size = h.fittingSize
        size.width = min(max(size.width, 132), 620)
        size.height = max(size.height, 34)

        let origin = caretOrigin(for: size) ?? bottomCenterOrigin(for: size)
        let target = NSRect(origin: origin, size: size)
        if p.isVisible, p.frame.size != size {
            // 文字增长时平滑扩宽，不要一跳一跳
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                p.animator().setFrame(target, display: true)
            }
        } else {
            p.setFrame(target, display: true)
        }
    }

    private func scheduleHide(after: TimeInterval) {
        hideWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let p = self.panel else { return }
            self.fadingOut = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                p.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                // 期间可能已经开了新会话（present 会把 fadingOut 置回 false），
                // 这时绝不能把新会话的浮条收走
                guard let self, self.fadingOut else { return }
                self.fadingOut = false
                p.orderOut(nil)
                self.model.reset()
            }
        }
        hideWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: item)
    }

    private func bottomCenterOrigin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        return NSPoint(x: f.midX - size.width / 2, y: f.minY + 88)
    }

    /// 尝试用辅助功能 API 读出插入点位置，把浮条贴到光标下方。
    /// 只读用途，失败就回退到屏幕底部 —— Electron / 浏览器上大概率拿不到。
    private func caretOrigin(for size: NSSize) -> NSPoint? {
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,
                kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let el = unsafeBitCast(element, to: AXUIElement.self)

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el,
                kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rv = rangeValue else { return nil }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rv, &bounds) == .success,
              let bv = bounds else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(bv, to: AXValue.self), .cgRect, &rect),
              rect.width.isFinite, rect.height.isFinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.origin.x != 0 || rect.origin.y != 0     // Electron 常无条件返回 {0,0,0,0}
        else { return nil }

        guard let primary = NSScreen.screens.first else { return nil }
        let flippedY = primary.frame.maxY - rect.maxY

        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: rect.midX, y: flippedY))
        } ?? primary
        let vf = screen.visibleFrame

        var x = rect.origin.x - 12
        var y = flippedY - size.height - 10          // 贴光标下方
        x = min(max(x, vf.minX + 10), vf.maxX - size.width - 10)
        if y < vf.minY + 10 { y = flippedY + rect.height + 10 }   // 下方放不下就翻上去
        return NSPoint(x: x, y: y)
    }
}

// MARK: - SwiftUI 外观

struct HUDRoot: View {
    @ObservedObject var model: HUDModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 9) {
            indicator
            content
            if model.phase != .message {
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 1, height: 13)
                Waveform(bars: model.bars, active: model.phase == .listening)
                    .frame(width: 34, height: 15)
            }
        }
        // ⚠️ 这里必须给出宽度上限。根节点原来是无约束的 .fixedSize()，
        //    SwiftUI 会按「单行 ideal 宽度」排版（长句能到 2000pt+），
        //    而面板最多 620pt —— 超出部分连同圆角一起被窗口裁掉，
        //    用户看到一条右端被削平的黑条，且 lineLimit(3) 永远不会生效。
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.black.opacity(0.66))
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.34), radius: 12, y: 4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 左侧状态点。识别中脉动，收尾/润色换成对应指示。
    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .listening:
            Circle()
                .fill(Color(red: 1.0, green: 0.32, blue: 0.32))
                .frame(width: 7, height: 7)
                .shadow(color: Color.red.opacity(0.8), radius: 4)
                .scaleEffect(pulse ? 1.3 : 0.85)
                .animation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true),
                           value: pulse)
                .onAppear { pulse = true }
        case .finalizing:
            ProgressView().controlSize(.mini).scaleEffect(0.62).frame(width: 9)
        case .polishing:
            Image(systemName: "sparkles")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.purple, .pink],
                                                startPoint: .top, endPoint: .bottom))
        case .message:
            Image(systemName: model.isError
                  ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.isError ? Color.orange : Color.green)
        }
    }

    @ViewBuilder private var content: some View {
        if let m = model.message {
            Text(m)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(model.isError ? Color.orange : Color.white.opacity(0.9))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.committed.isEmpty && model.partial.isEmpty {
            Text("说吧")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
        } else {
            // 已定稿实心、未定稿半透明 —— 用颜色明示「这段还会变」，
            // 用户就不会因为文字跳变而困惑。廉价但极有效。
            (Text(model.committed).foregroundColor(Color.white.opacity(0.95))
             + Text(model.partial).foregroundColor(Color.white.opacity(0.42)))
                .font(.system(size: 13))
                .lineSpacing(2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .animation(nil, value: model.partial)   // 文字不做过渡，否则会糊
        }
    }
}

// MARK: - 波形

private struct Waveform: View {
    let bars: [Float]
    let active: Bool

    /// 只取最近 12 个采样，保持小巧
    private var shown: [Float] { Array(bars.suffix(12)) }

    var body: some View {
        GeometryReader { geo in
            let n = shown.count
            let spacing: CGFloat = 1.4
            let w = max(1.4, (geo.size.width - CGFloat(n - 1) * spacing) / CGFloat(n))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<n, id: \.self) { i in
                    let v = CGFloat(shown[i])
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(opacity(i, n, v)))
                        .frame(width: w, height: max(2, v * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .animation(.linear(duration: 0.06), value: shown)
        }
    }

    private func opacity(_ i: Int, _ n: Int, _ v: CGFloat) -> Double {
        guard active else { return 0.2 }
        let recency = Double(i) / Double(max(n - 1, 1))
        let base = 0.34 + 0.56 * recency
        return v < 0.02 ? base * 0.4 : base
    }
}
