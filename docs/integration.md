# 本地整合记录

交付目录：`/Users/pumbaa/Documents/GitHub/tendedero`。分支：`codex/integrate-selected-prs`。开始时工作区干净，`main` 与拉取后的上游一致。未修改旧工作区，未推送、创建 PR、发布、替换已安装应用或更改登录项。

## 来源

2026-10-09 通过 Git fetch 与 GitHub PR 元数据核对。上游 `alejandrobujan/tendedero` 的 `main`：`ed0618a67cc59e0a8621b97bb5e32ab9af3b0b69`。

| PR | 已审查、采用的 head SHA | 本地适配 |
| --- | --- | --- |
| [#22](https://github.com/alejandrobujan/tendedero/pull/22) | `fac076e6a698da7df9726d1c99c0ef687a23c5e2` | 后台打开/扫描；准备与启用分离；代次令牌隔离启动、停止、连续切换 |
| [#24](https://github.com/alejandrobujan/tendedero/pull/24) | `e687fda83e94a1d51f7353e048026548c661b9d8` | 收起动画后 orderOut；每次显隐取消旧延迟，修复 hide→reveal→hide |
| [#21](https://github.com/alejandrobujan/tendedero/pull/21) | `8716362f110a707b69935884953c112e1ffc747b` | 小缩略图、每屏共享裁剪 overlay、最多两个大飞入、延迟无损复制快照、原子编辑保存 |
| [#11](https://github.com/alejandrobujan/tendedero/pull/11) | `502f7e3a1a5edbb43e513426366a7eef550eaa9f` | 默认关闭；只给当前悬停项大预览；视图与飞入/掉落使用相同缩放和邻居位移；按下不提前缩小拖动区域 |
| [#1](https://github.com/alejandrobujan/tendedero/pull/1) | `0f4b3df1d05ed88303b0c3bb3311aa4c08d57745` | 默认关闭；过滤敏感标记和自身复制；Finder 挂原文件；生成图片用单独专用目录 |
| [#29](https://github.com/alejandrobujan/tendedero/pull/29) | `0b88e3cc612adb22d180b6cd2d07b42dbcd6581e` | 顶部 2 pt 触发；上方显示器覆盖的横向范围回退到菜单栏；换屏重置停留计时 |
| [#14](https://github.com/alejandrobujan/tendedero/pull/14) | `8f3cf8dbf9c6c1d50c3bf5e5529dc12b2e3ba8a3` | 自动展开默认开启；关闭时隐藏状态下不启动飞入；满容量新增图片仍能触发自动展开 |

以上七个 PR 在核对时均未合并。采用功能和经审查的代码后进行适配整合，没有盲目按顺序 cherry-pick。#4 和 #7 已在上游历史中，没有重复叠加；未采用 #6、#13、#16 或其他未选功能。

目录设置只读参考旧目录 `/Users/pumbaa/Documents/Codex/2026-10-08/task/tendedero` 的未提交 `Inbox.swift`、相关调用与测试，再适配到当前翻译与异步架构。未操作旧预览。新旧目录均未找到 AGENTS.md 或 checkout 内 `.agents/skills`；已读取本机 ponytail 技能，相关本地记忆检索未命中。

## 文件和行为

- `Inbox.swift`：选择/恢复默认目录；读写验证；接管关闭时仅保存选择；首次快照不被后续切换覆盖；逐项比较并保护外部更改；失败恢复及重试。
- `ScreenshotWatcher.swift`、`ScreenshotMonitoring.swift`：I/O 后台执行；旧监听在新目录可用且设置提交成功前继续运行；停止或新请求使旧结果失效；启动期间截图可追踪；选择目录不导入旧图片；路径统一规范化，避免 `/var` 与 `/private/var` 别名。
- `ClipboardWatcher.swift`、`ClipboardImage.swift`、`Line.swift`：测试可注入独立粘贴板；敏感类型过滤、自身标记、文件 URL 优先；图片生成和转换后台执行；取消只清理本次生成文件；原文件不移动；点击复制保留原图快照与原始分辨率。
- `LineView.swift`、`PeggedView.swift`、`GrabArea.swift`、`CaptureFlight.swift`：共享缩放布局；保持原版晾衣绳、飞入曲线、落地轻摆、微风和 0.55 秒掉落；普通卡片小预览；高分辨率只用于当前放大项；飞入最多两个，额外截图直接挂上。
- `AppDelegate.swift`、`DelayedHide.swift`、`EdgeReveal.swift`：菜单设置、取消过期隐藏、上下排列屏幕触发。
- `ImageAssets.swift`、`Markup.swift`：完整分辨率 PNG/方向处理、复制快照、临时文件原子替换。
- 三种 `Localizable.strings` 与 README：补齐 40 条文案，说明目录、剪贴板和默认选项。
- `Tests/TendederoTests`、`scripts/test.sh`：适配本机仅有 Command Line Tools 的 Swift Testing；真实动画窗口测试明确 opt-in。
- `scripts/build-app.sh`：使用仓库内构建缓存；`SIGN_IDENTITY=-` 明确生成 ad hoc 本地签名，不访问 Developer ID 私钥或执行安装。

## 验证

最终结果见下方交付检查记录。测试只操作临时目录、独立 UserDefaults suite 和测试命名粘贴板，不写 `com.apple.screencapture`，不读取或替换用户的系统剪贴板，不启动 AppDelegate，不操作登录项或用户废纸篓。

初次沙箱内测试无法使用系统粘贴板服务。允许访问该服务后，专用测试粘贴板用例可通过。测试也暴露了目录枚举 URL 的 `/private/var` 别名，已在 watcher 输出处统一规范化后通过。工具链出现缺失 CLT Developer 搜索路径的链接警告；部分命名粘贴板用例打印 sandbox extension 警告，但内容读写及断言成功。

真实 UI 尚未验证：原版动画的视觉手感、实际拖放/Markup、真实多屏触发、系统权限对话框及真实截图设置接管/恢复。5 个会显示 overlay 的测试默认跳过。运行新应用及任何权限/系统截图位置操作须先取得用户明确同意；未重试曾超时的截图工具。

PR #21 的历史内存测量保留在 `memory-usage.md`，明确标为上游报告，未当作本机实测。Intel 仅交叉编译验证，未在 Intel 硬件运行。

## 交付检查记录（2026-10-09）

- `scripts/test.sh -c release`：47 项登记测试，**42 项执行通过，5 项真实窗口测试跳过**，零失败。覆盖目录启动/停止/准备期间截图、连续切换及失败保持旧监听、设置快照/恢复/外部修改/双重写失败、剪贴板敏感标记/自身复制/去重/停止清理、快速显隐、缩放与邻居坐标、多屏边缘、图像保真及原子写入。
- `swift scripts/check-strings.swift`：**40 strings, all present in en, es, zh-Hans**。使用 macOS 26.5 SDK。
- `git diff --check` 与 `bash -n scripts/build-app.sh scripts/test.sh`：通过。
- `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SIGN_IDENTITY=- scripts/build-app.sh release`：arm64、x86_64 均成功。
- `lipo -info`、`file`：Mach-O universal，包含 `x86_64 arm64`。
- `codesign --verify --deep --strict --verbose=2 build/Tendedero.app`：valid on disk / satisfies its Designated Requirement。签名类型为 ad hoc。
- `plutil -lint build/Tendedero.app/Contents/Info.plist`：OK。
- 应用包：`build/Tendedero.app`。
- 可执行文件 SHA-256：`f5c0d8b73bbee8fc7b14d71eb0ab157f883757b6d514078151d15c634dd82fbe`。
- 原始日志：`build/validation/tests-release.log`、`build/validation/build-universal.log`（构建目录按原仓库规则不纳入版本控制）。

没有启动交付应用、打开新权限、修改真实截图位置、运行真实 UI 验证、启用登录项或操作旧任务预览。需要这些动作才能完成的端到端验收仍待用户授权。

## 2026-10-11 后续整合

用户确认的上游 A—E 功能已按本地文件保护策略适配；本节以前的来源、功能范围和测试数量属于历史记录。当前功能、82 项执行通过／5 项窗口测试跳过、双架构产物及未测项见 [上游 A—E 整合与验证](upstream-ae-validation.md)。历史容量和左右批量已加入，清空、超量及批量均只取下；录屏裁剪始终另存副本。
