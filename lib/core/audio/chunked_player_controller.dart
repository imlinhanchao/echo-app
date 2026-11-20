import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../features/auth/auth_controller.dart';
import '../api/echo_api.dart';
import '../api/models.dart';
import '../storage/progress_store.dart';
import 'audio_service_engine.dart';
import 'srt_parser.dart';

/// 底层音频播放引擎抽象：生产环境由 [JustAudioEngine] 或
/// [AudioServiceEngine]（audio_service 后台媒体）驱动，
/// 测试环境可注入 [FakeAudioEngine] 进行确定性断言。
abstract class AudioEngine {
  Stream<Duration> get positionStream;
  Stream<bool> get playingStream;
  Stream<void> get completedStream;

  /// [mediaTitle]/[mediaArtist]/[mediaDuration] 供系统媒体通知
  /// （锁屏/通知栏：书名 + 章节名 + 进度条）。
  Future<void> setSource(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration initialPosition = Duration.zero,
    String? mediaTitle,
    String? mediaArtist,
    Duration? mediaDuration,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> dispose();
}

/// 系统播控（锁屏/通知栏）请求流：由支持后台媒体的引擎实现。
/// 控制器把"上一首/下一首"映射为章节切换（书不是音乐，进度单位是章节）。
abstract class LockScreenControls {
  Stream<void> get skipToNextRequests;
  Stream<void> get skipToPreviousRequests;
}

/// 基于 just_audio 的生产音频引擎（支持携带 Bearer Authorization 头）。
class JustAudioEngine implements AudioEngine {
  JustAudioEngine({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<void> get completedStream => _player.processingStateStream
      .where((s) => s == ProcessingState.completed)
      .map((_) {});

  @override
  Future<void> setSource(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration initialPosition = Duration.zero,
    String? mediaTitle,
    String? mediaArtist,
    Duration? mediaDuration,
  }) async {
    final source = AudioSource.uri(
      uri,
      headers: headers.isEmpty ? null : headers,
    );
    await _player.setAudioSource(source, initialPosition: initialPosition);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> dispose() => _player.dispose();
}

/// 纯内存音频引擎：供单元测试与 Widget 测试驱动分块续播、跨块跳转与字幕同步。
class FakeAudioEngine implements AudioEngine {
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  final StreamController<void> _completedController =
      StreamController<void>.broadcast();

  Uri? lastUri;
  Map<String, String> lastHeaders = const <String, String>{};
  String? lastMediaTitle;
  String? lastMediaArtist;
  Duration? lastMediaDuration;
  Duration position = Duration.zero;
  bool playing = false;
  double speed = 1.0;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<void> get completedStream => _completedController.stream;

  @override
  Future<void> setSource(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration initialPosition = Duration.zero,
    String? mediaTitle,
    String? mediaArtist,
    Duration? mediaDuration,
  }) async {
    lastUri = uri;
    lastHeaders = headers;
    lastMediaTitle = mediaTitle;
    lastMediaArtist = mediaArtist;
    lastMediaDuration = mediaDuration;
    position = initialPosition;
    _positionController.add(position);
  }

  @override
  Future<void> play() async {
    playing = true;
    _playingController.add(true);
  }

  @override
  Future<void> pause() async {
    playing = false;
    _playingController.add(false);
  }

  @override
  Future<void> stop() async {
    playing = false;
    _playingController.add(false);
  }

  @override
  Future<void> seek(Duration target) async {
    position = target;
    _positionController.add(position);
  }

  @override
  Future<void> setSpeed(double targetSpeed) async {
    speed = targetSpeed;
  }

  /// 测试辅助：推进播放位置。
  void emitPosition(Duration next) {
    position = next;
    _positionController.add(next);
  }

  /// 测试辅助：模拟当前分块播放完毕。
  void emitCompleted() {
    _completedController.add(null);
  }

  @override
  Future<void> dispose() async {
    await _positionController.close();
    await _playingController.close();
    await _completedController.close();
  }
}

/// 分块播放器完整不可变状态。
@immutable
class ChunkedPlayerState {
  const ChunkedPlayerState({
    this.audiobook,
    this.chunks = const <ChapterChunk>[],
    this.currentChunkIndex = 0,
    this.positionMs = 0,
    this.isPlaying = false,
    this.isLoading = false,
    this.speed = 1.0,
    this.cues = const <SrtCue>[],
    this.activeCueIndex = -1,
    this.error,
    this.sleepUntil,
  });

