# Pocket Motion

开源的大疆 Osmo Pocket 4P 实况照片（Live Photo / Motion Photo）整理与无损导出桌面工具，支持 **macOS** 与 **Windows**。

## 解决什么痛点

大疆 Osmo Pocket 4P 拍摄的「实况照片」在存储卡内是一段约 3 秒的 `.MP4` 视频，内部保留着真实的拍摄时间与相机设备信息。  
但如果通过手机 Mimo 导出为实况照片，往往会出现以下问题：

- **拍摄时间丢失或被篡改**：导出的静态图 `.JPG` 拍摄时间被清空，或视频 `.MOV` 的创建时间被刷成导出当天的时刻；
- **脱离手机相册后无法配对**：备份到 NAS（群晖 Synology Photos、Immich、MT Photos 等）或导入电脑相册时，时间线全部错乱，或无法识别为动态实况照片。

**Pocket Motion** 直接读取相机 SD 卡或本地备份目录中的原始素材，自动识别实况照片并完成导出，**完整保留原始拍摄时间戳与相机设备信息（`DJI` / `DJI OsmoPocket4P`）**，且源文件不会被修改。

## 核心特性

- **精准识别实况素材**：扫描文件前部 512 KB 的私有数据轨模板标识（`TPLG_VIDEO_LIVEPHOTO_*`），毫秒级区分「实况照片」、「普通视频」与「静态照片」。
- **双平台实况格式支持**：
  - **Apple 实况照片（`.JPG` + `.MOV`）**：抽帧生成静态 `.JPG` 并注入标准 Apple iOS MakerNote（`0x0011 ContentIdentifier`），同时对 `.MOV` 零重编码写入配对 `Keys:ContentIdentifier` UUID 与轨道时间戳，导入 iPhone / macOS「照片」App 及主流 NAS 相册即可自动合并为一张实况照片。
  - **Android / Google 动态照片（单文件 `.jpg`）**：抽帧并在 JPEG 头部写入标准 EXIF 与 Google `GCamera:MotionPhoto` Container XMP 目录，尾部内嵌原始 MP4 视频流，兼容 Google Photos 与主流 Android 相册。
- **纯 Dart 原生二进制元数据引擎**：直接从源 `.MP4` 的 `moov` 原子解析真实设备品牌（`Make`）、型号（`Model`）、拍摄时间与 GPS 信息，并以纯 Dart 构造大端序 TIFF/EXIF `APP1` 段与 QuickTime `mdta` 元数据原子，完美支持中英文路径与 NAS 挂载盘。
- **开箱即用，零环境配置**：macOS 与 Windows 发行版均已内置所需工具链，下载解压即可直接运行，无需手动安装任何命令行依赖。
- **自动记忆目录**：自动保存上次选择的「素材来源」与「导出位置」，下次打开无需重复选择。

## 下载与安装

前往 [Releases](../../releases) 页面下载对应系统的最新版本：

- **macOS**：下载 `PocketMotion-macOS.dmg`，打开后将 `Pocket Motion.app` 拖入 `Applications` 即可。
  - 若首次打开提示未验证开发者，可在「访达」中右键点击应用选择「打开」，或在终端执行：
    ```bash
    xattr -cr "/Applications/Pocket Motion.app"
    ```
- **Windows**：下载 `PocketMotion-windows.zip`，解压到任意目录，双击运行 `PocketMotion.exe`（窗口与任务栏显示名称为 **Pocket Motion**）。

## 使用方法

1. **选择素材来源**：点击左侧「素材来源」卡片右侧的 **更改**，选择相机 SD 卡目录（如 `DCIM/DJI_001`）或本地素材文件夹，程序会自动扫描并筛选出所有可转换的实况素材。
2. **选择导出位置**：点击「导出位置」卡片右侧的 **更改**，指定导出文件保存的文件夹（路径会自动记忆）。
3. **勾选并导出**：可单选或点击 **全选** 勾选需要转换的实况素材，点击左侧：
   - **导出为 Apple 实况照片**：在导出目录生成同名配对的 `<文件名>I.JPG` + `<文件名>I.MOV`；
   - **导出为 Android 动态照片**：在导出目录生成单文件动态照片 `<文件名>A.jpg`。

## 导出格式对比

| 导出格式 | 产物文件 | 写入的元数据 | 适用平台与相册 |
| :--- | :--- | :--- | :--- |
| **Apple Live Photo** | `<名>I.JPG` + `<名>I.MOV` | `Make=DJI`、`Model=DJI OsmoPocket4P`、原始拍摄时间（EXIF + QuickTime `mvhd`/`tkhd`/`mdhd`）、配对 `ContentIdentifier` UUID | iPhone / iPad / macOS 系统相册、绿联云、极空间、群晖 Synology Photos、Immich、MT Photos 等 |
| **Google Motion Photo** | `<名>A.jpg`（单文件内嵌视频） | `Make=DJI`、`Model=DJI OsmoPocket4P`、原始拍摄时间、`GCamera:MotionPhoto` XMP 容器描述 | Google Photos、小米 / OPPO / vivo / 三星等主流 Android 相册及支持动态照片的 NAS |

## 从源码构建

本地开发与调试需安装 [Flutter SDK](https://docs.flutter.dev/get-started/install)（`^3.13.0`）以及系统的 `ffmpeg`（开发环境下若未打包内置二进制，程序会自动回退调用系统 PATH 中的 `ffmpeg`）：

```bash
# 获取依赖
flutter pub get

# 调试运行
flutter run -d macos     # macOS
flutter run -d windows   # Windows

# 构建发行包
flutter build macos --release
flutter build windows --release
```

## 项目目录结构

```text
lib/
  main.dart                     # 主界面 UI、素材筛选与目录持久化配置
  src/
    models.dart                 # MediaAsset 媒体资产模型与规格解析
    media_scanner.dart          # 目录扫描 + TPLG_VIDEO_LIVEPHOTO 实况特征识别
    media_metadata.dart         # 纯 Dart MP4 设备信息提取、TIFF/EXIF 与 QuickTime MOV 原子读写引擎
    live_photo_exporter.dart    # Apple Live Photo (JPG + MOV) 导出器
    motion_photo_exporter.dart  # Google / Android Motion Photo (单文件 JPG) 导出器
    thumbnail_image.dart        # 视频帧缩略图懒加载与本地缓存
    tool_path.dart              # 跨平台内置工具路径解析（优先使用应用内置二进制）
```

## 免责声明

本工具仅对用户自行拍摄、存储在相机或本地磁盘中的原始素材文件进行读取与格式封装，用于解决实况照片导出后拍摄时间丢失与跨平台兼容问题。

- 本工具仅以只读方式读取源素材文件，绝不修改或删除相机内的任何原始文件；
- 本工具不对任何第三方 App 或固件进行反编译、逆向工程或破解；
- 文中提及的 "DJI"、"Osmo Pocket"、"Apple"、"Google" 等名称仅用于说明设备与格式兼容性，相关商标归各自所有者所有；
- 用户需对自己拍摄的素材数据及导出结果自行负责。
