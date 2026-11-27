import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/standalone_config_store.dart';
import '../tts/download_keepalive_service.dart';
import '../tts/sentence_splitter.dart';
import 'language_detector.dart';
import 'translation_cache_store.dart';
import 'translation_engine.dart';
import 'translation_model_manager.dart';
import 'translation_models.dart';

String _chapterMapKey(
  int bookId,
  int chapterIndex,
  String targetLangCode,
  String modelId,
) => '$bookId::$chapterIndex::$targetLangCode::${modelId.isEmpty ? "default" : modelId}';

String _taskUniqueKey(String chapterKey, String hash) => '$chapterKey::$hash';

class _QueuedTranslationTask {
  _QueuedTranslationTask({
    required this.priority,
    required this.order,
    required this.chapterKey,
    required this.bookId,
    required this.chapterIndex,
    required this.targetLang,
    required this.modelId,
    required this.modelPath,
    required this.segment,
    this.isPretranslate = false,
  });

  final int priority; // 0: 当前页, 1: 后台预翻同章后续, 2: 手动整章/整书预翻
  final int order;
  final String chapterKey;
  final int bookId;
  final int chapterIndex;
  final TranslationTargetLanguage targetLang;
  final String modelId;
  final String modelPath;
  final ParagraphSegment segment;
  final bool isPretranslate;

  String get uniqueKey => _taskUniqueKey(chapterKey, segment.hash);
}

class _PhraseTranslationRequest {
  _PhraseTranslationRequest({
    required this.key,
    required this.sourceText,
    required this.targetLang,
    required this.modelPath,
    required this.maxTokens,
    required this.completer,
  });

  final String key;
  final String sourceText;
  final TranslationTargetLanguage targetLang;
  final String modelPath;
  final int maxTokens;
  final Completer<String?> completer;
}

@immutable
class TranslationSchedulerState {
  const TranslationSchedulerState({
    this.chapterTranslations = const <String, Map<String, String>>{},
    this.activeParagraphKeys = const <String>{},
    this.currentTranslatingKey,
    this.pretranslateRunning = false,
    this.pretranslateTitle = '',
    this.pretranslateBookId,
    this.pretranslateCompleted = 0,
    this.pretranslateTotal = 0,
    this.lastError,
  });

  final Map<String, Map<String, String>> chapterTranslations;
  final Set<String> activeParagraphKeys;
  final String? currentTranslatingKey;
  final bool pretranslateRunning;
  final String pretranslateTitle;
  final int? pretranslateBookId;
  final int pretranslateCompleted;
  final int pretranslateTotal;
  final String? lastError;

  Map<String, String> chapterMapFor({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
  }) {
    return chapterTranslations[_chapterMapKey(
          bookId,
          chapterIndex,
          targetLangCode,
          modelId,
        )] ??
        const <String, String>{};
  }

  String? translationOf({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
    required String paragraphHash,
  }) {
    return chapterMapFor(
      bookId: bookId,
      chapterIndex: chapterIndex,
      targetLangCode: targetLangCode,
      modelId: modelId,
    )[paragraphHash];
  }

  bool isTranslatingParagraph({
    required int bookId,
    required int chapterIndex,
    required String targetLangCode,
    required String modelId,
    required String paragraphHash,
  }) {
    final ck = _chapterMapKey(bookId, chapterIndex, targetLangCode, modelId);
    return activeParagraphKeys.contains(_taskUniqueKey(ck, paragraphHash));
  }