  final AudiobookInfo? audiobook;
  final List<ChapterChunk> chunks;
  final int currentChunkIndex;
  final int positionMs;
  final bool isPlaying;
  final bool isLoading;
  final double speed;
  final List<SrtCue> cues;
  final int activeCueIndex;
  final String? error;

  /// 睡眠定时到点时刻（null = 未启用）。UI 显示"至 HH:mm"。
  final DateTime? sleepUntil;

  bool get hasBook => audiobook != null && chunks.isNotEmpty;

  ChapterChunk? get currentChunk =>
      (currentChunkIndex >= 0 && currentChunkIndex < chunks.length)
          ? chunks[currentChunkIndex]
          : null;

  bool get hasPreviousChunk => currentChunkIndex > 0;
  bool get hasNextChunk => currentChunkIndex + 1 < chunks.length;

  int get currentChunkDurationMs {
    final chunk = currentChunk;
    if (chunk == null) return 0;
    return (chunk.durationS * 1000).round();
  }

  int get totalDurationMs {
    if (chunks.isNotEmpty) {
      final last = chunks.last;
      if (last.endS > 0) return (last.endS * 1000).round();
      final sum = chunks.fold<double>(0, (acc, c) => acc + c.durationS);
      if (sum > 0) return (sum * 1000).round();
    }
    return ((audiobook?.durationS ?? 0) * 1000).round();
  }

  int get globalPositionMs {
    final chunk = currentChunk;
    if (chunk == null) return positionMs;
    return (chunk.startS * 1000).round() + positionMs;
  }

  SrtCue? get activeCue =>
      (activeCueIndex >= 0 && activeCueIndex < cues.length)
          ? cues[activeCueIndex]
          : null;

  ChunkedPlayerState copyWith({
    AudiobookInfo? audiobook,
    List<ChapterChunk>? chunks,
    int? currentChunkIndex,
    int? positionMs,
    bool? isPlaying,
    bool? isLoading,
    double? speed,
    List<SrtCue>? cues,
    int? activeCueIndex,
    String? error,
    bool clearError = false,
    DateTime? sleepUntil,
    bool clearSleepUntil = false,
  }) {
    return ChunkedPlayerState(
      audiobook: audiobook ?? this.audiobook,
      chunks: chunks ?? this.chunks,
      currentChunkIndex: currentChunkIndex ?? this.currentChunkIndex,
      positionMs: positionMs ?? this.positionMs,
      isPlaying: isPlaying ?? this.isPlaying,
      isLoading: isLoading ?? this.isLoading,
      speed: speed ?? this.speed,
      cues: cues ?? this.cues,
      activeCueIndex: activeCueIndex ?? this.activeCueIndex,
      error: clearError ? null : (error ?? this.error),
      sleepUntil: clearSleepUntil ? null : (sleepUntil ?? this.sleepUntil),
    );
  }
}

/// 分块播放控制器：
/// - 驱动 `manifest.json` 分章清单（单块 ≤30 分钟，独立音频 + SRT）；
/// - 块播完自动无缝切入下一块；
/// - `±15s` 支持跨分块边界跳转；
/// - 实时计算当前 SRT 跟读高亮句并持久化 `{chapterIndex, chunkN, offsetMs}`。
class ChunkedPlayerController extends StateNotifier<ChunkedPlayerState> {
  ChunkedPlayerController(
    this._api,
    this._engine,
    this._progressStore,
  ) : super(const ChunkedPlayerState()) {
    _posSub = _engine.positionStream.listen(_onPosition);
    _playSub = _engine.playingStream.listen(_onPlayingChanged);
    _doneSub = _engine.completedStream.listen((_) => _onChunkCompleted());
    // 锁屏/通知栏的"上一首/下一首"映射为章节切换。
    if (_engine is LockScreenControls) {
      final controls = _engine as LockScreenControls;
      _lockScreenSubs
          .add(controls.skipToNextRequests.listen((_) => unawaited(nextChunk())));
      _lockScreenSubs.add(controls
          .skipToPreviousRequests.listen((_) => unawaited(previousChunk())));
    }
  }

