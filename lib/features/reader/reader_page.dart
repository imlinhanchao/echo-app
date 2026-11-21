import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../core/reader/reading_store.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../library/library_controller.dart';
import '../player/player_sheet.dart' show openPlayer;

/// 阅读位置存储 Provider（生产：持久化）。
final Provider<ReadingStore> readingStoreProvider =
    Provider<ReadingStore>((ref) => PersistentReadingStore());

/// 阅读器（对齐常规电子书）：
/// - 按可视尺寸精确分页，左右滑动翻页；
/// - 记住上次阅读位置（章号 + 字符偏移，字号变化后仍精准）；
/// - 顶部「从当前位置开始听书」。
class ReaderPageView extends ConsumerStatefulWidget {
  const ReaderPageView({super.key, required this.book});

  final LibraryBook book;

  @override
  ConsumerState<ReaderPageView> createState() => _ReaderPageViewState();
}

class _ReaderPageViewState extends ConsumerState<ReaderPageView> {
  final PageController _pageController = PageController();
  List<ChapterPreview> _chapters = const <ChapterPreview>[];
  List<ReaderPage> _pages = const <ReaderPage>[];
  int _currentPage = 0;
  double _fontScale = 1.0;
  bool _loading = true;
  String? _error;
  bool _listening = false;

  /// 上次已知的阅读位置（章号 + 字符偏移），用于重排后复原。
  int _chapterIndex = 0;
  int _charOffset = 0;

  /// 上一次分页使用的版心尺寸，尺寸变化时需要重排。
  Size? _layoutSize;

  @override
  void initState() {
    super.initState();
    _loadChapters();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  TextStyle _textStyle(EchoTokens tokens) => TextStyle(
        fontFamily: 'serif',
        fontSize: 17 * _fontScale,
        height: 1.9,
        color: tokens.paperText,
      );

  Future<void> _loadChapters() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final chapters = await ref
          .read(echoApiProvider)
          .bookChapters(widget.book.id, full: true);
      final saved = await ref.read(readingStoreProvider).read(widget.book.id);
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        if (saved != null) {
          _chapterIndex = saved.chapterIndex;
          _charOffset = saved.charOffset;
        }
        _loading = false;
        _layoutSize = null; // 触发下一次布局时重新分页
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// 按当前版心尺寸精确分页（保证每页都放得下，不会溢出到工具栏下面）。
  Future<void> _repaginate(Size size, EchoTokens tokens) async {
    if (_chapters.isEmpty) return;
    final style = _textStyle(tokens);
    final textScaler = MediaQuery.textScalerOf(context);
    final pages = <ReaderPage>[];
    for (var i = 0; i < _chapters.length; i++) {
      final chapter = _chapters[i];
      pages.addAll(
        paginateChapterBySize(
          chapterIndex: chapter.index,
          chapterTitle:
              chapter.title.isNotEmpty ? chapter.title : '第 ${i + 1} 章',
          text: chapter.text,
          style: style,
          textScaler: textScaler,
          maxWidth: size.width,
          maxHeight: size.height,
        ),
      );
      // 大书分页耗时较长，逐章让出事件循环避免卡顿。
      if (i % 4 == 3) await Future<void>.delayed(Duration.zero);
    }
    if (!mounted) return;
    final target = pageIndexForOffset(pages, _chapterIndex, _charOffset);
    setState(() {
      _pages = pages;
      _currentPage = target;
      _layoutSize = size;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      if (_pageController.page?.round() != target) {
        _pageController.jumpToPage(target);
      }
    });
  }

  /// 章节目录：跳到该章第一页。
  void _showToc() {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    // 每章第一页的下标
    final firstPageOfChapter = <int, int>{};
    for (var i = 0; i < _pages.length; i++) {
      firstPageOfChapter.putIfAbsent(_pages[i].chapterIndex, () => i);
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (sheetCtx, controller) => ListView.builder(
          key: const Key('reader_toc_list'),
          controller: controller,
          padding: const EdgeInsets.all(EchoMetrics.space2),
          itemCount: _chapters.length,
          itemBuilder: (_, i) {
            final chapter = _chapters[i];
            final firstPage = firstPageOfChapter[chapter.index];
            final selected = _chapterIndex == chapter.index;
            return ListTile(
              key: Key('reader_toc_item_$i'),
              selected: selected,
              selectedTileColor: tokens.readingHighlight,
              leading: Icon(
                selected ? Icons.bookmark : Icons.article_outlined,
                color: selected ? tokens.primary : tokens.textSecondary,
              ),
              title: Text(
                chapter.title.isNotEmpty ? chapter.title : '第 ${i + 1} 章',
                style: TextStyle(
                  color: selected ? tokens.primary : tokens.paperText,
                ),
              ),
              subtitle: Text(
                '${chapter.chars} 字',
                style: TextStyle(color: tokens.textSecondary),
              ),
              onTap: firstPage == null
                  ? null
                  : () {
                      Navigator.of(sheetCtx).pop();
                      _pageController.jumpToPage(firstPage);
                    },
            );
          },
        ),
      ),
    );
  }

