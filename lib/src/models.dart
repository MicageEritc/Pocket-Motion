/// 媒体资产类型
enum MediaKind { livePhoto, video, photo }

/// 一个媒体文件（实况是 MP4，导出时再拆成 JPG+MOV）
class MediaAsset {
  final String path;
  final String filename;
  final MediaKind kind;
  final DateTime? shotAt; // 拍摄时间（北京时间）
  final int sizeBytes;
  final String? template; // 相机写入的 TPLG 模板串（调试用）

  const MediaAsset({
    required this.path,
    required this.filename,
    required this.kind,
    required this.shotAt,
    required this.sizeBytes,
    this.template,
  });

  String get kindLabel => switch (kind) {
        MediaKind.livePhoto => '实况',
        MediaKind.video => '视频',
        MediaKind.photo => '照片',
      };

  /// 友好参数：从模板串解析分辨率/帧率，如 "4K / 29.97 fps"
  String get friendlySpec {
    if (template == null) return '';
    final t = template!;
    String res = '';
    if (t.contains('4K')) res = '4K';
    if (t.contains('3K')) res = '3K';
    String fps = '';
    if (t.contains('2997')) fps = '29.97 fps';
    if (t.contains('5994')) fps = '59.94 fps';
    if (res.isEmpty && fps.isEmpty) return '';
    return [res, fps].where((s) => s.isNotEmpty).join(' / ');
  }
}