  final EchoApi _api;
  final AudioEngine _engine;
  final ProgressStore _progressStore;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playSub;
  StreamSubscription<void>? _doneSub;
  final List<StreamSubscription<void>> _lockScreenSubs =
      <StreamSubscription<void>>[];
  int _lastSavedMs = -1;

  /// 载入有声书并自动恢复上次断点续听位置。
  Future<void> loadAudiobook(
    AudiobookInfo audiobook, {
    bool autoPlay = true,
  }) async {
    state = state.copyWith(
      audiobook: audiobook,
      isLoading: true,
      clearError: true,
    );

    List<ChapterChunk> chunks;
    try {
      final manifest = await _api.getAudiobookChapters(audiobook.id);
      chunks = manifest.chunks;
    } on ApiException catch (e) {
      // 兼容尚未分块的旧有声书：若存在整本 audioUrl 则构造单块降级播放。
      if (audiobook.audioUrl.isNotEmpty) {
        chunks = <ChapterChunk>[
          ChapterChunk(
            n: 0,
            chapterIndex: 0,
            title: audiobook.bookTitle.isNotEmpty
                ? audiobook.bookTitle
                : '全书音频',
            startS: 0,
            endS: audiobook.durationS,
            durationS: audiobook.durationS,
            audioUrl: audiobook.audioUrl,
            srtUrl: audiobook.srtUrl,
          ),
        ];
      } else {
        state = state.copyWith(isLoading: false, error: e.message);
        return;
      }
    }

    if (chunks.isEmpty) {
      state = state.copyWith(isLoading: false, error: '该有声书暂无可播放章节');
      return;
    }

    // 恢复断点续听记录；若上次已听完（最后一块末尾 ≥2s）则从头重播，
    // 避免"恢复到块尾 → 瞬间 completed → 暂停"的假死循环。
    int targetIndex = 0;
    int initialOffsetMs = 0;
    final saved = await _progressStore.read(audiobook.id);
    if (saved != null) {
      final foundIdx = chunks.indexWhere((c) => c.n == saved.chunkN);
      if (foundIdx != -1) {
        final chunkMs = (chunks[foundIdx].durationS * 1000).round();
        final listenedToEnd = foundIdx == chunks.length - 1 &&
            chunkMs > 0 &&
            saved.offsetMs >= chunkMs - 2000;
        if (!listenedToEnd) {
          targetIndex = foundIdx;
          initialOffsetMs = saved.offsetMs;
        }
      }
    }

    state = state.copyWith(chunks: chunks);
    await _loadChunk(
      targetIndex,
      initialOffsetMs: initialOffsetMs,
      autoPlay: autoPlay,
    );
  }

  /// 重新加载当前分块（播放失败/卡住时的重试入口）。
  Future<void> reload() async {
    if (!state.hasBook) return;
    final index = state.currentChunkIndex;
    final offset = state.positionMs;
    state = state.copyWith(clearError: true);
    await _loadChunk(
      index,
      initialOffsetMs: offset > 0 ? offset - 3000 : 0,
      autoPlay: true,
    );
  }

  /// 跳到指定分块内的毫秒位置（进度条跨章拖动）。
  Future<void> selectChunkAt(int index, int offsetMs) async {
    if (index < 0 || index >= state.chunks.length) return;
    await _loadChunk(index, initialOffsetMs: offsetMs, autoPlay: true);
  }

