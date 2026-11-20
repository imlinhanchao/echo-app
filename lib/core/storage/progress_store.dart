import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 统一播放进度模型：`{chapterIndex, chunkN, offsetMs}`（听看共享）。
@immutable
class PlaybackProgress {
  const PlaybackProgress({
    required this.audiobookId,
    required this.chapterIndex,
    required this.chunkN,
    required this.offsetMs,
    this.updatedAt,
  });

  factory PlaybackProgress.fromJson(Map<String, dynamic> json) =>
      PlaybackProgress(
        audiobookId: (json['audiobook_id'] as num?)?.toInt() ?? 0,
        chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
        chunkN: (json['chunk_n'] as num?)?.toInt() ?? 0,
        offsetMs: (json['offset_ms'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
      );

  final int audiobookId;
  final int chapterIndex;
  final int chunkN;
  final int offsetMs;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'audiobook_id': audiobookId,
        'chapter_index': chapterIndex,
        'chunk_n': chunkN,
        'offset_ms': offsetMs,
        'updated_at': (updatedAt ?? DateTime.now().toUtc()).toIso8601String(),
      };
}

/// 断点续听进度存储抽象。
abstract class ProgressStore {
  Future<PlaybackProgress?> read(int audiobookId);
  Future<void> write(PlaybackProgress progress);
  Future<void> delete(int audiobookId);
}

/// 持久化进度存储（基于跨平台键值存储）。
class PersistentProgressStore implements ProgressStore {
  PersistentProgressStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static String _key(int audiobookId) => 'echo_progress_$audiobookId';

  @override
  Future<PlaybackProgress?> read(int audiobookId) async {
    final raw = await _storage.read(key: _key(audiobookId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      return map is Map<String, dynamic>
          ? PlaybackProgress.fromJson(map)
          : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(PlaybackProgress progress) => _storage.write(
        key: _key(progress.audiobookId),
        value: jsonEncode(progress.toJson()),
      );

  @override
  Future<void> delete(int audiobookId) =>
      _storage.delete(key: _key(audiobookId));
}

/// 内存进度存储（用于单元测试与 Widget 测试）。
class MemoryProgressStore implements ProgressStore {
  final Map<int, PlaybackProgress> _items = <int, PlaybackProgress>{};

  @override
  Future<PlaybackProgress?> read(int audiobookId) async => _items[audiobookId];

  @override
  Future<void> write(PlaybackProgress progress) async {
    _items[progress.audiobookId] = progress;
  }

  @override
  Future<void> delete(int audiobookId) async {
    _items.remove(audiobookId);
  }
}