  TranslationSchedulerState copyWith({
    Map<String, Map<String, String>>? chapterTranslations,
    Set<String>? activeParagraphKeys,
    String? currentTranslatingKey,
    bool clearCurrentTranslating = false,
    bool? pretranslateRunning,
    String? pretranslateTitle,
    int? pretranslateBookId,
    bool clearPretranslateBook = false,
    int? pretranslateCompleted,
    int? pretranslateTotal,
    String? lastError,
    bool clearLastError = false,
  }) {
    return TranslationSchedulerState(
      chapterTranslations: chapterTranslations ?? this.chapterTranslations,
      activeParagraphKeys: activeParagraphKeys ?? this.activeParagraphKeys,
      currentTranslatingKey: clearCurrentTranslating
          ? null
          : (currentTranslatingKey ?? this.currentTranslatingKey),
      pretranslateRunning: pretranslateRunning ?? this.pretranslateRunning,
      pretranslateTitle: pretranslateTitle ?? this.pretranslateTitle,
      pretranslateBookId: clearPretranslateBook
          ? null
          : (pretranslateBookId ?? this.pretranslateBookId),
      pretranslateCompleted:
          pretranslateCompleted ?? this.pretranslateCompleted,
      pretranslateTotal: pretranslateTotal ?? this.pretranslateTotal,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }
}

/// 翻译队列优先级调度器与整章/整书预翻译管理器。
class TranslationScheduler extends StateNotifier<TranslationSchedulerState> {
  TranslationScheduler({
    required TranslationEngine engine,
    required TranslationCacheStore cacheStore,
    required StandaloneConfig Function() readConfig,
    required String? Function() readActiveModelPath,
    Future<String?> Function()? ensureActiveModelPath,
    DownloadKeepAliveService? keepAlive,
  }) : _engine = engine,
       _cacheStore = cacheStore,
       _readConfig = readConfig,
       _readActiveModelPath = readActiveModelPath,
       _ensureActiveModelPath = ensureActiveModelPath,
       _keepAlive = keepAlive ?? const PlatformDownloadKeepAliveService(),
       super(const TranslationSchedulerState());

  final TranslationEngine _engine;
  final TranslationCacheStore _cacheStore;
  final StandaloneConfig Function() _readConfig;
  final String? Function() _readActiveModelPath;
  final Future<String?> Function()? _ensureActiveModelPath;
  final DownloadKeepAliveService _keepAlive;

  void clearError() {
    if (_disposed || state.lastError == null) return;
    state = state.copyWith(clearLastError: true);
  }

  Future<String?> _resolveModelPath() async {
    final current = _readActiveModelPath();
    if (current != null && current.isNotEmpty) return current;
    final ensure = _ensureActiveModelPath;
    if (ensure != null) {
      return ensure();
    }
    return current;
  }

  final List<_QueuedTranslationTask> _queue = <_QueuedTranslationTask>[];
  _QueuedTranslationTask? _runningTask;
  final List<_PhraseTranslationRequest> _phraseQueue =
      <_PhraseTranslationRequest>[];
  _PhraseTranslationRequest? _runningPhraseRequest;
  final Map<String, String> _phraseCache = <String, String>{};
  bool _loopRunning = false;
  bool _disposed = false;
  int _orderSeq = 1;
  bool _pretranslateCancelled = false;
  final Set<String> _loadedChapterKeys = <String>{};

  /// 清空内存中的章节译文缓存及加载标记（用户清空磁盘缓存后同步调用）。
  void clearMemoryCache() {
    _loadedChapterKeys.clear();
    _phraseCache.clear();
    if (_disposed) return;
    state = state.copyWith(
      chapterTranslations: const <String, Map<String, String>>{},
    );
  }

  /// 将章节已有持久化缓存加载进内存状态（二次打开与同会话切章秒显，避免重复磁盘 I/O）。
  Future<Map<String, String>> ensureChapterLoaded({
    required int bookId,
    required int chapterIndex,
    String? targetLangCode,
    String? modelId,
    bool forceReload = false,
  }) async {
    final cfg = _readConfig();
    final lang = targetLangCode ?? cfg.translationTargetLang;
    final model = modelId ?? cfg.activeTranslationModelId;
    final ck = _chapterMapKey(bookId, chapterIndex, lang, model);
    if (!forceReload && _loadedChapterKeys.contains(ck)) {
      return state.chapterTranslations[ck] ?? const <String, String>{};
    }
    final cached = await _cacheStore.readChapterTranslations(
      bookId: bookId,
      chapterIndex: chapterIndex,
      targetLangCode: lang,
      modelId: model,
    );
    if (_disposed) {
      return cached;
    }
    _loadedChapterKeys.add(ck);
    if (cached.isNotEmpty) {
      final existing = state.chapterTranslations[ck] ?? const <String, String>{};
      final merged = Map<String, String>.from(existing)..addAll(cached);
      if (mapEquals(existing, merged)) {
        return existing;
      }
      final next = Map<String, Map<String, String>>.from(
        state.chapterTranslations,
      );
      next[ck] = merged;
      state = state.copyWith(chapterTranslations: next);
      return merged;
    }
    return state.chapterTranslations[ck] ?? const <String, String>{};
  }

