# 02: 可下载的发行包与首次打开说明

**What to build:** 不会编译 Swift 的用户，可以从 GitHub Releases 下载 zip，按 README 的步骤在 macOS 13–15+ 上第一次打开应用。发版前，维护者用一条命令生成带版本号的 zip 和 SHA-256 校验值。

**Blocked by:** 01（发行包应包含快速跳过，否则宣传带来的用户首先会遇到慢速重复导入）

**Status:** ready-for-agent

- [ ] 打包脚本从 Info.plist 读取版本号，输出 `ActionImport-<版本>-macOS.zip` 和对应的 `.sha256`
- [ ] 脚本能打印（但不自动执行）`gh release create` 命令；发布属于对外动作，由维护者确认后执行
- [ ] README 增加“下载使用”一节：下载地址、ad-hoc 签名未公证的说明、macOS 15 起需在“系统设置 → 隐私与安全性”中点“仍要打开”、命令行替代方案
- [ ] README 写明已验证范围：DJI Osmo Action 6 + Apple Silicon Mac
- [ ] 本地运行打包脚本成功，`codesign --verify` 通过，并在 zip 中验证校验值

外部门槛（需维护者处理）：实际创建 GitHub Release；如需免拦截安装，要加入 Apple Developer Program 并完成公证。
