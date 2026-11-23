import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/models.dart';
import '../books/local_library_store.dart';
import '../reader/reading_store.dart';
import '../settings/standalone_config_store.dart';
import '../stats/stats_store.dart';
import '../tts/sentence_splitter.dart';
import '../tts/sherpa_tts_engine.dart';
import '../tts/tts_model_manager.dart';
import '../tts/wav_encoder.dart';
import 'audio_service_engine.dart';
import 'chunked_player_controller.dart';

/// 实时「边听边生成」朗读器状态。
@immutable
class LiveTtsState {
  const LiveTtsState({
    this.book,
    this.chapters = const <ChapterPreview>[],
    this.chapterIndex = 0,
    this.sentences = const <TextSentence>[],
    this.sentenceIndex = 0,
    this.isPlaying = false,
    this.isSynthesizing = false,
    this.speed = 1.0,
    this.speakerId = 0,
    this.modelId = '',
    this.error,
  });

  final LibraryBook? book;
  final List<ChapterPreview> chapters;
  final int chapterIndex;
  final List<TextSentence> sentences;
  final int sentenceIndex;
  final bool isPlaying;
  final bool isSynthesizing;
  final double speed;
  final int speakerId;
  final String modelId;
  final String? error;

  bool get hasBook => book != null;

  String get chapterTitle {
    if (chapterIndex >= 0 && chapterIndex < chapters.length) {
      return chapters[chapterIndex].title;
    }
    return '';
  }

  TextSentence? get currentSentence {
    if (sentenceIndex >= 0 && sentenceIndex < sentences.length) {
      return sentences[sentenceIndex];
    }
    return null;
  }

  String get currentCueText => currentSentence?.text ?? '';

  double get chapterProgress =>
      sentences.isEmpty ? 0.0 : (sentenceIndex + 1) / sentences.length;

