cask "viva" do
  version "0.13.2"
  sha256 "4bd664c7385e79761db96a4375ff882007c21989b1e9829771c41dbb086057f2"

  url "https://github.com/d100000/viva/releases/download/v#{version}/Viva-#{version}.dmg"
  name "Viva"
  desc "语音输入工具：按住热键说话，文字实时写进光标处"
  homepage "https://github.com/d100000/viva"

  # arm64 二进制；Intel 需 Rosetta 且未经实测
  # ⚠️ 用 symbol 而不是 ">= :sonoma" 字符串 —— 后者已被 Homebrew 弃用，会报警告
  depends_on macos: :sonoma        # Package.swift: platforms [.macOS(.v14)]
  depends_on arch: :arm64

  app "Viva.app"

  # Viva 的默认发布包使用自签名而非 Apple Developer ID，尚未公证。
  # Homebrew 默认会给下载物打 quarantine，装完双击会被 Gatekeeper 拦下，
  # 提示「已损坏，应移到废纸篓」。这一行在安装后清掉隔离属性。
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Viva.app"],
                   sudo: false
  end

  uninstall quit: "com.local.viva"

  # 配置、历史和日志在 ~/.config/viva/。
  # 放在 zap 而不是 uninstall —— 普通卸载/升级不该删掉用户数据，
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

    首次启动用邮箱验证码注册或登录；不需要供应商 API Key。

    默认热键：按住右 ⌘ 说话。
  EOS
end
