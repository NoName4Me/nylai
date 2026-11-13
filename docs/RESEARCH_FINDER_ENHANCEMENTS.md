# 访达右键增强调研

调研日期：2026-11-10。结论基于 Apple 文档、本机 SDK 和公开项目作者的一手记录；尚未在本项目中完成真实 Finder 扩展验收。

## 结论与首版范围

三个动作适合做成独立、默认关闭的“访达增强”模块：**新建文件、复制路径、在此打开终端**。优先保证右键目标、文件安全和菜单简洁，不先扩展成文件管理器。

- **文档与运行时需区分**：Apple 文档把 `targetedURL()` 定义为 Control-click 目标，`selectedItemURLs()` 是选择集合。但本机真实 Finder 验证发现，项目菜单的 `targetedURL` 仍可返回所在目录。实现因此只在单选时使用唯一选中项；多选以原始右键坐标和辅助功能元素 URL 匹配，不取数组首项。[Apple：targetedURL](https://developer.apple.com/documentation/findersync/fifindersynccontroller/targetedurl())、[Apple：selectedItemURLs](https://developer.apple.com/documentation/findersync/fifindersynccontroller/selecteditemurls())
- **不是已验证的全场景保证**：桌面、搜索结果、最近使用、iCloud Drive、第三方云盘，以及在已有多选内／外右键，仍须在真实 Finder 中逐项验证。文档定义和本地纯函数测试不能代替系统实际回调。
- **现有 ad-hoc 发布不是已证实的硬阻塞**：公开项目作者在 macOS 26.6 实测，带沙盒 entitlement 的 ad-hoc Finder Sync 扩展可以注册；这只是其单机一手记录，不能当作 Apple 对全部版本的兼容承诺。[作者实测记录](https://github.com/sherman-yang/mac-finder-menu/blob/main/docs/FINDINGS.md)

## 右键目标规则

菜单构造时同时读取 `menuKind` 和 `targetedURL()`，把目标快照绑定到本次菜单动作，避免动作执行时前台目录／选择已经变化。

| 右键位置 | 复制路径 | 新建文件／打开终端的目录 |
|---|---|---|
| Finder 窗口空白区域 | 本次右键所在目录 | 同一目录 |
| 文件 | 被右键文件的绝对路径 | 该文件的父目录 |
| 文件夹 | 被右键文件夹的绝对路径 | 被右键的文件夹 |
| 已有多选中的某项 | 按原始右键坐标匹配 Finder 元素，不取选择数组首项；无法确定时提示重试 | 由同一目标解析 |
| 目标不存在、URL 缺失或非文件 URL | 禁用动作，不猜测当前前台窗口 | 禁用动作 |

其中空白区域与项目区域可用 `FIMenuKind.contextualMenuForContainer` 和 `.contextualMenuForItems` 区分；侧栏和工具栏也有独立菜单类型。上表是建议的产品规则，特别是“文件夹右键时终端进入该文件夹”需要与主产品保持一致。[Apple：FIMenuKind](https://developer.apple.com/documentation/findersync/fimenukind)、[Apple：menu(for:)](https://developer.apple.com/documentation/findersync/fifindersyncprotocol/menu(for:))

本机 macOS SDK 的 `FinderSync.framework/Headers/FinderSync.h` 同样写明以上语义；`targetedURL` 和选择集合只保证在菜单构造或其菜单动作中有效，托管目录外可返回 nil。不要使用延迟读取前台 Finder 窗口或模拟复制来修补歧义。[Apple：Finder Sync 指南](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)

## 三个动作的产品细节

### 新建文件

- 直接创建“未命名.txt”，不弹出文件名输入窗口。
- 同名时自动编号为“未命名 2.txt”等，不覆盖已有项目。
- 创建后选中新文件并进入 Finder 原位重命名；已在本地 Finder 列表视图验证。
- 原位重命名使用辅助功能权限，并先核对选中目标；只读目录、目标消失、创建权限拒绝返回明确错误。

这是实际产品在补的缺口：开源 NewFile 明确围绕 Finder 右键／工具栏新建文件、类型和模板设计。不过产品存在只能证明有人使用这种方案，不足以证明它是全体 Mac 用户排名第一的痛点。[NewFile 官方项目](https://github.com/mariusgm/newfile)

### 复制路径

- 默认复制**未添加 shell 引号的绝对路径文本**，便于粘贴到编辑器、聊天和文件选择器。
- 不复制所有已选项，不偷偷附换行，不跟随符号链接解析到另一个位置。
- “复制终端转义路径”如果后续增加，必须用独立名称；不能让同一个动作在普通文本和 shell 格式间无提示变化。

Finder 已有 Option + 右键的“拷贝为路径名称”，但入口隐藏且输出格式有使用摩擦。Apple 自己说明了隐藏入口，Apple 社区也有用户直接报告路径外层引号影响其使用；这属于可核实的用户反馈，不代表统计上的普遍性。[Apple：Terminal 中的路径](https://support.apple.com/guide/terminal/apd3cf6fe02-3ec8-48f1-951f-866e52955fc8/mac)、[Apple 社区原始反馈](https://discussions.apple.com/thread/255762727)

### 在此打开终端

- 首版只支持 macOS Terminal；目录取右键快照，不取当前前台 Finder 窗口。
- 把目录作为文件 URL 交给系统启动／打开机制，避免把名称拼成可执行 shell 命令。
- 如果必须脚本桥接，要单独处理引号、换行、非 ASCII 名称以及自动化授权；不能直接拼接 `cd + path`。

系统已经能从 Finder 路径栏右键“在终端中打开”，也有文件夹终端服务。增强价值是把动作放到用户实际右键处、减少层级与目标选择成本，而不是声称 macOS 没有这个能力。[Apple：从 Finder 打开 Terminal](https://support.apple.com/guide/terminal/trmlb20c7888/mac)

## 接入与发布边界

1. **原生接入**：独立 Finder Sync extension target，通过 `com.apple.FinderSync` 注册；设置并监控用户允许的目录，宿主应用检测扩展开关并提供系统扩展管理入口。Apple 将该框架定位为文件同步状态与控制，明确说它不是通用 Finder UI 修改工具，因此采用它做通用菜单增强是一项产品兼容取舍，而不是 Apple 对任意文件管理功能的背书。[Apple：Finder Sync](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)
2. **进程隔离**：扩展运行于独立进程，Open／Save 对话框也可能拉起额外实例；应只保留菜单与目标解析，不在扩展里跑常驻扫描或复杂自动化。主应用不必因为扩展而整体改成 App Sandbox。[Apple：Finder Sync 指南](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)
3. **共享设置**：Apple 推荐宿主与扩展通过相同 App Group 共享偏好；App Group 标识涉及开发团队配置。现工程无开发团队、使用 ad-hoc 签名，不能未经验证直接引入团队专属配置，也不能把是否能编译等同于是否能在用户 Finder 中运行。[Apple：配置 App Groups](https://help.apple.com/xcode/mac/current/en.lproj/dev8dd3880fe.html)
4. **权限与动作执行**：扩展沙盒和用户数据目录保护要分别验证。启动子进程并不会自然逃离扩展沙盒；如果动作交给宿主，通道必须只允许有限动作、验证文件 URL，不提供任意命令执行接口。公开项目作者报告了沙盒继承、启动参数未送达以及 iCloud Desktop／Documents 不显示菜单等问题；这些是有价值的测试线索，不是所有机器必现的系统规则。[项目作者实测](https://github.com/sherman-yang/mac-finder-menu/blob/main/docs/FINDINGS.md)

调研开始时工程只有应用和测试两个 target，发布流程使用 ad-hoc。本轮实现已补 Finder Sync target、嵌入与有限动作转交，保留 ad-hoc 发布身份。编译、单元测试与签名检查不能代替真实 Finder 验收；未自动启用系统扩展。

## 还值得增强什么

| 建议 | 减少的实际步骤 | 建议优先级与边界 |
|---|---|---|
| 用常用应用打开 | 每次在“打开方式”长菜单找编辑器／终端 | P1；少量用户配置的固定应用，不接管默认关联。开源 finder-menu 已覆盖这类入口，说明它是同类工具认可的场景。[官方项目](https://github.com/nikgrbn/finder-menu) |
| 从模板新建 | 反复创建同结构 Markdown、JSON 或项目记录 | P1，排在纯文本新建稳定以后；NewFile 官方已有每类型模板能力。[NewFile](https://github.com/mariusgm/newfile) |
| 移动到／复制到常用目录 | 在两个窗口之间反复导航、拖放 | P2；先做少量收藏目的地、冲突预览，不先做双栏管理器。这是结合现有剪贴板／快捷键模块的产品推断，尚无本次样本的需求频率证明。 |
| 批量重命名预览 | 多次试改编号、日期、正则规则 | P2；只补系统不覆盖的部分。Finder 已提供替换文本、添加文本和格式化命名，简单换名不值得重写。[Apple：批量重命名](https://support.apple.com/guide/mac-help/mchlp1144/mac) |

**暂不优先做**：基础图片转格式／缩尺寸、旋转、合并 PDF、去背景；Finder 原生 Quick Actions 已覆盖这些能力。除非提供明确的批处理参数、目标体积或隐私清理价值，否则只是再做一个入口。[Apple：Finder 快速操作](https://support.apple.com/guide/mac-help/mchl97ff9142/mac)

## 真实 Finder 验收最小矩阵

2026-11-10 排障记录：真实菜单点击时 `representedObject` 没有被 Finder 回传，导致三个动作在扩展内提前返回。现改用可回传的菜单 `tag` 对应扩展内的有界动作快照表。已复现修复前路径未复制、修复后单文件路径正确复制及新建文件实际落盘；终端由用户确认可用。辅助功能元素按已知坐标命中目标已验证，多选物理右键、不同视图和云盘仍按下列矩阵补充验收。多选辅助定位使用已有辅助功能权限；无权限或有歧义时提示，不猜测目标。

- 图标／列表／分栏视图：单选、已有多选内右键、多选外右键、保留多选后点空白。
- 桌面与普通本地目录：右键目标和实际创建／复制／终端目录一致。
- 包与别名／符号链接、中文、空格、单引号、换行、同名、只读目录和已删除目标。
- iCloud Drive、同步桌面／文稿、第三方 File Provider、外置盘及网络盘：逐个记录支持与不支持，不先承诺“所有位置”。
- 扩展关闭／重新启用、应用更新／移动、Finder 重新启动、macOS 14 与当前版本、arm64／Intel 安装包。
- 专项测试目标解析与无覆盖创建；其余截图、鼠标手势、系统监控无需为该功能执行全量回归。