  /// 为当前可见页入队 P0 优先级句子，并将本页之后最多 [prefetchCount] 句按 P1 排队预翻。
  Future<void> enqueuePageAndPrefetch({
    required int bookId,
    required int chapterIndex,
    required List<ParagraphSegment> visibleSegments,
    required List<ParagraphSegment> chapterSegments,
    int prefetchCount = 10,
  }) async {
    final modelPath = await _resolveModelPath();
    if (_disposed) return;
    if (modelPath == null || modelPath.isEmpty) {
      state = state.copyWith(
        lastError: '尚未下载或导入离线翻译模型，请前往模型管理安装',
      );
      return;
    }

    if (state.lastError != null) {
      state = state.copyWith(clearLastError: true);
    }

    final cfg = _readConfig();
    final targetLang = TranslationTargetLanguage.fromCode(
      cfg.translationTargetLang,
    );
    final modelId = cfg.activeTranslationModelId;
    final ck = _chapterMapKey(bookId, chapterIndex, targetLang.code, modelId);

    // 确保最新持久化缓存已在内存中
    final existingMap = await ensureChapterLoaded(
      bookId: bookId,
      chapterIndex: chapterIndex,
      targetLangCode: targetLang.code,
      modelId: modelId,
    );
    if (_disposed) return;

    // 清理过期的旧实时任务（P0 / P1），保留 P2 预翻译任务继续在空闲时推进
    _queue.removeWhere((t) => !t.isPretranslate && t.priority <= 1);

    final visibleHashes = visibleSegments.map((s) => s.hash).toSet();

    // 若当前正在推理旧章/旧页任务、P2 预翻或后台短语对齐，且新可见页有未缓存句子，立即打断让路；
    // 若当前已在翻译目标页可见句之一，则不打断当前推理。
    final hasUncachedVisible = visibleSegments.any(
      (s) => !existingMap.containsKey(s.hash),
    );
    final runningIsVisibleOnTarget =
        _runningTask != null &&
        _runningTask!.chapterKey == ck &&
        visibleHashes.contains(_runningTask!.segment.hash);
    if (hasUncachedVisible &&
        ((_runningTask != null && !runningIsVisibleOnTarget) ||
            _runningPhraseRequest != null)) {
      _engine.cancelCurrent();
    }

    void addIfNeeded(ParagraphSegment seg, int priority) {
      if (existingMap.containsKey(seg.hash)) return;
      final uk = _taskUniqueKey(ck, seg.hash);
      if (_runningTask?.uniqueKey == uk) return;
      if (_queue.any((q) => q.uniqueKey == uk && q.priority <= priority)) {
        return;
      }
      _queue.removeWhere((q) => q.uniqueKey == uk);
      _queue.add(
        _QueuedTranslationTask(
          priority: priority,
          order: _orderSeq++,
          chapterKey: ck,
          bookId: bookId,
          chapterIndex: chapterIndex,
          targetLang: targetLang,
          modelId: modelId,
          modelPath: modelPath,
          segment: seg,
        ),
      );
    }

    for (final seg in visibleSegments) {
      addIfNeeded(seg, 0);
    }

    if (visibleSegments.isNotEmpty && prefetchCount > 0) {
      final lastIdx = visibleSegments.last.index;
      var added = 0;
      for (final seg in chapterSegments) {
        if (seg.index <= lastIdx) continue;
        if (added >= prefetchCount) break;
        if (!existingMap.containsKey(seg.hash)) {
          addIfNeeded(seg, 1);
          added++;
        }
      }
    }

    _syncActiveParagraphKeys();
    _ensureLoopStarted();
  }

