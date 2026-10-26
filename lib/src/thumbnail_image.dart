import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'tool_path.dart';

/// 懒加载缩略图：首次构建时用 ffmpeg 从 MP4 抽一帧，缓存到临时目录。
class ThumbnailImage extends StatefulWidget {
  final String videoPath;
  final double size;
  final bool isLive;
  const ThumbnailImage({
    super.key,
    required this.videoPath,
    this.size = 56,
    this.isLive = false,
  });

  @override
  State<ThumbnailImage> createState() => _ThumbnailImageState();
}

class _ThumbnailImageState extends State<ThumbnailImage> {
  String? _cachePath;
  bool _loading = true;

  Future<String> _cacheDir() async {
    final tmp = Directory.systemTemp;
    final dir = Directory(p.join(tmp.path, 'dji_live_thumbs'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  @override
  void initState() {
    super.initState();
    _ensureThumb();
  }

  Future<void> _ensureThumb() async {
    final dir = await _cacheDir();
    // 用文件名做缓存键
    final key = widget.videoPath.split('/').last.replaceAll('.', '_');
    final cache = p.join(dir, '$key.jpg');
    final f = File(cache);
    if (await f.exists()) {
      setState(() { _cachePath = cache; _loading = false; });
      return;
    }
    // ffmpeg 抽 1.5s 处、缩放到 320 宽
    final r = await Process.run(ToolPath.find('ffmpeg'), [
      '-y', '-ss', '1.5', '-i', widget.videoPath,
      '-frames:v', '1', '-vf', 'scale=320:-1',
      '-q:v', '5', '-update', '1', cache,
    ]);
    if (r.exitCode == 0 && await f.exists()) {
      setState(() { _cachePath = cache; _loading = false; });
    } else {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          width: widget.size,
          height: widget.size * 0.66,
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(6),
          ),
          clipBehavior: Clip.antiAlias,
          child: _loading
              ? const Center(
                  child: SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)))
              : _cachePath != null
                  ? Image.file(File(_cachePath!), fit: BoxFit.cover)
                  : const Icon(Icons.movie, color: Colors.grey),
        ),
        if (widget.isLive)
          Positioned(
            right: 0, bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.teal,
                borderRadius: BorderRadius.circular(3)),
              child: const Text('LIVE',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 8, fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    );
  }
}
