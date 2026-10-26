# Pocket Motion

开源的大疆 Osmo Pocket 4P 实况照片整理与导出工具（Flutter 桌面，macOS / Windows）。

## 它解决什么问题

大疆 Pocket 4P 的「实况照片」源文件是一段约 3 秒的 MP4，机内带着真实拍摄时间。
但用 DJI Mimo 导出成 iOS 实况时，Mimo 会抽帧成 JPG、把 MP4 转成 MOV 并写入配对 UUID，
**同时把 JPG 的 EXIF 拍摄时间清空、把 MOV 时间刷成导出那一刻**。

结果脱离 iPhone 相册后，传到 NAS / 别的设备，时间就全错了。
Pocket Motion 直接读相机里的原始 MP4，自己识别实况、自己导出，**保留真实拍摄时间**。

## 下载

在 [Releases](../../releases) 下载：
- **macOS**：`PocketMotion-macOS.dmg`，拖进 Applications（未签名，首次右键→打开）
- **Windows**：`PocketMotion-windows.zip`，解压后运行 `dji_live_gallery.exe`

## 运行依赖

程序调用系统命令行工具完成抽帧和元数据写入，需先安装：

- macOS：`brew install ffmpeg exiftool`
- Windows：安装 [ffmpeg](https://ffmpeg.org/) 和 [exiftool](https://exiftool.org/) 并加入 PATH

## 从源码构建

```bash
flutter pub get
flutter run -d macos   # 或 flutter run -d windows
```

## 核心原理（已逆向验证）

相机在 MP4 的 dbgi 私有数据轨写入拍摄配置模板：

- 实况：`TPLG_VIDEO_LIVEPHOTO_4K_16X9_2997_KA`（含 `LIVEPHOTO`）
- 普通视频：`TPLG_VIDEO_4K_16X9_5994_KA`（不含）

程序扫描文件前部 512KB，命中 `TPLG_VIDEO_LIVEPHOTO` 即判为实况。
在 166 个真机文件上实测：136 个实况 / 30 个视频，零误判。

## 导出格式

| 格式 | 产物 | 适用 |
|---|---|---|
| Apple Live Photo | `<名>I.JPG` + `<名>I.MOV`（配对 UUID 一致） | iPhone 相册 |
| Google Motion Photo | `<名>A.jpg`（JPG 内嵌 MP4 + Container XMP） | Google Photos / Android |

两种格式都写回真实拍摄时间（从文件名 `DJI_YYYYMMDDHHMMSS` 解析）和 `Make=DJI / Model=DJI OsmoPocket4P`。

## 目录结构

```
lib/
  main.dart                     # UI
  src/
    models.dart                 # MediaAsset 模型
    media_scanner.dart          # 扫描 + LIVEPHOTO 识别
    live_photo_exporter.dart    # Apple Live 导出
    motion_photo_exporter.dart  # Google Motion Photo 导出
    thumbnail_image.dart        # 视频缩略图
```
