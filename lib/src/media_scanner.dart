import 'dart:io';
import 'dart:typed_data';
import 'models.dart';

/// 媒体扫描器：从相机 DCIM 目录识别 照片/视频/实况。
///
/// 关键判据（已逆向验证）：相机在 MP4 的 dbgi 数据轨写入拍摄配置模板串，
/// 实况为 `TPLG_VIDEO_LIVEPHOTO_*`，普通视频为 `TPLG_VIDEO_*`（无 LIVEPHOTO）。
class MediaScanner {
  /// 只扫文件前部即可，TPLG 位于 mdat 开头（偏移 ~10KB），
  /// 避免读整个 GB 级文件，保证扫描速度。
  static const _scanHeadBytes = 512 * 1024;

  static final _liveMarker = ascii('TPLG_VIDEO_LIVEPHOTO');
  static final _tplgRegex = RegExp(r'TPLG_[\x20-\x7E]{3,60}');

  static Uint8List ascii(String s) =>
      Uint8List.fromList(s.codeUnits);

  /// 扫描目录，返回识别出的媒体列表。
  Future<List<MediaAsset>> scan(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];

    final entities = dir.listSync();
    final List<MediaAsset> assets = [];

    for (final e in entities) {
      if (e is! File) continue;
      final name = e.path.split('/').last;
      final ext = name.split('.').last.toLowerCase();
      final stat = await e.stat();

      // 从文件名解析拍摄时间：DJI_20261022215019_0170_D.MP4
      final shotAt = _parseFileNameTime(name);

      if (ext == 'mp4') {
        final kind = await _classifyVideo(e.path);
        final tplg = kind.$2;
        assets.add(MediaAsset(
          path: e.path,
          filename: name,
          kind: kind.$1,
          shotAt: shotAt,
          sizeBytes: stat.size,
          template: tplg,
        ));
      } else if (ext == 'jpg' || ext == 'jpeg' || ext == 'dng') {
        assets.add(MediaAsset(
          path: e.path,
          filename: name,
          kind: MediaKind.photo,
          shotAt: shotAt,
          sizeBytes: stat.size,
        ));
      }
      // LRF 是低码率代理文件，跳过
    }

    assets.sort((a, b) => b.shotAt?.compareTo(a.shotAt ?? DateTime(0)) ?? 0);
    return assets;
  }

  /// 返回 (类型, TPLG模板串)
  Future<(MediaKind, String?)> _classifyVideo(String path) async {
    final f = File(path);
    final raf = await f.open();
    try {
      final len = await raf.length();
      final readLen = len < _scanHeadBytes ? len : _scanHeadBytes;
      final buf = await raf.read(readLen);
      final data = String.fromCharCodes(buf);
      final isLive = _containsMarker(buf);
      final m = _tplgRegex.firstMatch(data);
      final tplg = m?.group(0);
      return (isLive ? MediaKind.livePhoto : MediaKind.video, tplg);
    } finally {
      await raf.close();
    }
  }

  static bool _containsMarker(Uint8List buf) {
    // 简单子串匹配：找 TPLG_VIDEO_LIVEPHOTO
    final marker = _liveMarker;
    outer:
    for (var i = 0; i + marker.length <= buf.length; i++) {
      for (var j = 0; j < marker.length; j++) {
        if (buf[i + j] != marker[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  /// DJI_20261022215019_... -> 2026-10-22 21:50:19 (本地/北京时间)
  static DateTime? _parseFileNameTime(String name) {
    final m = RegExp(r'(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})').firstMatch(name);
    if (m == null) return null;
    return DateTime(
      int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!),
      int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!),
    );
  }
}
