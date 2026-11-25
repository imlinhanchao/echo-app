import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/standalone_config_store.dart';
import '../../core/tts/tts_model_manager.dart';
import '../../core/tts/voice_recorder_service.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';

/// 适合 3–8 秒清晰朗读的预设引导词（与 ZipVoice 词典标点兼容）。
const List<String> zipvoiceSamplePrompts = <String>[
  '夜深时分，翻开一卷好书，让温暖的声音陪你慢慢阅读。',
  '清晨的阳光洒在书桌上，今天也要保持平静与专注。',
  '每一个字句都值得被温柔朗读，回声将伴随你的阅读旅程。',
  '微风拂过窗前的树叶，安静地聆听一段来自纸页间的故事。',
];

/// ZipVoice 参考音色现场录制页（极简书房 Editorial Minimalism）：
/// - 引导台词预设切换与自定义编辑；
/// - 实时 24 柱声波电平、等宽计时器与时长区间建议；
/// - 录完即时试听、重录与保存为参考音色。
class ZipVoiceReferenceRecorderPage extends ConsumerStatefulWidget {
  const ZipVoiceReferenceRecorderPage({super.key});

  @override
  ConsumerState<ZipVoiceReferenceRecorderPage> createState() =>
      _ZipVoiceReferenceRecorderPageState();
}

