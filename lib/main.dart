import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'src/models.dart';
import 'src/media_scanner.dart';
import 'src/live_photo_exporter.dart';
import 'src/motion_photo_exporter.dart';
import 'src/thumbnail_image.dart';

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
  String _cameraDir = '/Volumes/Pocket4P/DCIM/DJI_001';
  String _outDir = '/Users/micage/Downloads/照片测试/live_out';

  List<MediaAsset> _assets = [];
  MediaKind? _filter = MediaKind.livePhoto; // 默认只显示实况
  bool _scanning = false;
  final Set<String> _selected = {};
  final List<String> _logs = [];
  bool _exporting = false;
  int _doneCount = 0;
  int _totalCount = 0;
  int _success = 0;
  int _fail = 0;

  List<MediaAsset> get _liveAssets =>
      _assets.where((a) => a.kind == MediaKind.livePhoto).toList();

  List<MediaAsset> get _visible => _filter == null
      ? _assets
      : _assets.where((a) => a.kind == _filter).toList();

  Future<void> _scan() async {
    setState(() { _scanning = true; _logs.clear(); });
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
    if (dir != null) { setState(() => _cameraDir = dir); _selected.clear(); }
  }

  Future<void> _pickOutDir() async {
    final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择导出目录');
    if (dir != null) setState(() => _outDir = dir);
  }

  List<MediaAsset> get _picked => _liveAssets
      .where((a) => _selected.contains(a.path)).toList();

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

  void _exportApple() => _runExport((a) => LivePhotoExporter(
        onLog: _log,
      ).export(asset: a, outDir: _outDir));

  void _exportMotion() => _runExport((a) => MotionPhotoExporter(
        onLog: _log,
      ).export(asset: a, outDir: _outDir));

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
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text('导出格式',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (_picked.isEmpty || _exporting) ? null : _exportApple,
              child: const Text('导出为 Apple 实况照片'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: (_picked.isEmpty || _exporting) ? null : _exportMotion,
              child: const Text('导出为 Android 动态照片'),
            ),
          ),
        ]),
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
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(
          '保留原始拍摄时间与设备信息，源文件不会被修改。',
          style: TextStyle(fontSize: 11, color: Colors.black45)),
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
          final wide = constraints.maxWidth > 720;
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
              onSelected: (_) => setState(() => _filter = MediaKind.livePhoto),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              label: const Text('视频'),
              selected: _filter == MediaKind.video,
              onSelected: (_) => setState(() => _filter = MediaKind.video),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              label: const Text('照片'),
              selected: _filter == MediaKind.photo,
              onSelected: (_) => setState(() => _filter = MediaKind.photo),
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
              final visibleLive = _visible.where((a)=>a.kind==MediaKind.livePhoto);
              final allSel = visibleLive.every((a)=>_selected.contains(a.path));
              allSel
                  ? _selected.removeAll(visibleLive.map((a)=>a.path))
                  : _selected.addAll(visibleLive.map((a)=>a.path));
            }),
            child: const Text('全选'),
          ),
          Text('已选 ${_selected.length} 项',
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
            final selectable = a.kind == MediaKind.livePhoto;
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
              trailing: selectable
                  ? Checkbox(
                      value: selected,
                      onChanged: (v) => setState(() {
                        v == true
                            ? _selected.add(a.path)
                            : _selected.remove(a.path);
                      }))
                  : null,
              onTap: selectable
                  ? () => setState(() {
                      selected
                          ? _selected.remove(a.path)
                          : _selected.add(a.path);
                    })
                  : null,
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
