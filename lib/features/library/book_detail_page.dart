import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../core/offline/offline_store.dart';
import '../../design/book_cover.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../library/convert_sheet.dart';
import '../library/library_controller.dart';
import '../player/player_sheet.dart' show formatDurationMs, openPlayer;
import '../reader/reader_page.dart';

/// 书籍 / 有声书详情页（设计图 ui-mobile-book-detail）：
/// 大封面 + 元信息 + 主操作（继续收听 / 开始阅读 / 转有声书）
/// + 简介 + 有声书列表（含离线下载）+ 章节预览（可跳转阅读器）。
class BookDetailPage extends ConsumerStatefulWidget {
  const BookDetailPage({super.key, required this.book, this.audiobook});

  final LibraryBook book;

  /// 从有声书列表进入时带上对应的有声书。
  final AudiobookInfo? audiobook;

  @override
  ConsumerState<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends ConsumerState<BookDetailPage> {
  List<ChapterPreview> _chapters = const <ChapterPreview>[];
  bool _loadingChapters = true;

  @override
  void initState() {
    super.initState();
    _loadChapters();
    // 载入后刷新各有声书的离线状态（显示"已下载"角标）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final audios = ref
          .read(libraryControllerProvider)
          .audiobooks
          .where((a) => a.bookId == widget.book.id && a.isReady);
      for (final audio in audios) {
        await ref.read(offlineStoreProvider.notifier).refreshStatus(audio);
      }
    });
  }

  Future<void> _loadChapters() async {
    try {
      final chapters = await ref
          .read(echoApiProvider)
          .bookChapters(widget.book.id);
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        _loadingChapters = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() => _loadingChapters = false);
    }
  }

  Future<void> _play(AudiobookInfo audio) async {
    await ref.read(chunkedPlayerProvider.notifier).loadAudiobook(
          audio,
          coverUrl: widget.book.coverUrl,
        );
    if (!mounted) return;
    await openPlayer(context);
  }

  Future<void> _openReader() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderPageView(book: widget.book),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final lib = ref.watch(libraryControllerProvider);
    final book = lib.books.firstWhere(
      (b) => b.id == widget.book.id,
      orElse: () => widget.book,
    );
    final audiobooks =
        lib.audiobooks.where((a) => a.bookId == book.id).toList();
    final readyAudio = audiobooks.where((a) => a.isReady).toList();
    final isEpub = book.format.toLowerCase() == 'epub';
    final authorText =
        book.authors.isNotEmpty ? book.authors.join(', ') : '未知作者';

    return Scaffold(
      key: const Key('book_detail_page'),
      appBar: AppBar(title: const Text('书籍详情')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          EchoMetrics.space3,
          EchoMetrics.space2,
          EchoMetrics.space3,
          EchoMetrics.space4,
        ),
        children: [
          // 头部：封面 + 标题/作者/元信息
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BookCover(url: book.coverUrl, width: 110, height: 150),
              const SizedBox(width: EchoMetrics.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      key: const Key('detail_title'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleLarge?.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: EchoMetrics.spaceHalf),
                    Text(
                      authorText,
                      style: textTheme.bodyMedium
                          ?.copyWith(color: tokens.textSecondary),
                    ),
                    const SizedBox(height: EchoMetrics.space1),
                    Wrap(
                      spacing: EchoMetrics.spaceHalf,
                      runSpacing: EchoMetrics.spaceHalf,
                      children: [
                        if (book.format.isNotEmpty) _pill(book.format.toUpperCase()),
                        if (book.year.isNotEmpty) _pill(book.year),
                        if (book.language.isNotEmpty) _pill(book.language),
                        if (readyAudio.isNotEmpty)
                          _pill('有声书 ${readyAudio.length}')
                        else if (audiobooks.isNotEmpty)
                          _pill('转换中'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: EchoMetrics.space3),

          // 主操作
          Row(
            children: [
              if (readyAudio.isNotEmpty)
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('detail_play'),
                    onPressed: () => _play(widget.audiobook ?? readyAudio.first),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('继续收听'),
                  ),
                )
              else if (isEpub)
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('detail_read'),
                    onPressed: _openReader,
                    icon: const Icon(Icons.menu_book),
                    label: const Text('开始阅读'),
                  ),
                ),
              if (isEpub) ...[
                const SizedBox(width: EchoMetrics.space2),
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const Key('detail_convert'),
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      builder: (_) => ConvertSheet(book: book),
                    ),
                    icon: const Icon(Icons.graphic_eq),
                    label: Text(readyAudio.isEmpty ? '转有声书' : '再转一版'),
                  ),
                ),
              ],
            ],
          ),
          if (readyAudio.isNotEmpty && isEpub) ...[
            const SizedBox(height: EchoMetrics.space1),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('detail_read'),
                onPressed: _openReader,
                icon: const Icon(Icons.menu_book),
                label: const Text('阅读原文'),
              ),
            ),
          ],

          // 简介
          if (book.description.isNotEmpty) ...[
            const SizedBox(height: EchoMetrics.space4),
            Text(
              '简介',
              style: textTheme.titleSmall?.copyWith(color: tokens.textPrimary),
            ),
            const SizedBox(height: EchoMetrics.space1),
            _ExpandableText(text: book.description),
          ],

          // 有声书
          if (audiobooks.isNotEmpty) ...[
            const SizedBox(height: EchoMetrics.space4),
            Text(
              '有声书',
              style: textTheme.titleSmall?.copyWith(color: tokens.textPrimary),
            ),
            const SizedBox(height: EchoMetrics.space1),
            for (final audio in audiobooks)
              _AudiobookTile(
                audio: audio,
                book: book,
                onPlay: () => _play(audio),
              ),
          ],

          // 章节预览
          const SizedBox(height: EchoMetrics.space4),
          Row(
            children: [
              Text(
                '章节',
                style:
                    textTheme.titleSmall?.copyWith(color: tokens.textPrimary),
              ),
              const Spacer(),
              if (_chapters.isNotEmpty)
                TextButton(
                  key: const Key('detail_all_chapters'),
                  onPressed: _openReader,
                  child: const Text('开始阅读'),
                ),
            ],
          ),
          if (_loadingChapters)
            const Padding(
              padding: EdgeInsets.all(EchoMetrics.space2),
              child: LinearProgressIndicator(minHeight: 2),
            )
          else if (_chapters.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: EchoMetrics.space2),
              child: Text(
                '暂无章节信息（仅 EPUB 支持章节解析）',
                style:
                    textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
              ),
            )
          else
            for (final chapter in _chapters.take(6))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  chapter.title.isNotEmpty
                      ? chapter.title
                      : '第 ${chapter.index + 1} 章',
                  style: textTheme.bodyMedium
                      ?.copyWith(color: tokens.textPrimary),
                ),
                subtitle: Text(
                  '${chapter.chars} 字',
                  style: textTheme.bodySmall
                      ?.copyWith(color: tokens.textSecondary),
                ),
                onTap: _openReader,
              ),
          if (_chapters.length > 6)
            Padding(
              padding: const EdgeInsets.only(top: EchoMetrics.space1),
              child: Text(
                '共 ${_chapters.length} 章，进入阅读器可查看完整目录',
                style:
                    textTheme.bodySmall?.copyWith(color: tokens.textDisabled),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pill(String label) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: tokens.surfaceSubtle,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}

/// 可展开的长简介。
class _ExpandableText extends StatefulWidget {
  const _ExpandableText({required this.text});

  final String text;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: tokens.textPrimary,
          height: 1.7,
        );
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.text,
            key: const Key('detail_description'),
            maxLines: _expanded ? null : 4,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: style,
          ),
          const SizedBox(height: 4),
          Text(
            _expanded ? '收起' : '展开',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: tokens.primary),
          ),
        ],
      ),
    );
  }
}

