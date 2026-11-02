# 技术架构

## 选型

采用 Swift 6 语言模式、SwiftUI 界面和 AppKit 生命周期，最低 macOS 14。该版本提供 Observation 和 ScreenCaptureKit 的静态截图 API，减少兼容分支；仍需在最低系统实机验证。

AppKit 的 `NSStatusItem` / `NSMenu` 管理菜单栏，`NSWindowController` 托管 SwiftUI 设置界面。相比全 SwiftUI 的 `MenuBarExtra` / `Settings`，多几行桥接代码，但窗口激活、关闭后重开和菜单动作更直接可控。无需引入第三方菜单栏辅助库。

单一应用 target，按目录隔离功能；测试独立 target。目前不拆 Swift Package、不引入插件系统、依赖注入框架、全局事件总线或持久化数据库。

## 运行方式与职责

- `App/main.swift`：启动 accessory 应用；`LSUIElement` 隐藏 Dock 图标。
- `AppDelegate`：持有共享偏好、菜单栏、快捷键控制器和懒加载设置窗口；启动注册快捷键，退出注销；关闭设置不退出，重复启动打开设置。
- `StatusBarController`：仅负责菜单入口与动作转发。
- `Features/Settings`：原生表单、设置窗口复用、权限展示。当前唯一持久化选项是「打开应用时显示设置」。
- `Features/GlobalShortcuts`：`CarbonGlobalShortcutRegistrar` 实现注册/注销协议，`SettingsShortcutController` 管理固定 `⌃⌥N` 的状态、重试和设置动作。使用 `RegisterEventHotKey` 独占注册；重复注册和系统占用返回明确错误。Carbon 事件回调按签名及进程内唯一 ID 路由，各注册器不会误消费其他注册器的事件。
- `Features/Screenshot`：按显示器 ID 异步返回 `CGImage` 的协议，无实现。未来适配 ScreenCaptureKit；区域选择和编辑不属于当前接口承诺。
- `Shared/Preferences`：注入式 UserDefaults，便于隔离测试。
- `Shared/Permissions`：按能力逐步增加权限支持，当前只做屏幕录制预检查和系统设置跳转，不主动申请权限。

快捷键注册、注销和事件处理也限制在主线程。退出显式清理；注册器释放时将清理任务交给主线程，并保留 C 回调上下文直到移除 handler。注册失败且无有效快捷键时也移除 handler。系统注册 API 无法穷尽识别第三方基于原始键盘监听实现的快捷键；后续自定义录入时另行处理系统保留组合与布局显示。

UI 和窗口生命周期限制在主线程。后续截图编码、文件写入等耗时工作应离开主线程，明确取消和错误处理，避免不必要的后台计时器。

## 公共能力与数据

共享能力随已确认需求增量建立；功能通过小接口访问系统，不互相依赖内部 UI。不提前实现快捷键配置页、模块管理器或通用权限框架。

简单偏好用 UserDefaults；后续如有历史记录，优先在 Application Support 下存储，图片由文件管理。只有查询规模和一致性需求明确后再选择 SQLite / SwiftData；敏感凭据如有需求使用 Keychain。

当前不采集遥测、不访问网络、不保存屏幕内容。未来仅在用户触发相关功能时申请必要权限；权限拒绝或撤销必须提供恢复路径。普通快捷键是否需要辅助功能取决于实现，不能一律要求授权。

## 开发与发布

不启用 App Sandbox；不添加未经实际需求验证的 entitlements。当前用 ad-hoc 签名本地运行，无开发者会员依赖。固定 bundle ID 为 `com.noname4me.nylai`；后续评估签名变化对系统权限识别的影响。

面向 GitHub Releases，先完成可用小版本及许可证选择，再决定 Developer ID 签名、公证和安装包。未签名分发存在系统安装限制，不把本机成功运行视作外部分发验收。自动更新延后。

## 原生 API 参考

- [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
- [RegisterEventHotKey](https://developer.apple.com/documentation/carbon/registereventhotkey(_:_:_:_:_:_:))

快捷键 API 的独占语义及线程约束以本机 macOS SDK 的 `HIToolbox.framework/Headers/CarbonEvents.h` 为依据；无需辅助功能或输入监控权限。
