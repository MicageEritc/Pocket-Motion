import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'src/models.dart';
import 'src/media_scanner.dart';
import 'src/live_photo_exporter.dart';
import 'src/motion_photo_exporter.dart';
import 'src/thumbnail_image.dart';
import 'src/tool_path.dart';

void main() => runApp(const DjiLiveApp());

class DjiLiveApp extends StatelessWidget {
  const DjiLiveApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pocket Motion',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorSchemeSeed: Colors.teal,
      ),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _scanner = MediaScanner();
  late String _cameraDir = _defaultCameraDir();
  late String _outDir = _defaultOutDir();

  List<MediaAsset> _assets = [];
  MediaKind _filter = MediaKind.livePhoto; // 默认只显示实况
  bool _scanning = false;
  final Set<String> _selected = {};
  String? _anchorPath; // Shift 连选起点
  final List<String> _logs = [];
  bool _exporting = false;
  int _doneCount = 0;
  int _totalCount = 0;
  int _success = 0;
  int _fail = 0;

  @override
  void initState() {
    super.initState();
    _loadSavedDirs();
  }

  static String _defaultCameraDir() {
    if (Platform.isWindows) {
      return r'D:\DCIM\DJI_001';
    }
    return '/Volumes/Pocket4P/DCIM/DJI_001';
  }

  static String _defaultOutDir() {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'] ?? r'C:\Users\Public';
      return p.join(userProfile, 'Downloads', 'PocketMotion_Out');
    }
    final home = Platform.environment['HOME'] ?? '/Users/Shared';
    return p.join(home, 'Downloads', 'live_out');
  }

  static File _configFile() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.systemTemp.path;
      return File(p.join(appData, 'PocketMotion', 'config.json'));
    }
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return File(p.join(home, 'Library', 'Application Support', 'PocketMotion', 'config.json'));
  }

  Future<void> _loadSavedDirs() async {
    try {
      final file = _configFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content);
        if (data is Map) {
          final savedCamera = data['cameraDir'];
          final savedOut = data['outDir'];
          setState(() {
            if (savedCamera is String && savedCamera.trim().isNotEmpty) {
              _cameraDir = savedCamera.trim();
            }
            if (savedOut is String && savedOut.trim().isNotEmpty) {
              _outDir = savedOut.trim();
            }
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveDirs() async {
    try {
      final file = _configFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'cameraDir': _cameraDir,
        'outDir': _outDir,
      }));
    } catch (_) {}
  }

  List<MediaAsset> get _liveAssets =>
      _assets.where((a) => a.kind == MediaKind.livePhoto).toList();

  List<MediaAsset> get _visible =>
      _assets.where((a) => a.kind == _filter).toList();

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _selected.clear();
      _anchorPath = null;
      _logs.clear();
    });
    final list = await _scanner.scan(_cameraDir);
    setState(() {
      _assets = list;
      _scanning = false;
    });
  }

  void _log(String s) => setState(() => _logs.add(s));

  Future<void> _pickCameraDir() async {
    final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择相机素材目录');
    if (dir != null) {
      setState(() {
        _cameraDir = dir;
        _selected.clear();
        _anchorPath = null;
      });
      await _saveDirs();
      await _scan();
    }
  }

  Future<void> _pickOutDir() async {
    final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择导出目录');
    if (dir != null) {
      setState(() => _outDir = dir);
      await _saveDirs();
    }
  }

  List<MediaAsset> get _picked =>
      _visible.where((a) => _selected.contains(a.path)).toList();

  void _onItemTap(int index, MediaAsset asset) {
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final anchorIdx = _anchorPath == null
        ? -1
        : _visible.indexWhere((a) => a.path == _anchorPath);

    setState(() {
      if (isShift && anchorIdx != -1) {
        final start = anchorIdx < index ? anchorIdx : index;
        final end = anchorIdx < index ? index : anchorIdx;
        for (var i = start; i <= end; i++) {
          _selected.add(_visible[i].path);
        }
        _anchorPath = asset.path;
      } else {
        if (_selected.contains(asset.path)) {
          _selected.remove(asset.path);
        } else {
          _selected.add(asset.path);
        }
        _anchorPath = asset.path;
      }
    });
  }

  Future<void> _runExport(Future<void> Function(MediaAsset a) task) async {
    final picks = _picked;
    if (picks.isEmpty || _exporting) return;
    setState(() {
      _exporting = true; _doneCount = 0;
      _totalCount = picks.length; _success = 0; _fail = 0;
    });
    for (final a in picks) {
      try {
        await task(a);
        _success++;
      } catch (e) {
        _fail++;
        _log('失败: ${a.filename} ($e)');
      }
      setState(() => _doneCount++);
    }
    _log('完成：成功 $_success，失败 $_fail');
    setState(() => _exporting = false);
  }

  void _exportApple() {
    final liveOutDir = p.join(_outDir, 'live');
    _runExport((a) => LivePhotoExporter(
          onLog: _log,
        ).export(asset: a, outDir: liveOutDir));
  }

  void _exportMotion() {
    final liveOutDir = p.join(_outDir, 'live');
    _runExport((a) => MotionPhotoExporter(
          onLog: _log,
        ).export(asset: a, outDir: liveOutDir));
  }

  void _exportVideos() {
    final movieOutDir = p.join(_outDir, 'movie');
    _runExport((a) => _copyMediaFile(a, movieOutDir, 'movie'));
  }

  void _exportPhotos() {
    final photoOutDir = p.join(_outDir, 'photo');
    _runExport((a) => _copyMediaFile(a, photoOutDir, 'photo'));
  }

  Future<void> _copyMediaFile(
      MediaAsset asset, String targetDir, String folderLabel) async {
    await Directory(targetDir).create(recursive: true);
    final destPath = p.join(targetDir, asset.filename);
    _log('导出: ${asset.filename} -> $folderLabel/');
    await File(asset.path).copy(destPath);

    DateTime? shotAt = asset.shotAt;
    if (shotAt == null) {
      try {
        shotAt = await File(asset.path).lastModified();
      } catch (_) {}
    }

    if (shotAt != null) {
      if (Platform.isMacOS) {
        try {
          await Process.run(ToolPath.find('SetFile'), [
            '-d',
            _macTime(shotAt),
            destPath,
          ]);
        } catch (_) {}
      }
      try {
        await File(destPath).setLastModified(shotAt);
      } catch (_) {}
    }
    _log('完成: $folderLabel/${asset.filename}');
  }

  static String _macTime(DateTime dt) =>
      '${dt.month.toString().padLeft(2, '0')}/'
      '${dt.day.toString().padLeft(2, '0')}/'
      '${dt.year} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Row(children: [
        SizedBox(width: 300, child: _buildSidebar()),
        const VerticalDivider(width: 1),
        Expanded(child: _buildMain()),
      ]),
    );
  }

  Widget _buildSidebar() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 素材来源标题行（刷新按钮挪到标题右侧）
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
        child: Row(children: [
          const Expanded(
            child: Text('素材来源',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          IconButton(
            icon: _scanning
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 18),
            onPressed: _scanning ? null : _scan,
            tooltip: '重新扫描',
          ),
        ]),
      ),
      _PathCard(
        path: _cameraDir,
        onChange: _pickCameraDir,
      ),
      const SizedBox(height: 20),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text('导出位置',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
      _PathCard(path: _outDir, onChange: _pickOutDir, isOut: true),
      const SizedBox(height: 20),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          _filter == MediaKind.livePhoto ? '导出格式' : '导出操作',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
      ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _buildExportButtons(),
      ),
      if (_exporting)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            LinearProgressIndicator(value: _totalCount == 0
                ? 0 : _doneCount / _totalCount),
            const SizedBox(height: 6),
            Text('正在导出 $_doneCount/$_totalCount  '
                '成功 $_success · 失败 $_fail',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ]),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(
          switch (_filter) {
            MediaKind.livePhoto =>
              '实况将导出至 live 文件夹，保留原始拍摄时间与设备信息。',
            MediaKind.video =>
              '视频将导出至 movie 文件夹，保留原始拍摄时间，源文件不会被修改。',
            MediaKind.photo =>
              '照片将导出至 photo 文件夹，保留原始拍摄时间，源文件不会被修改。',
          },
          style: const TextStyle(fontSize: 11, color: Colors.black45),
        ),
      ),
      const Spacer(),
      if (_logs.isNotEmpty)
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(8),
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8)),
            child: ListView(children: _logs
                .map((l) => Text(l,
                    style: const TextStyle(
                        fontSize: 10, color: Colors.black54)))
                .toList()),
          ),
        ),
    ]);
  }

  Widget _buildExportButtons() {
    final disabled = _picked.isEmpty || _exporting;
    switch (_filter) {
      case MediaKind.livePhoto:
        return Column(children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: disabled ? null : _exportApple,
              child: const Text('导出为 Apple 实况照片'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: disabled ? null : _exportMotion,
              child: const Text('导出为 Android 动态照片'),
            ),
          ),
        ]);
      case MediaKind.video:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: disabled ? null : _exportVideos,
            child: const Text('导出视频'),
          ),
        );
      case MediaKind.photo:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: disabled ? null : _exportPhotos,
            child: const Text('导出照片'),
          ),
        );
    }
  }

  void _switchFilter(MediaKind kind) {
    if (_filter == kind) return;
    setState(() {
      _filter = kind;
      _selected.clear();
      _anchorPath = null;
    });
  }

  Widget _buildMain() {
    return Column(children: [
      // 标题区
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
        color: Colors.white,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('实况照片转换',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
          const SizedBox(height: 4),
          Text('将DJI实况导出为Apple或Android动态照片，保留完整的时间戳',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ]),
      ),
      // 统计 + 筛选（响应式）
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
          color: Colors.white),
        child: LayoutBuilder(builder: (context, constraints) {
          final stats = Row(mainAxisSize: MainAxisSize.min, children: [
            _statChip('可转换实况', _liveAssets.length, Colors.teal),
            const SizedBox(width: 12),
            _statChip('普通视频',
                _assets.where((a)=>a.kind==MediaKind.video).length, Colors.orange),
            const SizedBox(width: 12),
            _statChip('照片',
                _assets.where((a)=>a.kind==MediaKind.photo).length, Colors.blue),
          ]);
          final filters = Row(mainAxisSize: MainAxisSize.min, children: [
            ChoiceChip(
              label: const Text('实况'),
              selected: _filter == MediaKind.livePhoto,
              onSelected: (_) => _switchFilter(MediaKind.livePhoto),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              label: const Text('视频'),
              selected: _filter == MediaKind.video,
              onSelected: (_) => _switchFilter(MediaKind.video),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              label: const Text('照片'),
              selected: _filter == MediaKind.photo,
              onSelected: (_) => _switchFilter(MediaKind.photo),
            ),
          ]);
          // 无论宽窄，统计和筛选都从最左开始排列，必要时横向滚动
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              stats,
              const SizedBox(width: 16),
              filters,
            ]),
          );
        }),
      ),
      // 选择行
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Row(children: [
          TextButton(
            onPressed: () => setState(() {
              final allSel = _visible.isNotEmpty &&
                  _visible.every((a) => _selected.contains(a.path));
              if (allSel) {
                _selected.removeAll(_visible.map((a) => a.path));
              } else {
                _selected.addAll(_visible.map((a) => a.path));
              }
            }),
            child: const Text('全选'),
          ),
          Text('已选 ${_picked.length} 项（按住 Shift 可区间连选）',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ]),
      ),
      // 列表
      Expanded(
        child: ListView.separated(
          itemCount: _visible.length,
          separatorBuilder: (_, __) =>
              Divider(height: 1, color: Colors.grey.shade100),
          itemBuilder: (_, i) {
            final a = _visible[i];
            final selected = _selected.contains(a.path);
            return ListTile(
              key: ValueKey(a.path),
              leading: a.kind == MediaKind.photo
                  ? Image.file(File(a.path),
                      width: 64, height: 42, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.image, color: Colors.grey))
                  : ThumbnailImage(
                      videoPath: a.path,
                      isLive: a.kind == MediaKind.livePhoto,
                      size: 64,
                    ),
              title: Text(a.filename,
                  style: const TextStyle(
                      fontSize: 13, color: Colors.black87)),
              subtitle: Text(
                [
                  _fmtTime(a.shotAt),
                  '${(a.sizeBytes/1024/1024).toStringAsFixed(1)} MB',
                  if (a.friendlySpec.isNotEmpty) a.friendlySpec,
                ].join(' · '),
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
              trailing: Checkbox(
                value: selected,
                onChanged: (_) => _onItemTap(i, a),
              ),
              onTap: () => _onItemTap(i, a),
            );
          },
        ),
      ),
    ]);
  }

  Widget _statChip(String label, int count, Color color) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 8, height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text('$label $count',
          style: const TextStyle(fontSize: 12, color: Colors.black54)),
    ]);
  }

  String _fmtTime(DateTime? t) => t == null ? '无时间'
      : '${t.year}-${t.month.toString().padLeft(2,'0')}-${t.day.toString().padLeft(2,'0')} '
        '${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}';
}

/// 路径卡片：显示末尾目录名，悬停提示完整路径，右侧"更改"按钮
class _PathCard extends StatelessWidget {
  final String path;
  final VoidCallback onChange;
  final bool isOut;
  const _PathCard({
    required this.path,
    required this.onChange,
    this.isOut = false,
  });

  @override
  Widget build(BuildContext context) {
    final name = path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull ?? path;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(children: [
        Icon(isOut ? Icons.output : Icons.sd_storage,
            size: 18, color: Colors.teal),
        const SizedBox(width: 8),
        Expanded(
          child: Tooltip(
            message: path,
            child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
        ),
        TextButton(onPressed: onChange, child: const Text('更改')),
      ]),
    );
  }
}