  Future<void> _onPageChanged(int index) async {
    if (index < 0 || index >= _pages.length) return;
    final page = _pages[index];
    setState(() {
      _currentPage = index;
      _chapterIndex = page.chapterIndex;
      _charOffset = page.startChar;
    });
    await ref.read(readingStoreProvider).write(
          ReadingPosition(
            bookId: widget.book.id,
            chapterIndex: page.chapterIndex,
            charOffset: page.startChar,
          ),
        );
  }

  Future<void> _cycleFontScale() async {
    setState(() {
      _fontScale = switch (_fontScale) {
        1.0 => 1.18,
        1.18 => 0.9,
        _ => 1.0,
      };
      _layoutSize = null; // 触发重排
    });
  }

  /// 从当前位置开始听书：跳到该书有声书的对应章节起播。
  Future<void> _listenFromHere() async {
    if (_listening) return;
    setState(() => _listening = true);
    try {
      await _listenFromHereInner();
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _listenFromHereInner() async {
    final audio = ref
        .read(libraryControllerProvider)
        .audiobooks
        .where((a) => a.bookId == widget.book.id && a.isReady)
        .firstOrNull;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (audio == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('这本书还没有有声书，先在书架转一本吧')),
      );
      return;
    }

    final controller = ref.read(chunkedPlayerProvider.notifier);
    final cover = ref
        .read(libraryControllerProvider)
        .books
        .where((b) => b.id == widget.book.id)
        .map((b) => b.coverUrl)
        .firstOrNull;

    await controller.loadAudiobook(audio, autoPlay: false, coverUrl: cover);
    final chunks = ref.read(chunkedPlayerProvider).chunks;
    if (chunks.isEmpty) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('该书音频尚未分章，无法定位')),
      );
      return;
    }
    final chapterIndex = _chapterIndex;
    var index = chunks.indexWhere((c) => c.chapterIndex == chapterIndex);
    if (index == -1) {
      var best = 0;
      var bestDelta = 1 << 30;
      for (var i = 0; i < chunks.length; i++) {
        final delta = (chunks[i].chapterIndex - chapterIndex).abs();
        if (delta < bestDelta) {
          bestDelta = delta;
          best = i;
        }
      }
      index = best;
    }
    await controller.selectChunkAt(index, 0);
    if (!mounted) return;
    await openPlayer(context);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final hasAudio = ref
        .watch(libraryControllerProvider)
        .audiobooks
        .any((a) => a.bookId == widget.book.id && a.isReady);
    final page = (_currentPage >= 0 && _currentPage < _pages.length)
        ? _pages[_currentPage]
        : null;

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
              style: textTheme.titleMedium?.copyWith(color: tokens.paperText),
            ),
            Text(
              page?.chapterTitle ?? '',
              key: const Key('reader_chapter_label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('reader_toc_button'),
            tooltip: '目录',
            onPressed: _loading || _chapters.isEmpty ? null : _showToc,
            icon: Icon(Icons.list, color: tokens.paperText),
          ),
          IconButton(
            key: const Key('reader_font_button'),
            tooltip: '字号',
            onPressed: _loading ? null : _cycleFontScale,
            icon: Text(
              'Aa',
              style: textTheme.labelLarge?.copyWith(color: tokens.paperText),
            ),
          ),
          IconButton(
            key: const Key('reader_play_button'),
            tooltip: '从当前位置开始听书',
            onPressed: _loading ? null : _listenFromHere,
            icon: Icon(
              Icons.headphones,
              color: hasAudio ? tokens.paperText : tokens.textDisabled,
            ),
          ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: tokens.primary))
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
                      FilledButton(onPressed: _loadChapters, child: const Text('重试')),
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
                  : _ReaderBody(
                      pages: _pages,
                      pageController: _pageController,
                      textStyle: _textStyle(tokens),
                      layoutSize: _layoutSize,
                      onNeedPagination: _repaginate,
                      onPageChanged: _onPageChanged,
                    ),
      bottomNavigationBar: _loading || _pages.isEmpty
          ? null
          : BottomAppBar(
              color: tokens.paperWarm,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '第 ${page?.pageInChapter ?? 1}/${page?.pageCountInChapter ?? 1} 页',
                    key: const Key('reader_page_indicator'),
                    style: textTheme.labelMedium
                        ?.copyWith(color: tokens.textSecondary),
                  ),
                  Text(
                    _pages.isEmpty
                        ? '0%'
                        : '${_currentPage + 1}/${_pages.length} · '
                            '${((_currentPage + 1) / _pages.length * 100).round()}%',
                    key: const Key('reader_global_indicator'),
                    style: textTheme.labelMedium
                        ?.copyWith(color: tokens.textSecondary),
                  ),
                  if (hasAudio)
                    TextButton.icon(
                      key: const Key('reader_listen_here'),
                      onPressed: _listenFromHere,
                      icon: const Icon(Icons.play_circle_outline, size: 18),
                      label: const Text('从当前位置听'),
                    )
                  else
                    const SizedBox.shrink(),
                ],
              ),
            ),
    );
  }
}

