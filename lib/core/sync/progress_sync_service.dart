import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/auth_controller.dart';
import '../api/echo_api.dart';
import '../api/models.dart';
import '../notes/note_store.dart';
import '../reader/reading_store.dart';
import '../storage/progress_store.dart';

enum SyncStatus { idle, syncing, success, error }

@immutable
class SyncState {
  const SyncState({
    this.status = SyncStatus.idle,
    this.lastSyncTime,
    this.errorMessage,
  });

  final SyncStatus status;
  final DateTime? lastSyncTime;
  final String? errorMessage;

  SyncState copyWith({
    SyncStatus? status,
    DateTime? lastSyncTime,
    String? errorMessage,
    bool clearError = false,
  }) => SyncState(
    status: status ?? this.status,
    lastSyncTime: lastSyncTime ?? this.lastSyncTime,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );
}

/// 进度与笔记云端同步服务（Offline-First + LWW 时间戳裁决）。
class ProgressSyncService extends StateNotifier<SyncState> {
  ProgressSyncService({
    required EchoApi api,
    ProgressStore? progressStore,
    ReadingStore? readingStore,
    NoteStore? noteStore,
  }) : _api = api,
       _progressStore = progressStore ?? PersistentProgressStore(),
       _readingStore = readingStore ?? PersistentReadingStore(),
       _noteStore = noteStore ?? NoteStore.instance,
       super(const SyncState());

  final EchoApi _api;
  final ProgressStore _progressStore;
  final ReadingStore _readingStore;
  final NoteStore _noteStore;

  Timer? _debounceTimer;
  final Map<String, SyncProgressItem> _pendingProgress = {};

