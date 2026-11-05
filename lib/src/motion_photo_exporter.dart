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
    final deviceLabel = mp4Info.model.toUpperCase().startsWith(mp4Info.make.toUpperCase())
        ? mp4Info.model
        : '${mp4Info.make} ${mp4Info.model}';

    // 1) 抽中间帧为纯 JPEG
    _log('抽帧: $base ($deviceLabel)');
    final res = await Process.run(ToolPath.find('ffmpeg'), [
      '-y', '-ss', '1.5', '-i', asset.path,
      '-frames:v', '1', '-q:v', '2', '-update', '1', tmpJpg,
    ]);
    if (res.exitCode != 0) {
      _log('  !! ffmpeg 失败: ${res.stderr}');
      throw Exception('ffmpeg 抽帧失败 (exit ${res.exitCode})');
    }

    try {
      // 2) 读静态 JPEG 和原 MP4
      var jpg = await File(tmpJpg).readAsBytes();
      final mp4 = await File(asset.path).readAsBytes();
      final dims = MediaMetadata.extractJpegDimensions(jpg);

      // 3) 纯 Dart 构造 EXIF APP1 段（设备品牌/型号、拍摄时间、宽高）与 Google Motion Photo XMP APP1 段并注入 SOI 之后
      final exifApp1 = MediaMetadata.buildExifApp1Segment(
        make: mp4Info.make,
        model: mp4Info.model,
        software: 'Pocket Motion',
        shotAt: shotAt,
        imageWidth: dims?.$1,
        imageHeight: dims?.$2,
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
        if (File(tmpJpg).existsSync()) {
          File(tmpJpg).deleteSync();
        }
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

  Uint8List _buildXmpSegment({required int mp4Length}) {
    const presentationUs = 1500000;
    final xml = '''<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Pocket Motion">
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
    final segLen = content.length + 2;
    final b = BytesBuilder()
      ..add([0xFF, 0xE1])
      ..add([(segLen >> 8) & 0xFF, segLen & 0xFF])
      ..add(content);
    return b.toBytes();
  }
}
