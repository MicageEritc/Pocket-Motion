import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'media_metadata.dart';
import 'models.dart';
import 'tool_path.dart';

/// Apple Live Photo 导出器（原生 .HEIC + .MOV）。
///
/// 流程（纯 Dart 封装 .HEIC 与 .MOV 定时元数据轨，不依赖外部 exiftool / Perl 进程）：
/// 1. 从源 MP4 解析设备品牌/型号（如 DJI / DJI OsmoPocket4P）与拍摄时间；
/// 2. ffmpeg 抽取原 MP4 1.5s 中间帧编码为单帧 HEVC (hvc1)，由纯 Dart 封装为标准 ISO/IEC 23008-12 原生 .HEIC 文件并写入完整 EXIF 与 Apple MakerNote；
/// 3. ffmpeg 将原 MP4 无损重封装为纯净 QuickTime MOV 容器（剔除私有 dbgi 轨）；
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

  Future<(String heic, String mov)> export({
    required MediaAsset asset,
    required String outDir,
  }) async {
    final base = asset.filename.replaceAll(RegExp(r'\.[^.]+$'), '') + 'I';
    final outHeic = p.join(outDir, '$base.HEIC');
    final outMov = p.join(outDir, '$base.MOV');
    final tmpHevcMp4 = p.join(outDir, '.$base.hevc_frame.mp4');
    final tmpRemuxMov = p.join(outDir, '.$base.remux.mov');
    await Directory(outDir).create(recursive: true);

    final uuid = _newUuid();
    final mp4Info = await MediaMetadata.extractFromMp4(asset.path);
    final shotAt = asset.shotAt ?? mp4Info.creationTime;
    final deviceLabel = mp4Info.model.toUpperCase().startsWith(mp4Info.make.toUpperCase())
        ? mp4Info.model
        : '${mp4Info.make} ${mp4Info.model}';

    // 1) 抽取 1.5s 中间帧编码为单帧 HEVC (hvc1)，并由纯 Dart 封装为带完整 EXIF + Apple MakerNote 的原生 .HEIC
    _log('生成原生 HEIC 封面: $base ($deviceLabel)');
    try {
      await _run('ffmpeg', [
        '-y',
        '-ss', '1.5',
        '-i', asset.path,
        '-frames:v', '1',
        '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2',
        '-c:v', 'libx265',
        '-preset', 'fast',
        '-crf', '16',
        '-x265-params', 'log-level=error:keyint=1:bframes=0:ref=1',
        '-pix_fmt', 'yuv420p',
        '-tag:v', 'hvc1',
        tmpHevcMp4,
      ], mustSucceed: true);

      await MediaMetadata.buildHeicFromHevcMp4(
        hevcMp4Path: tmpHevcMp4,
        outHeicPath: outHeic,
        make: mp4Info.make,
        model: mp4Info.model,
        uuid: uuid,
        shotAt: shotAt,
      );
    } finally {
      try {
        if (File(tmpHevcMp4).existsSync()) {
          File(tmpHevcMp4).deleteSync();
        }
      } catch (_) {}
    }

    // 2) 先用 ffmpeg 零重编码重封装为标准 QuickTime MOV（仅保留视频轨与音频轨，清理相机私有数据轨）
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

    // 3) 纯 Dart 生成最终 MOV：写入 still-image-time 定时元数据轨、QuickTime Keys:ContentIdentifier、设备信息与轨道时间戳
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

    // 4) 文件系统时间归位
    if (shotAt != null) {
      for (final filePath in [outHeic, outMov]) {
        if (Platform.isMacOS) {
          await _run('SetFile', ['-d', _macTime(shotAt), filePath]);
        }
        try {
          final f = File(filePath);
          await f.setLastModified(shotAt);
        } catch (_) {}
      }
    }

    _log('完成: $base.HEIC + $base.MOV (UUID $uuid)');
    return (outHeic, outMov);
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

  Future<void> _run(String exe, List<String> args, {bool mustSucceed = false}) async {
    final p = await Process.run(ToolPath.find(exe), args);
    if (p.exitCode != 0) {
      _log('  !! $exe 失败: ${p.stderr}');
      if (mustSucceed) {
        throw Exception('$exe 执行失败 (exit ${p.exitCode})');
      }
    }
  }
}