  Future<void> _loadChunk(
    int index, {
    int initialOffsetMs = 0,
    bool autoPlay = true,
  }) async {
    if (index < 0 || index >= state.chunks.length) return;
    final chunk = state.chunks[index];
    state = state.copyWith(
      currentChunkIndex: index,
      positionMs: initialOffsetMs,
      cues: const <SrtCue>[],
      activeCueIndex: -1,
      isLoading: true,
      clearError: true,
    );

    final audioUri = _api.resolveUri(chunk.audioUrl);
    try {
      final headers = await _api.authHeaders();
      final book = state.audiobook;
      final bookTitle = (book?.bookTitle.isNotEmpty ?? false)
          ? book!.bookTitle
          : '有声书 #${book?.id ?? 0}';
      // 音频源加载超时兜底：网络不可达时避免无限"假播放"（停留在 00:00）。
      await _engine
          .setSource(
            audioUri,
            headers: headers,
            initialPosition: Duration(milliseconds: initialOffsetMs),
            // 锁屏/通知栏媒体信息：书名 + 章节名 + 块时长（进度条刻度）。
            mediaTitle: bookTitle,
            mediaArtist: chunk.title.isNotEmpty
                ? chunk.title
                : '第 ${state.currentChunkIndex + 1} 章',
            mediaDuration:
                Duration(milliseconds: (chunk.durationS * 1000).round()),
          )
          .timeout(const Duration(seconds: 30));
      await _engine.setSpeed(state.speed);

      // 异步拉取当前分块 SRT 字幕（失败或无字幕时自动降级为纯封面模式）。
      List<SrtCue> parsedCues = const <SrtCue>[];
      if (chunk.srtUrl.isNotEmpty) {
        try {
          final rawSrt = await _api.fetchText(chunk.srtUrl);
          parsedCues = SrtParser.parse(rawSrt);
        } catch (_) {
          parsedCues = const <SrtCue>[];
        }
      }

      final cueIdx = SrtParser.activeCueIndex(parsedCues, initialOffsetMs);
      state = state.copyWith(
        cues: parsedCues,
        activeCueIndex: cueIdx,
        isLoading: false,
      );

      _lastSavedMs = initialOffsetMs;
      await _saveProgress();

      if (autoPlay) {
        await _engine.play();
      }
    } catch (e) {
      final raw = e.toString();
      final message = switch (e) {
        TimeoutException() => '音频加载超时：请检查网络或服务地址是否可达',
        ApiException(:final message) => message,
        _ when raw.contains('Source error') =>
          '音频无法加载：服务地址不可达，或被系统拦截明文 HTTP（$audioUri）',
        _ => '音频加载失败：$raw',
      };
      state = state.copyWith(isLoading: false, error: message);
    }
  }

  Future<void> togglePlayPause() async {
    if (!state.hasBook) return;
    if (state.isPlaying) {
      await _engine.pause();
      await _saveProgress();
    } else {
      // 已播到块尾时按播放：先回到开头，避免"点播放没反应"。
      final endMs = state.currentChunkDurationMs;
      if (endMs > 0 && state.positionMs >= endMs - 500) {
        await _engine.seek(Duration.zero);
        final cueIdx = SrtParser.activeCueIndex(state.cues, 0);
        state = state.copyWith(positionMs: 0, activeCueIndex: cueIdx);
      }
      await _engine.play();
    }
  }

  /// 快进 / 快退（如 ±15s），支持无缝跨越分块边界。
  Future<void> skipBy(Duration delta) async {
    if (!state.hasBook) return;
    final targetMs = state.positionMs + delta.inMilliseconds;
    final chunkDurMs = state.currentChunkDurationMs;

    if (targetMs < 0) {
      if (state.hasPreviousChunk) {
        final prevIndex = state.currentChunkIndex - 1;
        final prevDurMs = (state.chunks[prevIndex].durationS * 1000).round();
        final prevOffset =
            (prevDurMs + targetMs).clamp(0, prevDurMs > 0 ? prevDurMs : 0);
        await _loadChunk(
          prevIndex,
          initialOffsetMs: prevOffset,
          autoPlay: state.isPlaying,
        );
      } else {
        await seekToMs(0);
      }
      return;
    }

    if (chunkDurMs > 0 && targetMs > chunkDurMs) {
      if (state.hasNextChunk) {
        final nextIndex = state.currentChunkIndex + 1;
        final nextDurMs = (state.chunks[nextIndex].durationS * 1000).round();
        final overflow = targetMs - chunkDurMs;
        final nextOffset =
            overflow.clamp(0, nextDurMs > 0 ? nextDurMs : overflow);
        await _loadChunk(
          nextIndex,
          initialOffsetMs: nextOffset,
          autoPlay: state.isPlaying,
        );
      } else {
        await seekToMs(chunkDurMs);
      }
      return;
    }

    await seekToMs(targetMs);
  }

  /// 块内跳转（毫秒）。
  Future<void> seekToMs(int positionMs) async {
    if (!state.hasBook) return;
    final clamped = positionMs < 0 ? 0 : positionMs;
    await _engine.seek(Duration(milliseconds: clamped));
    final cueIdx = SrtParser.activeCueIndex(state.cues, clamped);
    state = state.copyWith(positionMs: clamped, activeCueIndex: cueIdx);
    await _saveProgress();
  }

