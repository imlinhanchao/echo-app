import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/discover/discover_config.dart';
import '../../core/discover/discover_models.dart';
import '../../core/discover/discover_repository.dart';
import '../../core/settings/standalone_config_store.dart';

/// 荐书模块状态。
@immutable
class DiscoverState {
  const DiscoverState({
    this.snapshot,
    this.activeSourceId = '',
    this.activeFeedId = '',
    this.feedData,
    this.isLoading = false,
    this.isUpdatingConfig = false,
    this.error,
    this.notice,
  });

  final DiscoverConfigSnapshot? snapshot;
  final String activeSourceId;
  final String activeFeedId;
  final DiscoverFeedData? feedData;
  final bool isLoading;
  final bool isUpdatingConfig;
  final String? error;
  final String? notice;

  List<DiscoverSourceConfig> get enabledSources =>
      snapshot?.config.enabledSources ?? const <DiscoverSourceConfig>[];

  DiscoverSourceConfig? get activeSource {
    final cfg = snapshot?.config;
    if (cfg == null) return null;
    if (activeSourceId.isNotEmpty) {
      final matched = cfg.sourceById(activeSourceId);
      if (matched != null) return matched;
    }
    return cfg.resolveDefaultSource();
  }

  DiscoverFeedConfig? get activeFeed {
    final src = activeSource;
    if (src == null || src.feeds.isEmpty) return null;
    if (activeFeedId.isNotEmpty) {
      final matched = src.feedById(activeFeedId);
      if (matched != null) return matched;
    }
    return src.feeds.first;
  }

  DiscoverState copyWith({
    DiscoverConfigSnapshot? snapshot,
    String? activeSourceId,
    String? activeFeedId,
    DiscoverFeedData? feedData,
    bool clearFeedData = false,
    bool? isLoading,
    bool? isUpdatingConfig,
    String? error,
    bool clearError = false,
    String? notice,
    bool clearNotice = false,
  }) => DiscoverState(
    snapshot: snapshot ?? this.snapshot,
    activeSourceId: activeSourceId ?? this.activeSourceId,
    activeFeedId: activeFeedId ?? this.activeFeedId,
    feedData: clearFeedData ? null : (feedData ?? this.feedData),
    isLoading: isLoading ?? this.isLoading,
    isUpdatingConfig: isUpdatingConfig ?? this.isUpdatingConfig,
    error: clearError ? null : (error ?? this.error),
    notice: clearNotice ? null : (notice ?? this.notice),
  );
}

/// 荐书频道切换、刷新与远程规则更新控制器。
class DiscoverController extends StateNotifier<DiscoverState> {
  DiscoverController(
    this._repository, {
    String initialSourceId = '',
    ValueChanged<String>? onSourceChanged,
  }) : _initialSourceId = initialSourceId.trim(),
       _onSourceChanged = onSourceChanged,
       super(DiscoverState(activeSourceId: initialSourceId.trim()));

  final DiscoverRepository _repository;
  final String _initialSourceId;
  final ValueChanged<String>? _onSourceChanged;
  bool _initialized = false;
  bool _feedLoaded = false;
  int _requestSeq = 0;

  /// 仅加载当前规则配置快照（供设置页展示，不触发列表抓取）。
  Future<void> ensureConfigLoaded() async {
    if (state.snapshot != null) return;
    final snapshot = await _repository.loadActiveConfig();
    if (!mounted) return;
    final preferredId = state.activeSourceId.isNotEmpty
        ? state.activeSourceId
        : _initialSourceId;
    final source =
        snapshot.config.sourceById(preferredId) ??
        snapshot.config.resolveDefaultSource();
    final feed = source == null || source.feeds.isEmpty
        ? null
        : (source.feedById(state.activeFeedId) ?? source.feeds.first);
    state = state.copyWith(
      snapshot: snapshot,
      activeSourceId: source?.id ?? '',
      activeFeedId: feed?.id ?? '',
    );
  }

  /// 首次进入时幂等加载默认规则与首屏榜单。
  Future<void> ensureLoaded() async {
    if (_initialized || state.isLoading) return;
    _initialized = true;
    _feedLoaded = true;

    final snapshot = await _repository.loadActiveConfig();
    if (!mounted) return;

    final preferredId = state.activeSourceId.isNotEmpty
        ? state.activeSourceId
        : _initialSourceId;
    final source =
        snapshot.config.sourceById(preferredId) ??
        snapshot.config.resolveDefaultSource();
    final feed = source == null || source.feeds.isEmpty
        ? null
        : (source.feedById(state.activeFeedId) ?? source.feeds.first);

    state = state.copyWith(
      snapshot: snapshot,
      activeSourceId: source?.id ?? '',
      activeFeedId: feed?.id ?? '',
      isLoading: source != null && feed != null,
      clearError: true,
    );

    if (source != null && feed != null) {
      await _fetchFeed(source.id, feed.id, forceRefresh: false);
    }
    if (!mounted) return;
    unawaited(_checkBackgroundConfigUpdate());
  }

  Future<void> _checkBackgroundConfigUpdate() async {
    final updatedSnapshot = await _repository
        .maybeRefreshRemoteConfigInBackground();
    if (!mounted || updatedSnapshot == null) return;

    final source =
        updatedSnapshot.config.sourceById(state.activeSourceId) ??
        updatedSnapshot.config.resolveDefaultSource();
    final feed = source == null || source.feeds.isEmpty
        ? null
        : (source.feedById(state.activeFeedId) ?? source.feeds.first);

    state = state.copyWith(
      snapshot: updatedSnapshot,
      activeSourceId: source?.id ?? '',
      activeFeedId: feed?.id ?? '',
    );
    if (source != null && feed != null) {
      await _fetchFeed(source.id, feed.id, forceRefresh: false);
    }
  }

