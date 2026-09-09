# Noto macOS 图标候选

生成方式：内置 image_gen。2026-09-09。

已选定：方案 01「静页」。选定原图为 `../app-icon-selected.png`，1254 × 1254 PNG。其余候选保留。

已接入应用：`../AppIcon.icns` 包含 16–1024 像素的标准 macOS iconset 尺寸，带透明边缘和圆角。构建脚本复制图标并设置 `CFBundleIconFile`，DMG 打包沿用相同应用资源。

重新生成：在项目根目录运行 `swift scripts/make-icon.swift`，然后运行 `iconutil -c icns build/AppIcon.iconset -o design/AppIcon.icns`，最后运行 `zsh scripts/build.sh`。

基于项目的本地小记、待办和 AI 对话功能，以及安静、轻量的现有设计。用户已确认 Mark 指 Mac / macOS。

参考：[Apple App Icons HIG](https://developer.apple.com/design/human-interface-guidelines/app-icons)。采用简洁主体、清晰轮廓和克制层次；满幅方形背景供后续平台遮罩处理。

下列 PNG 是静态候选原稿。选定方案已制作传统 macOS `.icns`，未制作 Icon Composer 分层或独立明暗/着色变体。

| 方案 | 文件 | 含义 |
| --- | --- | --- |
| 01 静页 | 01-quiet-page.png | 纸页与勾选，记录与完成 |
| 02 折叠 N | 02-folded-n.png | 纸带构成 n，品牌与整理想法 |
| 03 会思考的笔记 | 03-thinking-page.png | 笔记与气泡合一，AI 整理与对话 |

## 完整生成提示词

### 1

```text
Use case: logo-brand. Asset type: macOS app icon design candidate for Noto, a quiet native local-first notes and tasks app with optional AI conversations. Create ONE polished standalone square 1024x1024 icon artwork, not a presentation board. Calm premium macOS visual language, extremely simple bold recognizable silhouette, restrained dimensionality, subtly layered materials, centered frontal composition, precise geometry, large generous breathing room around subject. Full-bleed opaque square background, no pre-rounded outer corners or external drop shadow (OS mask applied later). No captions, words, watermark, interface screenshots, surrounding objects, Apple logo, tiny details, busy decoration. All essential symbol content within central 70 percent. Subtle internal ambient shadows only. Concept 01 "Quiet page": warm ivory background. One white gently raised paper sheet with softly rounded corners and a modest folded upper-right corner, occupying central 62% width. On the sheet two short thick slate-gray horizontal strokes near top and a single confident large cobalt-blue checkmark in the lower half, deeply recognizable and softly rounded ends. Evokes capturing a note and turning it into a finished task. Paper-like matte porcelain, very restrained highlights, sophisticated and warm, not a literal screenshot and not Apple Notes yellow header.
```

### 2

```text
Use case: logo-brand. Asset type: macOS app icon design candidate for Noto, a quiet native local-first notes and tasks app with optional AI conversations. Create ONE polished standalone square 1024x1024 icon artwork, not a presentation board. Calm premium macOS visual language, extremely simple bold recognizable silhouette, restrained dimensionality, subtly layered materials, centered frontal composition, precise geometry, large generous breathing room around subject. Full-bleed opaque square background, no pre-rounded outer corners or external drop shadow (OS mask applied later). No captions, words, watermark, interface screenshots, surrounding objects, Apple logo, tiny details, busy decoration. All essential symbol content within central 70 percent. Subtle internal ambient shadows only. Concept 02 "Folded N": very pale cool gray background. One bold sculptural lowercase n-shaped monogram made from a continuous folded cobalt blue paper ribbon, with broad strokes and a generous open negative-space arch. A small folded plane visible on upper-right suggests a notebook page becoming organized thought; the silhouette must remain unmistakably lowercase n and geometric. Blue-on-blue fold shading, tactile matte material, precise restrained depth, minimal, calm, strong silhouette. No extra checkmarks or sparkles, no text other than the abstract n-shaped symbol.
```

### 3

```text
Use case: logo-brand. Asset type: macOS app icon design candidate for Noto, a quiet native local-first notes and tasks app with optional AI conversations. Create ONE polished standalone square 1024x1024 icon artwork, not a presentation board. Calm premium macOS visual language, extremely simple bold recognizable silhouette, restrained dimensionality, subtly layered materials, centered frontal composition, precise geometry, large generous breathing room around subject. Full-bleed opaque square background, no pre-rounded outer corners or external drop shadow (OS mask applied later). No captions, words, watermark, interface screenshots, surrounding objects, Apple logo, tiny details, busy decoration. All essential symbol content within central 70 percent. Subtle internal ambient shadows only. Concept 03 "Thinking page": deep muted midnight blue background with a very subtle tonal lift in center. One large pearl-white softly raised note tile whose lower-left edge forms a short integrated speech-bubble tail, a single unified note-and-conversation silhouette. Two broad dark slate horizontal note strokes in upper half, with the lower stroke shorter. One small but clearly visible simple four-point blue glint cut into or inlaid in the lower-right area of the white tile to suggest optional AI organizing thoughts, not a floating accessory. Satin porcelain surface, crisp contour, restrained soft depth, no neon, no futuristic circuits.
```