  /// 启动整章或整书后台离线预翻译（P2 优先级，含通知栏进度保活）。
  Future<void> startPretranslate({
    required int bookId,
    required String bookTitle,
    required List<int> chapterIndices,
    required Future<String?> Function(int chapterIndex) loadChapterContent,
  }) async {
    final modelPath = await _resolveModelPath();
    if (_disposed) return;
    if (modelPath == null || modelPath.isEmpty) {
      state = state.copyWith(lastError: '请先下载或导入离线翻译模型（HY-MT1.5）');
      return;
    }

    await cancelPretranslate();
    if (_disposed) return;

    _pretranslateCancelled = false;
    final cfg = _readConfig();
    final targetLang = TranslationTargetLanguage.fromCode(
      cfg.translationTargetLang,
    );
    final modelId = cfg.activeTranslationModelId;

    final tasks = <_QueuedTranslationTask>[];
    for (final chIdx in chapterIndices) {
      if (_pretranslateCancelled || _disposed) return;
      final content = await loadChapterContent(chIdx);
      if (content == null || content.trim().isEmpty) continue;

      final existingMap = await ensureChapterLoaded(
        bookId: bookId,
        chapterIndex: chIdx,
        targetLangCode: targetLang.code,
        modelId: modelId,
      );
      final segs = splitChapterSentences(content);
      final ck = _chapterMapKey(bookId, chIdx, targetLang.code, modelId);

      for (final seg in segs) {
        if (existingMap.containsKey(seg.hash)) continue;
        final uk = _taskUniqueKey(ck, seg.hash);
        if (tasks.any((t) => t.uniqueKey == uk)) continue;
        tasks.add(
          _QueuedTranslationTask(
            priority: 2,
            order: _orderSeq++,
            chapterKey: ck,
            bookId: bookId,
            chapterIndex: chIdx,
            targetLang: targetLang,
            modelId: modelId,
            modelPath: modelPath,
            segment: seg,
            isPretranslate: true,
          ),
        );
      }
    }

    if (_pretranslateCancelled || _disposed) return;
    if (tasks.isEmpty) {
      state = state.copyWith(
        pretranslateRunning: false,
        pretranslateTitle: '',
        clearPretranslateBook: true,
        pretranslateCompleted: 0,
        pretranslateTotal: 0,
        clearLastError: true,
      );
      return;
    }

    final scopeLabel = chapterIndices.length == 1
        ? '本章预翻译（${targetLang.label}）'
        : '整书预翻译（${targetLang.label}）';

    state = state.copyWith(
      pretranslateRunning: true,
      pretranslateTitle: scopeLabel,
      pretranslateBookId: bookId,
      pretranslateCompleted: 0,
      pretranslateTotal: tasks.length,
      clearLastError: true,
    );

    _queue.addAll(tasks);
    _syncActiveParagraphKeys();

    await _keepAlive.startOrUpdate(
      title: '正在离线翻译《$bookTitle》',
      text: '$scopeLabel · 0 / ${tasks.length} 句',
      progress: 0,
      max: tasks.length,
    );

    _ensureLoopStarted();
  }

  /// 取消整章/整书后台预翻译（保留已写入缓存的段落）。
  Future<void> cancelPretranslate() async {
    _pretranslateCancelled = true;
    _queue.removeWhere((t) => t.isPretranslate);
    if (_runningTask?.isPretranslate ?? false) {
      _engine.cancelCurrent();
    }
    _syncActiveParagraphKeys();
    state = state.copyWith(
      pretranslateRunning: false,
      pretranslateTitle: '',
      clearPretranslateBook: true,
      pretranslateCompleted: 0,
      pretranslateTotal: 0,
    );
    await _keepAlive.stop();
  }

