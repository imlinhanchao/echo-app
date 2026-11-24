import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'chunked_player_controller.dart' show AudioEngine, LockScreenControls;

/// audio_service 后台处理器：把 just_audio 会话桥接到系统媒体控制
/// （锁屏/通知栏：书名 + 章节名 + 进度条 + 上一章/-15s/播放/+15s/下一章）。
class EchoAudioHandler extends BaseAudioHandler {
  EchoAudioHandler() {
    _player.playingStream.listen((_) => _broadcast());
    _player.positionStream.listen((_) => _broadcast());
    _player.processingStateStream.listen((_) => _broadcast());
    _player.speedStream.listen((_) => _broadcast());
  }

  final AudioPlayer _player = AudioPlayer();
  final StreamController<void> _skipNext = StreamController<void>.broadcast();
  final StreamController<void> _skipPrev = StreamController<void>.broadcast();
  final StreamController<void> _fastForward =
      StreamController<void>.broadcast();
  final StreamController<void> _rewind = StreamController<void>.broadcast();

  AudioPlayer get player => _player;
  bool _switchingSource = false;
  bool _keepPlayingAcrossSwitch = false;
  Stream<void> get skipNextRequests => _skipNext.stream;
  Stream<void> get skipPrevRequests => _skipPrev.stream;
  Stream<void> get fastForwardRequests => _fastForward.stream;
  Stream<void> get rewindRequests => _rewind.stream;

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
    _keepPlayingAcrossSwitch = _player.playing || _keepPlayingAcrossSwitch;
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
  Future<void> play() {
    _keepPlayingAcrossSwitch = true;
    return _player.play();
  }

  @override
  Future<void> pause() {
    _keepPlayingAcrossSwitch = false;
    return _player.pause();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0.0, 1.0));

  @override
  Future<void> stop() async {
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
    final effectivePlaying =
        _player.playing || (_switchingSource && _keepPlayingAcrossSwitch);
    final effectiveProcState = (_switchingSource && procState == ProcessingState.idle)
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
    // 暂停后允许划掉通知，终止播放时先退出前台状态再彻底撤除通知栏卡片，
    // 同时保持 androidResumeOnClick 为 true 确保锁屏/蓝牙媒体控件会话激活。
    androidNotificationOngoing: false,
    androidStopForegroundOnPause: true,
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

  /// 在 main() 中初始化后台媒体会话与音频焦点（来电/耳机拔出自动暂停）；
  /// 非 Android/iOS 平台（桌面/测试）自动跳过并回退 just_audio。
  static Future<void> tryInit() async {
    if (kIsWeb) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      final handler = await AudioService.init(
        builder: () => EchoAudioHandler(),
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
              if (_handler.player.playing) {
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
        if (_handler.player.playing) {
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
  Future<void> play() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (_) {}
    await _handler.play();
  }

  @override
  Future<void> pause() => _handler.pause();

  static const MethodChannel _mediaNotifChannel = MethodChannel(
    'org.hancel.echo/media_notification',
  );

  @override
  Future<void> stop() async {
    await _handler.stop();
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
}
