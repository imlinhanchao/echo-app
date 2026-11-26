import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 持久化在本地的远程规则缓存记录。
@immutable
class StoredRemoteDiscoverRules {
  const StoredRemoteDiscoverRules({
    required this.rawJson,
    required this.remoteUrl,
    required this.fetchedAt,
  });

  factory StoredRemoteDiscoverRules.fromJson(Map<String, dynamic> json) {
    final ms = (json['fetched_at_ms'] as num?)?.toInt() ?? 0;
    return StoredRemoteDiscoverRules(
      rawJson: json['raw_json'] as String? ?? '',
      remoteUrl: (json['remote_url'] as String? ?? '').trim(),
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
    );
  }

  final String rawJson;
  final String remoteUrl;
  final DateTime fetchedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'raw_json': rawJson,
    'remote_url': remoteUrl,
    'fetched_at_ms': fetchedAt.toUtc().millisecondsSinceEpoch,
  };
}

/// 远程荐书规则配置持久化抽象。
abstract class DiscoverConfigStore {
  Future<StoredRemoteDiscoverRules?> read();
  Future<void> write(StoredRemoteDiscoverRules record);
  Future<void> clear();
}

/// 内存版规则配置存储（供测试与无文件插件环境使用）。
class MemoryDiscoverConfigStore implements DiscoverConfigStore {
  MemoryDiscoverConfigStore([StoredRemoteDiscoverRules? initial])
    : _record = initial;

  StoredRemoteDiscoverRules? _record;

  @override
  Future<StoredRemoteDiscoverRules?> read() async => _record;

  @override
  Future<void> write(StoredRemoteDiscoverRules record) async {
    _record = record;
  }

  @override
  Future<void> clear() async {
    _record = null;
  }
}

/// 基于 `ApplicationSupportDirectory/discover/remote_rules.json` 的配置存储。
/// 若遇平台通道异常或文件错误，自动静默降级为内存存储。
class FileDiscoverConfigStore implements DiscoverConfigStore {
  FileDiscoverConfigStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;
  StoredRemoteDiscoverRules? _memoryFallback;

  Future<File?> _resolveFile() async {
    try {
      final root = await _directoryProvider();
      final dir = Directory(p.join(root.path, 'discover'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return File(p.join(dir.path, 'remote_rules.json'));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<StoredRemoteDiscoverRules?> read() async {
    final file = await _resolveFile();
    if (file == null) return _memoryFallback;
    try {
      if (!await file.exists()) return _memoryFallback;
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return _memoryFallback;
      final record = StoredRemoteDiscoverRules.fromJson(decoded);
      if (record.rawJson.trim().isEmpty) return _memoryFallback;
      _memoryFallback = record;
      return record;
    } catch (_) {
      return _memoryFallback;
    }
  }

  @override
  Future<void> write(StoredRemoteDiscoverRules record) async {
    _memoryFallback = record;
    final file = await _resolveFile();
    if (file == null) return;
    try {
      await file.writeAsString(jsonEncode(record.toJson()));
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    _memoryFallback = null;
    final file = await _resolveFile();
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
