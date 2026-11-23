import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../core/audio/live_tts_player_controller.dart';
import '../../core/reader/reading_store.dart';
import '../../core/stats/stats_store.dart';
import '../../core/sync/progress_sync_service.dart';
import '../../core/tts/tts_model_manager.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../library/library_controller.dart';
import '../player/player_sheet.dart' show openPlayer;
import '../tts/tts_model_manager_page.dart';

/// 在单页正文中定位当前朗读句的字符区间（支持跨换行/空白差异的容错匹配）。
({int start, int end})? findCueSpanInPage(String pageText, String cueText) {
  final trimmedCue = cueText.trim();
  if (trimmedCue.isEmpty || pageText.isEmpty) return null;

  final direct = pageText.indexOf(trimmedCue);
  if (direct >= 0) {
    return (start: direct, end: direct + trimmedCue.length);
  }

  // 忽略空白字符后做归一化映射，兼容 EPUB 段落换行与 SRT 单行文本差异
  final normPage = StringBuffer();
  final indexMap = <int>[];
  for (var i = 0; i < pageText.length; i++) {
    final ch = pageText[i];
    if (ch.trim().isNotEmpty) {
      normPage.write(ch);
      indexMap.add(i);
    }
  }
  final normCue = trimmedCue.replaceAll(RegExp(r'\s+'), '');
  if (normCue.isEmpty) return null;

  final normIdx = normPage.toString().indexOf(normCue);
  if (normIdx < 0 || normIdx + normCue.length > indexMap.length) return null;

  return (
    start: indexMap[normIdx],
    end: indexMap[normIdx + normCue.length - 1] + 1,
  );
}

/// 阅读器（对齐设计 §4.1 & §5.2 边听边看）：
/// - 按可视尺寸精确分页，左右滑动翻页；
/// - 记住上次阅读位置（章号 + 字符偏移，字号变化后仍精准）；
/// - 顶部「边听边看」原地起播/暂停，正文实时以淡靛蓝高亮当前朗读句并自动翻页。
class ReaderPageView extends ConsumerStatefulWidget {
  const ReaderPageView({
    super.key,
    required this.book,
    this.initialChapterIndex,
  });

  final LibraryBook book;

  /// 从播放器跳回阅读器时传入当前朗读章号，实现听看无缝衔接。
  final int? initialChapterIndex;

  @override
  ConsumerState<ReaderPageView> createState() => _ReaderPageState();
}

enum _ReaderTheme { warmDark, pureBlack, lightPaper }

class _ReaderPageState extends ConsumerState<ReaderPageView> {
  final PageController _pageController = PageController();
  List<ChapterPreview> _chapters = const <ChapterPreview>[];
  List<ReaderPage> _pages = const <ReaderPage>[];
  int _currentPage = 0;
  double _fontSize = 17.0;
  double _lineHeight = 1.9;
  _ReaderTheme _readerTheme = _ReaderTheme.warmDark;
  bool _loading = true;
  String? _error;
  bool _listening = false;

  /// 上次已知的阅读位置（章号 + 字符偏移），用于重排后复原。
  int _chapterIndex = 0;
  int _charOffset = 0;

  /// 上一次分页使用的版心尺寸，尺寸变化时需要重排。
  Size? _layoutSize;

  /// 上一次自动翻页匹配的字幕文本，避免同一句反复触发翻页。
  String? _lastAutoPagedCue;

