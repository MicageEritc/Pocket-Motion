# Pocket Motion

开源的大疆 Osmo Pocket 4P 实况照片整理与导出工具（Flutter 桌面，macOS / Windows）。

## 它解决什么问题

大疆 Pocket 4P 的「实况照片」源文件是一段约 3 秒的 MP4，机内带着真实拍摄时间。
但通过手机 App 导出成 iOS 实况时，会抽帧成 JPG、把 MP4 转成 MOV 并写入配对 UUID，
**同时把 JPG 的拍摄时间清空、把 MOV 时间刷成导出那一刻**。

结果脱离手机相册后，传到 NAS / 别的设备，时间就全错了。
Pocket Motion 直接读相机里的原始 MP4，自己识别实况、自己导出，**保留真实拍摄时间**。

## 识别原理

相机在 MP4 的私有数据轨里写入了拍摄配置模板字符串，例如：

- 实况：`TPLG_VIDEO_LIVEPHOTO_4K_16X9_2997_KA`（含 `LIVEPHOTO`）
- 普通视频：`TPLG_VIDEO_4K_16X9_5994_KA`（不含）

程序扫描文件前部 512KB，命中 `TPLG_VIDEO_LIVEPHOTO` 即判为实况。
在 166 个真机文件上实测：136 个实况 / 30 个视频，零误判。

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

## 声明

本工具仅对用户自行拍摄、存储在相机中的原始素材文件进行读取和再封装，
用于解决导出后拍摄时间丢失的问题。

- 本工具不修改相机内的任何原始文件；
- 本工具不对任何第三方 App 或软件进行反编译、逆向工程或破解；
- "DJI"、"Osmo Pocket" 等名称仅为设备识别用途，商标归大疆创新所有；
- 用户对自己拍摄的素材和导出结果自行负责。
