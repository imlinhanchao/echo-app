import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/ebook_api_client.dart';
import '../api/models.dart';
import '../api/provider_token_store.dart';
import '../settings/standalone_config_store.dart';
import '../tts/tts_model_catalog.dart';
import 'book_source_driver.dart';
import 'book_source_models.dart';
import 'book_source_stores.dart';
import 'bundled_book_sources.dart';
import 'ebook_api_book_source_driver.dart';
import 'mirror_pool_manager.dart';
import 'opds_book_source_driver.dart';
import 'rule_book_source_driver.dart';

/// Immutable UI & business state exposed by [BookSourceManager].
@immutable
class BookSourcesState {
  const BookSourcesState({
    this.initialized = false,
    this.sources = const <ResolvedBookSource>[],
    this.subscriptions = const <BookSourceSubscription>[],
    this.activeSourceId = '',
    this.isSyncing = false,
  });

  final bool initialized;
  final List<ResolvedBookSource> sources;
  final List<BookSourceSubscription> subscriptions;
  final String activeSourceId;
  final bool isSyncing;

  List<ResolvedBookSource> get enabledSources =>
      sources.where((s) => s.isEnabled).toList(growable: false);

  ResolvedBookSource? sourceById(String id) {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return null;
    for (final s in sources) {
      if (s.id == trimmed) return s;
    }
    return null;
  }

  ResolvedBookSource? get activeSource {
    final matched = sourceById(activeSourceId);
    if (matched != null && matched.isEnabled) return matched;
    final enabled = enabledSources;
    return enabled.isEmpty ? null : enabled.first;
  }

  BookSourcesState copyWith({
    bool? initialized,
    List<ResolvedBookSource>? sources,
    List<BookSourceSubscription>? subscriptions,
    String? activeSourceId,
    bool? isSyncing,
  }) {
    return BookSourcesState(
      initialized: initialized ?? this.initialized,
      sources: sources ?? this.sources,
      subscriptions: subscriptions ?? this.subscriptions,
      activeSourceId: activeSourceId ?? this.activeSourceId,
      isSyncing: isSyncing ?? this.isSyncing,
    );
  }
}

/// Result of importing a subscription URL or JSON snippet.
@immutable
class BookSourceImportResult {
  const BookSourceImportResult({
    required this.addedCount,
    required this.updatedCount,
    required this.message,
    this.sourceIds = const <String>[],
  });

  final int addedCount;
  final int updatedCount;
  final String message;
  final List<String> sourceIds;
}

/// Startup preloader so [BookSourceManager] renders populated sources on frame 1.
abstract final class BookSourceBootstrap {
  static BookSourceBundle? _bundled;

  static BookSourceBundle get bundled {
    if (_bundled != null) return _bundled!;
    _bundled = loadBundledBookSourcesFallback();
    return _bundled!;
  }

  static Future<BookSourceBundle> init() async {
    try {
      final raw = await rootBundle.loadString(
        'assets/bundled-book-sources.json',
      );
      final parsed = parseBookSourceInput(raw);
      if (validateBookSourceBundle(parsed) == null) {
        _bundled = parsed;
        return parsed;
      }
    } catch (_) {}
    _bundled = loadBundledBookSourcesFallback();
    return _bundled!;
  }
}

/// Unified manager for client-side `rule`, `opds`, and `ebook_api` book sources:
/// - 3-tier persistence isolation (definitions vs user overlays vs secure creds)
/// - legacy `ebook-api` config/token auto-migration
/// - remote subscription fetch & background refresh (GitHub mirror aware)
/// - single-source switching, mirror probing, dynamic auth, search & download
class BookSourceManager extends StateNotifier<BookSourcesState> {
  BookSourceManager({
    required BookSourceRegistryStore registryStore,
    required BookSourceUserStateStore userStateStore,
    required BookSourceCredentialStore credentialStore,
    required ProviderTokenStore legacyTokenStore,
    required StandaloneConfig Function() readStandaloneConfig,
    required Dio dio,
    MirrorPoolManager? mirrorPool,
    Map<BookSourceDriverType, BookSourceDriver>? drivers,
    Future<BookSourceBundle> Function()? loadBundled,
    DateTime Function()? now,
  }) : _registryStore = registryStore,
       _userStateStore = userStateStore,
       _credentialStore = credentialStore,
       _legacyTokenStore = legacyTokenStore,
       _readStandaloneConfig = readStandaloneConfig,
       _dio = dio,
       _mirrorPool = mirrorPool ?? MirrorPoolManager(dio: dio),
       _loadBundled = loadBundled ?? (() async => BookSourceBootstrap.bundled),
       _now = now ?? (() => DateTime.now().toUtc()),
       super(
         _initialState(
           readStandaloneConfig: readStandaloneConfig,
           bundled: BookSourceBootstrap.bundled,
         ),
       ) {
    _drivers =
        drivers ??
        <BookSourceDriverType, BookSourceDriver>{
          BookSourceDriverType.rule: RuleBookSourceDriver(
            mirrorPool: _mirrorPool,
          ),
          BookSourceDriverType.opds: OpdsBookSourceDriver(
            mirrorPool: _mirrorPool,
          ),
          BookSourceDriverType.ebookApi: EbookApiBookSourceDriver(),
        };
    unawaited(ensureLoaded());
  }