  /// 供双语短语级高亮对齐使用的串行回译通道（让路于 P0 可见页翻译，静默失败不扰动 UI 错误提示）。
  Future<String?> translatePhraseForAlignment({
    required String phrase,
    required TranslationTargetLanguage targetLang,
  }) async {
    if (_disposed) return null;
    final trimmed = phrase.trim();
    if (trimmed.isEmpty) return null;

    final modelId = _readConfig().activeTranslationModelId;
    final key = '${targetLang.code}::$modelId::$trimmed';
    final cached = _phraseCache[key];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    if (_runningPhraseRequest?.key == key) {
      return _runningPhraseRequest!.completer.future;
    }
    for (final existing in _phraseQueue) {
      if (existing.key == key) {
        return existing.completer.future;
      }
    }

    final modelPath = await _resolveModelPath();
    if (_disposed || modelPath == null || modelPath.isEmpty) {
      return null;
    }

    final maxTokens = (trimmed.length * 3 + 24).clamp(32, 128);
    final req = _PhraseTranslationRequest(
      key: key,
      sourceText: trimmed,
      targetLang: targetLang,
      modelPath: modelPath,
      maxTokens: maxTokens,
      completer: Completer<String?>(),
    );
    _phraseQueue.add(req);
    _ensureLoopStarted();
    return req.completer.future;
  }

  /// 清空指定页面的 P0/P1 队列（例如切回纯原文模式时节省电量和算力）。
  void pauseLiveQueue() {
    _queue.removeWhere((t) => !t.isPretranslate);
    for (final req in _phraseQueue) {
      if (!req.completer.isCompleted) {
        req.completer.complete(null);
      }
    }
    _phraseQueue.clear();
    if ((_runningTask != null && !_runningTask!.isPretranslate) ||
        _runningPhraseRequest != null) {
      _engine.cancelCurrent();
    }
    _syncActiveParagraphKeys();
  }

  void _syncActiveParagraphKeys() {
    if (_disposed) return;
    final keys = <String>{
      if (_runningTask != null) _runningTask!.uniqueKey,
      for (final q in _queue) q.uniqueKey,
    };
    final nextCurrentKey = _runningTask?.uniqueKey;
    if (setEquals(state.activeParagraphKeys, keys) &&
        state.currentTranslatingKey == nextCurrentKey) {
      return;
    }
    state = state.copyWith(
      activeParagraphKeys: keys,
      currentTranslatingKey: nextCurrentKey,
      clearCurrentTranslating: nextCurrentKey == null,
    );
  }

  void _ensureLoopStarted() {
    if (_loopRunning || _disposed) return;
    _loopRunning = true;
    unawaited(_drainLoop());
  }

