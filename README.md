<div align="center">

# Pocket Motion

**专为大疆 DJI Mimo 生态下的 Osmo Pocket 系列打造的全平台实况照片（Live Photo / Motion Photo）与媒体无损导出工具**

[![Version](https://img.shields.io/badge/Version-v2.1.1-0A84FF?style=flat-square)](#)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-4A90E2?style=flat-square)](#)
[![Flutter](https://img.shields.io/badge/Built%20with-Flutter%203.24-02569B?style=flat-square&logo=flutter)](#)
[![License](https://img.shields.io/badge/License-MIT-2ECC71?style=flat-square)](#)

针对 DJI Mimo 拍摄的 Osmo Pocket 系列素材，将 SD 卡或本地目录中的文件一键导出为 **Apple 实况照片（原生 `.HEIC + .MOV`）**、**Google 动态照片（`.jpg`）**、**原片视频（`.MP4`）** 与 **高清照片（`.JPG`）**，支持 macOS 与 Windows 双平台开箱即用，完整保留原片画质、真实拍摄设备型号、时间戳与 iPhone 相册原生交互体验。

</div>

## 核心特性

- **Apple Live Photo 原生 `.HEIC + .MOV` 实况合成**
  - 自动从原视频 `1.5s` 处抽取中间帧编码为单帧 `HEVC Main Profile (hvc1)`，由纯 Dart 引擎封装为符合 ISO/IEC 23008-12 标准的原生 `.HEIC` 静态封面（`<文件名>I.HEIC`），配合零重编码重封装的 `.MOV` 动态轨（`<文件名>I.MOV`）。
  - **支持 iPhone 相册滑动自动播放（Vitality）**：内置 `LivePhotoAuto` 与 `VitalityScore` 元数据及完整 Apple `MakerNote`（`ContentIdentifier`、`RunTime`、`AccelerationVector`、`PhotoIdentifier`、`MediaGroupUUID`），在 iPhone 相册左右滑动时即可自动丝滑播放动态效果，无需长按。
  - **支持 iPhone 相册「编辑」任意重选封面帧**：在 `.MOV` 中由纯 Dart 原生构建并注入 `com.apple.quicktime.still-image-time`（`mebx`）定时元数据轨道及 `tref -> cdsc` 关联引用，完美激活 iOS 系统相册底部的「设为主要照片」逐帧选封面滑块。
  - **完美兼容大疆 Mimo 二次编辑**：将 `still-image-time` 轨道时间锚点精准对齐至 `1.5s` 封面帧，通过大疆 Mimo 套滤镜或调色二次导出后封面不会跳回第 0 秒首帧，且二次导出后依然支持在 iPhone 相册中重选封面帧。

- **Google Motion Photo 单文件动态照片**
  - 采用 MicroVideo XMP + GCamera 标准规范，将封面图与原 MP4 视频流无损拼接为单张 `.jpg` 文件。
  - 原生兼容 Google 相册、小米、OPPO、vivo、一加、三星、华为等主流 Android 机型相册。

- **实况 / 视频 / 照片全类型分类导出**
  - **实况模式**：左下方可切换导出为「Apple 实况 (`.HEIC+.MOV`)」或「Google 动态图 (`.jpg`)」，自动归档至导出目录下的 **`live/`** 文件夹。
  - **视频模式**：左侧面板自动切换为「导出视频」，将选中的原片 `.MP4` 无损复制归档至导出目录下的 **`movie/`** 文件夹，并完整保留拍摄创建时间与修改时间。
  - **照片模式**：左侧面板自动切换为「导出照片」，将选中的原片 `.JPG` 无损复制归档至导出目录下的 **`photo/`** 文件夹，并完整保留原图时间属性。

- **自动抓取源文件真实设备信息**
  - 纯 Dart 引擎直接解析源 `.MP4` 容器中的 QuickTime 元数据原子与大疆固件签名，自动提取真实拍摄设备品牌与型号——覆盖 Osmo Pocket 全系列（如 `DJI OsmoPocket3` / `DJI OsmoPocket4P`）、原始拍摄时间及时区信息。
  - 导出的 Apple `.HEIC`、`.MOV` 以及 Google `.jpg` 均写入真实相机型号与拍摄时间，绝不写死虚拟手机型号。

- **纯 Dart 元数据与容器引擎 + 独立内置 FFmpeg 动态库（彻底兼容全系统与中文路径）**
  - 移除对外部 `exiftool` / Perl 进程的依赖，所有 `.HEIC` 容器组装、TIFF/EXIF/MakerNote 构造、XMP 注入与 `.MOV` 定时元数据轨道写入均由纯 Dart 内存级完成。
  - macOS 安装包已将 `ffmpeg` 及其所有底层 `.dylib` 动态库完整内置至 `Contents/Resources/lib/` 并完成 `@executable_path` 重定向签名，**无需用户电脑安装 Homebrew 或任何依赖库**，彻底杜绝在其他 Mac（如 macOS 26.6.2）上出现 `dyld: Library not loaded` 报错，且 100% 兼容包含中文、空格或特殊符号的文件夹路径。

- **Shift 区间连选 & 目录记忆**
  - **Shift 快捷多选**：点击任意卡片作为起点，按住键盘 `Shift` 键再点击目标卡片，即可一键选中或取消头尾之间的全部素材；点击顶部「刷新」按钮时自动清空已选状态。
  - **智能目录记忆**：自动记住上次选择的「素材源目录」与「导出位置」，下次启动软件直接恢复，无需重复选择。
  - **智能实况识别**：自动识别时长 `≤ 4.0s` 的短片为「实况」素材并归入「实况」标签页。

## 系统支持与安装

可在项目的 [**Releases**](../../releases) 页面直接下载对应系统的最新打包版本：

| 平台 | 架构要求 | 安装包格式 | 内置组件说明 |
| :--- | :--- | :--- | :--- |
| **macOS** | Apple Silicon / Intel (macOS 11.0+) | `Pocket-Motion-macOS-v*.dmg` | 已完整内置 `ffmpeg` 及全套依赖 `.dylib`，拖拽至 `Applications` 即可脱机运行 |
| **Windows** | Windows 10 / 11 (64-bit x86_64) | `Pocket-Motion-Windows-v*.zip` | 已内置 `ffmpeg.exe`，解压后双击 `Pocket Motion.exe` 即可运行 |

> **macOS 首次打开提示**：若系统提示“无法验证开发者”，请在终端执行以下命令放行，或在「系统设置 → 隐私与安全性」中点击“仍要打开”：
> ```bash
> xattr -cr "/Applications/Pocket Motion.app"
> ```

## 使用指南

1. **连接素材源**
   - 插入 DJI Osmo Pocket 系列相机的 SD 卡（如 Osmo Pocket 3 / 4，或将相机通过 USB-C 连接电脑），软件会自动扫描挂载的卷并定位 `DCIM` 目录；也可点击左侧 **「素材源目录 → 选择…」** 手动指定任意本地文件夹（路径会自动保存）。
2. **筛选与多选素材**
   - 在顶部标签栏切换 **「实况」**（`≤ 4.0s` 短视频）、**「视频」** 或 **「照片」**。
   - 单击卡片可逐个勾选；选中第一个素材后，**按住 `Shift` 键点击末尾素材**即可快速选中整段区间；也可点击右上角 **「全选当前」**。
3. **设置导出目录与开始导出**
   - 在左侧 **「导出位置」** 选择保存目录（同样会自动记忆）。
   - 若当前在 **「实况」** 标签页，可在左下角选择 **「Apple 实况 (.HEIC+.MOV)」** 或 **「Google 动态图 (.jpg)」**。
   - 点击右下角导出按钮，导出的文件将自动按类型归类存放至导出目录下的子文件夹中：
     - 实况照片：`导出目录/live/`
     - 视频文件：`导出目录/movie/`
     - 照片文件：`导出目录/photo/`
4. **导入手机相册**
   - **iPhone / iPad / Mac 用户**：将 `live/` 目录下配对的 `<文件名>I.HEIC` 与 `<文件名>I.MOV` **同时选中**，通过 AirDrop（隔空投送）发送至 iPhone，或直接拖入 macOS「照片 (Photos.app)」图库，即可自动合并为支持滑动自动播放、编辑重选封面帧的原生 Live Photo。
   - **Android 用户**：将 `live/` 目录下生成的 `.jpg` 文件直接发送到手机，在系统相册或 Google 相册中打开即可播放动态照片。

## 开发者本地构建

### 环境要求
- Flutter SDK `>= 3.24.0`（Dart `>= 3.4.0`）
- **macOS 开发环境**：Xcode 15+，本地调试可安装 `brew install ffmpeg`
- **Windows 开发环境**：Visual Studio 2022（含“使用 C++ 的桌面开发”工作负载）

### 常用命令

```bash
# 1. 获取依赖
flutter pub get

# 2. 代码静态检查
flutter analyze

# 3. 本地运行调试 (macOS)
flutter run -d macos

# 4. 本地运行调试 (Windows)
flutter run -d windows

# 5. 构建 Release 正式版
flutter build macos --release
flutter build windows --release
```

## 项目目录结构

```text
Pocket-Motion/
├── .github/workflows/
│   └── release.yml                # GitHub Actions 双平台自动构建与动态库打包流水线
├── lib/
│   ├── main.dart                  # Flutter 桌面端主界面（Shift 连选、目录记忆、三模式导出）
│   └── src/
│       ├── dcim_scanner.dart      # SD 卡与 DCIM 目录媒体扫描器（自动识别 ≤4.0s 实况素材）
│       ├── live_photo_exporter.dart   # Apple Live Photo (.HEIC + .MOV) 导出器
│       ├── motion_photo_exporter.dart # Google Motion Photo (.jpg) 导出器
│       ├── media_metadata.dart    # 纯 Dart 媒体元数据与原生 HEIC / MOV still-image-time 引擎
│       ├── models.dart            # 媒体资产数据模型与格式化工具
│       └── tool_path.dart         # 跨平台内置工具路径解析器
├── macos/                         # macOS 原生工程配置与应用图标
├── windows/                       # Windows 原生工程配置、应用图标与版本资源
└── pubspec.yaml                   # Flutter 依赖与版本配置 (v2.1.1)
```

## 开源协议

本项目基于 [MIT License](LICENSE) 开源发布。
