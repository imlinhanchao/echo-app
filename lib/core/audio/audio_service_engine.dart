import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'chunked_player_controller.dart' show AudioEngine, LockScreenControls;

/// 播放器适配器抽象：把 [AudioPlayer] 的事件流与控制接口暴露给 [EchoAudioHandler]，
/// 便于在单元测试中注入假播放器直接验证耳机按键暂停与恢复行为。
@visibleForTesting
abstract class EchoPlayerAdapter {
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<ProcessingState> get processingStateStream;
  Stream<double> get speedStream;

  bool get playing;
  ProcessingState get processingState;
  Duration get position;
  Duration get bufferedPosition;
  double get speed;

  Future<Duration?> setAudioSource(
    AudioSource source, {
    Duration? initialPosition,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration? position);
  Future<void> setSpeed(double speed);
  Future<void> setVolume(double volume);
}

class _JustAudioPlayerAdapter implements EchoPlayerAdapter {
  // 音频焦点与中断已由 AudioServiceEngine 统一接管，关闭 just_audio 内部重复监听，
  // 避免两者同时响应中断或抢占 AudioSession 状态。
  final AudioPlayer _player = AudioPlayer(
    handleInterruptions: false,
    handleAudioSessionActivation: false,
  );

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<ProcessingState> get processingStateStream =>
      _player.processingStateStream;

  @override
  Stream<double> get speedStream => _player.speedStream;

  @override
  bool get playing => _player.playing;

  @override
  ProcessingState get processingState => _player.processingState;

  @override
  Duration get position => _player.position;

  @override
  Duration get bufferedPosition => _player.bufferedPosition;

  @override
  double get speed => _player.speed;

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    Duration? initialPosition,
  }) => _player.setAudioSource(source, initialPosition: initialPosition);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration? position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);
}

/// audio_service 后台处理器：把 just_audio 会话桥接到系统媒体控制
/// （锁屏/通知栏：书名 + 章节名 + 进度条 + 上一章/-15s/播放/+15s/下一章）。
class EchoAudioHandler extends BaseAudioHandler {
  EchoAudioHandler({
    @visibleForTesting EchoPlayerAdapter? player,
    Future<bool> Function()? activateAudioSession,
    Future<void> Function()? onStopped,
  }) : _player = player ?? _JustAudioPlayerAdapter(),
       _activateAudioSession = activateAudioSession,
       _onStopped = onStopped {
    _player.playingStream.listen((_) => _broadcast());
    _player.positionStream.listen((_) => _broadcast());
    _player.processingStateStream.listen((_) => _broadcast());
    _player.speedStream.listen((_) => _broadcast());
  }

  final EchoPlayerAdapter _player;
  final Future<bool> Function()? _activateAudioSession;
  final Future<void> Function()? _onStopped;
  final StreamController<void> _skipNext = StreamController<void>.broadcast();
  final StreamController<void> _skipPrev = StreamController<void>.broadcast();
  final StreamController<void> _fastForward =
      StreamController<void>.broadcast();
  final StreamController<void> _rewind = StreamController<void>.broadcast();
  final StreamController<void> _playRequests =
      StreamController<void>.broadcast();
  final StreamController<void> _pauseRequests =
      StreamController<void>.broadcast();

  EchoPlayerAdapter get player => _player;
  bool _switchingSource = false;
  bool _keepPlayingAcrossSwitch = false;
  int _playbackOpToken = 0;

  bool get isEffectivelyPlaying =>
      _player.playing || (_switchingSource && _keepPlayingAcrossSwitch);

  Stream<void> get skipNextRequests => _skipNext.stream;
  Stream<void> get skipPrevRequests => _skipPrev.stream;
  Stream<void> get fastForwardRequests => _fastForward.stream;
  Stream<void> get rewindRequests => _rewind.stream;
  Stream<void> get playRequests => _playRequests.stream;
  Stream<void> get pauseRequests => _pauseRequests.stream;