  /// 切换荐书源。
  Future<void> selectSource(String sourceId) async {
    _feedLoaded = true;
    final snapshot = state.snapshot ?? await _repository.loadActiveConfig();
    if (!mounted) return;
    final source = snapshot.config.sourceById(sourceId);
    if (source == null || source.feeds.isEmpty) return;
    if (source.id == state.activeSourceId &&
        state.feedData != null &&
        state.error == null) {
      return;
    }
    final feed = source.feeds.first;
    _onSourceChanged?.call(source.id);
    state = state.copyWith(
      snapshot: snapshot,
      activeSourceId: source.id,
      activeFeedId: feed.id,
      clearFeedData: true,
      isLoading: true,
      clearError: true,
      clearNotice: true,
    );
    await _fetchFeed(source.id, feed.id, forceRefresh: false);
  }

  /// 切换当前源下的榜单/书单频道。
  Future<void> selectFeed(String feedId) async {
    _feedLoaded = true;
    final source = state.activeSource;
    if (source == null) return;
    final feed = source.feedById(feedId);
    if (feed == null) return;
    if (feed.id == state.activeFeedId &&
        state.feedData != null &&
        state.error == null) {
      return;
    }
    state = state.copyWith(
      activeFeedId: feed.id,
      clearFeedData: true,
      isLoading: true,
      clearError: true,
      clearNotice: true,
    );
    await _fetchFeed(source.id, feed.id, forceRefresh: false);
  }

  /// 手动强制刷新当前频道。
  Future<void> refreshFeed() async {
    final source = state.activeSource;
    final feed = state.activeFeed;
    if (source == null || feed == null) {
      _initialized = false;
      await ensureLoaded();
      return;
    }
    state = state.copyWith(isLoading: true, clearError: true, clearNotice: true);
    await _fetchFeed(source.id, feed.id, forceRefresh: true);
  }

  /// 从远程 URL 手动更新解析规则配置。
  Future<DiscoverConfigUpdateResult> refreshRemoteConfig({
    String? overrideUrl,
  }) async {
    state = state.copyWith(isUpdatingConfig: true, clearNotice: true);
    final result = await _repository.refreshRemoteConfig(
      overrideUrl: overrideUrl,
    );
    if (!mounted) return result;

    final nextSnapshot = result.snapshot;
    final source =
        nextSnapshot.config.sourceById(state.activeSourceId) ??
        nextSnapshot.config.resolveDefaultSource();
    final feed = source == null || source.feeds.isEmpty
        ? null
        : (source.feedById(state.activeFeedId) ?? source.feeds.first);

    state = state.copyWith(
      snapshot: nextSnapshot,
      activeSourceId: source?.id ?? '',
      activeFeedId: feed?.id ?? '',
      clearFeedData: result.updated,
      isUpdatingConfig: false,
      notice: result.message,
    );

    if (result.updated && _feedLoaded && source != null && feed != null) {
      state = state.copyWith(isLoading: true, clearError: true);
      await _fetchFeed(source.id, feed.id, forceRefresh: false);
    }
    return result;
  }

  /// 清空远程规则缓存，恢复内置默认规则。
  Future<DiscoverConfigSnapshot> resetConfig() async {
    state = state.copyWith(isUpdatingConfig: true, clearNotice: true);
    final snapshot = await _repository.resetToBundledConfig();
    if (!mounted) return snapshot;

    final source = snapshot.config.resolveDefaultSource();
    final feed = source == null || source.feeds.isEmpty
        ? null
        : source.feeds.first;

    state = state.copyWith(
      snapshot: snapshot,
      activeSourceId: source?.id ?? '',
      activeFeedId: feed?.id ?? '',
      clearFeedData: true,
      isUpdatingConfig: false,
      isLoading: _feedLoaded && source != null && feed != null,
      clearError: true,
      notice: '已恢复内置默认荐书规则',
    );

    if (_feedLoaded && source != null && feed != null) {
      await _fetchFeed(source.id, feed.id, forceRefresh: false);
    }
    return snapshot;
  }

  Future<void> _fetchFeed(
    String sourceId,
    String feedId, {
    required bool forceRefresh,
  }) async {
    final seq = ++_requestSeq;
    try {
      final data = await _repository.loadFeed(
        sourceId,
        feedId,
        forceRefresh: forceRefresh,
      );
      if (!mounted || seq != _requestSeq) return;
      state = state.copyWith(
        feedData: data,
        isLoading: false,
        clearError: true,
        notice: data.isStale ? '网络异常，当前展示本地缓存内容' : null,
        clearNotice: !data.isStale,
      );
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }
}

final StateNotifierProvider<DiscoverController, DiscoverState>
discoverControllerProvider =
    StateNotifierProvider<DiscoverController, DiscoverState>((ref) {
      final initialSourceId = ref.read(standaloneConfigProvider).discoverSourceId;
      return DiscoverController(
        ref.watch(discoverRepositoryProvider),
        initialSourceId: initialSourceId,
        onSourceChanged: (sourceId) {
          unawaited(
            ref
                .read(standaloneConfigProvider.notifier)
                .setDiscoverSourceId(sourceId),
          );
        },
      );
    });
