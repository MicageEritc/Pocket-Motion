import 'dart:io';
import 'package:path/path.dart' as p;

/// 查找命令行工具路径。优先从 app bundle 内置找，找不到再 fallback 系统。
class ToolPath {
  static final Map<String, String?> _cache = {};

  static String? get _bundledDir {
    if (!Platform.isMacOS) return null;
    // exe: .../Pocket Motion.app/Contents/MacOS/Pocket Motion
    final exe = Platform.resolvedExecutable;
    final dir = p.join(p.dirname(p.dirname(exe)), 'Resources', 'bin');
    if (Directory(dir).existsSync()) return dir;
    return null;
  }

  static String find(String name) {
    if (_cache.containsKey(name)) return _cache[name] ?? name;

    // 1. app bundle 内置（macOS）
    final bundled = _bundledDir;
    if (bundled != null) {
      if (name == 'exiftool') {
        for (final sub in ['exiftool', 'bin/exiftool']) {
          final script = p.join(p.dirname(bundled), 'exiftool_lib', sub);
          if (File(script).existsSync()) {
            _cache[name] = script;
            return script;
          }
        }
      }
      final path = p.join(bundled, name);
      if (File(path).existsSync()) {
        _cache[name] = path;
        return path;
      }
    }

    // 2. Windows: exe 同目录（内置 ffmpeg.exe / exiftool.exe）
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final bundledWin = p.join(exeDir, '$name.exe');
      if (File(bundledWin).existsSync()) {
        _cache[name] = bundledWin;
        return bundledWin;
      }
    }

    // 3. 系统常见路径（优先使用 Homebrew opt 真实二进制路径）
    for (final candidate in [
      '/opt/homebrew/opt/$name/bin/$name',
      '/usr/local/opt/$name/bin/$name',
      '/opt/homebrew/bin/$name',
      '/usr/local/bin/$name',
      '/usr/bin/$name',
    ]) {
      if (File(candidate).existsSync()) {
        _cache[name] = candidate;
        return candidate;
      }
    }

    _cache[name] = name;
    return name;
  }
}
