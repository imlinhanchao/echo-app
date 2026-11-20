import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../library/library_controller.dart';

/// 阅读器（Phase 2 收尾 · v1）：
/// - 服务端章节正文（`/api/library/{id}/chapters?full=1`）；
/// - 暖纸深底 + 衬线正文（阅读器专用 Token：paperWarm/paperText）；
/// - Aa 字号三档（0.9x / 1.0x / 1.15x）；
/// - 该书已有有声书时顶栏出现"边听边看"入口，点播后返回主壳跟随迷你播放条。
class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({super.key, required this.book});

  final LibraryBook book;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  List<ChapterPreview> _chapters = const <ChapterPreview>[];
  int _index = 0;
  double _fontScale = 1.0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final chapters = await ref
          .read(echoApiProvider)
          .bookChapters(widget.book.id, full: true);
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _cycleFontScale() {
    setState(() {
      _fontScale = switch (_fontScale) {
        1.0 => 1.15,
        1.15 => 0.9,
        _ => 1.0,
      };
    });
  }

  Future<void> _startListening(AudiobookInfo audio) async {
    await ref.read(chunkedPlayerProvider.notifier).loadAudiobook(audio);
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    final readyAudios = ref
        .watch(libraryControllerProvider)
        .audiobooks
        .where((a) => a.bookId == widget.book.id && a.isReady)
        .toList();
    final readyAudio =
        readyAudios.isEmpty ? null : readyAudios.first;

    final chapter = _chapters.isEmpty ? null : _chapters[_index];
    final chapterLabel = chapter == null
        ? ''
        : (chapter.title.isNotEmpty
            ? chapter.title
            : '第 ${_index + 1} 章');

    return Scaffold(
      key: const Key('reader_page'),
      backgroundColor: tokens.paperWarm,
      appBar: AppBar(
        backgroundColor: tokens.paperWarm,
        foregroundColor: tokens.paperText,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.book.title,
              key: const Key('reader_book_title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleMedium
                  ?.copyWith(color: tokens.paperText),
            ),
            Text(
              chapterLabel,
              key: const Key('reader_chapter_label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall
                  ?.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('reader_font_button'),
            tooltip: '字号（当前 ${_fontScale}x）',
            onPressed: _cycleFontScale,
            icon: Text(
              'Aa',
              style: textTheme.labelLarge
                  ?.copyWith(color: tokens.paperText),
            ),
          ),
          if (readyAudio != null)
            IconButton(
              key: const Key('reader_play_button'),
              tooltip: '边听边看',
              icon: Icon(Icons.headphones, color: tokens.paperText),
              onPressed: () => _startListening(readyAudio),
            ),
        ],
      ),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(color: tokens.primary))
          : _error != null
              ? Center(
                  key: const Key('reader_error'),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(EchoMetrics.space3),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium
                              ?.copyWith(color: tokens.error),
                        ),
                      ),
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _chapters.isEmpty
                  ? Center(
                      key: const Key('reader_empty'),
                      child: Text(
                        '本书暂无可读章节（仅 EPUB 支持阅读）',
                        style: textTheme.bodyLarge
                            ?.copyWith(color: tokens.textSecondary),
                      ),
                    )
                  : SingleChildScrollView(
                      key: const Key('reader_body'),
                      padding: const EdgeInsets.all(EchoMetrics.space3),
                      child: Text(
                        (chapter?.text ?? '').isEmpty ? '（本章暂无内容）' : chapter!.text,
                        key: const Key('reader_chapter_text'),
                        style: TextStyle(
                          fontFamily: 'serif',
                          fontSize: 17 * _fontScale,
                          height: 1.9,
                          color: tokens.paperText,
                        ),
                      ),
                    ),
      bottomNavigationBar: _chapters.isEmpty || _loading
          ? null
          : BottomAppBar(
              color: tokens.paperWarm,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    key: const Key('reader_prev_chapter'),
                    tooltip: '上一章',
                    onPressed:
                        _index > 0 ? () => setState(() => _index -= 1) : null,
                    icon: Icon(Icons.chevron_left, color: tokens.paperText),
                  ),
                  Text(
                    '第 ${_index + 1}/${_chapters.length} 章',
                    key: const Key('reader_chapter_position'),
                    style: textTheme.labelMedium
                        ?.copyWith(color: tokens.textSecondary),
                  ),
                  IconButton(
                    key: const Key('reader_next_chapter'),
                    tooltip: '下一章',
                    onPressed: _index + 1 < _chapters.length
                        ? () => setState(() => _index += 1)
                        : null,
                    icon: Icon(Icons.chevron_right, color: tokens.paperText),
                  ),
                ],
              ),
            ),
    );
  }
}