/// 有声书条目：播放 / 离线下载 / 进度。
class _AudiobookTile extends ConsumerWidget {
  const _AudiobookTile({
    required this.audio,
    required this.book,
    required this.onPlay,
  });

  final AudiobookInfo audio;
  final LibraryBook book;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    ref.watch(offlineStoreProvider);
    final state = ref.read(offlineStoreProvider.notifier).stateOf(audio.id);
    final label = audio.isReady
        ? '${audio.model} · ${audio.voice} · ${formatDurationMs((audio.durationS * 1000).round())}'
        : '状态：${audio.status} (${audio.progress}%)';

    return Card(
      key: Key('detail_audio_${audio.id}'),
      child: ListTile(
        leading: Icon(
          audio.isReady ? Icons.headphones : Icons.hourglass_top,
          color: audio.isReady ? tokens.primary : tokens.textSecondary,
        ),
        title: Text(
          audio.isReady ? '有声书 #${audio.id}' : '转码中 #${audio.id}',
          style: textTheme.bodyMedium?.copyWith(color: tokens.textPrimary),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style:
                  textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
            ),
            if (state.status == OfflineStatus.downloading)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: LinearProgressIndicator(
                  value: state.progress,
                  minHeight: 2,
                ),
              ),
            if (state.status == OfflineStatus.done)
              Text(
                '已下载 · 离线可听',
                style: textTheme.labelSmall
                    ?.copyWith(color: tokens.success),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (audio.isReady)
              IconButton(
                key: Key('detail_download_${audio.id}'),
                tooltip: state.status == OfflineStatus.done ? '已下载' : '下载离线',
                onPressed: state.status == OfflineStatus.downloading
                    ? null
                    : () async {
                        final controller =
                            ref.read(offlineStoreProvider.notifier);
                        if (state.status == OfflineStatus.done) {
                          await controller.remove(audio);
                        } else {
                          await controller.download(audio);
                        }
                      },
                icon: Icon(
                  state.status == OfflineStatus.done
                      ? Icons.download_done
                      : Icons.download_outlined,
                  color: state.status == OfflineStatus.done
                      ? tokens.success
                      : tokens.textSecondary,
                ),
              ),
            if (audio.isReady)
              IconButton(
                key: Key('detail_audio_play_${audio.id}'),
                tooltip: '播放',
                onPressed: onPlay,
                icon: Icon(Icons.play_arrow, color: tokens.primary),
              ),
          ],
        ),
      ),
    );
  }
}
