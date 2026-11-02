import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'media_metadata.dart';
import 'models.dart';
import 'tool_path.dart';

/// Apple Live Photo 导出器。
///
/// 流程（纯 Dart 写入 EXIF / MakerNote / QuickTime MOV 定时元数据轨，不依赖外部 exiftool / Perl 进程）：
/// 1. 从源 MP4 解析设备品牌/型号（如 DJI / DJI OsmoPocket4P）与拍摄时间；
/// 2. ffmpeg 抽原 MP4 1.5s 中间帧为 JPG，并将原 MP4 无损重封装为纯净 QuickTime MOV 容器（剔除私有 dbgi 轨）；
/// 3. 纯 Dart 向 JPG 注入标准 TIFF/EXIF APP1 段（Make、Model、拍摄时间、宽高 + Apple MakerNote ContentIdentifier / RunTime / AccelerationVector / LivePhotoVideoIndex）；
/// 4. 纯 Dart 向 .MOV 注入 com.apple.quicktime.still-image-time (mebx) 定时元数据轨与 QuickTime mdta 元数据；
/// 支持 iPhone 相册滑动自动播放、相册编辑自由更换封面帧，以及大疆 Mimo 二次编辑封面不跳帧。
class LivePhotoExporter {
  final String? seedJpgPath;
  final void Function(String log)? onLog;

  LivePhotoExporter({this.seedJpgPath, this.onLog});

  void _log(String s) {
    onLog?.call(s);
    stdout.writeln(s);
  }

  Future<(String jpg, String mov)> export({
    required MediaAsset asset,
    required String outDir,
  }) async {
    final base = asset.filename.replaceAll(RegExp(r'\.[^.]+$'), '') + 'I';
    final outJpg = p.join(outDir, '$base.JPG');
    final outMov = p.join(outDir, '$base.MOV');
    final tmpRemuxMov = p.join(outDir, '.$base.remux.mov');
    await Directory(outDir).create(recursive: true);

    final uuid = _newUuid();
    final mp4Info = await MediaMetadata.extractFromMp4(asset.path);
    final shotAt = asset.shotAt ?? mp4Info.creationTime;

    // 1) 抽中间帧（实况约3秒，中点取1.5s）
    _log('抽帧: $base (${mp4Info.make} ${mp4Info.model})');
    await _run('ffmpeg', [
      '-y', '-ss', '1.5', '-i', asset.path,
      '-frames:v', '1', '-q:v', '2', '-update', '1', outJpg,
    ]);

    // 2) 纯 Dart 向 JPG 写入 EXIF（设备品牌/型号、拍摄时间、宽高）与完整 Apple MakerNote
    final rawJpg = await File(outJpg).readAsBytes();
    final dims = MediaMetadata.extractJpegDimensions(rawJpg);
    final exifApp1 = MediaMetadata.buildExifApp1Segment(
      make: mp4Info.make,
      model: mp4Info.model,
      shotAt: shotAt,
      livePhotoUuid: uuid,
      imageWidth: dims?.$1,
      imageHeight: dims?.$2,
    );
    final patchedJpg = MediaMetadata.injectIntoJpeg(rawJpg, [exifApp1]);
    await File(outJpg).writeAsBytes(patchedJpg);

    // 3) 先用 ffmpeg 零重编码重封装为标准 QuickTime MOV（仅保留视频轨与音频轨，清理相机私有数据轨）
    await _run('ffmpeg', [
      '-y',
      '-i', asset.path,
      '-map', '0:v:0',
      '-map', '0:a?',
      '-c', 'copy',
      '-f', 'mov',
      tmpRemuxMov,
    ]);
    final movSourcePath = File(tmpRemuxMov).existsSync() ? tmpRemuxMov : asset.path;

    // 4) 纯 Dart 生成最终 MOV：写入 still-image-time 定时元数据轨、QuickTime Keys:ContentIdentifier、设备信息与轨道时间戳
    try {
      await MediaMetadata.writeMovLivePhotoMetadata(
        srcMp4Path: movSourcePath,
        outMovPath: outMov,
        uuid: uuid,
        make: mp4Info.make,
        model: mp4Info.model,
        shotAt: shotAt,
        coverTimeSeconds: 1.5,
      );
    } finally {
      try {
        if (File(tmpRemuxMov).existsSync()) {
          File(tmpRemuxMov).deleteSync();
        }
      } catch (_) {}
    }

    // 5) 文件系统时间归位
    if (shotAt != null) {
      for (final filePath in [outJpg, outMov]) {
        if (Platform.isMacOS) {
          await _run('SetFile', ['-d', _macTime(shotAt), filePath]);
        }
        try {
          final f = File(filePath);
          await f.setLastModified(shotAt);
        } catch (_) {}
      }
    }

    _log('完成: $base  (UUID $uuid)');
    return (outJpg, outMov);
  }

  static final Random _rng = Random();

  static String _newUuid() {
    final r = List<int>.generate(16, (_) => _rng.nextInt(256));
    r[6] = (r[6] & 0x0f) | 0x40;
    r[8] = (r[8] & 0x3f) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    return [
      for (var i = 0; i < 4; i++) hex(r[i]),
      '-',
      hex(r[4]), hex(r[5]), '-',
      hex(r[6]), hex(r[7]), '-',
      hex(r[8]), hex(r[9]), '-',
      for (var i = 10; i < 16; i++) hex(r[i]),
    ].join().toUpperCase();
  }

  static String _macTime(DateTime dt) =>
      '${dt.month.toString().padLeft(2, '0')}/'
      '${dt.day.toString().padLeft(2, '0')}/'
      '${dt.year} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';

  Future<void> _run(String exe, List<String> args) async {
    final p = await Process.run(ToolPath.find(exe), args);
    if (p.exitCode != 0) {
      _log('  !! $exe 失败: ${p.stderr}');
    }
  }
}