  LiveTtsState copyWith({
    LibraryBook? book,
    bool clearBook = false,
    List<ChapterPreview>? chapters,
    int? chapterIndex,
    List<TextSentence>? sentences,
    int? sentenceIndex,
    bool? isPlaying,
    bool? isSynthesizing,
    double? speed,
    int? speakerId,
    String? modelId,
    String? error,
    bool clearError = false,
  }) {
    return LiveTtsState(
      book: clearBook ? null : (book ?? this.book),
      chapters: chapters ?? this.chapters,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      sentences: sentences ?? this.sentences,
      sentenceIndex: sentenceIndex ?? this.sentenceIndex,
      isPlaying: isPlaying ?? this.isPlaying,
      isSynthesizing: isSynthesizing ?? this.isSynthesizing,
      speed: speed ?? this.speed,
      speakerId: speakerId ?? this.speakerId,
      modelId: modelId ?? this.modelId,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// 端侧「边听边生成」实时流式朗读控制器。
///
/// 核心能力：
/// - 打开任意本地书章节立即分句起播，后台异步预合成后续 2 句（容量 3 句窗口）；
/// - 临时 WAV 写入应用缓存目录并按 LRU 容量上限（默认 100MB）自动清理；
/// - 复用 [AudioEngine] / [AudioServiceEngine] 对接系统锁屏与通知栏播控；
/// - 实时暴露 [LiveTtsState.currentCueText]，与阅读器正文高亮/自动翻页无缝联动。
class LiveTtsPlayerController extends StateNotifier<LiveTtsState> {
  LiveTtsPlayerController({
    required LocalLibraryStore libraryStore,
    required OnDeviceTtsEngine ttsEngine,
    required AudioEngine audioEngine,
    required ResolvedTtsModelPaths? Function() resolveActiveModel,
    required StandaloneConfig Function() readConfig,
    ReadingStore? readingStore,
    Directory? cacheDirOverride,
    int maxCacheBytes = 100 * 1024 * 1024,
    SentenceSplitter? splitter,
  }) : _libraryStore = libraryStore,
       _ttsEngine = ttsEngine,
       _audioEngine = audioEngine,
       _resolveActiveModel = resolveActiveModel,
       _readConfig = readConfig,
       _readingStore = readingStore,
       _cacheDirOverride = cacheDirOverride,
       _maxCacheBytes = maxCacheBytes,
       _splitter = splitter ?? const SentenceSplitter(),
       super(const LiveTtsState()) {
    _completedSub = _audioEngine.completedStream.listen((_) {
      _onSentenceCompleted();
    });
    _playingSub = _audioEngine.playingStream.listen((playing) {
      if (!mounted || !state.hasBook) return;
      if (state.isPlaying != playing) {
        state = state.copyWith(isPlaying: playing);
      }
    });
    if (_audioEngine is LockScreenControls) {
      final controls = _audioEngine as LockScreenControls;
      _nextSub = controls.skipToNextRequests.listen((_) => nextChapter());
      _prevSub = controls.skipToPreviousRequests.listen((_) => prevChapter());
      _ffSub = controls.fastForwardRequests.listen((_) => nextSentence());
      _rwSub = controls.rewindRequests.listen((_) => prevSentence());
    }
  }

  final LocalLibraryStore _libraryStore;
  final OnDeviceTtsEngine _ttsEngine;
  final AudioEngine _audioEngine;
  final ResolvedTtsModelPaths? Function() _resolveActiveModel;
  final StandaloneConfig Function() _readConfig;
  final ReadingStore? _readingStore;
  final Directory? _cacheDirOverride;
  final int _maxCacheBytes;
  final SentenceSplitter _splitter;

  static const int _prefetchAhead = 2;

  StreamSubscription<void>? _completedSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<void>? _nextSub;
  StreamSubscription<void>? _prevSub;
  StreamSubscription<void>? _ffSub;
  StreamSubscription<void>? _rwSub;

  int _generation = 0;
  final Map<int, Future<File>> _sentenceCache = <int, Future<File>>{};
  DateTime? _sentenceStartAt;

  Future<Directory> _ensureCacheDir() async {
    if (_cacheDirOverride != null) {
      await _cacheDirOverride.create(recursive: true);
      return _cacheDirOverride;
    }
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'echo_live_tts_cache'));
    await dir.create(recursive: true);
    return dir;
  }

  /// 清空全部临时朗读 WAV 缓存并返还释放的字节数。
  Future<int> clearTempCache() async {
    _sentenceCache.clear();
    final dir = await _ensureCacheDir();
    var freed = 0;
    if (await dir.exists()) {
      for (final entity in dir.listSync()) {
        if (entity is File) {
          freed += entity.lengthSync();
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
    }
    return freed;
  }

  /// 计算当前临时朗读缓存体积。
  Future<int> tempCacheBytes() async {
    final dir = await _ensureCacheDir();
    var total = 0;
    if (await dir.exists()) {
      for (final entity in dir.listSync()) {
        if (entity is File) total += entity.lengthSync();
      }
    }
    return total;
  }

  /// 开始实时朗读指定书籍的指定章节（可按字符偏移精确定位到对应句子）。
  Future<void> playBookChapter(
    LibraryBook book, {
    int chapterIndex = 0,
    int startCharOffset = 0,
  }) async {
    final resolvedModel = _resolveActiveModel();
    if (resolvedModel == null) {
      state = state.copyWith(
        error: '尚未安装离线语音模型，请先前往「我的 → 语音模型管理」下载',
        isSynthesizing: false,
        isPlaying: false,
      );
      return;
    }

    final chapters = await _libraryStore.listChapters(book.id);
    if (chapters.isEmpty) {
      state = state.copyWith(error: '该书暂无可朗读章节');
      return;
    }

    final safeChapterIdx = chapterIndex.clamp(0, chapters.length - 1);
    final chapter = chapters[safeChapterIdx];
    final sentences = _splitter.split(chapter.text);
    if (sentences.isEmpty) {
      state = state.copyWith(error: '当前章节没有可朗读文本');
      return;
    }

    var startSentenceIdx = 0;
    if (startCharOffset > 0) {
      for (var i = 0; i < sentences.length; i++) {
        if (sentences[i].endOffset >= startCharOffset) {
          startSentenceIdx = i;
          break;
        }
      }
    }

    final cfg = _readConfig();
    final speakerId = resolvedModel.spec.speakers.any(
      (s) => s.id == cfg.activeTtsSpeakerId,
    )
        ? cfg.activeTtsSpeakerId
        : resolvedModel.spec.speakers.first.id;

    _generation++;
    _sentenceCache.clear();

    state = LiveTtsState(
      book: book,
      chapters: chapters,
      chapterIndex: safeChapterIdx,
      sentences: sentences,
      sentenceIndex: startSentenceIdx,
      isPlaying: false,
      isSynthesizing: true,
      speed: cfg.defaultTtsSpeed,
      speakerId: speakerId,
      modelId: resolvedModel.spec.id,
    );

    try {
      await _ttsEngine.loadModel(resolvedModel);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isSynthesizing: false, error: '加载语音模型失败：$e');
      return;
    }

    await _playSentenceAt(startSentenceIdx, expectedGen: _generation);
  }

  Future<void> _playSentenceAt(int index, {required int expectedGen}) async {
    if (!mounted || expectedGen != _generation) return;
    if (index < 0 || index >= state.sentences.length) return;

    state = state.copyWith(
      sentenceIndex: index,
      isSynthesizing: true,
      clearError: true,
    );

    // 同步保存阅读进度（听看一体）
    final book = state.book;
    final sentence = state.sentences[index];
    if (book != null && _readingStore != null) {
      unawaited(
        _readingStore.write(
          ReadingPosition(
            bookId: book.id,
            chapterIndex: state.chapterIndex,
            charOffset: sentence.startOffset,
          ),
        ),
      );
    }

    // 触发当前句 + 后续 2 句的预合成窗口
    final currentFuture = _ensureSentenceWav(index, expectedGen);
    for (var ahead = 1; ahead <= _prefetchAhead; ahead++) {
      final nextIdx = index + ahead;
      if (nextIdx < state.sentences.length) {
        unawaited(
          _ensureSentenceWav(nextIdx, expectedGen).catchError((_) => File('')),
        );
      }
    }

    try {
      final wavFile = await currentFuture;
      if (!mounted || expectedGen != _generation) return;
      if (!wavFile.existsSync()) return;

      await _audioEngine.setSource(
        wavFile.uri,
        mediaTitle: book?.title ?? '回声朗读',
        mediaArtist: state.chapterTitle.isNotEmpty ? state.chapterTitle : null,
        mediaArtUrl: (book?.coverUrl.isNotEmpty ?? false)
            ? book!.coverUrl
            : null,
      );
      if (!mounted || expectedGen != _generation) return;
      _sentenceStartAt = DateTime.now();
      state = state.copyWith(isSynthesizing: false, isPlaying: true);
      await _audioEngine.play();
    } catch (e) {
      if (!mounted || expectedGen != _generation) return;
      state = state.copyWith(
        isSynthesizing: false,
        isPlaying: false,
        error: '朗读合成失败：$e',
      );
    }
  }

  Future<File> _ensureSentenceWav(int index, int expectedGen) {
    final existing = _sentenceCache[index];
    if (existing != null) return existing;

    final future = _synthesizeSentenceToFile(index, expectedGen);
    _sentenceCache[index] = future;
    return future;
  }

  Future<File> _synthesizeSentenceToFile(int index, int expectedGen) async {
    final sentence = state.sentences[index];
    final bookId = state.book?.id ?? 0;
    final cacheDir = await _ensureCacheDir();
    final key =
        'b${bookId}_c${state.chapterIndex}_s${index}_${state.modelId}_sp${state.speakerId}_v${(state.speed * 100).round()}.wav';
    final outFile = File(p.join(cacheDir.path, key));
    if (await outFile.exists() && await outFile.length() > 44) {
      // 刷新 mtime 用于 LRU
      try {
        await outFile.setLastModified(DateTime.now());
      } catch (_) {}
      return outFile;
    }

    final result = await _ttsEngine.synthesize(
      sentence.text,
      speakerId: state.speakerId,
      speed: state.speed,
    );
    if (expectedGen != _generation) return outFile;

    final wavBytes = encodeFloat32ToWav(
      result.samples,
      sampleRate: result.sampleRate,
    );
    await outFile.writeAsBytes(wavBytes, flush: true);
    unawaited(_pruneCacheIfNeeded(cacheDir));
    return outFile;
  }

  Future<void> _pruneCacheIfNeeded(Directory cacheDir) async {
    try {
      final files = cacheDir
          .listSync()
          .whereType<File>()
          .map((f) => (file: f, stat: f.statSync()))
          .toList();
      var total = files.fold<int>(0, (acc, e) => acc + e.stat.size);
      if (total <= _maxCacheBytes) return;
      // 按最久未访问排序删除（LRU）
      files.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
      final target = (_maxCacheBytes * 0.75).round();
      for (final item in files) {
        if (total <= target) break;
        try {
          item.file.deleteSync();
          total -= item.stat.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  void _recordListeningDelta() {
    final started = _sentenceStartAt;
    if (started == null) return;
    _sentenceStartAt = null;
    final ms = DateTime.now().difference(started).inMilliseconds;
    if (ms > 0) {
      StatsStore.instance.addListenMs(ms);
    }
  }

  Future<void> _onSentenceCompleted() async {
    if (!mounted || !state.hasBook) return;
    _recordListeningDelta();
    final nextIdx = state.sentenceIndex + 1;
    if (nextIdx < state.sentences.length) {
      await _playSentenceAt(nextIdx, expectedGen: _generation);
    } else if (state.chapterIndex + 1 < state.chapters.length) {
      await playBookChapter(state.book!, chapterIndex: state.chapterIndex + 1);
    } else {
      state = state.copyWith(isPlaying: false, isSynthesizing: false);
    }
  }

  Future<void> togglePlayPause() async {
    if (!state.hasBook) return;
    if (state.isPlaying) {
      _recordListeningDelta();
      await _audioEngine.pause();
      state = state.copyWith(isPlaying: false);
    } else {
      _sentenceStartAt = DateTime.now();
      await _audioEngine.play();
      state = state.copyWith(isPlaying: true);
    }
  }

  Future<void> nextSentence() async {
    if (!state.hasBook) return;
    final nextIdx = state.sentenceIndex + 1;
    if (nextIdx < state.sentences.length) {
      _recordListeningDelta();
      await _playSentenceAt(nextIdx, expectedGen: _generation);
    } else {
      await nextChapter();
    }
  }

  Future<void> prevSentence() async {
    if (!state.hasBook) return;
    final prevIdx = state.sentenceIndex - 1;
    if (prevIdx >= 0) {
      _recordListeningDelta();
      await _playSentenceAt(prevIdx, expectedGen: _generation);
    } else {
      await prevChapter();
    }
  }

  Future<void> nextChapter() async {
    final book = state.book;
    if (book == null) return;
    if (state.chapterIndex + 1 < state.chapters.length) {
      _recordListeningDelta();
      await playBookChapter(book, chapterIndex: state.chapterIndex + 1);
    }
  }

  Future<void> prevChapter() async {
    final book = state.book;
    if (book == null) return;
    if (state.chapterIndex > 0) {
      _recordListeningDelta();
      await playBookChapter(book, chapterIndex: state.chapterIndex - 1);
    }
  }

  Future<void> setSpeed(double speed) async {
    final clamped = speed.clamp(0.5, 2.5);
    if ((clamped - state.speed).abs() < 0.01) return;
    _generation++;
    _sentenceCache.clear();
    state = state.copyWith(speed: clamped);
    if (state.hasBook && state.isPlaying) {
      await _playSentenceAt(state.sentenceIndex, expectedGen: _generation);
    }
  }

  Future<void> setSpeaker(int speakerId) async {
    if (speakerId == state.speakerId) return;
    _generation++;
    _sentenceCache.clear();
    state = state.copyWith(speakerId: speakerId);
    if (state.hasBook && state.isPlaying) {
      await _playSentenceAt(state.sentenceIndex, expectedGen: _generation);
    }
  }

  Future<void> stop() async {
    _generation++;
    _recordListeningDelta();
    _sentenceCache.clear();
    await _audioEngine.stop();
    state = const LiveTtsState();
  }

  @override
  void dispose() {
    _completedSub?.cancel();
    _playingSub?.cancel();
    _nextSub?.cancel();
    _prevSub?.cancel();
    _ffSub?.cancel();
    _rwSub?.cancel();
    super.dispose();
  }
}

final StateNotifierProvider<LiveTtsPlayerController, LiveTtsState>
liveTtsPlayerProvider =
    StateNotifierProvider<LiveTtsPlayerController, LiveTtsState>((ref) {
      final AudioEngine engine = AudioServiceEngine.instance;
      return LiveTtsPlayerController(
        libraryStore: ref.watch(localLibraryStoreProvider),
        ttsEngine: ref.watch(onDeviceTtsEngineProvider),
        audioEngine: engine,
        readingStore: ref.watch(readingStoreProvider),
        resolveActiveModel: () =>
            ref.read(ttsModelManagerProvider.notifier).activeModelPaths,
        readConfig: () => ref.read(standaloneConfigProvider),
      );
    });