/// 版心：用 LayoutBuilder 拿到可用宽高，交给父级做精确分页。
class _ReaderBody extends StatelessWidget {
  const _ReaderBody({
    required this.pages,
    required this.pageController,
    required this.textStyle,
    required this.layoutSize,
    required this.onNeedPagination,
    required this.onPageChanged,
  });

  final List<ReaderPage> pages;
  final PageController pageController;
  final TextStyle textStyle;
  final Size? layoutSize;
  final Future<void> Function(Size size, EchoTokens tokens) onNeedPagination;
  final ValueChanged<int> onPageChanged;

  static const EdgeInsets _insets = EdgeInsets.fromLTRB(
    EchoMetrics.space3,
    EchoMetrics.space2,
    EchoMetrics.space3,
    EchoMetrics.space1,
  );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = Size(
          constraints.maxWidth - _insets.horizontal,
          constraints.maxHeight - _insets.vertical,
        );
        // 尺寸变化（首次布局/旋转/字号）触发重新分页
        if (layoutSize == null ||
            (layoutSize!.width - available.width).abs() > 0.5 ||
            (layoutSize!.height - available.height).abs() > 0.5) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            onNeedPagination(available, tokens);
          });
        }
        return PageView.builder(
          key: const Key('reader_pageview'),
          controller: pageController,
          onPageChanged: onPageChanged,
          itemCount: pages.length,
          itemBuilder: (context, index) => Padding(
            padding: _insets,
            child: Text(
              pages[index].text,
              key: Key('reader_page_text_$index'),
              style: textStyle,
            ),
          ),
        );
      },
    );
  }
}

/// 兼容旧引用名。
typedef ReaderPageWidget = ReaderPageView;
