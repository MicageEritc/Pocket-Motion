import 'dart:io';
import 'package:path/path.dart' as p;
import 'models.dart';
import 'tool_path.dart';

/// Apple Live Photo 导出器。
///
/// 流程（已用真机验证）：
/// 1. ffmpeg 抽原 MP4 中间帧为 JPG；
/// 2. 原 MP4 不重编码，直接复制为 .MOV；
/// 3. exiftool 给 JPG 写拍摄时间 + Apple MakerNote ContentIdentifier；
/// 4. exiftool 给 MOV 写拍摄时间 + Keys ContentIdentifier；
/// 两端 UUID 一致，iPhone 相册即识别为一组实况。
///
/// 依赖：系统 ffmpeg、exiftool（自用桌面工具直接调用）。
class LivePhotoExporter {
  final String? seedJpgPath; // 带 Apple MakerNote 的种子 JPG
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
    final shotStr = _exifTime(asset.shotAt);

    // 1) 抽中间帧（实况约3秒，中点取1.5s）
    _log('抽帧: $base');
    await _run('ffmpeg', [
      '-y', '-ss', '1.5', '-i', asset.path,
      '-frames:v', '1', '-q:v', '2', '-update', '1', outJpg,
    ]);

    // 2) 原 MP4 复制为 MOV（零重编码）
    File(asset.path).copySync(outMov);

    // 3) JPG：先从种子复制 Apple MakerNote 结构，再写时间和 UUID
    if (seedJpgPath != null && File(seedJpgPath!).existsSync()) {
      await _run('exiftool', [
        '-overwrite_original', '-tagsfromfile', seedJpgPath!,
        '-Apple:all=', outJpg,
      ]);
    }
    await _run('exiftool', [
      '-overwrite_original', '-api', 'QuickTimeUTC=1',
      '-Apple:ContentIdentifier=$uuid',
      if (shotStr != null) ...[
        '-DateTimeOriginal=$shotStr',
        '-DateTimeDigitized=$shotStr',
        '-DateTime=$shotStr',
      ],
      '-Model=DJI OsmoPocket4P',
      outJpg,
    ]);

    // 4) MOV：写时间和 UUID
    await _run('exiftool', [
      '-overwrite_original', '-api', 'QuickTimeUTC=1',
      if (shotStr != null) ...[
        '-CreateDate=$shotStr',
        '-ModifyDate=$shotStr',
        '-TrackCreateDate=$shotStr',
        '-MediaCreateDate=$shotStr',
      ],
      '-Keys:ContentIdentifier=$uuid',
      outMov,
    ]);

    // 5) 文件系统时间归位
    if (asset.shotAt != null) {
      final ts = asset.shotAt!.millisecondsSinceEpoch ~/ 1000;
      for (final p in [outJpg, outMov]) {
        await _run('SetFile', ['-d', _macTime(asset.shotAt!), p]);
        // utime 兜底
        try {
          final f = File(p);
          await f.setLastModified(asset.shotAt!);
        } catch (_) {}
      }
    }

    _log('完成: $base  (UUID $uuid)');
    return (outJpg, outMov);
  }

  static String _newUuid() {
    // 简单 UUID v4，大写带连字符
    final r = _randomBytes(16);
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

  static List<int> _randomBytes(int n) {
    // 不引入 crypto 包，用 DateTime 做轻量随机
    final r = List<int>.generate(n, (_) {
      return DateTime.now().microsecondsSinceEpoch.remainder(256);
    });
    return r;
  }

  static String? _exifTime(DateTime? dt) => dt == null
      ? null
      : '${dt.year.toString().padLeft(4, '0')}:'
          '${dt.month.toString().padLeft(2, '0')}:'
          '${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}:'
          '${dt.second.toString().padLeft(2, '0')}';

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
