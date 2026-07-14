# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

**灵眸** — Flutter 目标检测 Android App。双模型（COCO 80类 + VOC 20类），通过 HTTP 调用服务器端 YOLO11s ONNX 推理，本地画框+显示。

## 架构

```
shujiapp/lib/
├── main.dart                     # Material3 主题 + 3 Tab 导航
├── pages/
│   ├── detect_page.dart          # 核心：选图→增强→服务器推理→画框+结果列表
│   ├── history_page.dart         # 检测历史（sqflite）+ 详情页
│   └── settings_page.dart        # 模型信息展示
├── models/
│   ├── detection_record.dart     # 检测结果数据模型
│   └── database.dart             # SQLite 封装（sqflite）
└── widgets/
    └── model_selector.dart       # 模型切换下拉
```

**推理流程：** 相册/拍照 → 图片增强(实时 ColorFilter.matrix + Transform，GPU运算零网络) → `POST /api/detect` → 服务器返回 `{objects: [{class, confidence, bbox}], width, height}` → CustomPainter 等比画框

## 关键实现

| 模块 | 文件 | 实现方式 |
|------|------|---------|
| 图像增强 | `detect_page.dart:_imgPrev()` | Flutter GPU `ColorFilter.matrix` + `Transform`，滑块拖动→setState→GPU重绘，**不经过网络** |
| 单图检测 | `detect_page.dart:_detect()` | HTTP POST→服务器 ONNX Runtime，~1-3s |
| 实时检测 | `detect_page.dart:_enterC()` | `camera` 包 CameraPreview + 800ms Timer 拍照→送检→画框 |
| 本地TFLite | `assets/*.tflite` | 模型文件就绪但**代码未接入**，预留 `task: YOLOTask.detect` |

## 关键命令

```bash
# 构建 APK
flutter build apk --release
# 输出: build/app/outputs/flutter-apk/app-release.apk

# 分析代码
flutter analyze

# 添加依赖
flutter pub add <package>

# 查看依赖
flutter pub deps

# 走代理
set HTTP_PROXY=http://127.0.0.1:7897 && set HTTPS_PROXY=http://127.0.0.1:7897 && flutter build apk --release
```

## Git

- `https://github.com/cdd0329/app` — 本仓库

## 环境要求

- Flutter SDK 3.44.6 → `D:\software\Flutter\flutter`
- Android SDK 36 + platform-tools → `D:\software\Android`
- 网络代理 `127.0.0.1:7897`（Gradle 下载依赖）

## 服务器依赖

APP 通过 HTTP 调用服务器推理。实际运行的是 `server_final.py`（FastAPI + ONNX Runtime + YOLO11s），位于 `/opt/`，始终运行在端口 8765。

默认地址：`http://218.195.250.194:8765`
训练监控：`http://218.195.250.194:8766`
App 右上角 ⚙ 可修改地址。

## 已知问题（详见 `E:\obj_detection\已知问题与待办.md`）

| 问题 | 说明 |
|------|------|
| `image_cropper` 冲突 | Reply already submitted 崩溃，已移除。增强效果用 ColorFilter.matrix + Transform 实现 |
| iOS 未适配 | 只支持 Android |
| 模型文件大 | voc_model.tflite 37MB, coco_model.tflite 37MB，不在 git 中，存在 `E:\obj_detection\shujiapp\assets\` |

## 构建规则

- 不要主动构建 APK，等用户说"构建"再执行
- 构建前先 `taskkill //F //IM java*` 清 Gradle 守护进程
- GPU 模式 `useGpu: false`（HyperOS 兼容）
- TFLite 推理需要 `task: YOLOTask.detect`（模型无内嵌元数据）