  static BookSourcesState _initialState({
    required StandaloneConfig Function() readStandaloneConfig,
    required BookSourceBundle bundled,
  }) {
    final resolved = bundled.sources
        .map(
          (d) => ResolvedBookSource(
            definition: d,
            origin: BookSourceOrigin.bundled,
          ),
        )
        .toList(growable: false);
    return BookSourcesState(
      initialized: false,
      sources: resolved,
      activeSourceId: resolved.isNotEmpty ? resolved.first.id : '',
    );
  }

  final BookSourceRegistryStore _registryStore;
  final BookSourceUserStateStore _userStateStore;
  final BookSourceCredentialStore _credentialStore;
  final ProviderTokenStore _legacyTokenStore;
  final StandaloneConfig Function() _readStandaloneConfig;
  final Dio _dio;
  final MirrorPoolManager _mirrorPool;
  late final Map<BookSourceDriverType, BookSourceDriver> _drivers;
  final Future<BookSourceBundle> Function() _loadBundled;
  final DateTime Function() _now;

  Completer<void>? _loadCompleter;
  DateTime? _lastBgRefreshAt;

  MirrorPoolManager get mirrorPool => _mirrorPool;

  /// Exposes the current immutable [BookSourcesState] outside `StateNotifier` subclasses.
  BookSourcesState get currentState => state;

  /// Ensures registry, user overlays, credentials, and legacy migration are loaded.
  Future<void> ensureLoaded() async {
    if (state.initialized) return;
    if (_loadCompleter != null) {
      return _loadCompleter!.future;
    }
    final completer = Completer<void>();
    _loadCompleter = completer;
    try {
      await _reloadAll(performMigration: true);
      completer.complete();
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      _loadCompleter = null;
    }
  }

  Future<void> _reloadAll({bool performMigration = false}) async {
    final bundled = await _loadBundled();
    var registry = await _registryStore.read();
    var userState = await _userStateStore.read();
    var credsMap = Map<String, BookSourceCredentials>.of(
      await _credentialStore.readAll(),
    );

    if (performMigration && !registry.legacyMigrated) {
      final migrated = await _migrateLegacyEbookApi(
        registry: registry,
        userState: userState,
        credsMap: credsMap,
      );
      registry = migrated.registry;
      userState = migrated.userState;
      credsMap = migrated.credsMap;
    }

    final resolved = _mergeSources(
      bundled: bundled,
      registry: registry,
      userState: userState,
      credsMap: credsMap,
    );

    var activeId = userState.activeSourceId;
    final activeExists = resolved.any(
      (s) => s.id == activeId && s.isEnabled,
    );
    if (!activeExists) {
      final firstEnabled = resolved.where((s) => s.isEnabled).firstOrNull;
      activeId = firstEnabled?.id ?? '';
    }

    state = state.copyWith(
      initialized: true,
      sources: resolved,
      subscriptions: registry.subscriptions,
      activeSourceId: activeId,
    );
  }

  Future<
    ({
      BookSourceRegistryData registry,
      BookSourceUserState userState,
      Map<String, BookSourceCredentials> credsMap,
    })
  >
  _migrateLegacyEbookApi({
    required BookSourceRegistryData registry,
    required BookSourceUserState userState,
    required Map<String, BookSourceCredentials> credsMap,
  }) async {
    final cfg = _readStandaloneConfig();
    final legacyUrl = normalizeOriginUrl(cfg.ebookApiBaseUrl);
    var nextRegistry = registry.copyWith(legacyMigrated: true);
    var nextUserState = userState;
    final nextCreds = Map<String, BookSourceCredentials>.of(credsMap);

    if (legacyUrl.isNotEmpty) {
      const legacyId = 'ebook_api_legacy';
      final alreadyPresent = nextRegistry.localSources.any(
        (s) => s.id == legacyId,
      );
      if (!alreadyPresent) {
        final def = BookSourceDefinition(
          schemaVersion: kBookSourceSchemaVersion,
          id: legacyId,
          name: '自建 ebook-api',
          description: '从旧版 ebook-api 配置自动迁移',
          driver: BookSourceDriverType.ebookApi,
          defaultEnabled: true,
          domains: <String>[legacyUrl],
          ebookApi: const BookSourceEbookApiConfig(remoteProvider: 'zlib'),
        );
        nextRegistry = nextRegistry.copyWith(
          localSources: <BookSourceDefinition>[
            def,
            ...nextRegistry.localSources,
          ],
        );
      }

      final legacyStored = await _legacyTokenStore.read('zlib');
      final legacyApiKey = cfg.ebookApiKey.trim();
      final legacyToken = legacyStored?.credentialToken.trim() ?? '';
      if ((legacyApiKey.isNotEmpty || legacyToken.isNotEmpty) &&
          !nextCreds.containsKey(legacyId)) {
        final acc = legacyStored?.account;
        final migratedCreds = BookSourceCredentials(
          sourceId: legacyId,
          modeId: 'password',
          values: <String, String>{
            if (legacyApiKey.isNotEmpty) 'api_key': legacyApiKey,
            if (legacyToken.isNotEmpty) 'credential_token': legacyToken,
          },
          account: acc != null
              ? BookSourceAccountStatus(
                  configured: acc.configured,
                  status: acc.status,
                  email: acc.email,
                  dailyUsed: acc.dailyUsed,
                  dailyLimit: acc.dailyLimit,
                  dailyRemaining: acc.dailyRemaining,
                  quotaKnown: acc.quotaKnown,
                  lastVerifiedAt: acc.lastVerifiedAt,
                )
              : null,
          savedAt: legacyStored?.savedAt ?? _now(),
        );
        nextCreds[legacyId] = migratedCreds;
        await _credentialStore.write(migratedCreds);
      }

      if (nextUserState.activeSourceId.isEmpty) {
        nextUserState = nextUserState.copyWith(activeSourceId: legacyId);
        await _userStateStore.write(nextUserState);
      }
    }

    await _registryStore.write(nextRegistry);
    return (
      registry: nextRegistry,
      userState: nextUserState,
      credsMap: nextCreds,
    );
  }