  /// 点击跟读字幕句直接跳转到该句起始时间。
  Future<void> seekToCue(SrtCue cue) => seekToMs(cue.startMs);

  /// 切换到指定分块 / 章节。
  Future<void> selectChunk(int index) async {
    if (index < 0 || index >= state.chunks.length) return;
    await _loadChunk(index, initialOffsetMs: 0, autoPlay: true);
  }

  Future<void> nextChunk() async {
    if (state.hasNextChunk) {
      await selectChunk(state.currentChunkIndex + 1);
    }
  }

  Future<void> previousChunk() async {
    // 若当前块已播放超过 5 秒，点"上一章"先回到本章开头；否则切到上一块。
    if (state.positionMs > 5000 || !state.hasPreviousChunk) {
      await seekToMs(0);
    } else {
      await selectChunk(state.currentChunkIndex - 1);
    }
  }

  Future<void> setSpeed(double speed) async {
    await _engine.setSpeed(speed);
    state = state.copyWith(speed: speed);
  }

  // ---- 睡眠定时 ----

  Timer? _sleepTimer;

  bool get sleepTimerActive => state.sleepUntil != null;

  /// 设置睡眠定时：到点自动暂停并保存进度（播着睡着的场景）。
  Future<void> setSleepTimer(Duration duration) async {
    _sleepTimer?.cancel();
    final until = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () async {
      await _engine.pause();
      await _saveProgress();
      state = state.copyWith(isPlaying: false, clearSleepUntil: true);
    });
    state = state.copyWith(sleepUntil: until);
  }

  /// 关闭睡眠定时。
  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    state = state.copyWith(clearSleepUntil: true);
  }

  void _onPosition(Duration pos) {
    final ms = pos.inMilliseconds;
    final cueIdx = SrtParser.activeCueIndex(state.cues, ms);
    if (ms != state.positionMs || cueIdx != state.activeCueIndex) {
      state = state.copyWith(positionMs: ms, activeCueIndex: cueIdx);
    }
    if ((ms - _lastSavedMs).abs() >= 3000) {
      _lastSavedMs = ms;
      unawaited(_saveProgress());
    }
  }

  void _onPlayingChanged(bool playing) {
    if (state.isPlaying != playing) {
      state = state.copyWith(isPlaying: playing);
    }
  }

  Future<void> _onChunkCompleted() async {
    if (state.hasNextChunk) {
      await _loadChunk(
        state.currentChunkIndex + 1,
        initialOffsetMs: 0,
        autoPlay: true,
      );
    } else {
      await _engine.pause();
      state = state.copyWith(isPlaying: false);
      await _saveProgress();
    }
  }

  Future<void> _saveProgress() async {
    final book = state.audiobook;
    final chunk = state.currentChunk;
    if (book == null || chunk == null) return;
    await _progressStore.write(
      PlaybackProgress(
        audiobookId: book.id,
        chapterIndex: chunk.chapterIndex,
        chunkN: chunk.n,
        offsetMs: state.positionMs,
      ),
    );
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _playSub?.cancel();
    _doneSub?.cancel();
    _sleepTimer?.cancel();
    for (final sub in _lockScreenSubs) {
      sub.cancel();
    }
    _engine.dispose();
    super.dispose();
  }
}

final Provider<ProgressStore> progressStoreProvider =
    Provider<ProgressStore>((ref) => PersistentProgressStore());

/// 生产引擎选择：Android/iOS 已初始化 audio_service（锁屏播控）时用
/// [AudioServiceEngine]，桌面/测试等平台回退 [JustAudioEngine]。
final Provider<AudioEngine> audioEngineProvider = Provider<AudioEngine>(
  (ref) => AudioServiceEngine.initialized
      ? AudioServiceEngine.instance
      : JustAudioEngine(),
);

final StateNotifierProvider<ChunkedPlayerController, ChunkedPlayerState>
    chunkedPlayerProvider =
    StateNotifierProvider<ChunkedPlayerController, ChunkedPlayerState>((ref) {
  return ChunkedPlayerController(
    ref.watch(echoApiProvider),
    ref.watch(audioEngineProvider),
    ref.watch(progressStoreProvider),
  );
});
