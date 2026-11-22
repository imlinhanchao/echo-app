import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/echo_api.dart';
import '../../core/api/models.dart';
import '../../core/storage/progress_store.dart';
import '../auth/auth_controller.dart';

@immutable
class LibraryState {
  const LibraryState({
    this.books = const <LibraryBook>[],
    this.audiobooks = const <AudiobookInfo>[],
    this.progressMap = const <int, PlaybackProgress>{},
    this.isLoading = false,
    this.error,
  });

  final List<LibraryBook> books;
  final List<AudiobookInfo> audiobooks;

  /// 各有声书本地断点进度（按 audiobookId 索引，用于书架展示收听进度与剩余时长）。
  final Map<int, PlaybackProgress> progressMap;
  final bool isLoading;
  final String? error;

  LibraryState copyWith({
    List<LibraryBook>? books,
    List<AudiobookInfo>? audiobooks,
    Map<int, PlaybackProgress>? progressMap,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return LibraryState(
      books: books ?? this.books,
      audiobooks: audiobooks ?? this.audiobooks,
      progressMap: progressMap ?? this.progressMap,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// 书架与有声书列表状态控制器。
class LibraryController extends StateNotifier<LibraryState> {
  LibraryController(this._api, [this._progressStore])
    : super(const LibraryState());

  final EchoApi _api;
  final ProgressStore? _progressStore;

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        _api.listAudiobooks(),
        _api.listBooks(),
      ]);
      final audiobooks = results[0] as List<AudiobookInfo>;
      final books = results[1] as List<LibraryBook>;
      final progressMap = Map<int, PlaybackProgress>.of(state.progressMap);
      final store = _progressStore;
      if (store != null) {
        for (final audio in audiobooks) {
          if (!audio.isReady) continue;
          try {
            final p = await store.read(audio.id);
            if (p != null) {
              progressMap[audio.id] = p;
            }
          } catch (_) {
            // 单本进度读取失败不阻塞书架渲染
          }
        }
      }
      state = state.copyWith(
        audiobooks: audiobooks,
        books: books,
        progressMap: progressMap,
        isLoading: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    }
  }

  /// 播放过程中实时更新某本有声书的进度缓存，驱动书架卡片即时刷新。
  void updateProgress(PlaybackProgress progress) {
    state = state.copyWith(
      progressMap: <int, PlaybackProgress>{
        ...state.progressMap,
        progress.audiobookId: progress,
      },
    );
  }

  Future<String?> deleteBook(int id) async {
    try {
      await _api.deleteBook(id);
      state = state.copyWith(
        books: state.books.where((b) => b.id != id).toList(),
      );
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  Future<String?> deleteAudiobook(int id) async {
    try {
      await _api.deleteAudiobook(id);
      state = state.copyWith(
        audiobooks: state.audiobooks.where((a) => a.id != id).toList(),
      );
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }
}

final StateNotifierProvider<LibraryController, LibraryState>
libraryControllerProvider =
    StateNotifierProvider<LibraryController, LibraryState>((ref) {
      final controller = LibraryController(
        ref.watch(echoApiProvider),
        ref.watch(progressStoreProvider),
      );
      controller.refresh();
      return controller;
    });
