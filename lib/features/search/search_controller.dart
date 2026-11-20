import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/echo_api.dart';
import '../../core/api/models.dart';
import '../auth/auth_controller.dart';

/// 搜索筛选条件（对应 GET /api/search 查询参数）。
@immutable
class SearchFilters {
  const SearchFilters({
    this.extensions = const <String>[],
    this.order = '',
  });

  /// 扩展名筛选（如仅 EPUB：`['EPUB']`）。
  final List<String> extensions;
  final String order;
}

@immutable
class SearchState {
  const SearchState({
    this.books = const <SearchBook>[],
    this.page = 0,
    this.totalPages = 0,
    this.isLoading = false,
    this.error,
    this.lastQuery = '',
    this.history = const <String>[],
  });

  final List<SearchBook> books;
  final int page;
  final int totalPages;
  final bool isLoading;
  final String? error;
  final String lastQuery;

  /// 搜索历史（会话内，去重置顶，最多 8 条；设计图 ui-mobile-search）。
  final List<String> history;

  bool get hasMore => page < totalPages;

  SearchState copyWith({
    List<SearchBook>? books,
    int? page,
    int? totalPages,
    bool? isLoading,
    String? error,
    bool clearError = false,
    String? lastQuery,
    List<String>? history,
  }) {
    return SearchState(
      books: books ?? this.books,
      page: page ?? this.page,
      totalPages: totalPages ?? this.totalPages,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      lastQuery: lastQuery ?? this.lastQuery,
      history: history ?? this.history,
    );
  }
}

/// 搜索控制器：发起查询、分页加载更多、筛选切换。
class SearchController extends StateNotifier<SearchState> {
  SearchController(this._api, {SearchFilters filters = const SearchFilters()})
      : _filters = filters,
        super(const SearchState());

  final EchoApi _api;
  SearchFilters _filters;

  SearchFilters get filters => _filters;

  Future<void> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final history = [trimmed, ...state.history.where((e) => e != trimmed)]
        .take(8)
        .toList();
    state = SearchState(
      isLoading: true,
      lastQuery: trimmed,
      history: history,
    );
    await _fetch(page: 1, query: trimmed, append: false);
  }

  /// 删除一条搜索历史。
  void removeHistory(String query) {
    state = state.copyWith(
      history: state.history.where((e) => e != query).toList(),
    );
  }

  Future<void> loadMore() async {
    if (!state.hasMore || state.isLoading || state.lastQuery.isEmpty) return;
    state = state.copyWith(isLoading: true, clearError: true);
    await _fetch(page: state.page + 1, query: state.lastQuery, append: true);
  }

  Future<void> setFilters(SearchFilters filters) async {
    _filters = filters;
    if (state.lastQuery.isNotEmpty) {
      await search(state.lastQuery);
    }
  }

  Future<void> _fetch({
    required int page,
    required String query,
    required bool append,
  }) async {
    try {
      final result = await _api.search(
        query: query,
        page: page,
        extensions: _filters.extensions,
        order: _filters.order,
      );
      state = state.copyWith(
        books: append ? [...state.books, ...result.books] : result.books,
        page: result.page,
        totalPages: result.totalPages,
        isLoading: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    }
  }
}

final StateNotifierProvider<SearchController, SearchState>
    searchControllerProvider =
    StateNotifierProvider<SearchController, SearchState>((ref) {
  return SearchController(ref.watch(echoApiProvider));
});
