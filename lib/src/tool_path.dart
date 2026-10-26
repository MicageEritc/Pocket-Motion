import 'dart:io';

/// 查找系统命令行工具的完整路径。
/// 打包成 macOS app 后 PATH 里没有 /opt/homebrew/bin，需要手动找。
class ToolPath {
  static final Map<String, String?> _cache = {};

  static String find(String name) {
    if (_cache.containsKey(name)) return _cache[name] ?? name;

    final candidates = [
      '/opt/homebrew/bin/$name', // Apple Silicon Homebrew
      '/usr/local/bin/$name', // Intel Homebrew
      '/usr/bin/$name',
      '/bin/$name',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        _cache[name] = path;
        return path;
      }
    }
    // fallback 到 PATH
    _cache[name] = name;
    return name;
  }
}
