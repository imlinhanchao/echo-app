import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/api/models.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../jobs/jobs_controller.dart';
import '../library/library_controller.dart';

/// 转有声书发起表单（Bottom Sheet）：
/// TTS 模型 / 音色 / 语速 / 章节范围选择 / 音色试听 / 提交任务。
class ConvertSheet extends ConsumerStatefulWidget {
  const ConvertSheet({super.key, required this.book});

  final LibraryBook book;

  @override
  ConsumerState<ConvertSheet> createState() => _ConvertSheetState();
}

class _ConvertSheetState extends ConsumerState<ConvertSheet> {
  final _instructController = TextEditingController();

  TtsModelsResponse? _modelsResponse;
  List<TtsVoiceInfo> _voices = const <TtsVoiceInfo>[];
  List<ChapterPreview> _chapters = const <ChapterPreview>[];
  Set<int> _selectedChapterIndexes = <int>{};

  String? _selectedModel;
  String? _selectedVoice;
  double _speed = 1.0;
  bool _loading = true;
  String? _error;
  bool _submitting = false;

  AudioPlayer? _samplePlayer;
  bool _samplePlaying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _instructController.dispose();
    _samplePlayer?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = ref.read(echoApiProvider);
    try {
      final models = await api.ttsModels();
      if (!mounted) return;
      final defaultModel = models.models.firstWhere(
        (m) => m.isDefault,
        orElse: () => models.models.first,
      );
      final selected = _selectedModel ?? defaultModel.id;
      final voices = await api.ttsVoices(selected);
      if (!mounted) return;
      setState(() {
        _modelsResponse = models;
        _selectedModel ??= selected;
        _voices = voices;
        _selectedVoice = voices.isNotEmpty ? voices.first.id : '';
        _loading = false;
      });
      // 章节清单失败不阻塞表单（可整本转换）。
      try {
        final chapters = await api.bookChapters(widget.book.id);
        if (mounted) {
          setState(() => _chapters = chapters);
        }
      } catch (_) {
        // 非 EPUB 或解析失败：不展示章节选择。
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _onModelChanged(String? model) async {
    if (model == null || model == _selectedModel) return;
    setState(() {
      _selectedModel = model;
      _selectedVoice = null;
      _voices = const <TtsVoiceInfo>[];
    });
    try {
      final voices = await ref.read(echoApiProvider).ttsVoices(model);
      if (mounted) {
        setState(() {
          _voices = voices;
          _selectedVoice = voices.isNotEmpty ? voices.first.id : '';
        });
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    }
  }

  Future<void> _toggleSample() async {
    final model = _selectedModel;
    final voice = _selectedVoice ?? '';
    if (model == null) return;
    final api = ref.read(echoApiProvider);

    if (_samplePlaying) {
      await _samplePlayer?.stop();
      if (mounted) setState(() => _samplePlaying = false);
      return;
    }

    _samplePlayer ??= AudioPlayer();
    try {
      final headers = await api.authHeaders();
      await _samplePlayer!.setUrl(
        api.ttsSampleUrl(model, voice).toString(),
        headers: headers,
      );
      await _samplePlayer!.play();
      if (mounted) setState(() => _samplePlaying = true);
    } catch (_) {
      if (mounted) {
        setState(() => _samplePlaying = false);
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('试听失败，请稍后再试')));
      }
    }
  }

  Future<void> _pickChapters() async {
    if (_chapters.isEmpty) return;
    // 选中集合必须提升到 StatefulBuilder 之外：
    // 放在 builder 内会在每次 setDialogState 重建时被重置，表现为"勾选没反应"。
    final chosen = Set<int>.of(_selectedChapterIndexes);
    final selected = await showDialog<Set<int>?>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          return AlertDialog(
            title: const Text('选择转换章节'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _chapters.length,
                itemBuilder: (_, i) {
                  final chapter = _chapters[i];
                  final checked = chosen.contains(chapter.index);
                  return CheckboxListTile(
                    value: checked,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: Text(
                      chapter.title.isNotEmpty
                          ? chapter.title
                          : '第 ${chapter.index + 1} 章',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('${chapter.chars} 字'),
                    onChanged: (v) => setDialogState(() {
                      v == true
                          ? chosen.add(chapter.index)
                          : chosen.remove(chapter.index);
                    }),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                key: const Key('chapters_select_all'),
                onPressed: () => setDialogState(() {
                  chosen
                    ..clear()
                    ..addAll(_chapters.map((c) => c.index));
                }),
                child: const Text('全选'),
              ),
              TextButton(
                key: const Key('chapters_clear'),
                onPressed: () => setDialogState(chosen.clear),
                child: const Text('清除'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogCtx).pop(chosen),
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
    if (selected != null) {
      setState(() => _selectedChapterIndexes = selected);
    }
  }

  Future<void> _submit() async {
    final model = _selectedModel;
    if (model == null) return;
    setState(() => _submitting = true);
    try {
      await ref
          .read(echoApiProvider)
          .createAudiobook(
            bookId: widget.book.id,
            model: model,
            voice: _selectedVoice ?? '',
            speed: _speed,
            instruct: _instructController.text.trim(),
            chapters: _selectedChapterIndexes.toList()..sort(),
          );
      await ref.read(jobsControllerProvider.notifier).refresh();
      ref.read(libraryControllerProvider.notifier).refresh();
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('已提交转换任务，可在「任务」页查看进度')));
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final models = _modelsResponse?.models ?? const <TtsModelInfo>[];
    final chapterLabel = _selectedChapterIndexes.isEmpty
        ? '全部章节${_chapters.isEmpty ? '' : '（${_chapters.length} 章）'}'
        : '已选 ${_selectedChapterIndexes.length} 章';

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Scaffold(
        backgroundColor: tokens.surfaceBase,
        body: ListView(
          controller: scrollController,
          key: const Key('convert_sheet'),
          padding: const EdgeInsets.all(EchoMetrics.space3),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: EchoMetrics.space2),
                decoration: BoxDecoration(
                  color: tokens.surfaceSubtle,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Text(
              '转有声书',
              key: const Key('convert_sheet_title'),
              style: textTheme.titleLarge?.copyWith(color: tokens.textPrimary),
            ),
            const SizedBox(height: EchoMetrics.spaceHalf),
            Text(
              widget.book.title,
              style: textTheme.bodyMedium?.copyWith(
                color: tokens.textSecondary,
              ),
            ),
            const SizedBox(height: EchoMetrics.space2),

            if (_loading)
              const Padding(
                padding: EdgeInsets.all(EchoMetrics.space4),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null) ...[
              if (_modelsResponse == null) ...[
                // TTS 不可用：预检失败，禁用提交并提示（功能矩阵失败模式约定）。
                Text(
                  _error!,
                  key: const Key('convert_tts_unavailable'),
                  style: textTheme.bodyMedium?.copyWith(color: tokens.error),
                ),
                const SizedBox(height: EchoMetrics.space2),
                FilledButton(onPressed: _load, child: const Text('重试')),
              ] else ...[
                Text(
                  _error!,
                  style: textTheme.bodySmall?.copyWith(color: tokens.error),
                ),
                const SizedBox(height: EchoMetrics.space2),
              ],
            ] else ...[
              DropdownButtonFormField<String>(
                key: const Key('convert_model_dropdown'),
                initialValue: _selectedModel,
                decoration: const InputDecoration(
                  labelText: 'TTS 模型',
                  prefixIcon: Icon(Icons.record_voice_over),
                ),
                items: [
                  for (final m in models)
                    DropdownMenuItem(
                      value: m.id,
                      child: Text('${m.id}（${m.provider}）'),
                    ),
                ],
                onChanged: _onModelChanged,
              ),
              const SizedBox(height: EchoMetrics.space2),
              DropdownButtonFormField<String>(
                key: const Key('convert_voice_dropdown'),
                initialValue: _selectedVoice,
                decoration: const InputDecoration(
                  labelText: '音色',
                  prefixIcon: Icon(Icons.speaker),
                ),
                items: [
                  for (final v in _voices)
                    DropdownMenuItem(
                      value: v.id,
                      child: Text(
                        v.name.isNotEmpty ? '${v.name} · ${v.id}' : v.id,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _selectedVoice = v),
              ),
              const SizedBox(height: EchoMetrics.space2),

              // 音色试听
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('convert_sample_button'),
                  onPressed: _toggleSample,
                  icon: Icon(_samplePlaying ? Icons.stop : Icons.play_arrow),
                  label: Text(_samplePlaying ? '停止试听' : '试听当前音色'),
                ),
              ),

              // 语速（服务端约束 0.6 ~ 1.6）
              Row(
                children: [
                  Text('语速', style: textTheme.bodyMedium),
                  Expanded(
                    child: Slider(
                      key: const Key('convert_speed_slider'),
                      value: _speed,
                      min: 0.6,
                      max: 1.6,
                      divisions: 10,
                      label: '${_speed.toStringAsFixed(1)}x',
                      onChanged: (v) => setState(() => _speed = v),
                    ),
                  ),
                  Text('${_speed.toStringAsFixed(1)}x'),
                ],
              ),

              // 章节范围
              ListTile(
                key: const Key('convert_chapters_entry'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.format_list_numbered),
                title: Text(chapterLabel),
                subtitle: _chapters.isEmpty ? const Text('整本转换') : null,
                trailing: _chapters.isEmpty
                    ? null
                    : const Icon(Icons.chevron_right),
                onTap: _chapters.isEmpty ? null : _pickChapters,
              ),

              if (_selectedModel != null && _selectedModel!.contains('qwen'))
                Padding(
                  padding: const EdgeInsets.only(bottom: EchoMetrics.space2),
                  child: TextFormField(
                    key: const Key('convert_instruct_field'),
                    controller: _instructController,
                    decoration: const InputDecoration(
                      labelText: '朗读语气提示（可选，Qwen 系列支持）',
                      hintText: '例如：平静沉稳的讲述',
                    ),
                  ),
                ),

              EchoPrimaryButton(
                key: const Key('convert_submit'),
                label: '提交转换任务',
                busy: _submitting,
                onPressed: _submitting ? null : _submit,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
