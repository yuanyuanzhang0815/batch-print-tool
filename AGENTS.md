# BatchPrint（批量打印工具）

## 目标

macOS 原生批量打印小工具（SwiftUI，单文件实现）。把一堆文件按同一套规则缩放排版后一次性发到打印机，为「报销凭证批量打印」这类场景写的。

公开仓库：https://github.com/yuanyuanzhang0815/batch-print-tool （MIT）

## 状态

- **v1.3**，已开源（2026-09-24）。DMG / ZIP 挂在 GitHub Release `v1.3` 上
- 单仓库：这里既是开发仓库也是发布仓库，没有第二个快照仓库了
- 上次合并：原公开发布仓库 `macos-batch-print` 的内容（LICENSE、screenshots、英文 README、AGENTS.md）已并入本仓库，那个仓库随后归档

## 关键事实与决策

- **本仓库既是开发仓库也是发布仓库**。曾经分成「私有开发仓库 print-tools + 公开发布快照 macos-batch-print」，2026-09-24 合并为一个，原因：两边 `src/App.swift` 完全相同，维护两份必然漂移
- 仓库名是 `batch-print-tool`，但 app 名和 bundle 名是 `批量打印工具` / `BatchPrint`，产物路径 `dist/批量打印工具.app`
- `dist/` **不进仓库**（.gitignore 里忽略）——app 只通过 GitHub Release 的 DMG/ZIP 分发。历史里有旧二进制（移除前的 commit），但那不影响以后
- 只测 Apple Silicon + macOS 26；未公证，首次打开需手动放行
- Git 推送：本机全局 git 把 github 代理设成空值（走直连，会 75s 超时）。本仓库已设 repo-local `http.https://github.com/.proxy = http://127.0.0.1:7890`，直接 `git push` 即可

### 被推翻的旧决策

- ~~「开发在 print-tools 做，发布时拷到 macos-batch-print」~~（2026-09-24 推翻，改为单仓库）
- ~~README 里 macos-batch-print 的 `../../releases/latest` 链接~~ —— 那是错的相对路径，已改成 `releases/latest`

## 文件清单

- `src/App.swift` → 全部实现（单文件，约 1660 行）
- `build.sh` → 构建 + 打包 + ad-hoc 签名；`--install` / `--package`
- `README.md` → 英文（对外主 README）
- `README.zh-CN.md` → 中文（含实现要点 / 视觉语言 / 无头自检等开发文档）
- `screenshots/01-06*.png` → README 与 Release 用的真机快照
- `design/queue-redesign-v1~v3.html` → 队列布局迭代过程的三版 HTML 原型（仅历史参考）
- `tools/scalepdf.swift` → 早期独立 CLI 原型
- `legacy/AppKit-v1.swift.bak` → 最早的 AppKit 版本，仅参考
- `assets/AppIcon.icns` → 应用图标

## 待办

- [ ] 每次发版：改 `VERSION`（`build.sh` 会同步 plist）→ `./build.sh --package` → 提交 → 打 tag → 建 Release 上传 DMG/ZIP

## 已完成

- [x] `dist/` 移出仓库（.gitignore 忽略），app 只走 Release 分发