  List<ResolvedBookSource> _mergeSources({
    required BookSourceBundle bundled,
    required BookSourceRegistryData registry,
    required BookSourceUserState userState,
    required Map<String, BookSourceCredentials> credsMap,
  }) {
    final map = <String, ResolvedBookSource>{};
    final orderedIds = <String>[];

    void put(
      BookSourceDefinition def, {
      required BookSourceOrigin origin,
      String subscriptionId = '',
      String subscriptionName = '',
    }) {
      if (!map.containsKey(def.id)) {
        orderedIds.add(def.id);
      }
      map[def.id] = ResolvedBookSource(
        definition: def,
        origin: origin,
        subscriptionId: subscriptionId,
        subscriptionName: subscriptionName,
        overlay: userState.overlays[def.id],
        credentials: credsMap[def.id],
      );
    }

    for (final def in bundled.sources) {
      put(def, origin: BookSourceOrigin.bundled);
    }
    for (final sub in registry.subscriptions) {
      for (final def in sub.sources) {
        put(
          def,
          origin: BookSourceOrigin.subscription,
          subscriptionId: sub.id,
          subscriptionName: sub.name,
        );
      }
    }
    for (final def in registry.localSources) {
      put(def, origin: BookSourceOrigin.local);
    }

    final list = orderedIds.map((id) => map[id]!).toList();
    list.sort((a, b) {
      final oa = a.overlay?.sortOrder;
      final ob = b.overlay?.sortOrder;
      if (oa != null && ob != null) return oa.compareTo(ob);
      if (oa != null) return -1;
      if (ob != null) return 1;
      return 0;
    });
    return List<ResolvedBookSource>.unmodifiable(list);
  }

  // ---------------------------------------------------------------------------
  // Source Selection, Enable/Disable, Network Overlays
  // ---------------------------------------------------------------------------

