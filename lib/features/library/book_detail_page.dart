import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../core/audio/live_tts_player_controller.dart';
import '../../core/export/book_exporter.dart';
import '../../core/offline/offline_store.dart';
import '../../design/book_cover.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../library/convert_sheet.dart';
import '../library/library_controller.dart';
import '../player/player_sheet.dart' show formatDurationMs, openPlayer;
import '../reader/reader_page.dart';
import '../tts/tts_model_manager_page.dart';

/// 书籍详情页（极简书房 Editorial Minimalism）：
/// 真实 2:3 书封主视觉（柔和平影无紫晕） → 暖墨/象牙版心排印 → 实时朗读胶囊 → 有声版本与章节预览 → 固定底栏。
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

  Future<void> _liveListen(LibraryBook book) async {
    final liveCtrl = ref.read(liveTtsPlayerProvider.notifier);
    final liveState = ref.read(liveTtsPlayerProvider);
    if (liveState.hasBook && liveState.book?.id == book.id) {
      await liveCtrl.togglePlayPause();
      return;
    }
    final chunkedState = ref.read(chunkedPlayerProvider);
    if (chunkedState.hasBook && chunkedState.isPlaying) {
      await ref.read(chunkedPlayerProvider.notifier).togglePlayPause();
    }
    await liveCtrl.playBookChapter(book);
    if (!mounted) return;
    final err = ref.read(liveTtsPlayerProvider).error;
    if (err != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(err),
          action: SnackBarAction(
            label: '去下载模型',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const TtsModelManagerPage(),
                ),
              );
            },
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hairline = echoHairlineColor(context, darkAlpha: 0.08);
    final lib = ref.watch(libraryControllerProvider);
    final book = lib.books.firstWhere(
      (b) => b.id == widget.book.id,
      orElse: () => widget.book,
    );
    final audiobooks = lib.audiobooks
        .where((a) => a.bookId == book.id)
        .toList();
    final readyAudio = audiobooks.where((a) => a.isPlayable).toList();
    final fmt = book.format.toLowerCase();
    final canReadOrConvert = fmt == 'epub' || fmt == 'txt';
    final liveState = ref.watch(liveTtsPlayerProvider);
    final isLivePlaying =
        liveState.hasBook && liveState.book?.id == book.id && liveState.isPlaying;
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
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'export',
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.file_download_outlined),
                  title: Text(
                    book.format.isNotEmpty
                        ? '导出 ${book.format.toUpperCase()}'
                        : '导出书籍',
                  ),
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
            SizedBox(height: MediaQuery.paddingOf(context).top + 52),
            Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.44 : 0.16,
                      ),
                      blurRadius: 24,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: BookCover(
                  url: book.coverUrl,
                  title: book.title,
                  author: authorText,
                  width: 144,
                  height: 204,
                  borderRadius: 12,
                ),
              ),
            ),
            const SizedBox(height: EchoMetrics.space3),

            // 居中书名与元信息
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: EchoMetrics.space3,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    book.title,
                    key: const Key('detail_title'),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.headlineSmall?.copyWith(
                      fontSize: 22,
                      color: tokens.textPrimary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    authorText,
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (book.format.isNotEmpty)
                        _pill(book.format.toUpperCase()),
                      if (book.year.isNotEmpty) _pill(book.year),
                      if (book.language.isNotEmpty) _pill(book.language),
                      if (readyAudio.isNotEmpty)
                        _pill(
                          '总时长 ${formatDurationMs((readyAudio.first.durationS * 1000).round())}',
                          highlight: true,
                        )
                      else if (audiobooks.isNotEmpty)
                        _pill('转换中', highlight: true),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: EchoMetrics.space3),

            // 正文内容面板
            Padding(
              padding: const EdgeInsets.fromLTRB(
                EchoMetrics.pagePadding,
                0,
                EchoMetrics.pagePadding,
                EchoMetrics.space4,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 端侧实时朗读入口条
                  if (canReadOrConvert) ...[
                    Container(
                      decoration: echoElevatedCardDecoration(
                        context,
                        radius: 14,
                        borderColor: isLivePlaying
                            ? tokens.primary.withValues(alpha: 0.45)
                            : hairline,
                      ),
                      child: InkWell(
                        key: const Key('detail_live_tts'),
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _liveListen(book),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: tokens.primary.withValues(alpha: 0.14),
                                ),
                                child: Icon(
                                  isLivePlaying
                                      ? Icons.pause_rounded
                                      : Icons.record_voice_over_outlined,
                                  size: 18,
                                  color: tokens.primary,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isLivePlaying ? '暂停实时朗读' : '端侧实时朗读',
                                      style: textTheme.titleSmall?.copyWith(
                                        color: tokens.textPrimary,
                                      ),
                                    ),
                                    Text(
                                      '免转码直接「边听边生成」，支持离线语音引擎',
                                      style: textTheme.labelSmall?.copyWith(
                                        color: tokens.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.chevron_right_rounded,
                                size: 20,
                                color: tokens.textSecondary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: EchoMetrics.space3),
                  ],

                  // 简介
                  if (book.description.isNotEmpty) ...[
                    const EchoSectionHeader(title: '简介'),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: echoElevatedCardDecoration(
                        context,
                        radius: 14,
                      ),
                      child: _ExpandableText(text: book.description),
                    ),
                    const SizedBox(height: EchoMetrics.space3),
                  ],

                  // 有声书
                  if (audiobooks.isNotEmpty) ...[
                    EchoSectionHeader(
                      title: '有声版本',
                      subtitle: '${audiobooks.length} 个',
                    ),
                    const SizedBox(height: 10),
                    for (var i = 0; i < audiobooks.length; i++) ...[
                      if (i > 0) const SizedBox(height: 8),
                      _AudiobookTile(
                        audio: audiobooks[i],
                        book: book,
                        onPlay: () => _play(audiobooks[i]),
                      ),
                    ],
                    const SizedBox(height: EchoMetrics.space3),
                  ],

                  // 章节预览
                  EchoSectionHeader(
                    title: '章节目录',
                    subtitle: _chapters.isNotEmpty
                        ? '${_chapters.length} 章'
                        : null,
                    trailing: _chapters.isNotEmpty
                        ? TextButton(
                            key: const Key('detail_all_chapters'),
                            onPressed: () => _openReader(),
                            child: const Text('开始阅读'),
                          )
                        : null,
                  ),
                  const SizedBox(height: 8),
                  if (_loadingChapters)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: EchoMetrics.space2,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          minHeight: 2,
                          color: tokens.primary,
                          backgroundColor: tokens.surfaceSubtle,
                        ),
                      ),
                    )
                  else if (_chapters.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: echoElevatedCardDecoration(
                        context,
                        radius: 14,
                      ),
                      child: Text(
                        '暂无章节信息（支持 EPUB / TXT 格式）',
                        style: textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    )
                  else
                    EchoGroupedCard(
                      dividerIndent: 16,
                      children: [
                        for (final chapter in _chapters.take(6))
                          ListTile(
                            key: Key('detail_chapter_${chapter.index}'),
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 2,
                            ),
                            title: Text(
                              chapter.title.isNotEmpty
                                  ? chapter.title
                                  : '第 ${chapter.index + 1} 章',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodyMedium?.copyWith(
                                fontSize: 14.5,
                                color: tokens.textPrimary,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${chapter.chars} 字',
                                  style: textTheme.labelSmall?.copyWith(
                                    color: tokens.textSecondary,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                  color: tokens.textDisabled,
                                ),
                              ],
                            ),
                            onTap: () =>
                                _openReader(chapterIndex: chapter.index),
                          ),
                      ],
                    ),
                  if (_chapters.length > 6)
                    Padding(
                      padding: const EdgeInsets.only(top: 10, left: 4),
                      child: Text(
                        '共 ${_chapters.length} 章，进入阅读器可查看完整目录',
                        style: textTheme.labelSmall?.copyWith(
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
      bottomNavigationBar: (readyAudio.isNotEmpty || canReadOrConvert)
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surfaceElevated,
                border: Border(top: BorderSide(color: hairline, width: 0.6)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  key: const Key('detail_bottom_bar'),
                  padding: const EdgeInsets.fromLTRB(
                    EchoMetrics.pagePadding,
                    10,
                    EchoMetrics.pagePadding,
                    12,
                  ),
                  child: Row(
                    children: [
                      if (readyAudio.isNotEmpty && canReadOrConvert) ...[
                        EchoSquareIconButton(
                          key: const Key('detail_read'),
                          tooltip: '阅读原文',
                          onPressed: () => _openReader(),
                          icon: Icons.menu_book_outlined,
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (canReadOrConvert) ...[
                        EchoSecondaryButton(
                          key: const Key('detail_convert'),
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            useSafeArea: true,
                            builder: (_) => ConvertSheet(book: book),
                          ),
                          icon: Icons.graphic_eq_rounded,
                          label: readyAudio.isEmpty ? '转有声书' : '再转一版',
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (readyAudio.isNotEmpty)
                        Expanded(
                          child: EchoPrimaryButton(
                            key: const Key('detail_play'),
                            icon: Icons.play_arrow_rounded,
                            label: readyAudio.first.isReady ? '继续收听' : '抢先收听',
                            onPressed: () =>
                                _play(widget.audiobook ?? readyAudio.first),
                          ),
                        )
                      else if (canReadOrConvert)
                        Expanded(
                          child: EchoPrimaryButton(
                            key: const Key('detail_read'),
                            icon: Icons.menu_book_rounded,
                            label: '开始阅读',
                            onPressed: () => _openReader(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            )
          : null,
    );
  }

  Widget _pill(String label, {bool highlight = false}) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return EchoPillBadge(
      label: label,
      color: highlight ? tokens.primary : tokens.textSecondary,
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
      fontSize: 14.5,
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
          const SizedBox(height: 6),
          Text(
            _expanded ? '收起' : '展开全文',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: tokens.primary,
              fontWeight: FontWeight.w600,
            ),
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
    final isFailed = audio.isFailedOrCancelled;
    final label = audio.isReady
        ? '${audio.model} · ${audio.voice} · ${formatDurationMs((audio.durationS * 1000).round())}'
        : audio.isPlayable
        ? '${audio.model} · 转换中 ${audio.progress}% · 可抢先收听'
        : isFailed
        ? '${audio.status == 'cancelled' ? '已取消' : '转换失败'} (${audio.progress}%) · 左滑删除'
        : '状态：${audio.status} (${audio.progress}%)';

    final card = Container(
      key: Key('detail_audio_${audio.id}'),
      decoration: echoElevatedCardDecoration(context, radius: 14),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Icon(
          audio.isPlayable
              ? Icons.headphones_rounded
              : (isFailed ? Icons.error_outline : Icons.hourglass_top_rounded),
          color: audio.isPlayable
              ? tokens.primary
              : (isFailed ? tokens.error : tokens.textSecondary),
        ),
        title: Text(
          audio.isReady
              ? '有声书 #${audio.id}'
              : audio.isPlayable
              ? '转码中 #${audio.id}（可抢先听）'
              : isFailed
              ? '${audio.status == 'cancelled' ? '已取消' : '转换失败'} #${audio.id}'
              : '转码中 #${audio.id}',
          style: textTheme.titleSmall?.copyWith(color: tokens.textPrimary),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: textTheme.labelSmall?.copyWith(
                color: isFailed ? tokens.error : tokens.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (state.status == OfflineStatus.downloading)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: state.progress,
                    minHeight: 2.5,
                    backgroundColor: tokens.surfaceSubtle,
                    color: tokens.primary,
                  ),
                ),
              ),
            if (state.status == OfflineStatus.done)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '已缓存 · 离线可听',
                  style: textTheme.labelSmall?.copyWith(color: tokens.success),
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (audio.isReady && state.status != OfflineStatus.done)
              IconButton(
                key: Key('detail_download_${audio.id}'),
                tooltip: state.status == OfflineStatus.downloading
                    ? '取消下载'
                    : '下载离线',
                onPressed: () async {
                  final controller = ref.read(offlineStoreProvider.notifier);
                  if (state.status == OfflineStatus.downloading) {
                    controller.cancelDownload(audio.id);
                  } else {
                    await controller.download(audio);
                  }
                },
                icon: Icon(
                  state.status == OfflineStatus.downloading
                      ? Icons.close_rounded
                      : Icons.download_outlined,
                  color: tokens.textSecondary,
                ),
              ),
            if (audio.isPlayable)
              IconButton(
                key: Key('detail_audio_play_${audio.id}'),
                tooltip: audio.isReady ? '播放' : '抢先收听',
                style: IconButton.styleFrom(
                  backgroundColor: tokens.primary.withValues(alpha: 0.14),
                  foregroundColor: tokens.primary,
                ),
                onPressed: onPlay,
                icon: const Icon(Icons.play_arrow_rounded),
              ),
          ],
        ),
      ),
    );

    if (!isFailed) return card;

    return Dismissible(
      key: ValueKey<String>('dismiss_audio_${audio.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: EchoMetrics.space3),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: tokens.error.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, color: Colors.white, size: 20),
            SizedBox(width: 6),
            Text(
              '删除',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      confirmDismiss: (_) async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        final err = await ref
            .read(libraryControllerProvider.notifier)
            .deleteAudiobook(audio.id);
        if (err != null) {
          messenger?.showSnackBar(SnackBar(content: Text(err)));
          return false;
        }
        messenger?.showSnackBar(
          SnackBar(content: Text('已删除转换记录 #${audio.id}')),
        );
        return true;
      },
      child: card,
    );
  }
}
