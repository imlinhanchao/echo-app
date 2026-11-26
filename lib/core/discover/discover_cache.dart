import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'discover_models.dart';

/// 荐书频道与书单详情缓存抽象。
abstract class DiscoverCacheStore {
  Future<DiscoverFeedData?> read(String key);
  Future<void> write(String key, DiscoverFeedData data);
  Future<void> clear();
}

/// 内存缓存实现（供测试与缺失目录插件时兜底）。
class MemoryDiscoverCacheStore implements DiscoverCacheStore {
  final Map<String, DiscoverFeedData> _entries = <String, DiscoverFeedData>{};

  @override
  Future<DiscoverFeedData?> read(String key) async => _entries[key];

  @override
  Future<void> write(String key, DiscoverFeedData data) async {
    _entries[key] = data;
  }

  @override
  Future<void> clear() async {
    _entries.clear();
  }
}

/// 基于临时目录 JSON 文件的荐书缓存存储。
/// 若在无平台插件环境（如 widget test）下失败，自动静默降级为内存缓存。
class FileDiscoverCacheStore implements DiscoverCacheStore {
  FileDiscoverCacheStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getTemporaryDirectory;

  final Future<Directory> Function() _directoryProvider;
  final Map<String, DiscoverFeedData> _memoryFallback =
      <String, DiscoverFeedData>{};

  Future<Directory?> _resolveDir() async {
    try {
      final root = await _directoryProvider();
      final dir = Directory(p.join(root.path, 'echo_discover_cache'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (_) {
      return null;
    }
  }

  String _safeFileName(String key) {
    final sanitized = key.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return '$sanitized.json';
  }

  @override
  Future<DiscoverFeedData?> read(String key) async {
    final mem = _memoryFallback[key];
    final dir = await _resolveDir();
    if (dir == null) return mem;
    try {
      final file = File(p.join(dir.path, _safeFileName(key)));
      if (!await file.exists()) return mem;
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return mem;
      final parsed = DiscoverFeedData.fromJson(decoded);
      _memoryFallback[key] = parsed;
      return parsed;
    } catch (_) {
      return mem;
    }
  }

  @override
  Future<void> write(String key, DiscoverFeedData data) async {
    _memoryFallback[key] = data;
    final dir = await _resolveDir();
    if (dir == null) return;
    try {
      final file = File(p.join(dir.path, _safeFileName(key)));
      await file.writeAsString(jsonEncode(data.toJson()));
    } catch (_) {
      // 写入失败时保留内存副本，不阻塞主流程。
    }
  }

  @override
  Future<void> clear() async {
    _memoryFallback.clear();
    final dir = await _resolveDir();
    if (dir == null) return;
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }
}