  Future<void> setActiveSource(String sourceId) async {
    await ensureLoaded();
    final target = state.sourceById(sourceId);
    if (target == null) return;
    var userState = await _userStateStore.read();
    if (!target.isEnabled) {
      final overlays = Map<String, BookSourceUserOverlay>.of(
        userState.overlays,
      );
      final cur = overlays[sourceId] ?? BookSourceUserOverlay(sourceId: sourceId);
      overlays[sourceId] = cur.copyWith(enabled: true);
      userState = userState.copyWith(overlays: overlays);
    }
    userState = userState.copyWith(activeSourceId: sourceId);
    await _userStateStore.write(userState);
    await _reloadAll();
  }

  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    await ensureLoaded();
    var userState = await _userStateStore.read();
    final overlays = Map<String, BookSourceUserOverlay>.of(userState.overlays);
    final cur = overlays[sourceId] ?? BookSourceUserOverlay(sourceId: sourceId);
    overlays[sourceId] = cur.copyWith(enabled: enabled);
    userState = userState.copyWith(overlays: overlays);
    await _userStateStore.write(userState);
    await _reloadAll();
  }

  /// Disables all configured sources (pure local-book mode).
  Future<void> disableAllSources() async {
    await ensureLoaded();
    var userState = await _userStateStore.read();
    final overlays = Map<String, BookSourceUserOverlay>.of(userState.overlays);
    for (final src in state.sources) {
      final cur = overlays[src.id] ?? BookSourceUserOverlay(sourceId: src.id);
      overlays[src.id] = cur.copyWith(enabled: false);
    }
    userState = userState.copyWith(activeSourceId: '', overlays: overlays);
    await _userStateStore.write(userState);
    await _reloadAll();
  }

  /// Enables bundled public-domain sources cleanly.
  Future<void> enableBundledSources() async {
    await ensureLoaded();
    var userState = await _userStateStore.read();
    final overlays = Map<String, BookSourceUserOverlay>.of(userState.overlays);
    String firstBundled = '';
    for (final src in state.sources) {
      if (src.isBundled) {
        if (firstBundled.isEmpty) firstBundled = src.id;
        final cur = overlays[src.id] ?? BookSourceUserOverlay(sourceId: src.id);
        overlays[src.id] = cur.copyWith(enabled: true);
      }
    }
    userState = userState.copyWith(
      overlays: overlays,
      activeSourceId: userState.activeSourceId.isEmpty
          ? firstBundled
          : userState.activeSourceId,
    );
    await _userStateStore.write(userState);
    await _reloadAll();
  }

  Future<void> updateNetworkOverlay(
    String sourceId, {
    String? preferredDomain,
    String? customDomain,
    String? proxyPrefix,
  }) async {
    await ensureLoaded();
    if (customDomain != null && customDomain.trim().isNotEmpty) {
      final urlErr = validateBookSourceUrl(customDomain);
      if (urlErr != null) {
        throw ApiException(code: 'INVALID_INPUT', message: urlErr);
      }
    }
    if (proxyPrefix != null && proxyPrefix.trim().isNotEmpty) {
      final proxyErr = validateBookSourceProxyPrefix(proxyPrefix);
      if (proxyErr != null) {
        throw ApiException(code: 'INVALID_INPUT', message: proxyErr);
      }
    }

    final userState = await _userStateStore.read();
    final overlays = Map<String, BookSourceUserOverlay>.of(userState.overlays);
    final cur = overlays[sourceId] ?? BookSourceUserOverlay(sourceId: sourceId);
    overlays[sourceId] = cur.copyWith(
      preferredDomain: preferredDomain != null
          ? normalizeOriginUrl(preferredDomain)
          : null,
      customDomain: customDomain != null
          ? (customDomain.trim().isEmpty
                ? ''
                : normalizeOriginUrl(customDomain))
          : null,
      proxyPrefix: proxyPrefix?.trim(),
    );
    await _userStateStore.write(userState.copyWith(overlays: overlays));
    await _reloadAll();
  }

  // ---------------------------------------------------------------------------
  // Import / Subscription / Export / Quick Add / Legacy Sync
  // ---------------------------------------------------------------------------

  Future<BookSourceImportResult> importFromJsonString(String rawJson) async {
    await ensureLoaded();
    final dynamic decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException catch (e) {
      throw ApiException(
        code: 'INVALID_INPUT',
        message: 'JSON 格式错误：${e.message}',
      );
    }
    if (decoded is! Map) {
      throw const ApiException(
        code: 'INVALID_INPUT',
        message: '书源配置 JSON 根节点必须为对象',
      );
    }
    final map = decoded.cast<String, dynamic>();
    final bundle = parseBookSourceInput(rawJson);
    final err = validateBookSourceBundle(bundle, rawJson: map);
    if (err != null) {
      throw ApiException(code: 'INVALID_INPUT', message: err);
    }

    final registry = await _registryStore.read();
    final locals = List<BookSourceDefinition>.of(registry.localSources);
    var added = 0;
    var updated = 0;
    final ids = <String>[];

    for (final src in bundle.sources) {
      ids.add(src.id);
      final idx = locals.indexWhere((e) => e.id == src.id);
      if (idx >= 0) {
        locals[idx] = src;
        updated++;
      } else {
        locals.add(src);
        added++;
      }
    }

    await _registryStore.write(registry.copyWith(localSources: locals));

    // If user had no active source yet, select the first imported enabled source.
    var userState = await _userStateStore.read();
    if (userState.activeSourceId.isEmpty && bundle.sources.isNotEmpty) {
      userState = userState.copyWith(activeSourceId: bundle.sources.first.id);
      await _userStateStore.write(userState);
    }

    await _reloadAll();
    return BookSourceImportResult(
      addedCount: added,
      updatedCount: updated,
      sourceIds: ids,
      message: '已导入 ${bundle.sources.length} 个书源（新增 $added，更新 $updated）',
    );
  }

  Future<BookSourceImportResult> importFromUrl(
    String rawUrl, {
    bool asSubscription = true,
  }) async {
    await ensureLoaded();
    final url = rawUrl.trim();
    final urlErr = validateBookSourceUrl(url);
    if (urlErr != null) {
      throw ApiException(code: 'INVALID_INPUT', message: urlErr);
    }

    state = state.copyWith(isSyncing: true);
    try {
      final fetched = await _fetchAndValidateRemoteBundle(url);
      final registry = await _registryStore.read();

      if (asSubscription) {
        final subId = 'sub_${_stableHash(url)}';
        final subName = fetched.bundle.name.isNotEmpty
            ? fetched.bundle.name
            : (Uri.tryParse(url)?.host ?? '书源订阅');
        final subs = List<BookSourceSubscription>.of(registry.subscriptions);
        final existingIdx = subs.indexWhere(
          (s) => s.url == url || s.id == subId,
        );
        final prevIds = existingIdx >= 0
            ? subs[existingIdx].sources.map((s) => s.id).toSet()
            : <String>{};
        var added = 0;
        var updated = 0;
        for (final src in fetched.bundle.sources) {
          if (prevIds.contains(src.id)) {
            updated++;
          } else {
            added++;
          }
        }
        final nextSub = BookSourceSubscription(
          id: subId,
          name: subName,
          url: url,
          configVersion: fetched.bundle.configVersion,
          configTtlHours: fetched.bundle.configTtlHours,
          fetchedAt: _now(),
          sources: fetched.bundle.sources,
        );
        if (existingIdx >= 0) {
          subs[existingIdx] = nextSub;
        } else {
          subs.add(nextSub);
        }
        // Only updates subscription definitions; overlays & credentials stay untouched!
        await _registryStore.write(registry.copyWith(subscriptions: subs));
        await _reloadAll();
        return BookSourceImportResult(
          addedCount: added,
          updatedCount: updated,
          sourceIds: fetched.bundle.sources
              .map((s) => s.id)
              .toList(growable: false),
          message:
              '已同步订阅「$subName」（共 ${fetched.bundle.sources.length} 个书源）',
        );
      } else {
        return await importFromJsonString(fetched.rawJson);
      }
    } finally {
      state = state.copyWith(isSyncing: false);
    }
  }

  Future<BookSourceImportResult> refreshSubscription(
    String subscriptionId,
  ) async {
    await ensureLoaded();
    final registry = await _registryStore.read();
    final target = registry.subscriptions
        .where((s) => s.id == subscriptionId)
        .firstOrNull;
    if (target == null) {
      throw const ApiException(code: 'NOT_FOUND', message: '未找到该订阅源');
    }
    return importFromUrl(target.url, asSubscription: true);
  }

  Future<void> refreshAllSubscriptions() async {
    await ensureLoaded();
    final subs = state.subscriptions;
    for (final sub in subs) {
      await refreshSubscription(sub.id);
    }
  }

  Future<void> maybeRefreshSubscriptionsInBackground() async {
    await ensureLoaded();
    final now = _now();
    if (_lastBgRefreshAt != null &&
        now.difference(_lastBgRefreshAt!) < const Duration(minutes: 10)) {
      return;
    }
    _lastBgRefreshAt = now;
    for (final sub in state.subscriptions) {
      final ttl = Duration(
        hours: sub.configTtlHours > 0
            ? sub.configTtlHours
            : kDefaultBookSourceConfigTtlHours,
      );
      if (now.difference(sub.fetchedAt) >= ttl) {
        try {
          await refreshSubscription(sub.id);
        } catch (_) {}
      }
    }
  }

  Future<void> removeSubscription(String subscriptionId) async {
    await ensureLoaded();
    final registry = await _registryStore.read();
    final nextSubs = registry.subscriptions
        .where((s) => s.id != subscriptionId)
        .toList(growable: false);
    await _registryStore.write(registry.copyWith(subscriptions: nextSubs));
    await _reloadAll();
  }

  Future<ResolvedBookSource> addQuickOpds({
    required String name,
    required String catalogUrl,
    String searchUrl = '',
    String username = '',
    String password = '',
  }) async {
    await ensureLoaded();
    final urlErr = validateBookSourceUrl(catalogUrl);
    if (urlErr != null) {
      throw ApiException(code: 'INVALID_INPUT', message: urlErr);
    }
    if (searchUrl.trim().isNotEmpty) {
      final sErr = validateBookSourceUrl(searchUrl);
      if (sErr != null) {
        throw ApiException(code: 'INVALID_INPUT', message: '搜索地址无效：$sErr');
      }
    }

    final normUrl = normalizeOriginUrl(catalogUrl);
    final trimmedName = name.trim().isEmpty
        ? (Uri.tryParse(normUrl)?.host ?? 'OPDS 书库')
        : name.trim();
    final id = 'opds_${_stableHash('$normUrl|$trimmedName')}';

    final def = BookSourceDefinition(
      schemaVersion: kBookSourceSchemaVersion,
      id: id,
      name: trimmedName,
      description: 'OPDS 书库 ($normUrl)',
      driver: BookSourceDriverType.opds,
      defaultEnabled: true,
      domains: <String>[normUrl],
      opds: BookSourceOpdsConfig(searchUrl: searchUrl.trim()),
      auth: const BookSourceAuthConfig(
        required: false,
        modes: <BookSourceAuthMode>[
          BookSourceAuthMode(
            id: 'basic',
            label: '账号密码 (HTTP Basic)',
            fields: <BookSourceAuthField>[
              BookSourceAuthField(key: 'username', label: '用户名', type: 'text'),
              BookSourceAuthField(
                key: 'password',
                label: '密码',
                type: 'password',
              ),
            ],
          ),
        ],
      ),
    );

    final registry = await _registryStore.read();
    final locals = List<BookSourceDefinition>.of(registry.localSources)
      ..removeWhere((s) => s.id == id)
      ..add(def);
    await _registryStore.write(registry.copyWith(localSources: locals));

    if (username.trim().isNotEmpty || password.isNotEmpty) {
      await _credentialStore.write(
        BookSourceCredentials(
          sourceId: id,
          modeId: 'basic',
          values: <String, String>{
            if (username.trim().isNotEmpty) 'username': username.trim(),
            if (password.isNotEmpty) 'password': password,
          },
          account: BookSourceAccountStatus(
            configured: true,
            status: 'ok',
            email: username.trim(),
            lastVerifiedAt: _now(),
          ),
          savedAt: _now(),
        ),
      );
    }

    final userState = await _userStateStore.read();
    if (userState.activeSourceId.isEmpty) {
      await _userStateStore.write(userState.copyWith(activeSourceId: id));
    }

    await _reloadAll();
    return state.sourceById(id)!;
  }

  Future<ResolvedBookSource> addQuickEbookApi({
    required String name,
    required String baseUrl,
    String apiKey = '',
    String remoteProvider = 'zlib',
    String idOverride = '',
  }) async {
    await ensureLoaded();
    final normalized = normalizeEbookApiUrl(baseUrl);
    final urlErr = validateEbookApiUrl(normalized);
    if (urlErr != null) {
      throw ApiException(code: 'INVALID_INPUT', message: urlErr);
    }
    final trimmedName = name.trim().isEmpty ? '自建 ebook-api' : name.trim();
    final id = idOverride.isNotEmpty
        ? idOverride
        : 'ebook_api_${_stableHash('$normalized|$remoteProvider')}';

    final def = BookSourceDefinition(
      schemaVersion: kBookSourceSchemaVersion,
      id: id,
      name: trimmedName,
      description: '自建 ebook-api 服务 ($normalized)',
      driver: BookSourceDriverType.ebookApi,
      defaultEnabled: true,
      domains: <String>[normalized],
      ebookApi: BookSourceEbookApiConfig(
        remoteProvider: remoteProvider.trim().isEmpty
            ? 'zlib'
            : remoteProvider.trim(),
      ),
    );

    final registry = await _registryStore.read();
    final locals = List<BookSourceDefinition>.of(registry.localSources)
      ..removeWhere((s) => s.id == id)
      ..add(def);
    await _registryStore.write(registry.copyWith(localSources: locals));

    final existingCreds = await _credentialStore.read(id);
    final nextValues = <String, String>{
      ...(existingCreds?.values ?? const <String, String>{}),
    };
    if (apiKey.trim().isNotEmpty) {
      nextValues['api_key'] = apiKey.trim();
    } else {
      nextValues.remove('api_key');
    }
    if (nextValues.isNotEmpty) {
      await _credentialStore.write(
        BookSourceCredentials(
          sourceId: id,
          modeId: existingCreds?.modeId ?? 'password',
          values: nextValues,
          account: existingCreds?.account,
          savedAt: _now(),
        ),
      );
    }

    await _reloadAll();
    return state.sourceById(id)!;
  }

  Future<void> removeSource(String sourceId) async {
    await ensureLoaded();
    final registry = await _registryStore.read();
    final nextLocals = registry.localSources
        .where((s) => s.id != sourceId)
        .toList(growable: false);
    await _registryStore.write(registry.copyWith(localSources: nextLocals));

    final userState = await _userStateStore.read();
    final nextOverlays = Map<String, BookSourceUserOverlay>.of(
      userState.overlays,
    )..remove(sourceId);
    final nextActive = userState.activeSourceId == sourceId
        ? ''
        : userState.activeSourceId;
    await _userStateStore.write(
      userState.copyWith(activeSourceId: nextActive, overlays: nextOverlays),
    );
    await _credentialStore.delete(sourceId);
    await _reloadAll();
  }

  /// Exports a single pure rule definition JSON (physically devoid of credentials/overlays).
  String exportSanitizedJson(String sourceId) {
    final src = state.sourceById(sourceId);
    if (src == null) {
      throw const ApiException(code: 'NOT_FOUND', message: '未找到指定书源');
    }
    return src.definition.toPrettyExportJson();
  }

  // ---------------------------------------------------------------------------
  // Runtime Driver Operations (Auth / Verify / Probe / Search / Detail / Download)
  // ---------------------------------------------------------------------------

  BookSourceDriver _driverFor(ResolvedBookSource source) =>
      _drivers[source.driver]!;

  Future<ProviderAccountInfo> authenticateSource({
    required String sourceId,
    required String modeId,
    required Map<String, String> inputs,
  }) async {
    await ensureLoaded();
    final src = state.sourceById(sourceId);
    if (src == null) {
      throw const ApiException(code: 'PROVIDER_NOT_FOUND', message: '未找到书源');
    }
    try {
      final creds = await _driverFor(
        src,
      ).authenticate(src, modeId: modeId, inputs: inputs);
      await _credentialStore.write(creds);
      await _reloadAll();
      return _toProviderAccountInfo(creds.account);
    } on BookSourceException catch (e) {
      throw _toApiException(e);
    }
  }

  Future<ProviderAccountInfo> verifySource(String sourceId) async {
    await ensureLoaded();
    final src = state.sourceById(sourceId);
    if (src == null) {
      throw const ApiException(code: 'PROVIDER_NOT_FOUND', message: '未找到书源');
    }
    try {
      final acc = await _driverFor(src).verify(src);
      final existing = await _credentialStore.read(sourceId);
      await _credentialStore.write(
        BookSourceCredentials(
          sourceId: sourceId,
          modeId: existing?.modeId ?? '',
          values: existing?.values ?? const <String, String>{},
          account: acc,
          savedAt: _now(),
        ),
      );
      await _reloadAll();
      return _toProviderAccountInfo(acc);
    } on BookSourceException catch (e) {
      if (e.code == 'SESSION_EXPIRED') {
        final existing = await _credentialStore.read(sourceId);
        if (existing != null) {
          await _credentialStore.write(
            existing.copyWith(
              account: BookSourceAccountStatus(
                configured: true,
                status: 'needs_login',
                email: existing.account?.email ?? '',
                lastVerifiedAt: _now(),
              ),
            ),
          );
          await _reloadAll();
        }
      }
      throw _toApiException(e);
    }
  }

  Future<void> clearCredentials(String sourceId) async {
    await ensureLoaded();
    await _credentialStore.delete(sourceId);
    await _reloadAll();
  }

  Future<List<MirrorProbeResult>> probeSourceDomains(String sourceId) async {
    await ensureLoaded();
    final src = state.sourceById(sourceId);
    if (src == null) return const <MirrorProbeResult>[];
    return _driverFor(src).probeDomains(src);
  }

  Future<List<ProviderInfo>> listAsProviderInfos() async {
    await ensureLoaded();
    return state.sources.map(_toProviderInfo).toList(growable: false);
  }

  Future<SearchPageInfo> search({
    required String query,
    String provider = '',
    int page = 1,
    int limit = 20,
    List<String> extensions = const <String>[],
    List<String> languages = const <String>[],
    int yearFrom = 0,
    int yearTo = 0,
    String order = '',
  }) async {
    await ensureLoaded();
    final target = provider.trim().isNotEmpty
        ? (state.sourceById(provider) ?? state.activeSource)
        : state.activeSource;
    if (target == null || !target.isEnabled) {
      throw const ApiException(
        code: 'EBOOK_API_NOT_CONFIGURED',
        message: '尚未启用任何在线书源，请先在「我的 → 书源管理」中启用或添加书源',
      );
    }
    try {
      final res = await _driverFor(target).search(
        target,
        BookSourceSearchRequest(
          query: query,
          page: page,
          limit: limit,
          extensions: extensions,
          languages: languages,
          yearFrom: yearFrom,
          yearTo: yearTo,
          order: order,
        ),
      );
      return SearchPageInfo(
        books: res.books.map(_toSearchBook).toList(growable: false),
        page: res.page,
        totalPages: res.totalPages,
        provider: target.id,
      );
    } on BookSourceException catch (e) {
      throw _toApiException(e);
    }
  }

  Future<SearchBook> getBookDetail(
    String providerId,
    String ref, {
    SearchBook? baseBook,
  }) async {
    await ensureLoaded();
    final target = state.sourceById(providerId) ?? state.activeSource;
    if (target == null) {
      if (baseBook != null) return baseBook;
      throw const ApiException(code: 'PROVIDER_NOT_FOUND', message: '未找到书源');
    }
    try {
      final res = await _driverFor(target).getBookDetail(
        target,
        ref,
        baseBook: baseBook != null ? _fromSearchBook(baseBook) : null,
      );
      return _toSearchBook(res);
    } on BookSourceException catch (e) {
      throw _toApiException(e);
    }
  }

  Future<DownloadedBookFile> downloadBook({
    required String providerId,
    required String ref,
    required String savePath,
    SearchBook? meta,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    await ensureLoaded();
    final target = state.sourceById(providerId) ?? state.activeSource;
    if (target == null) {
      throw const ApiException(
        code: 'EBOOK_API_NOT_CONFIGURED',
        message: '未找到可用书源，请先在「书源管理」中配置',
      );
    }
    try {
      final res = await _driverFor(target).downloadBook(
        target,
        ref: ref,
        savePath: savePath,
        meta: meta != null ? _fromSearchBook(meta) : null,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
      return DownloadedBookFile(
        savePath: res.savePath,
        filename: res.filename,
        format: res.format,
        sizeBytes: res.sizeBytes,
      );
    } on BookSourceException catch (e) {
      throw _toApiException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Remote Fetch & Model Conversions
  // ---------------------------------------------------------------------------

  Future<({BookSourceBundle bundle, String rawJson})>
  _fetchAndValidateRemoteBundle(String targetUrl) async {
    final candidates = _buildCandidateRemoteUrls(targetUrl);
    String? lastError;

    for (final candidate in candidates) {
      try {
        final resp = await _dio.get<String>(
          candidate,
          options: Options(
            responseType: ResponseType.plain,
            headers: const <String, String>{
              'Accept': 'application/json,text/plain,*/*',
            },
            connectTimeout: const Duration(seconds: 12),
            receiveTimeout: const Duration(seconds: 20),
          ),
        );
        final rawBody = resp.data ?? '';
        if (rawBody.trim().isEmpty) {
          lastError = '服务器返回内容为空';
          continue;
        }
        final decoded = jsonDecode(rawBody);
        if (decoded is! Map) {
          lastError = '书源配置根节点必须为 JSON 对象';
          continue;
        }
        final map = decoded.cast<String, dynamic>();
        final parsed = parseBookSourceInput(rawBody);
        final err = validateBookSourceBundle(parsed, rawJson: map);
        if (err != null) {
          lastError = '规则校验失败：$err';
          continue;
        }
        return (bundle: parsed, rawJson: rawBody);
      } on FormatException catch (e) {
        lastError = '规则格式错误：${e.message}';
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        lastError = status != null
            ? '请求书源配置失败（HTTP $status）'
            : '网络连接失败，请稍后重试';
      } catch (e) {
        lastError = '拉取书源配置失败：$e';
      }
    }

    throw ApiException(
      code: 'PROVIDER_UNAVAILABLE',
      message: lastError ?? '拉取书源配置失败',
    );
  }

  List<String> _buildCandidateRemoteUrls(String targetUrl) {
    final uri = Uri.tryParse(targetUrl);
    if (uri == null) return <String>[targetUrl];
    final isGitHub =
        uri.host == 'raw.githubusercontent.com' || uri.host == 'github.com';
    if (!isGitHub) return <String>[targetUrl];

    final cfg = _readStandaloneConfig();
    final mirrorId = cfg.ttsDownloadMirror;
    if (mirrorId == TtsModelCatalog.mirrorGithub) {
      return <String>[targetUrl];
    }

    var prefix = '';
    if (mirrorId == TtsModelCatalog.mirrorCustom) {
      if (TtsModelCatalog.validateCustomMirrorPrefix(
            cfg.customTtsMirrorPrefix,
          ) ==
          null) {
        prefix = TtsModelCatalog.normalizeMirrorPrefix(
          cfg.customTtsMirrorPrefix,
        );
      }
    } else {
      prefix = TtsModelCatalog.normalizeMirrorPrefix(
        TtsModelCatalog.mirrorById(mirrorId).prefix,
      );
    }
    if (prefix.isEmpty) return <String>[targetUrl];
    final mirrored = '$prefix$targetUrl';
    return mirrored == targetUrl
        ? <String>[targetUrl]
        : <String>[mirrored, targetUrl];
  }

  static ProviderAccountInfo _toProviderAccountInfo(
    BookSourceAccountStatus? acc,
  ) {
    if (acc == null) return const ProviderAccountInfo(configured: false);
    return ProviderAccountInfo(
      configured: acc.configured,
      status: acc.status,
      email: acc.email,
      dailyUsed: acc.dailyUsed,
      dailyLimit: acc.dailyLimit,
      dailyRemaining: acc.dailyRemaining,
      quotaKnown: acc.quotaKnown,
      lastVerifiedAt: acc.lastVerifiedAt,
    );
  }

  static ProviderInfo _toProviderInfo(ResolvedBookSource src) {
    return ProviderInfo(
      id: src.id,
      name: src.name,
      capabilities: <String>[
        'search',
        if (src.definition.detail?.isConfigured ?? false) 'detail',
        'download',
        if (src.hasAuthModes) 'login',
      ],
      defaultDomain: src.effectiveDomains.isNotEmpty
          ? src.effectiveDomains.first
          : '',
      domains: src.effectiveDomains,
      credentialKeys: src.definition.auth?.credentialKeys ?? const <String>[],
      account: src.account != null
          ? _toProviderAccountInfo(src.account)
          : (src.hasCredentials
                ? const ProviderAccountInfo(configured: true, status: 'ok')
                : null),
    );
  }

  static SearchBook _toSearchBook(BookSourceSearchBook b) => SearchBook(
    provider: b.provider,
    ref: b.ref,
    title: b.title,
    authors: b.authors,
    year: b.year,
    publisher: b.publisher,
    language: b.language,
    format: b.format,
    size: b.size,
    isbn: b.isbn,
    coverUrl: b.coverUrl,
    description: b.description,
    sourceUrl: b.sourceUrl,
    imageHeaders: b.imageHeaders,
    sourceVars: b.sourceVars,
  );

  static BookSourceSearchBook _fromSearchBook(SearchBook b) =>
      BookSourceSearchBook(
        provider: b.provider,
        ref: b.ref,
        title: b.title,
        authors: b.authors,
        year: b.year,
        publisher: b.publisher,
        language: b.language,
        format: b.format,
        size: b.size,
        isbn: b.isbn,
        coverUrl: b.coverUrl,
        description: b.description,
        sourceUrl: b.sourceUrl,
        imageHeaders: b.imageHeaders,
        sourceVars: b.sourceVars,
      );

  static ApiException _toApiException(BookSourceException e) =>
      ApiException(code: e.code, message: e.message, statusCode: e.statusCode);
}

String _stableHash(String input) {
  var h1 = 0x811c9dc5;
  var h2 = 0x01000193;
  for (final byte in utf8.encode(input)) {
    h1 ^= byte;
    h1 = (h1 * 0x01000193) & 0xffffffff;
    h2 = ((h2 * 31) ^ byte) & 0xffffffff;
  }
  return '${h1.toRadixString(16).padLeft(8, '0')}${h2.toRadixString(16).padLeft(8, '0')}';
}

final Provider<Dio> bookSourceDioProvider = Provider<Dio>(
  (ref) => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 45),
      sendTimeout: const Duration(seconds: 15),
    ),
  ),
);

final Provider<MirrorPoolManager> bookSourceMirrorPoolProvider =
    Provider<MirrorPoolManager>(
      (ref) => MirrorPoolManager(dio: ref.watch(bookSourceDioProvider)),
    );

final StateNotifierProvider<BookSourceManager, BookSourcesState>
bookSourceControllerProvider =
    StateNotifierProvider<BookSourceManager, BookSourcesState>((ref) {
      return BookSourceManager(
        registryStore: ref.watch(bookSourceRegistryStoreProvider),
        userStateStore: ref.watch(bookSourceUserStateStoreProvider),
        credentialStore: ref.watch(bookSourceCredentialStoreProvider),
        legacyTokenStore: ref.watch(providerTokenStoreProvider),
        readStandaloneConfig: () => ref.read(standaloneConfigProvider),
        dio: ref.watch(bookSourceDioProvider),
        mirrorPool: ref.watch(bookSourceMirrorPoolProvider),
      );
    });