  /// 全量双向同步：拉取云端最新数据，比对时间戳进行 LWW 合并。
  Future<void> syncAll() async {
    if (state.status == SyncStatus.syncing) return;
    state = state.copyWith(status: SyncStatus.syncing, clearError: true);

    try {
      // 1. 同步进度
      final cloudProgresses = await _api.getCloudProgress();
      final toPush = <SyncProgressItem>[];

      for (final cloud in cloudProgresses) {
        if (cloud.itemType == 'audiobook') {
          final local = await _progressStore.read(cloud.itemId);
          if (local == null) {
            await _progressStore.write(
              PlaybackProgress(
                audiobookId: cloud.itemId,
                chapterIndex: cloud.chapterIndex,
                chunkN: cloud.chunkN,
                offsetMs: cloud.offsetMs,
                updatedAt: cloud.updatedAt,
              ),
            );
          } else {
            final localTime =
                local.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            if (cloud.updatedAt.isAfter(localTime)) {
              await _progressStore.write(
                PlaybackProgress(
                  audiobookId: cloud.itemId,
                  chapterIndex: cloud.chapterIndex,
                  chunkN: cloud.chunkN,
                  offsetMs: cloud.offsetMs,
                  updatedAt: cloud.updatedAt,
                ),
              );
            } else if (localTime.isAfter(cloud.updatedAt)) {
              toPush.add(
                SyncProgressItem(
                  itemType: 'audiobook',
                  itemId: local.audiobookId,
                  chapterIndex: local.chapterIndex,
                  chunkN: local.chunkN,
                  offsetMs: local.offsetMs,
                  updatedAt: localTime,
                ),
              );
            }
          }
        } else if (cloud.itemType == 'book') {
          final local = await _readingStore.read(cloud.itemId);
          if (local == null) {
            await _readingStore.write(
              ReadingPosition(
                bookId: cloud.itemId,
                chapterIndex: cloud.chapterIndex,
                charOffset: cloud.charOffset,
                updatedAt: cloud.updatedAt,
              ),
            );
          } else {
            final localTime =
                local.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            if (cloud.updatedAt.isAfter(localTime)) {
              await _readingStore.write(
                ReadingPosition(
                  bookId: cloud.itemId,
                  chapterIndex: cloud.chapterIndex,
                  charOffset: cloud.charOffset,
                  updatedAt: cloud.updatedAt,
                ),
              );
            } else if (localTime.isAfter(cloud.updatedAt)) {
              toPush.add(
                SyncProgressItem(
                  itemType: 'book',
                  itemId: local.bookId,
                  chapterIndex: local.chapterIndex,
                  charOffset: local.charOffset,
                  updatedAt: localTime,
                ),
              );
            }
          }
        }
      }

      // 将本地更新的进度上报给云端
      if (toPush.isNotEmpty) {
        await _api.pushCloudProgress(toPush);
      }

      // 2. 同步时间戳笔记
      await _noteStore.load();
      final cloudNotes = await _api.getCloudNotes();
      final cloudNoteMap = {for (final n in cloudNotes) n.id: n};

      for (final cloud in cloudNotes) {
        // 如果本地没有该笔记，导入到本地
        final localExisting = _noteStore
            .notesFor(cloud.audiobookId)
            .where((n) => n.id == cloud.id)
            .firstOrNull;
        if (localExisting == null) {
          await _noteStore.add(
            audiobookId: cloud.audiobookId,
            positionMs: cloud.positionMs,
            text: cloud.text,
            chapterTitle: cloud.chapter,
          );
        }
      }

      // 检查本地是否有尚未同步到云端的笔记
      final localNotesToPush = <SyncNoteItem>[];
      for (final note in _noteStore.allNotes) {
        if (!cloudNoteMap.containsKey(note.id)) {
          localNotesToPush.add(
            SyncNoteItem(
              id: note.id,
              audiobookId: note.audiobookId,
              positionMs: note.positionMs,
              text: note.text,
              chapter: note.chapterTitle,
              createdAt: note.createdAt,
              updatedAt: note.createdAt,
            ),
          );
        }
      }
      if (localNotesToPush.isNotEmpty) {
        await _api.pushCloudNotes(localNotesToPush);
      }

      state = state.copyWith(
        status: SyncStatus.success,
        lastSyncTime: DateTime.now(),
      );
    } catch (e) {
      state = state.copyWith(
        status: SyncStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  /// 上报听书进度（防抖 2 秒提交）
  void reportAudioProgress(PlaybackProgress progress) {
    final key = 'audiobook_${progress.audiobookId}';
    _pendingProgress[key] = SyncProgressItem(
      itemType: 'audiobook',
      itemId: progress.audiobookId,
      chapterIndex: progress.chapterIndex,
      chunkN: progress.chunkN,
      offsetMs: progress.offsetMs,
      updatedAt: progress.updatedAt ?? DateTime.now().toUtc(),
    );
    _scheduleFlush();
  }

  /// 上报阅读进度（防抖 2 秒提交）
  void reportReadingProgress(ReadingPosition position) {
    final key = 'book_${position.bookId}';
    _pendingProgress[key] = SyncProgressItem(
      itemType: 'book',
      itemId: position.bookId,
      chapterIndex: position.chapterIndex,
      charOffset: position.charOffset,
      updatedAt: position.updatedAt ?? DateTime.now().toUtc(),
    );
    _scheduleFlush();
  }

  /// 上报新增笔记
  Future<void> reportNoteCreated(TimestampNote note) async {
    try {
      await _api.pushCloudNotes([
        SyncNoteItem(
          id: note.id,
          audiobookId: note.audiobookId,
          positionMs: note.positionMs,
          text: note.text,
          chapter: note.chapterTitle,
          createdAt: note.createdAt,
          updatedAt: note.createdAt,
        ),
      ]);
    } catch (_) {
      // 离线容错，待下次 syncAll 自动合并
    }
  }

  /// 上报删除笔记
  Future<void> reportNoteDeleted(String noteId) async {
    try {
      await _api.deleteCloudNote(noteId);
    } catch (_) {
      // 离线容错
    }
  }

  void _scheduleFlush() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 2), () {
      flushPending();
    });
  }

  /// 立即提交暂存的进度队列
  Future<void> flushPending() async {
    _debounceTimer?.cancel();
    if (_pendingProgress.isEmpty) return;
    final items = _pendingProgress.values.toList();
    _pendingProgress.clear();
    try {
      await _api.pushCloudProgress(items);
    } catch (_) {
      // 离线时不影响本地
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }
}

final progressSyncServiceProvider =
    StateNotifierProvider<ProgressSyncService, SyncState>((ref) {
      return ProgressSyncService(
        api: ref.watch(echoApiProvider),
        readingStore: ref.watch(readingStoreProvider),
        progressStore: ref.watch(progressStoreProvider),
      );
    });