class _ZipVoiceReferenceRecorderPageState
    extends ConsumerState<ZipVoiceReferenceRecorderPage> {
  static const int _barCount = 24;
  static const int _recommendedMaxMs = 15000;

  late final TextEditingController _textCtrl;
  late final VoiceRecorderService _recorder;
  late final VoicePreviewAudioPlayer _previewPlayer;
  StreamSubscription<bool>? _playingSub;

  int _promptIndex = 0;
  bool _recording = false;
  bool _polling = false;
  bool _saving = false;
  bool _previewPlaying = false;
  bool _permissionDenied = false;
  int _elapsedMs = 0;
  String? _errorMessage;
  RecordedVoiceResult? _recordedResult;
  Timer? _pollTimer;
  List<double> _levels = List<double>.filled(_barCount, 0.08);
  Directory? _fallbackTempDir;

  @override
  void initState() {
    super.initState();
    _recorder = ref.read(voiceRecorderServiceProvider);
    final existingText =
        ref.read(standaloneConfigProvider).zipvoiceRefText.trim();
    _textCtrl = TextEditingController(
      text: existingText.isNotEmpty
          ? existingText
          : zipvoiceSamplePrompts.first,
    );
    _textCtrl.addListener(_onTextChanged);

    _previewPlayer = ref.read(voicePreviewPlayerFactoryProvider)();
    _playingSub = _previewPlayer.playingStream.listen((playing) {
      if (!mounted) return;
      if (_previewPlaying != playing) {
        setState(() => _previewPlaying = playing);
      }
    });
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _textCtrl.removeListener(_onTextChanged);
    _textCtrl.dispose();
    _playingSub?.cancel();
    if (_recording) {
      unawaited(_recorder.cancelRecording());
    }
    _deleteTempFile(_recordedResult?.path);
    final dir = _fallbackTempDir;
    if (dir != null && dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
    unawaited(_previewPlayer.dispose());
    super.dispose();
  }

  void _deleteTempFile(String? path) {
    if (path == null || path.isEmpty) return;
    final file = File(path);
    if (file.existsSync()) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
  }

  Future<Directory> _resolveTempDir() async {
    try {
      return await ref.read(voiceRecorderTempDirProvider)();
    } catch (_) {
      return _fallbackTempDir ??= Directory.systemTemp.createTempSync(
        'echo_voice_rec_',
      );
    }
  }

  void _cyclePrompt() {
    _promptIndex = (_promptIndex + 1) % zipvoiceSamplePrompts.length;
    if (_textCtrl.text.trim() == zipvoiceSamplePrompts[_promptIndex]) {
      _promptIndex = (_promptIndex + 1) % zipvoiceSamplePrompts.length;
    }
    _textCtrl.text = zipvoiceSamplePrompts[_promptIndex];
  }

  Future<void> _toggleRecording() async {
    if (_saving) return;
    if (_recording) {
      await _stopRecording();
      return;
    }
    await _startRecording();
  }

  Future<void> _startRecording() async {
    final recorder = _recorder;
    if (!recorder.isSupported) {
      setState(() {
        _permissionDenied = false;
        _errorMessage = '当前平台暂不支持应用内录制，请导入本地 .wav 文件';
      });
      return;
    }

    final granted = await recorder.ensurePermission();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _permissionDenied = true;
        _errorMessage = '未获得麦克风录音权限，请在系统设置中开启后重试';
      });
      return;
    }

    await _previewPlayer.stop();
    final previousPath = _recordedResult?.path;
    final tmpDir = await _resolveTempDir();
    final outPath = buildTempVoiceRecordingPath(tmpDir);

    try {
      await recorder.startRecording(outPath, sampleRate: 24000);
      _deleteTempFile(previousPath);
      if (!mounted) {
        unawaited(recorder.cancelRecording());
        return;
      }
      setState(() {
        _recording = true;
        _elapsedMs = 0;
        _recordedResult = null;
        _permissionDenied = false;
        _errorMessage = null;
        _levels = List<double>.filled(_barCount, 0.08);
      });
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 60),
        (_) => unawaited(_pollStatus()),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recording = false;
        _errorMessage = '启动录音失败：$e';
      });
    }
  }

  Future<void> _pollStatus() async {
    if (_polling || !_recording || !mounted) return;
    _polling = true;
    try {
      final status = await _recorder.getStatus();
      if (!mounted || !_recording) return;
      final nextLevel = math.max(0.08, status.level.clamp(0.0, 1.0));
      setState(() {
        _elapsedMs = status.elapsedMs;
        _levels = <double>[..._levels.skip(1), nextLevel];
      });
      if (status.autoStopped) {
        await _stopRecording();
      }
    } catch (_) {
      // 忽略单次轮询异常
    } finally {
      _polling = false;
    }
  }

  Future<void> _stopRecording() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final recorder = _recorder;
    try {
      final result = await recorder.stopRecording();
      if (!mounted) {
        _deleteTempFile(result.path);
        return;
      }
      setState(() {
        _recording = false;
        _recordedResult = result;
        _elapsedMs = result.durationMs;
        _levels = List<double>.filled(_barCount, 0.08);
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recording = false;
        _errorMessage = '停止录音失败：$e';
      });
    }
  }

  Future<void> _togglePreviewPlay() async {
    final recorded = _recordedResult;
    if (recorded == null || _recording) return;
    try {
      if (_previewPlaying) {
        await _previewPlayer.stop();
        if (mounted) setState(() => _previewPlaying = false);
      } else {
        await _previewPlayer.playFile(recorded.path);
        if (mounted) setState(() => _previewPlaying = true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _previewPlaying = false;
        _errorMessage = '试听录音失败：$e';
      });
    }
  }

  Future<void> _resetRecording() async {
    await _previewPlayer.stop();
    final oldPath = _recordedResult?.path;
    setState(() {
      _recordedResult = null;
      _elapsedMs = 0;
      _previewPlaying = false;
      _errorMessage = null;
      _levels = List<double>.filled(_barCount, 0.08);
    });
    _deleteTempFile(oldPath);
  }

  Future<void> _saveAndApply() async {
    final recorded = _recordedResult;
    final refText = _textCtrl.text.trim();
    if (recorded == null || refText.isEmpty || _recording || _saving) return;

    await _previewPlayer.stop();
    setState(() {
      _saving = true;
      _errorMessage = null;
    });

    final err = await ref
        .read(ttsModelManagerProvider.notifier)
        .importZipVoiceReferenceAudio(File(recorded.path), refText);
    if (!mounted) return;

    if (err != null) {
      setState(() {
        _saving = false;
        _errorMessage = err;
      });
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(err)));
      return;
    }

    _deleteTempFile(recorded.path);
    _recordedResult = null;
    setState(() => _saving = false);
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('已保存并应用录制的参考音色')));
    Navigator.of(context).pop(true);
  }

  String _formatTenths(int ms) {
    final clamped = math.max(0, ms);
    final totalTenths = clamped ~/ 100;
    final secs = totalTenths ~/ 10;
    final tenths = totalTenths % 10;
    final mins = secs ~/ 60;
    final remSecs = secs % 60;
    final mm = mins.toString().padLeft(2, '0');
    final ss = remSecs.toString().padLeft(2, '0');
    return '$mm:$ss.$tenths';
  }

  ({String text, Color color}) _statusHint(EchoTokens tokens) {
    if (_recording) {
      if (_elapsedMs < 1000) {
        return (text: '时长较短，请继续朗读…', color: tokens.warning);
      }
      if (_elapsedMs <= 10000) {
        return (text: '时长理想，可随时停止', color: tokens.success);
      }
      return (text: '时长已足够，建议点击停止', color: tokens.primary);
    }
    final rec = _recordedResult;
    if (rec != null) {
      if (rec.durationMs < 1000) {
        return (text: '录制过短（不足 1 秒），建议重新录制', color: tokens.error);
      }
      return (text: '录制完成 · 可先试听再保存应用', color: tokens.success);
    }
    return (text: '准备就绪 · 建议录制 3–10 秒', color: tokens.textSecondary);
  }

  String _formatSampleRateKhz(int sampleRate) {
    if (sampleRate % 1000 == 0) {
      return '${sampleRate ~/ 1000} kHz';
    }
    return '${(sampleRate / 1000).toStringAsFixed(1)} kHz';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final recorder = ref.watch(voiceRecorderServiceProvider);
    final hint = _statusHint(tokens);
    final canSave =
        _recordedResult != null &&
        _textCtrl.text.trim().isNotEmpty &&
        !_recording &&
        !_saving;

    return Scaffold(
      appBar: AppBar(title: const Text('录制参考音色')),
      body: EchoAmbientBackground(
        child: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(EchoMetrics.pagePadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. 朗读台词准备区
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: echoElevatedCardDecoration(context, radius: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '1. 参考朗读文本',
                              style: textTheme.titleSmall?.copyWith(
                                color: tokens.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            key: const Key('zipvoice_recorder_next_prompt'),
                            onPressed: _recording || _saving
                                ? null
                                : _cyclePrompt,
                            icon: const Icon(
                              Icons.auto_awesome_outlined,
                              size: 16,
                            ),
                            label: const Text('换一句'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '请保持环境安静，用自然语速朗读下方文字（建议 3–10 秒），确保文字与实际朗读内容完全一致。',
                        style: textTheme.bodySmall?.copyWith(
                          fontSize: 12.5,
                          color: tokens.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const Key('zipvoice_recorder_text_field'),
                        controller: _textCtrl,
                        maxLines: 3,
                        minLines: 2,
                        enabled: !_saving,
                        decoration: const InputDecoration(
                          labelText: '将要或已朗读的文字内容',
                          hintText: '输入与你录音完全一致的文字，克隆效果更自然',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: EchoMetrics.space3),

                if (!recorder.isSupported) ...[
                  Container(
                    key: const Key('zipvoice_recorder_unsupported_banner'),
                    padding: const EdgeInsets.all(14),
                    decoration: echoElevatedCardDecoration(
                      context,
                      radius: 14,
                      borderColor: tokens.warning.withValues(alpha: 0.4),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded, color: tokens.warning),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '当前平台或设备暂不支持应用内麦克风录制，请返回上一页使用「导入 WAV」加载本地录音文件。',
                            style: textTheme.bodySmall?.copyWith(
                              color: tokens.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                ],

                if (_errorMessage != null) ...[
                  Container(
                    key: const Key('zipvoice_recorder_error_banner'),
                    padding: const EdgeInsets.all(14),
                    decoration: echoElevatedCardDecoration(
                      context,
                      radius: 14,
                      borderColor: tokens.error.withValues(alpha: 0.45),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.error_outline_rounded,
                              color: tokens.error,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: textTheme.bodySmall?.copyWith(
                                  color: tokens.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (_permissionDenied) ...[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () => recorder.openSettings(),
                              child: const Text('前往系统设置'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                ],

                // 2. 实时声波与录制控制区
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: echoElevatedCardDecoration(context, radius: 16),
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '2. 录制声音样本',
                          style: textTheme.titleSmall?.copyWith(
                            color: tokens.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // 24 柱实时电平仪表
                      Container(
                        height: 60,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: tokens.surfaceBase,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: echoHairlineColor(context),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            for (final level in _levels)
                              Expanded(
                                child: Center(
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 55),
                                    width: 4,
                                    height: (6 + level * 38).clamp(6.0, 44.0),
                                    decoration: BoxDecoration(
                                      color: _recording
                                          ? tokens.primary
                                          : tokens.textDisabled.withValues(
                                              alpha: 0.45,
                                            ),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '${_formatTenths(_elapsedMs)} / ${_formatTenths(_recommendedMaxMs)}',
                        style: textTheme.titleLarge?.copyWith(
                          color: tokens.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 6),
                      EchoPillBadge(
                        label: hint.text,
                        color: hint.color,
                        filled: _recording,
                      ),
                      const SizedBox(height: 18),
                      Semantics(
                        button: true,
                        label: _recording ? '停止录制' : '开始录制',
                        child: InkWell(
                          key: const Key('zipvoice_recorder_toggle_btn'),
                          onTap: _saving ? null : _toggleRecording,
                          customBorder: const CircleBorder(),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color:
                                  _recording ? tokens.error : tokens.primary,
                              boxShadow: [
                                BoxShadow(
                                  color: (_recording
                                          ? tokens.error
                                          : tokens.primary)
                                      .withValues(alpha: 0.25),
                                  blurRadius: 14,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Icon(
                              _recording
                                  ? Icons.stop_rounded
                                  : Icons.mic_rounded,
                              size: 32,
                              color: _recording
                                  ? Colors.white
                                  : tokens.textOnPrimary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _recording ? '点击停止录制' : '点击开始录制',
                        style: textTheme.labelMedium?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                      if (_recordedResult != null && !_recording) ...[
                        const SizedBox(height: 16),
                        const Divider(height: 1),
                        const SizedBox(height: 12),
                        Text(
                          '已录制 ${(_recordedResult!.durationMs / 1000).toStringAsFixed(1)} 秒 · ${_formatSampleRateKhz(_recordedResult!.sampleRate)} WAV',
                          style: textTheme.bodySmall?.copyWith(
                            color: tokens.textPrimary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            EchoSecondaryButton(
                              key: const Key('zipvoice_recorder_play_btn'),
                              onPressed: _saving ? null : _togglePreviewPlay,
                              icon: _previewPlaying
                                  ? Icons.stop_rounded
                                  : Icons.play_arrow_rounded,
                              label: _previewPlaying ? '停止试听' : '试听录音',
                            ),
                            TextButton.icon(
                              key: const Key('zipvoice_recorder_rerecord_btn'),
                              onPressed: _saving ? null : _resetRecording,
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: const Text('重新录制'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: tokens.surfaceElevated,
          border: Border(
            top: BorderSide(color: echoHairlineColor(context), width: 0.8),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              EchoMetrics.pagePadding,
              12,
              EchoMetrics.pagePadding,
              12,
            ),
            child: EchoPrimaryButton(
              key: const Key('zipvoice_recorder_apply_btn'),
              onPressed: canSave ? _saveAndApply : null,
              icon: Icons.check_rounded,
              label: _saving ? '正在保存...' : '保存并设为参考音色',
            ),
          ),
        ),
      ),
    );
  }
}
