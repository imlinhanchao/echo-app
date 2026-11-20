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

/// 阅读器（对齐常规电子书交互）：
/// - 左右滑动翻页（整本连续分页，跨章自动衔接）；
/// - 记住上次阅读位置（关闭后重开回到该页）；
/// - 顶部「从当前位置开始听书」：跳到该书有声书的对应章节起播。
class ReaderPageView extends ConsumerStatefulWidget {
  const ReaderPageView({super.key, required this.book});

  final LibraryBook book;

  @override
  ConsumerState<ReaderPageView> createState() => _ReaderPageViewState();
}

class _ReaderPageViewState extends ConsumerState<ReaderPageView> {
  final PageController _pageController = PageController();
  List<ReaderPage> _pages = const <ReaderPage>[];
  int _currentPage = 0;
  double _fontScale = 1.0;
  bool _loading = true;
  String? _error;
  bool _restored = false;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  int get _charsPerPage => (480 / _fontScale).round();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final chapters = await ref
          .read(echoApiProvider)
          .bookChapters(widget.book.id, full: true);
      final pages = buildReaderPages(chapters, charsPerPage: _charsPerPage);

      // 恢复上次阅读位置。
      int startPage = 0;
      if (!_restored) {
        final saved = await ref
            .read(readingStoreProvider)
            .read(widget.book.id);
        if (saved != null && saved.globalPage > 0) {
          startPage = saved.globalPage.clamp(0, pages.isEmpty ? 0 : pages.length - 1);
        }
        _restored = true;
      }

      if (!mounted) return;
      setState(() {
        _pages = pages;
        _currentPage = startPage;
        _loading = false;
      });
      // PageView 首帧后跳到恢复页。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients) return;
        if (startPage > 0) {
          _pageController.jumpToPage(startPage);
        }
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _onPageChanged(int index) async {
    setState(() => _currentPage = index);
    await ref.read(readingStoreProvider).write(
          ReadingPosition(bookId: widget.book.id, globalPage: index),
        );
  }

  /// 重新分页但保持阅读位置（字号变化时）。
  Future<void> _cycleFontScale() async {
    final chapterIndex = _pages.isEmpty ? 0 : _pages[_currentPage].chapterIndex;
    final pageInChapter = _pages.isEmpty ? 0 : _pages[_currentPage].pageInChapter;
    setState(() {
      _fontScale = switch (_fontScale) {
        1.0 => 1.18,
        1.18 => 0.9,
        _ => 1.0,
      };
    });
    await _load();
    // 尽量回到同一章同一页序。
    final target = _pages.indexWhere(
      (p) => p.chapterIndex == chapterIndex && p.pageInChapter == pageInChapter,
    );
    if (target > 0) {
      setState(() => _currentPage = target);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(target);
        }
      });
    }
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
    if (audio == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('这本书还没有有声书，先在书架转一本吧')),
      );
      return;
    }
    if (_pages.isEmpty) return;

    final chapterIndex = _pages[_currentPage].chapterIndex;
    final controller = ref.read(chunkedPlayerProvider.notifier);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(content: Text('正在定位到本章音频…')),
    );

    final cover = ref
        .read(libraryControllerProvider)
        .books
        .where((b) => b.id == widget.book.id)
        .map((b) => b.coverUrl)
        .firstOrNull;
    await controller.loadAudiobook(
      audio,
      autoPlay: false,
      coverUrl: cover,
    );
    final chunks = ref.read(chunkedPlayerProvider).chunks;
    if (chunks.isEmpty) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('该书音频尚未分章，无法定位')),
      );
      return;
    }
    // 找到当前章对应的分块；没有则取章节序号最接近的一块。
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
    final page = _pages.isEmpty ? null : _pages[_currentPage];
    final chapterTitle = page?.chapterTitle ?? '';

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
              chapterTitle,
              key: const Key('reader_chapter_label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('reader_font_button'),
            tooltip: '字号',
            onPressed: _loading ? null : _cycleFontScale,
            icon: Text('Aa',
                style: textTheme.labelLarge?.copyWith(color: tokens.paperText)),
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
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _pages.isEmpty
                  ? Center(
                      key: const Key('reader_empty'),
                      child: Text(
                        '本书暂无可读章节（仅 EPUB 支持阅读）',
                        style: textTheme.bodyLarge
                            ?.copyWith(color: tokens.textSecondary),
                      ),
                    )
                  : PageView.builder(
                      key: const Key('reader_pageview'),
                      controller: _pageController,
                      // 左右滑动翻页：常规电子书交互。
                      scrollDirection: Axis.horizontal,
                      pageSnapping: true,
                      onPageChanged: _onPageChanged,
                      itemCount: _pages.length,
                      itemBuilder: (context, index) {
                        final p = _pages[index];
                        return SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(
                            EchoMetrics.space3,
                            EchoMetrics.space2,
                            EchoMetrics.space3,
                            EchoMetrics.space3,
                          ),
                          child: Text(
                            p.text,
                            key: Key('reader_page_text_$index'),
                            style: TextStyle(
                              fontFamily: 'serif',
                              fontSize: 17 * _fontScale,
                              height: 1.9,
                              color: tokens.paperText,
                            ),
                          ),
                        );
                      },
                    ),
      bottomNavigationBar: _pages.isEmpty || _loading
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
                    '${_currentPage + 1} / ${_pages.length}',
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

/// 兼容旧引用名。
typedef ReaderPageWidget = ReaderPageView;
