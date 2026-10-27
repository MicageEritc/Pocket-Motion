import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'models.dart';
import 'tool_path.dart';

/// Apple Live Photo 导出器。
///
/// 流程（已用真机验证）：
/// 1. ffmpeg 抽原 MP4 中间帧为 JPG；
/// 2. 原 MP4 不重编码，直接复制为 .MOV；
/// 3. 构造最小 Apple iOS MakerNote（含 0x0011 ContentIdentifier），由 exiftool 写入 JPG 的 Apple MakerNote 与拍摄时间；
/// 4. exiftool 给 MOV 写拍摄时间 + Keys:ContentIdentifier；
/// 两端 UUID 一致，iPhone / macOS 相册与 NAS（群晖 Synology Photos / Immich 等）即识别为一组实况。
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
    final tmpMakerNote = p.join(outDir, '.$base.makernote.bin');
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

    // 3) JPG：直接注入内置构造的最小 Apple MakerNote（含 ContentIdentifier = uuid），无需外部种子 JPG
    await File(tmpMakerNote).writeAsBytes(_buildAppleMakerNote(uuid));
    try {
      await _run('exiftool', [
        '-overwrite_original',
        '-api', 'QuickTimeUTC=1',
        '-MakerNoteApple<=$tmpMakerNote',
        '-Make=Apple',
        '-Model=DJI OsmoPocket4P',
        if (shotStr != null) ...[
          '-DateTimeOriginal=$shotStr',
          '-DateTimeDigitized=$shotStr',
          '-DateTime=$shotStr',
        ],
        outJpg,
      ]);
    } finally {
      try {
        File(tmpMakerNote).deleteSync();
      } catch (_) {}
    }

    // 4) MOV：写时间和 UUID
    await _run('exiftool', [
      '-overwrite_original',
      '-api', 'QuickTimeUTC=1',
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
      for (final filePath in [outJpg, outMov]) {
        if (Platform.isMacOS) {
          await _run('SetFile', ['-d', _macTime(asset.shotAt!), filePath]);
        }
        // utime 兜底
        try {
          final f = File(filePath);
          await f.setLastModified(asset.shotAt!);
        } catch (_) {}
      }
    }

    _log('完成: $base  (UUID $uuid)');
    return (outJpg, outMov);
  }

  /// 构造包含 Tag 0x0011 (ContentIdentifier) 的最小 Apple iOS MakerNote 二进制块（70 字节）。
  ///
  /// 结构：
  /// - 0..13 (14B): "Apple iOS\0\0\x01MM" (大端序 Apple MakerNote 头)
  /// - 14..15 (2B): 0x0001 (1 个 IFD 条目)
  /// - 16..27 (12B): Tag=0x0011, Type=2(ASCII), Count=37, ValueOffset=32(0x00000020)
  /// - 28..31 (4B): 0x00000000 (Next IFD offset)
  /// - 32..69 (38B): 36 字节 UUID 字符串 + "\0\0"
  static Uint8List _buildAppleMakerNote(String uuid) {
    final b = BytesBuilder();
    // "Apple iOS\0\0\x01MM"
    b.add([
      0x41, 0x70, 0x70, 0x6C, 0x65, 0x20, 0x69, 0x4F, 0x53, 0x00,
      0x00, 0x01, 0x4D, 0x4D,
    ]);
    // Entry count = 1, Tag = 0x0011, Type = 2 (ASCII), Count = 37, Offset = 32, NextIFD = 0
    b.add([
      0x00, 0x01,
      0x00, 0x11,
      0x00, 0x02,
      0x00, 0x00, 0x00, 0x25,
      0x00, 0x00, 0x00, 0x20,
      0x00, 0x00, 0x00, 0x00,
    ]);
    b.add(uuid.codeUnits);
    b.add([0x00, 0x00]);
    return b.toBytes();
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
