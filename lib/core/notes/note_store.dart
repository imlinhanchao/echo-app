import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 一条时间戳笔记（设计文档 §5.5）。
@immutable
class TimestampNote {
  const TimestampNote({
    required this.id,
    required this.audiobookId,
    required this.positionMs,
    required this.text,
    required this.createdAt,
    this.chapterTitle = '',
  });

  factory TimestampNote.fromJson(Map<String, dynamic> json) => TimestampNote(
    id: json['id'] as String? ?? '',
    audiobookId: (json['audiobook_id'] as num?)?.toInt() ?? 0,
    positionMs: (json['position_ms'] as num?)?.toInt() ?? 0,
    text: json['text'] as String? ?? '',
    chapterTitle: json['chapter'] as String? ?? '',
    createdAt:
        DateTime.tryParse(json['created_at'] as String? ?? '') ??
        DateTime.now(),
  );

  final String id;
  final int audiobookId;
  final int positionMs;
  final String text;
  final String chapterTitle;
  final DateTime createdAt;

  String get positionLabel {
    final totalSeconds = positionMs ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'audiobook_id': audiobookId,
    'position_ms': positionMs,
    'text': text,
    'chapter': chapterTitle,
    'created_at': createdAt.toIso8601String(),
  };
}

/// 时间戳笔记存储（本地）。
class NoteStore {
  NoteStore._();

  static final NoteStore instance = NoteStore._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _key = 'echo_notes_v1';

  final List<TimestampNote> _notes = <TimestampNote>[];
  bool _loaded = false;
  DateTime? _lastSaveAt;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final raw = await _storage.read(key: _key);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          _notes
            ..clear()
            ..addAll(
              list.whereType<Map<String, dynamic>>().map(
                TimestampNote.fromJson,
              ),
            );
        }
      }
    } catch (_) {
      // 忽略损坏数据
    }
    _loaded = true;
  }

  List<TimestampNote> get allNotes => List.unmodifiable(_notes);

  List<TimestampNote> notesFor(int audiobookId) {
    final list = _notes.where((n) => n.audiobookId == audiobookId).toList()
      ..sort((a, b) => b.positionMs.compareTo(a.positionMs));
    return list;
  }

  Future<TimestampNote> add({
    required int audiobookId,
    required int positionMs,
    required String text,
    String chapterTitle = '',
  }) async {
    final note = TimestampNote(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      audiobookId: audiobookId,
      positionMs: positionMs,
      text: text.trim(),
      chapterTitle: chapterTitle,
      createdAt: DateTime.now(),
    );
    _notes.add(note);
    _scheduleSave();
    return note;
  }

  void remove(String id) {
    _notes.removeWhere((n) => n.id == id);
    _scheduleSave();
  }

  void _scheduleSave() {
    final now = DateTime.now();
    final last = _lastSaveAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastSaveAt = now;
    unawaited(save());
  }

  Future<void> save() async {
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode(_notes.map((n) => n.toJson()).toList()),
      );
    } catch (_) {
      // 忽略
    }
  }
}
