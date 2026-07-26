cask "viva" do
  version "0.10.0"
  sha256 "585c1f7ac6db46f5e71e65b398f8d846c9bb273a141108d8ed101a64ff57f008"

  url "https://github.com/d100000/viva/releases/download/v#{version}/Viva-#{version}.dmg"
  name "Viva"
  desc "语音输入工具：按住热键说话，文字实时写进光标处"
  homepage "https://github.com/d100000/viva"

  # arm64 二进制；Intel 需 Rosetta 且未经实测
  # ⚠️ 用 symbol 而不是 ">= :sonoma" 字符串 —— 后者已被 Homebrew 弃用，会报警告
  depends_on macos: :sonoma        # Package.swift: platforms [.macOS(.v14)]
  depends_on arch: :arm64

  app "Viva.app"

  # Viva 是 ad-hoc 签名（无 Apple 开发者证书，无法公证）。
  # Homebrew 默认会给下载物打 quarantine，装完双击会被 Gatekeeper 拦下，
  # 提示「已损坏，应移到废纸篓」。这一行在安装后清掉隔离属性。
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Viva.app"],
                   sudo: false
  end

  uninstall quit: "com.local.viva"

  # 配置和历史记录在 ~/.config/viva/，含 API Key。
  # 放在 zap 而不是 uninstall —— 普通卸载/升级不该删掉用户的凭证，
  # 只有显式 `brew uninstall --zap` 才清。
  zap trash: [
    "~/.config/viva",
    "~/Library/Preferences/com.local.viva.plist",
    "~/Library/Saved Application State/com.local.viva.savedState",
  ]

  caveats <<~EOS
    Viva 需要两个系统权限才能工作：

      1. 麦克风  —— 首次说话时会弹窗
      2. 辅助功能 —— 用于监听全局热键和把文字写进其它 App
                     授权后必须重启 Viva

    还需要一个火山引擎豆包语音识别的 API Key，首次启动的引导会问你要。

    默认热键：按住右 ⌘ 说话。
  EOS
end
