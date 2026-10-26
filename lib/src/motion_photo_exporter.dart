import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'models.dart';
import 'tool_path.dart';

/// Google Motion Photo 导出器。
///
/// 输出**单个 .jpg 文件**：结构 = [JPEG(含XMP标记)] + [MP4字节]
/// XMP 用 Google 的 gcamera 命名空间标记视频偏移，
/// Google Photos / Android 相册据此识别为动态照片。
///
/// 参考：GCamera:MicroVideo / MicroVideoOffset（MP4 在文件末尾的字节偏移）。
class MotionPhotoExporter {
  final void Function(String log)? onLog;
  MotionPhotoExporter({this.onLog});
  void _log(String s) { onLog?.call(s); }

  Future<String> export({
    required MediaAsset asset,
    required String outDir,
  }) async {
    await Directory(outDir).create(recursive: true);
    final base = asset.filename.replaceAll(RegExp(r'\.[^.]+$'), '') + 'A';
    final outPath = p.join(outDir, '$base.jpg');
    final tmpJpg = p.join(outDir, '.$base.still.jpg');

    // 1) 抽中间帧为纯 JPEG
    _log('抽帧: $base');
    await Process.run(ToolPath.find('ffmpeg'), [
      '-y', '-ss', '1.5', '-i', asset.path,
      '-frames:v', '1', '-q:v', '2', '-update', '1', tmpJpg,
    ]);

    // 2) 读静态 JPEG 和原 MP4
    var jpg = await File(tmpJpg).readAsBytes();
    final mp4 = await File(asset.path).readAsBytes();

    // 3) 构造 XMP 段并插入 JPEG 的 SOI 之后（文件开头）
    final xmp = _buildXmpSegment(mp4Length: mp4.length);
    jpg = _insertAfterSoi(jpg, xmp);

    // 4) 拼接：JPEG + MP4
    final out = BytesBuilder()
      ..add(jpg)
      ..add(mp4);
    await File(outPath).writeAsBytes(out.toBytes());

    // 5) 写拍摄时间到 EXIF
    final shotStr = _exifTime(asset.shotAt);
    await Process.run(ToolPath.find('exiftool'), [
      '-overwrite_original',
      '-Make=DJI',
      '-Model=DJI OsmoPocket4P',
      '-Software=DJI Live Gallery',
      if (shotStr != null) ...[
        '-DateTimeOriginal=$shotStr',
        '-DateTimeDigitized=$shotStr',
      ],
      outPath,
    ]);

    // 清理临时抽帧
    try { File(tmpJpg).deleteSync(); } catch (_) {}

    _log('完成: $base.jpg (Motion Photo, 内嵌 ${mp4.length} 字节视频)');
    return outPath;
  }

  /// 构造 XMP APP1 段（Google Container 标准 Motion Photo）。
  ///
  /// 关键：Container:Directory 列出段结构——
  ///   Primary (主图 JPEG, Length=0 表示从文件头到下一段)
  ///   MotionPhoto (video/mp4, Length=MP4字节数)
  /// 物理布局：[主JPEG][MP4]，视频紧跟主图 EOI。
  Uint8List _buildXmpSegment({required int mp4Length}) {
    // 静态帧取视频中点 1.5s，对应 PresentationTimestampUs（微秒）
    const presentationUs = 1500000;
    final xml = '''<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="DJI Live Gallery">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"
    xmlns:Container="http://ns.google.com/photos/1.0/container/"
    xmlns:Item="http://ns.google.com/photos/1.0/container/item/"
    GCamera:MotionPhoto="1"
    GCamera:MotionPhotoVersion="1"
    GCamera:MotionPhotoPresentationTimestampUs="$presentationUs">
   <Container:Directory>
    <rdf:Seq>
     <rdf:li rdf:parseType="Resource">
      <Container:Item
        Item:Mime="image/jpeg"
        Item:Semantic="Primary"
        Item:Length="0"
        Item:Padding="0"/>
     </rdf:li>
     <rdf:li rdf:parseType="Resource">
      <Container:Item
        Item:Mime="video/mp4"
        Item:Semantic="MotionPhoto"
        Item:Length="$mp4Length"/>
     </rdf:li>
    </rdf:Seq>
   </Container:Directory>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>''';

    final prefix = 'http://ns.adobe.com/xap/1.0/\x00';
    final content = Uint8List.fromList(
        [...prefix.codeUnits, ...xml.codeUnits]);
    // APP1: 长度含自身2字节
    final segLen = content.length + 2;
    final b = BytesBuilder()
      ..add([0xFF, 0xE1])
      ..add([(segLen >> 8) & 0xFF, segLen & 0xFF])
      ..add(content);
    return b.toBytes();
  }

  /// 在 JPEG 开头 SOI(FFD8) 之后插入 XMP 段。
  /// 关键：Google/exiftool 只认 JPEG 前部的 XMP，插在 EOI 前会被忽略。
  Uint8List _insertAfterSoi(Uint8List jpg, Uint8List segment) {
    if (jpg.length < 2 || jpg[0] != 0xFF || jpg[1] != 0xD8) {
      return Uint8List.fromList([...segment, ...jpg]);
    }
    return Uint8List.fromList([
      jpg[0], jpg[1],
      ...segment,
      ...jpg.sublist(2),
    ]);
  }

  static String? _exifTime(DateTime? dt) => dt == null
      ? null
      : '${dt.year.toString().padLeft(4, '0')}:'
          '${dt.month.toString().padLeft(2, '0')}:'
          '${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}:'
          '${dt.second.toString().padLeft(2, '0')}';
}