  /// 分页代数令牌：尺寸/字号变化或页面销毁时自增，立即中止旧的后台分页循环，防止并发卡死。
  int _paginationGen = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialChapterIndex != null) {
      _chapterIndex = widget.initialChapterIndex!;
      _charOffset = 0;
    }
    _loadChapters();
  }

  @override
  void dispose() {
    _paginationGen++;
    _pageController.dispose();
    super.dispose();
  }

  ({Color bg, Color fg, Color secondary}) _themeColors(EchoTokens tokens) =>
      switch (_readerTheme) {
        _ReaderTheme.warmDark => (
          bg: tokens.paperWarm,
          fg: tokens.paperText,
          secondary: tokens.textSecondary,
        ),
        _ReaderTheme.pureBlack => (
          bg: const Color(0xFF000000),
          fg: const Color(0xFFE2E8F0),
          secondary: const Color(0xFF94A3B8),
        ),
        _ReaderTheme.lightPaper => (
          bg: const Color(0xFFF6F1E7),
          fg: const Color(0xFF1E293B),
          secondary: const Color(0xFF64748B),
        ),
      };

  TextStyle _textStyle(EchoTokens tokens) => TextStyle(
    fontFamily: 'serif',
    fontSize: _fontSize,
    height: _lineHeight,
    color: _themeColors(tokens).fg,
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
      final saved = widget.initialChapterIndex == null
          ? await ref.read(readingStoreProvider).read(widget.book.id)
          : null;
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        if (widget.initialChapterIndex != null) {
          _chapterIndex = widget.initialChapterIndex!;
          _charOffset = 0;
        } else if (saved != null) {
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

  /// 按当前版心尺寸精确分页（两阶段：优先排版目标章实现首屏即显，其余逐章让帧增量合并）。
  Future<void> _repaginate(Size size, EchoTokens tokens) async {
    if (_chapters.isEmpty) return;
    // 立即锁定当前尺寸与代数，彻底避免 build 重入引发并发分页风暴（ANR 根因）
    _layoutSize = size;
    final gen = ++_paginationGen;
    final style = _textStyle(tokens);
    final textScaler = MediaQuery.textScalerOf(context);

    final targetChapterIdx = _chapters.indexWhere(
      (c) => c.index == _chapterIndex,
    );
    final initialIdx = targetChapterIdx >= 0 ? targetChapterIdx : 0;

    // 阶段 1：优先排版目标章，保证首屏立即可读
    final targetChapter = _chapters[initialIdx];
    final targetPages = paginateChapterBySize(
      chapterIndex: targetChapter.index,
      chapterTitle: targetChapter.title.isNotEmpty
          ? targetChapter.title
          : '第 ${initialIdx + 1} 章',
      text: targetChapter.text,
      style: style,
      textScaler: textScaler,
      maxWidth: size.width,
      maxHeight: size.height,
    );

    if (!mounted || gen != _paginationGen) return;

    final initialTarget = pageIndexForOffset(
      targetPages,
      _chapterIndex,
      _charOffset,
    );
    setState(() {
      _pages = targetPages;
      _currentPage = initialTarget;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      if (_pageController.page?.round() != initialTarget) {
        _pageController.jumpToPage(initialTarget);
      }
    });

    if (_chapters.length <= 1) return;

    // 阶段 2：逐章让出主线程增量排版其余章节，并定期刷新 _pages，确保超大书籍也能立刻往后翻页与跳章
    final allPages = <ReaderPage>[];
    void commitPartial() {
      if (!mounted || gen != _paginationGen) return;
      final target = pageIndexForOffset(allPages, _chapterIndex, _charOffset);
      setState(() {
        _pages = List<ReaderPage>.of(allPages);
        _currentPage = target;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || gen != _paginationGen || !_pageController.hasClients) {
          return;
        }
        if (_pageController.page?.round() != target) {
          _pageController.jumpToPage(target);
        }
      });
    }

    for (var i = 0; i < _chapters.length; i++) {
      if (!mounted || gen != _paginationGen) return;
      if (i == initialIdx) {
        allPages.addAll(targetPages);
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 4));
        if (!mounted || gen != _paginationGen) return;
        final chapter = _chapters[i];
        allPages.addAll(
          paginateChapterBySize(
            chapterIndex: chapter.index,
            chapterTitle: chapter.title.isNotEmpty
                ? chapter.title
                : '第 ${i + 1} 章',
            text: chapter.text,
            style: style,
            textScaler: textScaler,
            maxWidth: size.width,
            maxHeight: size.height,
          ),
        );
      }
      // 刚排完当前章的下一章，或每排完 8 章时，立即刷新一次可翻页范围
      if (i == initialIdx + 1 || (i > initialIdx && (i - initialIdx) % 8 == 0)) {
        commitPartial();
      }
    }

    commitPartial();
  }

  /// 章节目录：跳到该章第一页（若后台分页尚未覆盖到该章，则立即以该章优先重排）。
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
              onTap: () {
                Navigator.of(sheetCtx).pop();
                if (firstPage != null) {
                  _pageController.jumpToPage(firstPage);
                } else {
                  setState(() {
                    _chapterIndex = chapter.index;
                    _charOffset = 0;
                  });
                  final size = _layoutSize;
                  if (size != null) {
                    _repaginate(size, tokens);
                  }
                }
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
    StatsStore.instance.addPageRead();
    final position = ReadingPosition(
      bookId: widget.book.id,
      chapterIndex: page.chapterIndex,
      charOffset: page.startChar,
      updatedAt: DateTime.now().toUtc(),
    );
    await ref.read(readingStoreProvider).write(position);
    ref
        .read(progressSyncServiceProvider.notifier)
        .reportReadingProgress(position);
  }

  /// 排版设置面板（字号滑块 / 行距滑块 / 护眼底色）。
  void _showTypographySheet() {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final textTheme = Theme.of(sheetCtx).textTheme;
          return SafeArea(
            child: Padding(
              key: const Key('reader_typography_sheet'),
              padding: const EdgeInsets.all(EchoMetrics.space3),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '阅读排版',
                    style: textTheme.titleMedium?.copyWith(
                      color: tokens.textPrimary,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                  Row(
                    children: [
                      Text('字号', style: textTheme.bodySmall),
                      Expanded(
                        child: Slider(
                          key: const Key('reader_font_size_slider'),
                          value: _fontSize,
                          min: 14.0,
                          max: 26.0,
                          divisions: 12,
                          label: '${_fontSize.round()}px',
                          onChanged: (v) {
                            setSheetState(() {});
                            setState(() {
                              _fontSize = v;
                              _layoutSize = null;
                            });
                          },
                        ),
                      ),
                      Text(
                        '${_fontSize.round()}',
                        style: textTheme.labelMedium,
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Text('行距', style: textTheme.bodySmall),
                      Expanded(
                        child: Slider(
                          key: const Key('reader_line_height_slider'),
                          value: _lineHeight,
                          min: 1.5,
                          max: 2.2,
                          divisions: 7,
                          label: _lineHeight.toStringAsFixed(1),
                          onChanged: (v) {
                            setSheetState(() {});
                            setState(() {
                              _lineHeight = v;
                              _layoutSize = null;
                            });
                          },
                        ),
                      ),
                      Text(
                        _lineHeight.toStringAsFixed(1),
                        style: textTheme.labelMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: EchoMetrics.space1),
                  Wrap(
                    spacing: EchoMetrics.space1,
                    children: [
                      ChoiceChip(
                        key: const Key('reader_theme_warmDark'),
                        label: const Text('暖纸深底'),
                        selected: _readerTheme == _ReaderTheme.warmDark,
                        onSelected: (_) {
                          setSheetState(() {});
                          setState(
                            () => _readerTheme = _ReaderTheme.warmDark,
                          );
                        },
                      ),
                      ChoiceChip(
                        key: const Key('reader_theme_pureBlack'),
                        label: const Text('纯黑夜读'),
                        selected: _readerTheme == _ReaderTheme.pureBlack,
                        onSelected: (_) {
                          setSheetState(() {});
                          setState(
                            () => _readerTheme = _ReaderTheme.pureBlack,
                          );
                        },
                      ),
                      ChoiceChip(
                        key: const Key('reader_theme_lightPaper'),
                        label: const Text('柔和亮白'),
                        selected: _readerTheme == _ReaderTheme.lightPaper,
                        onSelected: (_) {
                          setSheetState(() {});
                          setState(
                            () => _readerTheme = _ReaderTheme.lightPaper,
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 边听边看：在阅读器内原地起播/暂停当前章节；[openFullPlayer] 为 true 时同时展开全屏播放器。
  Future<void> _listenFromHere({bool openFullPlayer = false}) async {
    if (_listening) return;
    setState(() => _listening = true);
    try {
      await _listenFromHereInner(openFullPlayer: openFullPlayer);
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _listenFromHereInner({required bool openFullPlayer}) async {
    final playerState = ref.read(chunkedPlayerProvider);
    final controller = ref.read(chunkedPlayerProvider.notifier);
    final liveState = ref.read(liveTtsPlayerProvider);
    final liveCtrl = ref.read(liveTtsPlayerProvider.notifier);

    // 1. 若本书正在进行端侧「边听边生成」实时朗读：原地切换播放/暂停
    if (liveState.hasBook && liveState.book?.id == widget.book.id) {
      await liveCtrl.togglePlayPause();
      return;
    }

    // 2. 若本书已加载到分块播放器：顶栏原地切换播放/暂停；底栏可展开全屏播放器
    if (playerState.hasBook && playerState.audiobook?.bookId == widget.book.id) {
      if (openFullPlayer) {
        await openPlayer(context);
        return;
      }
      await controller.togglePlayPause();
      return;
    }

    // 3. 若已有本地离线转好的有声书分块：优先零 CPU 播放离线分块
    final audio = ref
        .read(libraryControllerProvider)
        .audiobooks
        .where((a) => a.bookId == widget.book.id && a.isPlayable)
        .firstOrNull;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (audio == null) {
      // 4. 否则直接启动端侧「边听边生成」实时流式朗读（从当前页起始字符起播）
      if (playerState.hasBook && playerState.isPlaying) {
        await controller.togglePlayPause();
      }
      final startOffset =
          (_currentPage >= 0 && _currentPage < _pages.length)
          ? _pages[_currentPage].startChar
          : 0;
      await liveCtrl.playBookChapter(
        widget.book,
        chapterIndex: _chapterIndex,
        startCharOffset: startOffset,
      );
      final err = ref.read(liveTtsPlayerProvider).error;
      if (err != null && mounted) {
        messenger?.showSnackBar(
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
      return;
    }

    final cover = ref
        .read(libraryControllerProvider)
        .books
        .where((b) => b.id == widget.book.id)
        .map((b) => b.coverUrl)
        .firstOrNull;

    await controller.loadAudiobook(audio, autoPlay: false, coverUrl: cover);
    final chunks = ref.read(chunkedPlayerProvider).chunks;
    if (chunks.isEmpty) {
      messenger?.showSnackBar(const SnackBar(content: Text('该书音频尚未分章，无法定位')));
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
    if (openFullPlayer) {
      await openPlayer(context);
    }
  }

  /// 当前朗读句离开本页时，自动翻到包含该句的页面。
  void _syncPageWithActiveCue(ChunkedPlayerState playerState) {
    if (playerState.audiobook?.bookId != widget.book.id) return;
    _syncPageWithCueText(
      playerState.currentChunk?.chapterIndex,
      playerState.activeCue?.text ?? '',
    );
  }

  void _syncPageWithCueText(int? targetChapter, String rawCue) {
    if (!mounted || !_pageController.hasClients || _pages.isEmpty) return;
    final cueText = rawCue.trim();
    if (cueText.isEmpty || cueText == _lastAutoPagedCue) return;

    // 已在当前页命中：无需翻页
    if (_currentPage >= 0 &&
        _currentPage < _pages.length &&
        findCueSpanInPage(_pages[_currentPage].text, cueText) != null) {
      _lastAutoPagedCue = cueText;
      return;
    }

    var targetPage = -1;
    // 优先在当前朗读章内检索
    if (targetChapter != null) {
      for (var i = 0; i < _pages.length; i++) {
        if (_pages[i].chapterIndex == targetChapter &&
            findCueSpanInPage(_pages[i].text, cueText) != null) {
          targetPage = i;
          break;
        }
      }
    }
    // 回退：全书检索
    if (targetPage == -1) {
      for (var i = 0; i < _pages.length; i++) {
        if (findCueSpanInPage(_pages[i].text, cueText) != null) {
          targetPage = i;
          break;
        }
      }
    }
    if (targetPage >= 0 && targetPage != _currentPage) {
      _lastAutoPagedCue = cueText;
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      if (reduceMotion) {
        _pageController.jumpToPage(targetPage);
      } else {
        _pageController.animateToPage(
          targetPage,
          duration: EchoMetrics.motionBase,
          curve: EchoMetrics.easeEnter,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final palette = _themeColors(tokens);
    final playerState = ref.watch(chunkedPlayerProvider);
    final liveState = ref.watch(liveTtsPlayerProvider);
    final isThisBookLoaded =
        playerState.hasBook && playerState.audiobook?.bookId == widget.book.id;
    final isLiveThisBook =
        liveState.hasBook && liveState.book?.id == widget.book.id;
    final isPlayingThisBook =
        (isThisBookLoaded && playerState.isPlaying) ||
        (isLiveThisBook && liveState.isPlaying);
    final activeCueText = isLiveThisBook
        ? liveState.currentCueText
        : (isThisBookLoaded ? playerState.activeCue?.text : null);

    ref.listen<ChunkedPlayerState>(chunkedPlayerProvider, (prev, next) {
      if (next.audiobook?.bookId != widget.book.id) return;
      if (prev?.activeCue?.text != next.activeCue?.text ||
          prev?.currentChunkIndex != next.currentChunkIndex) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _syncPageWithActiveCue(next);
        });
      }
    });

    ref.listen<LiveTtsState>(liveTtsPlayerProvider, (prev, next) {
      if (next.book?.id != widget.book.id) return;
      if (prev?.currentCueText != next.currentCueText ||
          prev?.chapterIndex != next.chapterIndex) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _syncPageWithCueText(next.chapterIndex, next.currentCueText);
        });
      }
    });

    final hasAudio =
        ref
            .watch(libraryControllerProvider)
            .audiobooks
            .any((a) => a.bookId == widget.book.id && a.isPlayable) ||
        ref.watch(ttsModelManagerProvider).installedEntries.isNotEmpty;
    final page = (_currentPage >= 0 && _currentPage < _pages.length)
        ? _pages[_currentPage]
        : null;

    return Scaffold(
      key: const Key('reader_page'),
      backgroundColor: palette.bg,
      appBar: AppBar(
        backgroundColor: palette.bg,
        foregroundColor: palette.fg,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.book.title,
              key: const Key('reader_book_title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleMedium?.copyWith(color: palette.fg),
            ),
            Text(
              page?.chapterTitle ?? '',
              key: const Key('reader_chapter_label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(color: palette.secondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('reader_toc_button'),
            tooltip: '目录',
            onPressed: _loading || _chapters.isEmpty ? null : _showToc,
            icon: Icon(Icons.list, color: palette.fg),
          ),
          IconButton(
            key: const Key('reader_font_button'),
            tooltip: '排版设置',
            onPressed: _loading ? null : _showTypographySheet,
            icon: Text(
              'Aa',
              style: textTheme.labelLarge?.copyWith(color: palette.fg),
            ),
          ),
          IconButton(
            key: const Key('reader_play_button'),
            tooltip: isPlayingThisBook ? '暂停边听边看' : '边听边看',
            onPressed: _loading ? null : () => _listenFromHere(),
            icon: Icon(
              isPlayingThisBook
                  ? Icons.pause_circle_filled
                  : Icons.headphones,
              color: isPlayingThisBook
                  ? tokens.primary
                  : (hasAudio ? palette.fg : tokens.textDisabled),
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
                      style: textTheme.bodyMedium?.copyWith(
                        color: tokens.error,
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: _loadChapters,
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          : _chapters.isEmpty
          ? Center(
              key: const Key('reader_empty'),
              child: Text(
                '本书暂无可读章节（仅 EPUB 支持阅读）',
                style: textTheme.bodyLarge?.copyWith(
                  color: palette.secondary,
                ),
              ),
            )
          : _ReaderBody(
              pages: _pages,
              pageController: _pageController,
              textStyle: _textStyle(tokens),
              highlightColor: tokens.readingHighlight,
              activeCueText: activeCueText,
              layoutSize: _layoutSize,
              onNeedPagination: _repaginate,
              onPageChanged: _onPageChanged,
            ),
      bottomNavigationBar: _loading || _pages.isEmpty
          ? null
          : BottomAppBar(
              color: palette.bg,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '第 ${page?.pageInChapter ?? 1}/${page?.pageCountInChapter ?? 1} 页',
                    key: const Key('reader_page_indicator'),
                    style: textTheme.labelMedium?.copyWith(
                      color: palette.secondary,
                    ),
                  ),
                  Text(
                    _pages.isEmpty
                        ? '0%'
                        : '${_currentPage + 1}/${_pages.length} · '
                              '${((_currentPage + 1) / _pages.length * 100).round()}%',
                    key: const Key('reader_global_indicator'),
                    style: textTheme.labelMedium?.copyWith(
                      color: palette.secondary,
                    ),
                  ),
                  if (isThisBookLoaded)
                    TextButton.icon(
                      key: const Key('reader_open_player'),
                      onPressed: () => openPlayer(context),
                      icon: Icon(
                        isPlayingThisBook
                            ? Icons.graphic_eq
                            : Icons.play_circle_outline,
                        size: 18,
                      ),
                      label: const Text('全屏播放器'),
                    )
                  else if (hasAudio)
                    TextButton.icon(
                      key: const Key('reader_listen_here'),
                      onPressed: () => _listenFromHere(),
                      icon: const Icon(Icons.play_circle_outline, size: 18),
                      label: const Text('边听边看'),
                    )
                  else
                    const SizedBox.shrink(),
                ],
              ),
            ),
    );
  }
}

/// 版心：用 LayoutBuilder 拿到可用宽高，宽屏约束最大宽度 680dp（45–75ch），交给父级做精确分页。
class _ReaderBody extends StatelessWidget {
  const _ReaderBody({
    required this.pages,
    required this.pageController,
    required this.textStyle,
    required this.highlightColor,
    required this.activeCueText,
    required this.layoutSize,
    required this.onNeedPagination,
    required this.onPageChanged,
  });

  final List<ReaderPage> pages;
  final PageController pageController;
  final TextStyle textStyle;
  final Color highlightColor;
  final String? activeCueText;
  final Size? layoutSize;
  final Future<void> Function(Size size, EchoTokens tokens) onNeedPagination;
  final ValueChanged<int> onPageChanged;

  static const double _maxReadingWidth = 680.0;

  static const EdgeInsets _insets = EdgeInsets.fromLTRB(
    EchoMetrics.space3,
    EchoMetrics.space2,
    EchoMetrics.space3,
    EchoMetrics.space1,
  );

  Widget _buildPageText(int index, String pageText) {
    final cue = activeCueText;
    final span = (cue != null && cue.isNotEmpty)
        ? findCueSpanInPage(pageText, cue)
        : null;
    if (span == null) {
      return Text(
        pageText,
        key: Key('reader_page_text_$index'),
        style: textStyle,
      );
    }
    return Text.rich(
      key: Key('reader_page_text_$index'),
      TextSpan(
        style: textStyle,
        children: <InlineSpan>[
          if (span.start > 0) TextSpan(text: pageText.substring(0, span.start)),
          TextSpan(
            text: pageText.substring(span.start, span.end),
            style: textStyle.copyWith(backgroundColor: highlightColor),
          ),
          if (span.end < pageText.length)
            TextSpan(text: pageText.substring(span.end)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final effectiveWidth = constraints.maxWidth > _maxReadingWidth
            ? _maxReadingWidth
            : constraints.maxWidth;
        final available = Size(
          effectiveWidth - _insets.horizontal,
          constraints.maxHeight - _insets.vertical,
        );
        // 尺寸变化（首次布局/旋转/字号/行距）触发重新分页
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
          itemBuilder: (context, index) => Center(
            child: ConstrainedBox(
              key: index == 0 ? const Key('reader_column_constraint') : null,
              constraints: const BoxConstraints(maxWidth: _maxReadingWidth),
              child: SizedBox(
                width: effectiveWidth,
                height: constraints.maxHeight,
                child: Padding(
                  padding: _insets,
                  child: _buildPageText(index, pages[index].text),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 兼容旧引用名。
typedef ReaderPageWidget = ReaderPageView;
