# Agent 指南

## 项目

CameraImport 是一个面向 iOS 17.2+ 的 SwiftUI 应用，通过 ImageCaptureCore 的 PTP 支持浏览相机或读卡器中的照片和视频，提供预览、排序与系统分享。

## 代码入口

- `CameraImport/CameraManager.swift`：设备连接、文件读取、缩略图与排序。
- `CameraImport/ContentView.swift`：应用状态、导航与中英文文案。
- `CameraImport/Views/`：照片库、详情预览和分享界面。
- `CameraImportTests/`、`CameraImportUITests/`：单元测试和 UI 测试。

## 开发约定

- 使用 Swift 和 SwiftUI，尽量沿用现有结构与轻量本地化方式。
- 保持 iOS 17.2+ 兼容；设备访问相关改动需考虑连接中断和大文件内存占用。
- 项目可通过 Xcode 打开 `CameraImport.xcodeproj`；`build.sh` 和 `build_ipa.sh` 是仓库提供的构建脚本。
- 每完成一个任务后，运行 `git add -A && git commit`；提交信息使用 Conventional Commits 格式，简要概括本次改动。
- 每完成一个任务后，运行 `./build_ipa.sh` 编译；若编译报错，修复后重复运行，直到编译通过。
