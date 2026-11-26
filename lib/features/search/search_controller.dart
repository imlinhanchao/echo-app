import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api/echo_api.dart';
import '../../core/api/models.dart';
import '../auth/auth_controller.dart';

/// 搜索筛选条件（对应 GET /api/search 查询参数）。
@immutable
class SearchFilters {
  const SearchFilters({
    this.extensions = const <String>[],
    this.languages = const <String>[],
    this.yearFrom = 0,
    this.yearTo = 0,
    this.order = '',
  });

  /// 扩展名筛选（如仅 EPUB：`['EPUB']`）。
  final List<String> extensions;

  /// 语言筛选（zlib 使用 `chinese`/`english`/`japanese` 等值）。
  final List<String> languages;

  /// 出版年份范围（0 表示不限）。
  final int yearFrom;
  final int yearTo;

  /// 排序：空=相关度，`popular`=最热，`date`=最新。
  final String order;

  bool get isDefault =>
      extensions.isEmpty &&
      languages.isEmpty &&
      yearFrom == 0 &&
      yearTo == 0 &&
      order.isEmpty;

  /// 当前生效的筛选条数（用于按钮上的角标）。
  int get activeCount =>
      (extensions.isEmpty ? 0 : 1) +
      (languages.isEmpty ? 0 : 1) +
      (order.isEmpty ? 0 : 1) +
      ((yearFrom > 0 || yearTo > 0) ? 1 : 0);

  SearchFilters copyWith({
    List<String>? extensions,
    List<String>? languages,
    int? yearFrom,
    int? yearTo,
    String? order,
  }) => SearchFilters(
    extensions: extensions ?? this.extensions,
    languages: languages ?? this.languages,
    yearFrom: yearFrom ?? this.yearFrom,
    yearTo: yearTo ?? this.yearTo,
    order: order ?? this.order,
  );
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

/// 搜索历史存储抽象。
abstract class SearchHistoryStore {
  Future<List<String>> load();
  Future<void> save(List<String> history);
}

/// 基于 FlutterSecureStorage 的搜索历史安全存储。
class SecureSearchHistoryStore implements SearchHistoryStore {
  SecureSearchHistoryStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'echo_search_history_v1';

  @override
  Future<List<String>> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw) as List<dynamic>?;
      if (list == null) return const [];
      return list.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> save(List<String> history) async {
    try {
      await _storage.write(key: _key, value: jsonEncode(history));
    } catch (_) {}
  }
}

/// 内存版搜索历史存储（供测试使用）。
class MemorySearchHistoryStore implements SearchHistoryStore {
  MemorySearchHistoryStore([List<String>? initial])
    : _history = List.of(initial ?? const []);

  List<String> _history;

  @override
  Future<List<String>> load() async => List.unmodifiable(_history);

  @override
  Future<void> save(List<String> history) async {
    _history = List.of(history);
  }
}

/// 搜索控制器：发起查询、分页加载更多、筛选切换。
class SearchController extends StateNotifier<SearchState> {
  SearchController(
    this._api, {
    SearchFilters filters = const SearchFilters(),
    SearchHistoryStore? historyStore,
  }) : _filters = filters,
       _historyStore = historyStore ?? SecureSearchHistoryStore(),
       super(const SearchState()) {
    _initHistory();
  }

  final EchoApi _api;
  final SearchHistoryStore _historyStore;
  SearchFilters _filters;

  SearchFilters get filters => _filters;

  Future<void> _initHistory() async {
    final list = await _historyStore.load();
    if (list.isNotEmpty && mounted) {
      state = state.copyWith(history: list);
    }
  }

  Future<void> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final history = [
      trimmed,
      ...state.history.where((e) => e != trimmed),
    ].take(8).toList();
    // 保持既有 books 避免列表突兀白屏闪烁，通过 isLoading: true 呈现局部加载态；
    // 结果返回后在 _fetch 内原子替换。
    state = state.copyWith(
      isLoading: true,
      lastQuery: trimmed,
      history: history,
      clearError: true,
    );
    unawaited(_historyStore.save(history));
    await _fetch(page: 1, query: trimmed, append: false);
  }

  /// 删除一条搜索历史。
  void removeHistory(String query) {
    final history = state.history.where((e) => e != query).toList();
    state = state.copyWith(history: history);
    unawaited(_historyStore.save(history));
  }

  /// 清空全部搜索历史。
  void clearHistory() {
    state = state.copyWith(history: const <String>[]);
    unawaited(_historyStore.save(const <String>[]));
  }

  /// 清空当前搜索词与结果列表，返回初始荐书视图。
  void clearSearch() {
    state = SearchState(history: state.history);
  }

  Future<void> loadMore() async {
    if (!state.hasMore || state.isLoading || state.lastQuery.isEmpty) return;
    state = state.copyWith(isLoading: true, clearError: true);
    await _fetch(page: state.page + 1, query: state.lastQuery, append: true);
  }

  Future<void> setFilters(
    SearchFilters filters, {
    bool triggerSearch = true,
  }) async {
    _filters = filters;
    if (triggerSearch && state.lastQuery.isNotEmpty) {
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
        languages: _filters.languages,
        yearFrom: _filters.yearFrom,
        yearTo: _filters.yearTo,
        order: _filters.order,
      );
      state = state.copyWith(
        books: append ? [...state.books, ...result.books] : result.books,
        page: result.page,
        totalPages: result.totalPages,
        isLoading: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message,
        books: append ? null : const <SearchBook>[],
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: '搜索失败: $e',
        books: append ? null : const <SearchBook>[],
      );
    }
  }
}

final StateNotifierProvider<SearchController, SearchState>
searchControllerProvider = StateNotifierProvider<SearchController, SearchState>(
  (ref) {
    return SearchController(ref.watch(echoApiProvider));
  },
);

/// 与 flutter/material 的同名类区分。
typedef SearchControllerImpl = SearchController;
