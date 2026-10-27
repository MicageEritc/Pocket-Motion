import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'media_metadata.dart';
import 'models.dart';
import 'tool_path.dart';

/// Apple Live Photo 导出器。
///
/// 流程（纯 Dart 写入 EXIF / MakerNote / QuickTime MOV 元数据，不依赖外部 exiftool / Perl 进程）：
/// 1. 从源 MP4 解析设备品牌/型号（如 DJI / DJI OsmoPocket4P）与拍摄时间；
/// 2. ffmpeg 抽原 MP4 中间帧为 JPG；
/// 3. 纯 Dart 向 JPG 注入标准 TIFF/EXIF APP1 段（Make、Model、拍摄时间 + Apple iOS MakerNote 0x0011 ContentIdentifier）；
/// 4. 纯 Dart 生成 .MOV，更新 moov 内 mvhd/tkhd/mdhd 时间戳并注入 QuickTime mdta (Keys:ContentIdentifier / Make / Model / CreationDate)；
/// 两端 UUID 一致，iPhone / macOS 相册与 NAS（群晖 Synology Photos / Immich 等）即识别为一组动态实况照片。
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

    // 2) 纯 Dart 向 JPG 写入 EXIF（设备品牌/型号、拍摄时间）与 Apple MakerNote (ContentIdentifier = uuid)
    final rawJpg = await File(outJpg).readAsBytes();
    final exifApp1 = MediaMetadata.buildExifApp1Segment(
      make: mp4Info.make,
      model: mp4Info.model,
      shotAt: shotAt,
      livePhotoUuid: uuid,
    );
    final patchedJpg = MediaMetadata.injectIntoJpeg(rawJpg, [exifApp1]);
    await File(outJpg).writeAsBytes(patchedJpg);

    // 3) 纯 Dart 生成 MOV 并写入 QuickTime Keys:ContentIdentifier、设备信息与轨道时间戳
    await MediaMetadata.writeMovLivePhotoMetadata(
      srcMp4Path: asset.path,
      outMovPath: outMov,
      uuid: uuid,
      make: mp4Info.make,
      model: mp4Info.model,
      shotAt: shotAt,
    );

    // 4) 文件系统时间归位
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
    // 标准 UUID v4，大写带连字符
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
