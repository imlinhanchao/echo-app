import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/echo_api.dart';
import '../../core/api/models.dart';
import '../auth/auth_controller.dart';

@immutable
class LibraryState {
  const LibraryState({
    this.books = const <LibraryBook>[],
    this.audiobooks = const <AudiobookInfo>[],
    this.isLoading = false,
    this.error,
  });

  final List<LibraryBook> books;
  final List<AudiobookInfo> audiobooks;
  final bool isLoading;
  final String? error;

  LibraryState copyWith({
    List<LibraryBook>? books,
    List<AudiobookInfo>? audiobooks,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return LibraryState(
      books: books ?? this.books,
      audiobooks: audiobooks ?? this.audiobooks,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// 书架与有声书列表状态控制器。
class LibraryController extends StateNotifier<LibraryState> {
  LibraryController(this._api) : super(const LibraryState());

  final EchoApi _api;

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        _api.listAudiobooks(),
        _api.listBooks(),
      ]);
      state = state.copyWith(
        audiobooks: results[0] as List<AudiobookInfo>,
        books: results[1] as List<LibraryBook>,
        isLoading: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    }
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
  final controller = LibraryController(ref.watch(echoApiProvider));
  controller.refresh();
  return controller;
});
