import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../core/export/book_exporter.dart';
import '../../core/offline/offline_store.dart';
import '../../design/book_cover.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../library/convert_sheet.dart';
import '../library/library_controller.dart';
import '../player/player_sheet.dart' show formatDurationMs, openPlayer;
import '../reader/reader_page.dart';

/// 书籍 / 有声书详情页（高保真对齐 ui-mobile-book-detail.png）：
/// 深靛蓝氛围顶区 + 居中大封面 → 大圆角深色内容板（书名/作者/简介/有声书/章节）→ 固定渐变底栏。
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
    await ref
        .read(chunkedPlayerProvider.notifier)
        .loadAudiobook(audio, coverUrl: widget.book.coverUrl);
    if (!mounted) return;
    await openPlayer(context);
  }

  Future<void> _exportEpub() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(const SnackBar(content: Text('正在导出…')));
    try {
      final path = await BookExporter.export(
        ref.read(echoApiProvider),
        widget.book,
      );
      if (!mounted) return;
      if (path == null) {
        messenger?.showSnackBar(const SnackBar(content: Text('导出失败：文件为空')));
        return;
      }
      messenger?.showSnackBar(SnackBar(content: Text('已导出到：$path')));
      await BookExporter.share(path, title: widget.book.title);
    } on ApiException catch (e) {
      if (!mounted) return;
      messenger?.showSnackBar(SnackBar(content: Text('导出失败：${e.message}')));
    }
  }

  Future<void> _openReader({int? chapterIndex}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderPageView(
          book: widget.book,
          initialChapterIndex: chapterIndex,
        ),
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
    final audiobooks = lib.audiobooks
        .where((a) => a.bookId == book.id)
        .toList();
    final readyAudio = audiobooks.where((a) => a.isReady).toList();
    final isEpub = book.format.toLowerCase() == 'epub';
    final authorText = book.authors.isNotEmpty
        ? book.authors.join(', ')
        : '未知作者';

    return Scaffold(
      key: const Key('book_detail_page'),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            key: const Key('detail_menu'),
            onSelected: (value) async {
              if (value == 'export') await _exportEpub();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'export',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.file_download_outlined),
                  title: Text('导出 EPUB'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: EchoAmbientBackground(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // 顶部居中大封面氛围区（对齐 ui-mobile-book-detail.png）
            SizedBox(height: MediaQuery.paddingOf(context).top + 48),
            Center(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(EchoMetrics.radiusSheet),
                  boxShadow: [
                    BoxShadow(
                      color: tokens.primary.withValues(alpha: 0.28),
                      blurRadius: 32,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: BookCover(url: book.coverUrl, width: 164, height: 212),
              ),
            ),
            const SizedBox(height: EchoMetrics.space3),

            // 下方大圆角深色内容面板
            Container(
              padding: const EdgeInsets.fromLTRB(
                EchoMetrics.space3,
                EchoMetrics.space3,
                EchoMetrics.space3,
                EchoMetrics.space4,
              ),
              decoration: BoxDecoration(
                color: tokens.surfaceElevated.withValues(alpha: 0.92),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    key: const Key('detail_title'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.headlineSmall?.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.spaceHalf),
                  Text(
                    authorText,
                    style: textTheme.bodyMedium?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space1),
                  Wrap(
                    spacing: EchoMetrics.spaceHalf,
                    runSpacing: EchoMetrics.spaceHalf,
                    children: [
                      if (book.format.isNotEmpty)
                        _pill(book.format.toUpperCase()),
                      if (book.year.isNotEmpty) _pill(book.year),
                      if (book.language.isNotEmpty) _pill(book.language),
                      if (readyAudio.isNotEmpty)
                        _pill(
                          '总时长 ${formatDurationMs((readyAudio.first.durationS * 1000).round())}',
                        )
                      else if (audiobooks.isNotEmpty)
                        _pill('转换中'),
                    ],
                  ),

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

          // 章节预览（点击直达对应章节）
          const SizedBox(height: EchoMetrics.space4),
          Row(
            children: [
              Text(
                '章节',
                style: textTheme.titleSmall?.copyWith(
                  color: tokens.textPrimary,
                ),
              ),
              const Spacer(),
              if (_chapters.isNotEmpty)
                TextButton(
                  key: const Key('detail_all_chapters'),
                  onPressed: () => _openReader(),
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
                style: textTheme.bodySmall?.copyWith(
                  color: tokens.textSecondary,
                ),
              ),
            )
          else
            for (final chapter in _chapters.take(6))
              ListTile(
                key: Key('detail_chapter_${chapter.index}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  chapter.title.isNotEmpty
                      ? chapter.title
                      : '第 ${chapter.index + 1} 章',
                  style: textTheme.bodyMedium?.copyWith(
                    color: tokens.textPrimary,
                  ),
                ),
                subtitle: Text(
                  '${chapter.chars} 字',
                  style: textTheme.bodySmall?.copyWith(
                    color: tokens.textSecondary,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: tokens.textDisabled,
                ),
                onTap: () => _openReader(chapterIndex: chapter.index),
              ),
          if (_chapters.length > 6)
            Padding(
              padding: const EdgeInsets.only(top: EchoMetrics.space1),
              child: Text(
                '共 ${_chapters.length} 章，进入阅读器可查看完整目录',
                style: textTheme.bodySmall?.copyWith(
                  color: tokens.textDisabled,
                ),
              ),
            ),
                ],
              ),
            ),
          ],
        ),
      ),
      // 底部固定操作栏（对齐设计 §4.1：靛蓝渐变主按钮 + 次级圆角操作）
      bottomNavigationBar: (readyAudio.isNotEmpty || isEpub)
          ? SafeArea(
              top: false,
              child: Container(
                key: const Key('detail_bottom_bar'),
                padding: const EdgeInsets.fromLTRB(
                  EchoMetrics.space3,
                  EchoMetrics.space1,
                  EchoMetrics.space3,
                  EchoMetrics.space2,
                ),
                decoration: BoxDecoration(
                  color: tokens.surfaceElevated,
                  border: Border(top: BorderSide(color: tokens.surfaceSubtle)),
                ),
                child: Row(
                  children: [
                    if (readyAudio.isNotEmpty)
                      Expanded(
                        child: _GradientPrimaryButton(
                          key: const Key('detail_play'),
                          icon: Icons.play_arrow,
                          label: '继续收听',
                          onPressed: () =>
                              _play(widget.audiobook ?? readyAudio.first),
                        ),
                      )
                    else if (isEpub)
                      Expanded(
                        child: _GradientPrimaryButton(
                          key: const Key('detail_read'),
                          icon: Icons.menu_book,
                          label: '开始阅读',
                          onPressed: () => _openReader(),
                        ),
                      ),
                    if (readyAudio.isNotEmpty && isEpub) ...[
                      const SizedBox(width: EchoMetrics.space1),
                      IconButton.outlined(
                        key: const Key('detail_read'),
                        tooltip: '阅读原文',
                        onPressed: () => _openReader(),
                        icon: const Icon(Icons.menu_book_outlined),
                      ),
                    ],
                    if (isEpub) ...[
                      const SizedBox(width: EchoMetrics.space1),
                      FilledButton.tonalIcon(
                        key: const Key('detail_convert'),
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          useSafeArea: true,
                          builder: (_) => ConvertSheet(book: book),
                        ),
                        icon: const Icon(Icons.graphic_eq, size: 18),
                        label: Text(readyAudio.isEmpty ? '转有声书' : '再转一版'),
                      ),
                    ],
                  ],
                ),
              ),
            )
          : null,
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
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: tokens.textSecondary),
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
    final style = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: tokens.textPrimary, height: 1.7);
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
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: tokens.primary),
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
              style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
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
                style: textTheme.labelSmall?.copyWith(color: tokens.success),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: Key('detail_download_${audio.id}'),
              tooltip: state.status == OfflineStatus.done
                  ? '已下载（点击删除）'
                  : (state.status == OfflineStatus.downloading
                        ? '取消下载'
                        : '下载离线'),
              onPressed: () async {
                final controller = ref.read(offlineStoreProvider.notifier);
                if (state.status == OfflineStatus.downloading) {
                  controller.cancelDownload(audio.id);
                } else if (state.status == OfflineStatus.done) {
                  await controller.remove(audio);
                } else {
                  await controller.download(audio);
                }
              },
              icon: Icon(
                state.status == OfflineStatus.done
                    ? Icons.download_done
                    : (state.status == OfflineStatus.downloading
                          ? Icons.close
                          : Icons.download_outlined),
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

/// 靛蓝渐变主按钮（对齐设计图 ui-mobile-book-detail 底部固定 CTA）。
class _GradientPrimaryButton extends StatelessWidget {
  const _GradientPrimaryButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final radius = BorderRadius.circular(EchoMetrics.radiusCard);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[tokens.primary, tokens.primaryHover],
        ),
        borderRadius: radius,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: SizedBox(
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: tokens.textOnPrimary, size: 20),
                const SizedBox(width: EchoMetrics.space1),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: tokens.textOnPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
