# 上游 A—E 选择性整合与验证

日期：2026-10-11。工作目录：`/Users/pumbaa/Documents/GitHub/tendedero/.worktrees/upstream-ae`；任务分支：`codex/integrate-upstream-ae`。

基线为本地及 origin/main 的 `469cd5dea436ad88f1c5be6e4a675efcae93a9b6`；仅参考已确认的上游 `cf87e6ebc275d4f2cc42900e55f88a52d3ce9e46`（1.5.0）。没有把其他上游变更或更新入口纳入本轮。

本机命令入口首次返回 `exec-server transport disconnected`；在同一台 Mac 上重试后恢复。重新读取了 `/Users/pumbaa/.codex/AGENTS.md` 和 `RTK.md`；仓库及父目录链没有其他 AGENTS.md，checkout 中没有相关 `.agents/skills` 或 CodeGraph 索引。开始时主工作区干净。使用 ponytail 技能，按用户级规则创建已忽略的独立 worktree。

## 功能与保留行为

- A：可设置或移除全局快捷键；注册失败恢复原设置与注册。Quick Look 接入右键、重按和左右切换，并随绳子上的文件更新。右键菜单打开期间暂停自动收起；剪贴板监听状态使用实心图标，普通文件角标表示仅隐藏。
- B：最多三个额外监听目录，支持路径别名去重、异步准备、并发上限和停止失效保护；主目录失败回滚及旧监听保护继续保留。容量为按屏幕、25、50、100，横向滚动查看历史；悬停时纵向滚动缩放。支持小、中、大尺寸及菜单栏边缘、全屏展开开关。新截图先按目标屏幕更新容量；屏幕外历史项不创建掉落动画窗口。
- C：左侧、右侧、全部取下和超容量取下均不删除源文件；降低保留数量或增大尺寸造成的超量也仅取下。右键提供独立的“移到废纸篓”。既有角标行为保留：应用专用目录的叉号表示丢弃，普通目录的隐藏图标只取下。
- D：接管目录和额外目录支持 MOV/MP4、缩略图、视频文件复制、Quick Look、长按裁剪。裁剪先导出到隐藏临时文件，再以唯一名称发布新副本，绝不替换原视频；失败仅清理本次导出临时文件。复制视频只写文件 URL 和自身标记，图片仍使用延迟 PNG 快照。
- D 设置：补充录像位置及三个截图/录像目标键，纳入原有快照、逐项所有权比较和失败回滚。旧版本升级只补拍新接管键，不覆盖原位置快照；用户后来修改或删除的设置在恢复时保留。
- E：英语、西班牙语、简体中文、土耳其语、阿塞拜疆语、法语、巴西葡萄牙语、日语、韩语，共 61 个文案键全部齐全。保留严格缺失/多余键检查，并核对格式占位符；没有加入上游官网更新入口。

`ClipboardWatcher.swift`、`EdgeReveal.swift`、`DelayedHide.swift` 和严格翻译检查脚本没有改动。Finder 图片、文字与图片混合内容、首次提示、独立生成目录、自身复制识别、32 MiB／4000 万像素界限、PNG 完整性及任务失效保护均保留。原绳子、飞入、落地轻摆、微风和掉落时间参数保留；共享裁剪动画窗口仅增加全屏 Space 支持。

## 本轮验证

- `TENDEDERO_UI_TESTS=0 scripts/test.sh -c release`：**87 项登记，82 项测试函数执行通过，5 项真实窗口测试跳过，零失败**。其中录屏测试分别执行 MOV、MP4 两个参数用例。
- 新增测试覆盖：快捷键冲突回滚/移除/无效配置；100 张恢复及降低容量保留全部原文件；两侧批量与清空保留专用、剪贴板、自定义目录文件；滚轮方向分工和屏外布局；三个额外目录、并发上限、别名、失败、移除和停止失效；设置升级、失败回滚、外部修改；合成录屏缩略图、命名剪贴板复制、唯一裁剪副本及原视频字节不变。
- 原有剪贴板隐私、竞态、资源界限、Finder、自身复制、延迟 PNG、目录切换、文件未写完重试和动画坐标测试继续通过。
- 严格翻译检查：`61 strings, all present in az, en, es, fr, ja, ko, pt-BR, tr, zh-Hans`。
- `git diff --check`、两份 shell 脚本语法检查、九种语言格式占位符检查通过。
- 使用本机 macOS 26.5 SDK：`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SIGN_IDENTITY=- scripts/build-app.sh release`。arm64、x86_64 均构建成功；`lipo` 和 `file` 确认通用二进制包含两个架构。
- `codesign --verify --deep --strict --verbose=2`：通过；签名为 ad hoc，无 TeamIdentifier。`plutil -lint`：Info.plist 正常。

## 产物与日志

- 应用：`.worktrees/upstream-ae/build/Tendedero.app`，相对于主仓库根目录；未打开、安装或替换已有应用。
- 二进制 SHA-256：`f2b3dcf381fa9849aa4977e23b850bd6889fcbed717736cfb236efb7a64eb66b`。
- 任务工作区内日志：`build/validation/upstream-ae/tests-final.log`、`translations.log`、`build-universal.log`。第一轮成功回归也保存在 `tests-release.log`。

第一次沙箱构建在 dsymutil 生成调试符号时遇到权限错误，经工具审批放行后通过。翻译检查初次使用了不可写的默认模块缓存，改为工作区缓存及实际存在的 SDK 后通过。CLT 缺失 Developer 搜索路径的链接警告仍在；部分独立命名剪贴板测试打印 sandbox extension 警告，相关断言全部通过。

## 未运行与限制

没有启动 AppDelegate 或常驻应用，没有改真实截图设置，没有采集真实剪贴板或屏幕，没有使用 Accessibility/AppleScript，也没有操作用户文件的废纸篓。测试只使用临时文件、隔离 UserDefaults 和独立命名剪贴板；合成录屏不是录制真实屏幕。

真实重按、Quick Look/裁剪窗口、快捷键系统冲突、全屏切换、多屏动画手感以及系统权限对话框尚未交互验收。Intel 仅交叉编译，未在 Intel 硬件运行。翻译通过完整性检查，未经过各语言母语者审校。未执行发布、公证、推送或 PR 操作。