  /// 载入一个分块音源并广播媒体元数据（锁屏显示书名/章节/时长）。
  Future<void> setChunkSource(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration initialPosition = Duration.zero,
    Duration? duration,
    String title = '',
    String artist = '',
    Uri? artUri,
  }) async {
    _keepPlayingAcrossSwitch = isEffectivelyPlaying;
    _switchingSource = true;
    try {
      final baseItem = MediaItem(
        id: uri.toString(),
        album: 'Echo · 回声',
        title: title.isEmpty ? 'Echo · 回声' : title,
        artist: artist,
        duration: duration,
        // 锁屏 / 通知栏上部"小组件"的封面图
        artUri: artUri,
      );
      mediaItem.add(baseItem);
      final loadedDuration = await _player.setAudioSource(
        AudioSource.uri(uri, headers: headers.isEmpty ? null : headers),
        initialPosition: initialPosition,
      );
      if (duration == null &&
          loadedDuration != null &&
          loadedDuration > Duration.zero) {
        mediaItem.add(baseItem.copyWith(duration: loadedDuration));
      }
    } finally {
      _switchingSource = false;
    }
    _broadcast();
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        if (isEffectivelyPlaying) {
          await pause();
        } else {
          await play();
        }
      case MediaButton.next:
        await skipToNext();
      case MediaButton.previous:
        await skipToPrevious();
    }
  }

  /// App 内部发起的播放（UI 按钮 / 自动续句 / 切章）。
  Future<void> playFromApp() => _startPlayback(external: false);

  /// App 内部发起的暂停。
  Future<void> pauseFromApp() async {
    _playbackOpToken++;
    _keepPlayingAcrossSwitch = false;
    await _player.pause();
    _broadcast();
  }

  Future<void> _startPlayback({required bool external}) async {
    final token = ++_playbackOpToken;
    if (_activateAudioSession != null) {
      try {
        final granted = await _activateAudioSession();
        if (token != _playbackOpToken) return;
        if (!granted) {
          _keepPlayingAcrossSwitch = false;
          _broadcast();
          return;
        }
      } catch (_) {}
    }
    if (token != _playbackOpToken) return;
    final procState = _player.processingState;
    if (procState == ProcessingState.idle) {
      if (external) {
        _playRequests.add(null);
      }
      return;
    }
    if (procState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
      if (token != _playbackOpToken) return;
    }
    _keepPlayingAcrossSwitch = true;
    // just_audio 的 play() 在暂停或播完前不会返回，不能阻塞媒体按键回调与切句过渡状态。
    unawaited(_player.play().catchError((Object _) {}));
    _broadcast();
    if (external) {
      _playRequests.add(null);
    }
  }

  @override
  Future<void> play() => _startPlayback(external: true);

  @override
  Future<void> pause() async {
    await pauseFromApp();
    _pauseRequests.add(null);
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0.0, 1.0));

  @override
  Future<void> stop() async {
    _playbackOpToken++;
    _switchingSource = false;
    _keepPlayingAcrossSwitch = false;
    await _player.stop();
    mediaItem.add(null);
    playbackState.add(
      PlaybackState(
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
    await super.stop();
    await _onStopped?.call();
  }

  /// 锁屏"上一首/下一首"按设计映射为章节切换请求，
  /// "快退/快进"映射为 ±15s（由 ChunkedPlayerController 跨块处理）。
  @override
  Future<void> skipToNext() async => _skipNext.add(null);

  @override
  Future<void> skipToPrevious() async => _skipPrev.add(null);

  @override
  Future<void> fastForward() async => _fastForward.add(null);

  @override
  Future<void> rewind() async => _rewind.add(null);

  static const _processingStateMap = <ProcessingState, AudioProcessingState>{
    ProcessingState.idle: AudioProcessingState.idle,
    ProcessingState.loading: AudioProcessingState.loading,
    ProcessingState.buffering: AudioProcessingState.buffering,
    ProcessingState.ready: AudioProcessingState.ready,
    ProcessingState.completed: AudioProcessingState.completed,
  };

  void _broadcast() {
    final procState = _player.processingState;
    if (_switchingSource && procState == ProcessingState.idle) {
      return;
    }
    if (!_switchingSource && procState == ProcessingState.idle) {
      playbackState.add(
        PlaybackState(
          processingState: AudioProcessingState.idle,
          playing: false,
        ),
      );
      return;
    }
    final effectivePlaying = isEffectivelyPlaying;
    final effectiveProcState =
        (_switchingSource && procState == ProcessingState.idle)
        ? AudioProcessingState.buffering
        : (_processingStateMap[procState] ?? AudioProcessingState.idle);
    if (!_switchingSource &&
        !_player.playing &&
        procState != ProcessingState.loading &&
        procState != ProcessingState.buffering) {
      _keepPlayingAcrossSwitch = false;
    }
    playbackState.add(
      PlaybackState(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          MediaControl.rewind,
          if (effectivePlaying) MediaControl.pause else MediaControl.play,
          MediaControl.fastForward,
          MediaControl.skipToNext,
        ],
        systemActions: const <MediaAction>{
          MediaAction.play,
          MediaAction.pause,
          MediaAction.playPause,
          MediaAction.seek,
          MediaAction.rewind,
          MediaAction.fastForward,
          MediaAction.skipToPrevious,
          MediaAction.skipToNext,
        },
        // 紧凑通知栏优先展示：-15s / 播放暂停 / +15s（对齐设计 §4.1 锁屏播控卡）
        androidCompactActionIndices: const <int>[1, 2, 3],
        processingState: effectiveProcState,
        playing: effectivePlaying,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
      ),
    );
  }
}

/// 经 audio_service 驱动的生产引擎（Android/iOS），集成 audio_session 音频焦点。
/// 单例由 [tryInit] 在 main() 初始化；dispose 为空操作（会话与 App 同生命周期）。
class AudioServiceEngine implements AudioEngine, LockScreenControls {
  AudioServiceEngine._(this._handler);

  static bool initialized = false;
  static AudioServiceEngine? _instance;

