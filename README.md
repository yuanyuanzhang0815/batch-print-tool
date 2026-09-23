# 批量打印工具

macOS 原生（SwiftUI）批量打印小工具：把一堆文件丢进去，按统一规则缩放、排好版，一次性发到打印机。

为「报销凭证批量打印」这类场景写的——默认 80% 缩放 + 居中留白，方便装订时不压字。

![icon](assets/AppIcon.icns)

## 功能

- **多文件类型**：PDF、图片（PNG / JPG / JPEG / TIFF / GIF / BMP / HEIC / HEIF / WEBP）、Office 与文本（doc docx xls xlsx ppt pptx odt ods odp rtf txt csv）
- **统一缩放**：实际大小 / 适合页面 / 自定义比例（滑块 50–100%）
- **纸张与页边距**：A4 / Letter / A5；页边距 无 / 居中
- **逐文件控制**：页码范围（`全部` / `1-3` / `1,3,5`，非法输入红框提示）、份数（步进器）、**旋转**（左右各 90° 步进，0/90/180/270，每行独立；点角度数字可一键归零）
- **实时预览**：选定文件按当前缩放实时渲染，多页可翻页
- **双面打印**、批量队列、`⌘P` 打印、`⌘O` 添加、`⌫` 移除选中
- 队列可导出为缩放后的 PDF（不打印，先验证排版）
- 浅色 / 深色模式；跟随系统「减弱动态效果」自动降级动画

## 系统要求

- macOS 26（Tahoe）及以上 —— 使用了 `containerBackground` / `glassEffect` 等新 API
- Apple Silicon（构建目标 arm64）
- 可选：LibreOffice（仅当需要打印 Office / 文本类文件时；路径 `/Applications/LibreOffice.app` 或 `soffice` 在 PATH）

## 构建

```bash
./build.sh          # 编译 → 组装 .app → ad-hoc 签名，输出到 ~/Applications/批量打印工具.app
open -a ~/Applications/批量打印工具.app
```

> 依赖 macOS 26 SDK：脚本里写死为 `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`，换机时按实际路径改。

## 使用

1. 把文件（或整个文件夹）拖进窗口，或点「添加文件」
2. 在中间设置区选打印机 / 缩放 / 纸张 / 页边距 / 双面
3. 逐行检查页码范围与份数，右侧预览确认效果
4. 点「导出 PDF」先落文件验证，或直接「开始打印」

## 实现要点（几个踩过的坑）

- **旋转不另开分支**：先把内容外接盒按 90°/270° 换成宽高互换的盒子，缩放 / 纸张 / 页边距三套规则照常作用于这个盒子，绘制时再绕盒子中心旋转、并按原内容中心回移（`rotatedBox` / `placeContent`）。这样导出、打印、预览三条路径共用一份数学，不会出现「预览转了导出的没转」。实测四角度在纸上均居中（偏移 ≤2px），90° 后内容宽高比精确为原图倒数。
- **图片不是另一条流水线**：图片按 DPI 元数据换算成点尺寸后，用与 PDF **完全相同**的缩放/纸张/页边距数学画进 PDF，所以行为一致、只有一套逻辑。
- **Office 转换**：`soffice --headless --convert-to pdf`，按「转换器版本 + 路径 + mtime」缓存到 `~/Library/Caches/local.printtools.batchprint/office/`。
- **LibreOffice 中文乱码**：headless 模式下它在本机的字体发现是坏的（找不到系统 CJK 字体，中文渲染成空白/方块）。修法是注入一份指向 `/System/Library/Fonts` 的 `FONTCONFIG_FILE`，见 `ensureFontConfig()`。
- **光标接管**：`TextField` 获得焦点后 field editor 会把全局光标置成 I-beam，而鼠标离开时没有可靠复位（`cursorUpdate` tracking area 为 0）。AppKit 每次 mousemove 又用 cursor rect 覆盖回来，所以只在事件监听里 `set()` 无效。最终做法是 `window.disableCursorRects()` **接管光标管理**，自己按命中视图决定。
- **打印**：走 CUPS 的 `lp`（macOS 自带开源打印系统），不做任何 GUI 打印栈依赖；驱动层面的按比例缩放不可靠，因此缩放由本工具在生成 PDF 时完成。

## 已知限制

- Office 转换是同步的（1–3 秒/文件），大批量加入时会短暂阻塞，底栏显示转换进度
- 页码范围按源 PDF 页码；Office/图片按转换后的页码
- 没有拖拽排序、多选删除、每行独立双面设置
- 转换依赖 LibreOffice，未安装时 Office/文本类文件会加入失败

## 目录

```
src/App.swift          全部实现（单文件）
build.sh               构建 + 打包 + 签名
assets/AppIcon.icns    应用图标
tools/scalepdf.swift   早期独立 CLI 原型（缩放 PDF 的最小实现）
legacy/                最早的 AppKit 版本（仅作参考）
```