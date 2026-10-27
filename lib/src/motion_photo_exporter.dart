import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'media_metadata.dart';
import 'models.dart';
import 'tool_path.dart';

/// Google Motion Photo 导出器。
///
/// 输出**单个 .jpg 文件**：结构 = [JPEG(含标准 EXIF APP1 + Google XMP APP1)] + [MP4字节]
/// 纯 Dart 直接从源 MP4 提取设备型号与拍摄时间并写入 EXIF，不依赖外部 exiftool 进程。
class MotionPhotoExporter {
  final void Function(String log)? onLog;
  MotionPhotoExporter({this.onLog});
  void _log(String s) {
    onLog?.call(s);
  }

  Future<String> export({
    required MediaAsset asset,
    required String outDir,
  }) async {
    await Directory(outDir).create(recursive: true);
    final base = asset.filename.replaceAll(RegExp(r'\.[^.]+$'), '') + 'A';
    final outPath = p.join(outDir, '$base.jpg');
    final tmpJpg = p.join(outDir, '.$base.still.jpg');

    final mp4Info = await MediaMetadata.extractFromMp4(asset.path);
    final shotAt = asset.shotAt ?? mp4Info.creationTime;

    // 1) 抽中间帧为纯 JPEG
    _log('抽帧: $base (${mp4Info.make} ${mp4Info.model})');
    await Process.run(ToolPath.find('ffmpeg'), [
      '-y', '-ss', '1.5', '-i', asset.path,
      '-frames:v', '1', '-q:v', '2', '-update', '1', tmpJpg,
    ]);

    try {
      // 2) 读静态 JPEG 和原 MP4
      var jpg = await File(tmpJpg).readAsBytes();
      final mp4 = await File(asset.path).readAsBytes();

      // 3) 纯 Dart 构造 EXIF APP1 段（设备品牌/型号、拍摄时间）与 Google Motion Photo XMP APP1 段并注入 SOI 之后
      final exifApp1 = MediaMetadata.buildExifApp1Segment(
        make: mp4Info.make,
        model: mp4Info.model,
        software: 'DJI Live Gallery',
        shotAt: shotAt,
      );
      final xmpApp1 = _buildXmpSegment(mp4Length: mp4.length);
      jpg = MediaMetadata.injectIntoJpeg(jpg, [exifApp1, xmpApp1]);

      // 4) 拼接：JPEG + MP4
      final out = BytesBuilder()
        ..add(jpg)
        ..add(mp4);
      await File(outPath).writeAsBytes(out.toBytes());
    } finally {
      try {
        File(tmpJpg).deleteSync();
      } catch (_) {}
    }

    // 5) 文件系统时间归位
    if (shotAt != null) {
      try {
        await File(outPath).setLastModified(shotAt);
      } catch (_) {}
    }

    _log('完成: $base.jpg (Motion Photo)');
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
}