  Future<void> _drainLoop() async {
    try {
      while (!_disposed) {
        if (_queue.isEmpty && _phraseQueue.isEmpty) break;

        // 优先处理短语级回译对齐（不与可见页 P0 抢占模型；静默容错）
        final hasP0Task = _queue.any((t) => t.priority == 0);
        if (_phraseQueue.isNotEmpty && !hasP0Task) {
          final req = _phraseQueue.removeAt(0);
          _runningPhraseRequest = req;
          try {
            await _engine.ensureLoaded(req.modelPath);
            if (_disposed) {
              if (!req.completer.isCompleted) req.completer.complete(null);
              return;
            }
            final prompt = buildHyMtPrompt(
              sourceText: req.sourceText,
              targetLanguage: req.targetLang,
            );
            final out = (await _engine.translate(
              prompt,
              maxTokens: req.maxTokens,
            )).trim();
            if (!_disposed && out.isNotEmpty) {
              if (_phraseCache.length >= 64) {
                _phraseCache.remove(_phraseCache.keys.first);
              }
              _phraseCache[req.key] = out;
              if (!req.completer.isCompleted) {
                req.completer.complete(out);
              }
            } else if (!req.completer.isCompleted) {
              req.completer.complete(null);
            }
          } on TranslationCancelledException {
            if (!req.completer.isCompleted) req.completer.complete(null);
          } catch (_) {
            if (!req.completer.isCompleted) req.completer.complete(null);
          } finally {
            _runningPhraseRequest = null;
          }
          continue;
        }

        // 严格按照 (priority 升序, order 升序) 出队
        _queue.sort((a, b) {
          final p = a.priority.compareTo(b.priority);
          return p != 0 ? p : a.order.compareTo(b.order);
        });
        final task = _queue.removeAt(0);
        if (task.isPretranslate && _pretranslateCancelled) {
          continue;
        }

        // 若刚刚已在其他同 hash 段落翻译完毕，跳过重复计算
        final cachedText = state
            .chapterTranslations[task.chapterKey]?[task.segment.hash];
        if (cachedText != null) {
          if (task.isPretranslate && state.pretranslateRunning) {
            _advancePretranslateProgress(task);
          }
          continue;
        }

        _runningTask = task;
        _syncActiveParagraphKeys();

        var loadedOk = false;
        try {
          await _engine.ensureLoaded(task.modelPath);
          loadedOk = true;
          final translated = await _translateParagraphWithSplit(
            text: task.segment.text,
            targetLang: task.targetLang,
          );
          if (_disposed) return;

          if (translated.trim().isNotEmpty) {
            final existingMap =
                state.chapterTranslations[task.chapterKey] ??
                const <String, String>{};
            final nextMap = Map<String, String>.from(existingMap)
              ..[task.segment.hash] = translated;
            final nextAll = Map<String, Map<String, String>>.from(
              state.chapterTranslations,
            )..[task.chapterKey] = nextMap;

            state = state.copyWith(
              chapterTranslations: nextAll,
              clearLastError: true,
            );

            await _cacheStore.saveParagraphTranslation(
              bookId: task.bookId,
              chapterIndex: task.chapterIndex,
              targetLangCode: task.targetLang.code,
              modelId: task.modelId,
              paragraphHash: task.segment.hash,
              translatedText: translated,
            );
          }

          if (task.isPretranslate && state.pretranslateRunning) {
            _advancePretranslateProgress(task);
          }
        } on TranslationCancelledException {
          // 仅 P2 后台预翻译在被可见页 P0 抢占且未被主动取消时放回队列；
          // 过期的实时 P0/P1 任务在翻页/切章/暂停后直接丢弃，避免抢占新页算力。
          if (task.isPretranslate &&
              !_pretranslateCancelled &&
              state.pretranslateRunning) {
            _queue.add(task);
          }
        } catch (e) {
          if (!loadedOk) {
            // 模型加载本身失败时，移除同模型路径的阻塞任务，防止对后续所有段重复报错空转
            _queue.removeWhere(
              (t) => !t.isPretranslate && t.modelPath == task.modelPath,
            );
            if (task.isPretranslate) {
              _pretranslateCancelled = true;
              _queue.removeWhere(
                (t) => t.isPretranslate && t.modelPath == task.modelPath,
              );
              if (!_disposed) {
                state = state.copyWith(
                  pretranslateRunning: false,
                  pretranslateTitle: '',
                  clearPretranslateBook: true,
                  lastError: '翻译引擎错误：$e',
                );
              }
              unawaited(_keepAlive.stop());
            } else if (!_disposed) {
              state = state.copyWith(lastError: '翻译引擎错误：$e');
            }
          } else {
            if (!_disposed) {
              state = state.copyWith(lastError: '翻译引擎错误：$e');
            }
            if (task.isPretranslate && state.pretranslateRunning) {
              _advancePretranslateProgress(task);
            }
          }
        } finally {
          _runningTask = null;
          _syncActiveParagraphKeys();
        }
      }

      if (!_disposed && state.pretranslateRunning) {
        final hasRemainingPre = _queue.any((t) => t.isPretranslate);
        if (!hasRemainingPre) {
          final done = state.pretranslateCompleted;
          final total = state.pretranslateTotal;
          state = state.copyWith(
            pretranslateRunning: false,
            pretranslateTitle: '',
            clearPretranslateBook: true,
          );
          if (total > 0 && done >= total) {
            await _keepAlive.startOrUpdate(
              title: '离线预翻译完成',
              text: '已完成 $done / $total 句译文缓存',
              progress: total,
              max: total,
            );
            Future<void>.delayed(const Duration(seconds: 2), () {
              _keepAlive.stop();
            });
          } else {
            await _keepAlive.stop();
          }
        }
      }
    } finally {
      _loopRunning = false;
      _runningTask = null;
      _runningPhraseRequest = null;
      if (!_disposed && (_queue.isNotEmpty || _phraseQueue.isNotEmpty)) {
        _ensureLoopStarted();
      }
    }
  }

