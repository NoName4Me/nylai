# nylai

所需，信手拈来。一个本地优先、轻量常驻的原生 macOS 效率工具。

当前支持菜单栏入口、设置窗口、本地偏好和主显示器 PNG 截图。固定快捷键：`⌃⌥N` 打开设置，`⌃⌥S` 截取主显示器。

## 开发环境

- 最低运行系统：macOS 14.0；使用 SwiftUI、AppKit 和 Observation。
- 工程要求：Xcode 16 或更高，Swift 6 语言模式，无第三方依赖。
- 本机已验证工具链：macOS 26.7.2（Apple Silicon）、Xcode 27.2、Swift 6.4.2、macOS 27.2 SDK。其他工具链及 macOS 14 实机尚未验证。

## 构建与运行

1. 用 Xcode 打开 `nylai.xcodeproj`。
2. 选择 `nylai` scheme、`My Mac`，按 `⌘R`。
3. 点击菜单栏叠层图标 →「设置…」，或在其他应用中按 `Control + Option + N`。应用不显示 Dock 图标，关闭设置后继续常驻；通过菜单栏「退出 nylai」退出。

工程默认使用本地 ad-hoc 签名，无需开发者会员或 Development Team，不启用 App Sandbox。此签名用于本机开发，不代表已可供外部用户直接安装。

命令行构建和测试：

```sh
xcodebuild -project nylai.xcodeproj -scheme nylai -configuration Debug -derivedDataPath build build
xcodebuild -project nylai.xcodeproj -scheme nylai -configuration Debug -derivedDataPath build test
open build/Build/Products/Debug/nylai.app
```

快捷键启动时注册，退出时注销。若注册失败会打开设置显示原因，可排除冲突后点击「重试注册」。目前使用物理 N / S 键位置，尚不支持自定义录入和键盘布局转换；占用检测以系统 API 返回结果为准。

设置立即保存到应用专属的 UserDefaults。启动和设置界面不主动申请屏幕录制、辅助功能或输入监控权限；权限页面仅检查屏幕录制状态并提供系统设置入口。

## 截图

菜单栏选择「截取主显示器…」，或按 `Control + Option + S`。首次使用需允许 macOS 屏幕录制权限；拒绝后可从提示或设置界面进入系统权限页面，授权后重新截图。若系统要求重新打开应用，退出后再启动。

捕获主显示器全部内容，排除 nylai 自身窗口、不含鼠标指针，按显示器像素比例输出 sRGB PNG。捕获后通过系统保存面板选择位置；取消不写入文件，不自动复制剪贴板。编码和原子写入在后台执行，任务进行中不重复创建截图。

目前不支持显示器选择、区域截取和编辑。已在本机 1920×1080 显示器验证实际捕获与保存；Retina、多显示器、HDR 和最低系统仍需对应设备验证。

## 工程结构

```text
nylai.xcodeproj/             Xcode 工程与共享 scheme
nylai/
  App/                      进程生命周期、菜单栏
  Features/
    Settings/               SwiftUI 设置及窗口管理
    GlobalShortcuts/        系统快捷键注册、动作状态与重试
    Screenshot/             ScreenCaptureKit 捕获、保存流程与 PNG 写入
  Shared/
    Preferences/            本地偏好
    Permissions/            系统权限状态与设置入口
nylaiTests/                 偏好、快捷键、截图流程与窗口生命周期测试
```

设计与阶段计划见 [ARCHITECTURE.md](ARCHITECTURE.md)、[ROADMAP.md](ROADMAP.md)。

## 协作与发布

当前仓库地址：https://github.com/NoName4Me/nylai 。修改前先构建；涉及行为时补充必要测试；不提交构建产物和个人 Xcode 配置。提交使用当前仓库的 Git 身份配置。

后续通过 GitHub Releases 发布。许可证尚未确定，正式开源发布前需补充 LICENSE；签名、公证、DMG 和自动更新另行规划。
