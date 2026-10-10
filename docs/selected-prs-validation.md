# 选择性整合与隔离验证（2026-10-10）

工作目录：`/Users/pumbaa/Documents/GitHub/tendedero`。分支：`codex/integrate-selected-prs`。起始提交：`5e88d5d768753c431a355dc71d398e3680903f8a`。

首次本机只读检查成功，随后代码、测试和构建均在同一台 Mac 完成。仓库、父目录链中未找到适用的 AGENTS.md；checkout 中没有 .agents/skills。使用本机 ponytail 技能控制变更范围。开始前已有修改的 `docs/integration.md` 和未跟踪的 `docs/ui-validation.md` 按原样保留，不纳入本次提交；副本和差异保存在 `build/validation/selected-prs/`。

## 来源与范围

已通过 GitHub API 核对以下固定 head；按当前代码适配，未整体合并 PR。

| PR | 核对的 head | 本地采用 |
| --- | --- | --- |
| [#42](https://github.com/alejandrobujan/tendedero/pull/42) | `9b710a926929c473b72105750ebeb02995d9960e` | 剪贴板隐私预检、竞态保护、输入校验、资源限制与合成来源 |
| [#36](https://github.com/alejandrobujan/tendedero/pull/36) | `01cb14a6ccc8a06edc6676243c335ee716c2798c` | 仅恢复时绕过 hang 的默认 8 张截断 |
| [#50](https://github.com/alejandrobujan/tendedero/pull/50) | `3064c5c4162f0b906602260c78d05c86ad7aad2a` | 成功挂图后同步通知，满容量新图仍能触发预览 |
| [#51](https://github.com/alejandrobujan/tendedero/pull/51) | `557cb038cd07bfb5e173d06691e0b718678680f0` | 接受后才记为已处理，失败文件有界重试与后续写入恢复 |

未引入 #38、#44、#36 clear/overflow 自动移废纸篓；未重复 #49 的 orderFront。原有首次提示、opt-in、Finder 原图片文件 URL 导入、独立 Clipboard 目录、自身复制去重和 #21 延迟复制均保留。CaptureFlight、LineView、PeggedView、ClipboardImage、Inbox 的生产代码未改。

## 实现

- 剪贴板创建 watcher 时不访问系统粘贴板；启用/重新启用时建立基线，忽略此前已有内容。先扫描 board 和所有条目的敏感/自身标记，再读取任何图片或 Finder URL。
- 读取元数据、Finder URL、图片以及异步校验/落盘前后复核 changeCount 和代次令牌。失效结果不交付；已生成的失效文件只删除本次创建的那一份。
- 只接受匹配实际格式的 PNG/TIFF；输入和生成的 PNG 上限为 32 MiB，像素数上限为 4000 万，维度检查在解码前完成。ImageIO 负责解码验证，PNG 额外检查块边界、CRC 和 IEND：合成测试证明 ImageIO 会容忍部分截断 PNG，因此不能仅依赖它的 complete 状态。合法 PNG 原字节保留，TIFF 首帧转为 PNG。
- 新文件采用 UUID 命名、排他创建、禁止目标符号链接，并从第一次写入起使用 0600 权限；新建生成目录为 0700。已有用户目录不被归入图片清理目录，也不修改它们的权限。
- restore 直接恢复合法、去重后的列表，不调用 hang，也不重写持久列表。宽屏保存的 12 张可完整重启恢复；后续新增仍按当前真实容量淘汰显示项。clear/overflow 只取下，所有原文件保留。
- Line 在接受、淘汰与保存完成后同步发出 onCapture，事件携带当时的预览开关。重复路径、无法读取、quiet 恢复不发通知。初始恢复预览仍遵守同一开关；pendingScreen 在 hang 前设置，飞入入口及 #21 并发上限保留。
- 截图监听保留后台 opening/listing 与 prepare/commit 模式。onNew 返回接受状态；AppDelegate 对已在列表中的规范路径返回成功，避免重复重试与重复飞入。
- 不创建每个失败文件一个监听器。每个目录只有一个目录描述符及一个共享重试唤醒；现有管理器分别管理主目录、Desktop 补充目录和待提交目录，失败文件不增加监听器数量。默认每批最多尝试 16 个文件，每个未变化文件最多尝试 4 次（首次及 0.2/0.4/0.8 秒退避）。耗尽后仅每 5 秒后台复查元数据，文件大小、inode、修改或状态时间变化才重置该文件的预算。无关目录事件不重置失败项。
- 停止/换目录会取消唤醒、清空失败记录并更换代次，旧 opening/listing/目录回调不能影响新代次。首次 listing 失败会终止准备并关闭描述符，不把失败当空基线。

## 验证结果

- `TENDEDERO_UI_TESTS=0 scripts/test.sh -c release`：75 项登记，**70 项执行通过、5 项窗口测试跳过，零失败**。日志：`build/validation/selected-prs/tests-release.log`。
- 其中 16 项新的剪贴板测试完全使用合成来源；覆盖三类敏感标记和自身标记在首项、后续项、board 上的预检（含 Finder），各读取阶段与异步边界竞态，32 MiB 与 4000 万像素边界、损坏/错标格式、TIFF 回退、PNG 原字节、私有权限、唯一文件、取消清理及落盘失败。
- 3 项捕获通知测试覆盖空/未满/满容量、连续 10 次挂图、开关切换、持久化时序、重复/不可读/quiet/恢复，确认事件不改变 flying 状态。
- 7 项重试测试覆盖无需文件事件的重试、耗尽后原地写完、无关事件不重置、100 个损坏文件的描述符与批次上限、初始 listing 失败、旧异步结果、回调内停止及快速换目录。
- 2 项恢复/保留测试覆盖 12 张重启、规范路径去重、坏图/缺失文件、真实容量溢出、自定义/专用/剪贴板目录 clear 和 overflow 保留原文件。既有异步监听切换、Finder 命名粘贴板、自身延迟复制、目录隔离及图像保真回归也通过。
- 翻译检查：40 strings，en/es/zh-Hans 齐全。差异空白检查与两份 shell 脚本语法检查通过。

第一次沙箱构建被 dsymutil 权限阻止；获得自动审批放行后运行上述隔离测试。中途测试编译错误及截断 PNG 失败已经修正，失败日志保留作定位记录，最终成功日志如上。CLT 缺失 Developer 搜索路径的链接警告、专用命名粘贴板的 sandbox extension 警告仍存在；相关断言通过。

## 构建产物

- `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SIGN_IDENTITY=- scripts/build-app.sh release`：arm64、x86_64 均成功。日志：`build/validation/selected-prs/build-universal.log`。
- 应用包：`build/Tendedero.app`；只生成本地构建，未打开或安装。
- `lipo -info` / `file` 确认为 Mach-O universal，包含 x86_64、arm64。
- `codesign --verify --deep --strict --verbose=2`：valid on disk / satisfies its Designated Requirement。签名为 ad hoc。
- `plutil -lint`：Info.plist OK。
- 可执行文件 SHA-256：`c79ea3520e21b98f67c1cd498fe30ac4c13f8266a82f54473b0b50fd60e6dab2`。
- 翻译日志：`build/validation/selected-prs/translations.log`。固定 PR 提交差异、先前文档副本与最终日志均保留在同一目录；该目录按原仓库规则忽略，不纳入 Git。

## 本轮边界

本轮未启动正常应用或 AppDelegate，未显示测试窗口，未读取真实系统剪贴板或采集屏幕，未使用 Accessibility/AppleScript，未修改系统截图设置、登录项或用户废纸篓；未推送、创建 PR、发布或替换已安装应用。测试使用合成图片、临时目录、独立 UserDefaults suite 和专用命名粘贴板。

真实交互、动画视觉手感、系统权限提示和 Intel 硬件运行未测。重试耗尽后原地完成的图片若没有目录事件，最多等待约 5 秒的元数据复查；未变化的损坏文件不会无限解码。