  /// 已初始化的单例；未初始化时不应访问（引擎选择在 provider 中先行判断）。
  static AudioServiceEngine get instance => _instance!;

  final EchoAudioHandler _handler;
  bool _pausedByInterruption = false;

  @visibleForTesting
  static const AudioServiceConfig audioServiceConfig = AudioServiceConfig(
    androidNotificationChannelId: 'org.hancel.echo.playback',
    androidNotificationChannelName: 'Echo 播放',
    androidNotificationIcon: 'drawable/ic_stat_echo',
    // 暂停后保持前台服务保活，避免 Android 12+ / 鸿蒙在锁屏后台按耳机恢复播放时被系统拦截；
    // 显式 stop() 时通过原生 EchoAudioServiceBridge 退出前台并撤除通知栏卡片。
    androidNotificationOngoing: false,
    androidStopForegroundOnPause: false,
    androidResumeOnClick: true,
    rewindInterval: Duration(seconds: 15),
    fastForwardInterval: Duration(seconds: 15),
  );

  @visibleForTesting
  static Uri? parseArtUri(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('/')) {
      return Uri.file(trimmed);
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (const <String>{
      'http',
      'https',
      'file',
      'content',
    }.contains(uri.scheme.toLowerCase())) {
      return uri;
    }
    return null;
  }

  static Future<bool> _activateAudioSession() async {
    try {
      final session = await AudioSession.instance;
      return await session.setActive(true);
    } catch (_) {
      return true;
    }
  }

  static Future<void> _cleanupOnStop() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (_) {}
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _mediaNotifChannel.invokeMethod<void>(
          'cancelPlaybackNotification',
        );
      } catch (_) {}
    }
  }

  /// 在 main() 中初始化后台媒体会话与音频焦点（来电/耳机拔出自动暂停）；
  /// 非 Android/iOS 平台（桌面/测试）自动跳过并回退 just_audio。
  static Future<void> tryInit() async {
    if (kIsWeb) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      final handler = await AudioService.init(
        builder: () => EchoAudioHandler(
          activateAudioSession: _activateAudioSession,
          onStopped: _cleanupOnStop,
        ),
        config: audioServiceConfig,
      );
      final engine = AudioServiceEngine._(handler);
      await engine._initAudioSession();
      _instance = engine;
      initialized = true;
    } catch (e) {
      debugPrint('AudioService 初始化失败，回退 just_audio：$e');
    }
  }

  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              _handler.setVolume(0.35);
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (_handler.isEffectivelyPlaying) {
                _pausedByInterruption = true;
                unawaited(_handler.pause());
              }
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              _handler.setVolume(1.0);
            case AudioInterruptionType.pause:
              if (_pausedByInterruption) {
                _pausedByInterruption = false;
                unawaited(_handler.play());
              }
            case AudioInterruptionType.unknown:
              _pausedByInterruption = false;
          }
        }
      });
      // 拔出耳机 / 蓝牙断开时自动暂停，防止公放尴尬
      session.becomingNoisyEventStream.listen((_) {
        if (_handler.isEffectivelyPlaying) {
          unawaited(_handler.pause());
        }
      });
    } catch (e) {
      debugPrint('AudioSession 焦点配置失败，忽略：$e');
    }
  }

  @override
  Stream<Duration> get positionStream => _handler.player.positionStream;

  @override
  Stream<bool> get playingStream => _handler.player.playingStream;

  @override
  Stream<void> get completedStream => _handler.player.processingStateStream
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
    String? mediaArtUrl,
  }) => _handler.setChunkSource(
    uri,
    headers: headers,
    initialPosition: initialPosition,
    duration: mediaDuration,
    title: mediaTitle ?? '',
    artist: mediaArtist ?? '',
    // 本地缓存文件（file://）或远端地址都可；本地绝对路径自动补全 file://。
    artUri: parseArtUri(mediaArtUrl),
  );

  @override
  Future<void> play() => _handler.playFromApp();

  @override
  Future<void> pause() => _handler.pauseFromApp();

  static const MethodChannel _mediaNotifChannel = MethodChannel(
    'org.hancel.echo/media_notification',
  );

  @override
  Future<void> stop() => _handler.stop();

  @override
  Future<void> seek(Duration position) => _handler.seek(position);

  @override
  Future<void> setSpeed(double speed) => _handler.setSpeed(speed);

  @override
  Future<void> setVolume(double volume) => _handler.setVolume(volume);

  /// 空操作：后台媒体会话与 App 同生命周期，由系统管理释放。
  @override
  Future<void> dispose() async {}

  @override
  Stream<void> get skipToNextRequests => _handler.skipNextRequests;

  @override
  Stream<void> get skipToPreviousRequests => _handler.skipPrevRequests;

  @override
  Stream<void> get fastForwardRequests => _handler.fastForwardRequests;

  @override
  Stream<void> get rewindRequests => _handler.rewindRequests;

  @override
  Stream<void> get playRequests => _handler.playRequests;

  @override
  Stream<void> get pauseRequests => _handler.pauseRequests;
}