  void _advancePretranslateProgress(_QueuedTranslationTask task) {
    final nextDone = (state.pretranslateCompleted + 1).clamp(
      0,
      state.pretranslateTotal,
    );
    state = state.copyWith(pretranslateCompleted: nextDone);
    if (nextDone % 3 == 0 || nextDone == state.pretranslateTotal) {
      final total = state.pretranslateTotal;
      final pct = total > 0 ? ((nextDone / total) * 100).toInt() : 0;
      unawaited(
        _keepAlive.startOrUpdate(
          title: state.pretranslateTitle,
          text: '进度 $nextDone / $total 句（$pct%）',
          progress: nextDone,
          max: total > 0 ? total : 1,
        ),
      );
    }
  }

  /// 对超长段落或句子内部按分句分批翻译并拼接，确保既不超过上下文窗口也不破坏原字符偏移。
  Future<String> _translateParagraphWithSplit({
    required String text,
    required TranslationTargetLanguage targetLang,
  }) async {
    const maxSingleChunkChars = 650;
    if (text.length <= maxSingleChunkChars) {
      final prompt = buildHyMtPrompt(
        sourceText: text,
        targetLanguage: targetLang,
      );
      final maxTokens = (text.length * 2 + 64).clamp(96, 512);
      return (await _engine.translate(prompt, maxTokens: maxTokens)).trim();
    }

    final sentences = const SentenceSplitter(
      minChars: 8,
      maxChars: 550,
    ).split(text);
    if (sentences.isEmpty) return '';

    final chunks = <String>[];
    final buf = StringBuffer();
    for (final s in sentences) {
      if (buf.isNotEmpty && buf.length + s.text.length + 1 > maxSingleChunkChars) {
        chunks.add(buf.toString().trim());
        buf.clear();
      }
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(s.text);
    }
    if (buf.isNotEmpty) {
      chunks.add(buf.toString().trim());
    }

    final translatedParts = <String>[];
    for (final chunk in chunks) {
      final prompt = buildHyMtPrompt(
        sourceText: chunk,
        targetLanguage: targetLang,
      );
      final maxTokens = (chunk.length * 2 + 96).clamp(128, 768);
      final out = (await _engine.translate(prompt, maxTokens: maxTokens)).trim();
      if (out.isNotEmpty) {
        translatedParts.add(out);
      }
    }
    final joiner = targetLang.isChinese || targetLang == TranslationTargetLanguage.ja
        ? ''
        : ' ';
    return translatedParts.join(joiner);
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    for (final req in _phraseQueue) {
      if (!req.completer.isCompleted) {
        req.completer.complete(null);
      }
    }
    _phraseQueue.clear();
    final runningPhrase = _runningPhraseRequest;
    if (runningPhrase != null && !runningPhrase.completer.isCompleted) {
      runningPhrase.completer.complete(null);
    }
    _engine.cancelCurrent();
    unawaited(_keepAlive.stop());
    super.dispose();
  }
}

final StateNotifierProvider<TranslationScheduler, TranslationSchedulerState>
translationSchedulerProvider =
    StateNotifierProvider<TranslationScheduler, TranslationSchedulerState>(
      (ref) => TranslationScheduler(
        engine: ref.watch(translationEngineProvider),
        cacheStore: ref.watch(translationCacheStoreProvider),
        readConfig: () => ref.read(standaloneConfigProvider),
        readActiveModelPath: () =>
            ref.read(translationModelManagerProvider).activeModelPath,
        ensureActiveModelPath: () => ref
            .read(translationModelManagerProvider.notifier)
            .ensureInitializedAndGetActiveModelPath(),
      ),
    );
