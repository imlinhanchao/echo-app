import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../core/audio/live_tts_player_controller.dart';
import '../../core/notes/reading_annotation_store.dart';
import '../../core/reader/reading_store.dart';
import '../../core/reader/screen_keep_alive.dart';
import '../../core/settings/standalone_config_store.dart';
import '../../core/stats/stats_store.dart';
import '../../core/sync/progress_sync_service.dart';
import '../../core/tts/sentence_splitter.dart';
import '../../core/tts/tts_model_manager.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../library/library_controller.dart';
import '../player/player_sheet.dart' show openPlayer;
import '../tts/tts_model_manager_page.dart';
import 'reader_annotation_sheets.dart';

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
/// - 按章懒分页 + LRU 缓存，大书秒开且不阻塞 UI 与实时朗读；
/// - 记住上次阅读位置（章号 + 字符偏移，字号变化后仍精准）；
/// - 顶部「边听边看」从当前可见页首句起播，正文实时高亮当前句并自动翻页；
/// - 默认阅读时保持屏幕常亮，可在排版设置中随时开关。
class ReaderPageView extends ConsumerStatefulWidget {
  const ReaderPageView({
    super.key,
    required this.book,
    this.initialChapterIndex,
    this.initialCharOffset,
  });

  final LibraryBook book;

  /// 从播放器或目录跳入时指定目标章号。
  final int? initialChapterIndex;

  /// 从实时听书悬浮条跳入时直接传入当前句字符偏移，零延迟定位。
  final int? initialCharOffset;

  @override
  ConsumerState<ReaderPageView> createState() => _ReaderPageState();
}

enum _ReaderTheme { warmDark, pureBlack, lightPaper }

const TextHeightBehavior _kReaderTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: true,
  applyHeightToLastDescent: true,
);

class _ReaderPageState extends ConsumerState<ReaderPageView> {
  PageController _pageController = PageController();
  int _pageViewEpoch = 0;

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

  /// 分页代数令牌：尺寸/字号/切章或销毁时自增，立即中止过时分片分页任务。
  int _paginationGen = 0;
  bool _pendingJumpToLastPage = false;
  bool _switchingChapter = false;
  double _overscrollDelta = 0.0;
  bool _hasTextSelection = false;
  ReadingHighlightColor _lastHighlightColor = ReadingHighlightColor.gold;

  /// 已处理过的离线字幕/实时朗读位置，防止重复触发翻页。
  String? _lastAutoPagedCue;
  int _lastSyncedLiveChapter = -1;
  int _lastSyncedLiveSentence = -1;

  late final ScreenKeepAliveService _screenKeepAlive;

  @override
  void initState() {
    super.initState();
    _screenKeepAlive = ref.read(screenKeepAliveServiceProvider);
    final keepScreenOn =
        ref.read(standaloneConfigProvider).keepScreenOnWhileReading;
    if (keepScreenOn) {
      unawaited(_screenKeepAlive.setEnabled(true));
    }

    // 若从底部实时听书条返回本书，直接同步复用已加载章节与当前朗读位置，零 IO/JSON 等待
    final liveState = ref.read(liveTtsPlayerProvider);
    if (liveState.hasBook &&
        liveState.book?.id == widget.book.id &&
        liveState.chapters.isNotEmpty) {
      _chapters = liveState.chapters;
      final arrayIdx = widget.initialChapterIndex != null
          ? _findChapterArrayIdx(liveState.chapters, widget.initialChapterIndex!)
          : liveState.chapterIndex.clamp(0, liveState.chapters.length - 1);
      _chapterIndex = liveState.chapters[arrayIdx].index;
      _charOffset =
          widget.initialCharOffset ??
          liveState.currentSentence?.startOffset ??
          0;
      _loading = false;
      _lastSyncedLiveChapter = liveState.chapterIndex;
      _lastSyncedLiveSentence = liveState.sentenceIndex;
    } else {
      if (widget.initialChapterIndex != null) {
        _chapterIndex = widget.initialChapterIndex!;
        _charOffset = widget.initialCharOffset ?? 0;
      }
      _loadChapters();
    }
  }

  @override
  void dispose() {
    _paginationGen++;
    unawaited(_screenKeepAlive.setEnabled(false));
    _pageController.dispose();
    super.dispose();
  }

  static int _findChapterArrayIdx(List<ChapterPreview> chapters, int target) {
    final byIndex = chapters.indexWhere((c) => c.index == target);
    if (byIndex >= 0) return byIndex;
    return target.clamp(0, chapters.length - 1);
  }

  int _currentChapterArrayIdx() {
    if (_chapters.isEmpty) return 0;
    return _findChapterArrayIdx(_chapters, _chapterIndex);
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
    letterSpacing: 0.0,
    wordSpacing: 0.0,
    fontWeight: FontWeight.normal,
    fontStyle: FontStyle.normal,
    decoration: TextDecoration.none,
    leadingDistribution: TextLeadingDistribution.even,
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
          _charOffset = widget.initialCharOffset ?? 0;
        } else if (saved != null) {
          _chapterIndex = saved.chapterIndex;
          _charOffset = saved.charOffset;
        } else if (chapters.isNotEmpty) {
          _chapterIndex = chapters.first.index;
          _charOffset = 0;
        }
        _loading = false;
        _layoutSize = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// 按当前章 + 当前版心尺寸懒分页（先查 LRU 缓存，未命中则分时让帧排版当前单章）。
  Future<void> _paginateCurrentChapter(
    Size size,
    EchoTokens tokens, {
    bool jumpToLastPage = false,
  }) async {
    if (_chapters.isEmpty) return;
    final useLastPage = jumpToLastPage || _pendingJumpToLastPage;
    _pendingJumpToLastPage = false;
    _layoutSize = size;
    final gen = ++_paginationGen;
    final style = DefaultTextStyle.of(context).style.merge(_textStyle(tokens));
    final textScaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    final textScaleFactor = textScaler.scale(10.0) / 10.0;

    final arrayIdx = _currentChapterArrayIdx();
    final targetChapter = _chapters[arrayIdx];
    final chapterTitle = targetChapter.title.isNotEmpty
        ? targetChapter.title
        : '第 ${arrayIdx + 1} 章';

    final cacheKey = ChapterPaginationKey(
      bookId: widget.book.id,
      chapterIndex: targetChapter.index,
      maxWidth: size.width,
      maxHeight: size.height,
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      textScaleFactor: textScaleFactor,
    );

    var pages = ChapterPaginationCache.instance.get(cacheKey);
    if (pages == null) {
      pages = await paginateChapterBySizeAsync(
        chapterIndex: targetChapter.index,
        chapterTitle: chapterTitle,
        text: targetChapter.text,
        style: style,
        textScaler: textScaler,
        maxWidth: size.width,
        maxHeight: size.height,
        locale: locale,
        textHeightBehavior: _kReaderTextHeightBehavior,
        isCancelled: () => !mounted || gen != _paginationGen,
      );
      if (!mounted || gen != _paginationGen) return;
      if (pages.isNotEmpty) {
        ChapterPaginationCache.instance.put(cacheKey, pages);
      }
    }

    if (!mounted || gen != _paginationGen || pages.isEmpty) return;

    final targetPage = useLastPage
        ? pages.length - 1
        : pageIndexForOffset(pages, targetChapter.index, _charOffset);

    final oldController = _pageController;
    final nextController = PageController(initialPage: targetPage);

    setState(() {
      _pageController = nextController;
      _pageViewEpoch++;
      _pages = pages!;
      _currentPage = targetPage;
      _chapterIndex = targetChapter.index;
      if (useLastPage) {
        _charOffset = pages[targetPage].startChar;
      }
      _switchingChapter = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldController.dispose();
    });
  }

  void _jumpToChapterArrayIndex(
    int arrayIdx, {
    int charOffset = 0,
    bool jumpToLastPage = false,
  }) {
    if (arrayIdx < 0 || arrayIdx >= _chapters.length) return;
    final chapter = _chapters[arrayIdx];
    setState(() {
      _switchingChapter = true;
      _overscrollDelta = 0.0;
      _chapterIndex = chapter.index;
      _charOffset = charOffset;
      _pendingJumpToLastPage = jumpToLastPage;
    });
    unawaited(_persistPosition(chapter.index, charOffset));

    final size = _layoutSize;
    if (size != null && mounted) {
      final tokens = Theme.of(context).extension<EchoTokens>()!;
      unawaited(
        _paginateCurrentChapter(size, tokens, jumpToLastPage: jumpToLastPage),
      );
    }
  }

  /// 章节目录：直接切换到对应章节并按需分页。
  void _showToc() {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final currentArrayIdx = _currentChapterArrayIdx();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        maxChildSize: 0.9,
        builder: (sheetCtx, controller) => Column(
          children: [
            const EchoSheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: EchoSectionHeader(
                title: '目录',
                subtitle: '${_chapters.length} 章',
              ),
            ),
            Expanded(
              child: ListView.separated(
                key: const Key('reader_toc_list'),
                controller: controller,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                itemCount: _chapters.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 48, endIndent: 12),
                itemBuilder: (_, i) {
                  final chapter = _chapters[i];
                  final selected = i == currentArrayIdx;
                  return ListTile(
                    key: Key('reader_toc_item_$i'),
                    dense: true,
                    selected: selected,
                    selectedTileColor: tokens.readingHighlight,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    leading: Icon(
                      selected
                          ? Icons.bookmark_rounded
                          : Icons.article_outlined,
                      size: 19,
                      color: selected ? tokens.primary : tokens.textSecondary,
                    ),
                    title: Text(
                      chapter.title.isNotEmpty
                          ? chapter.title
                          : '第 ${i + 1} 章',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? tokens.primary : tokens.paperText,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: Text(
                      '${chapter.chars} 字',
                      style: Theme.of(sheetCtx).textTheme.labelSmall?.copyWith(
                        color: tokens.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _jumpToChapterArrayIndex(i);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _persistPosition(int chapterIndex, int charOffset) async {
    final position = ReadingPosition(
      bookId: widget.book.id,
      chapterIndex: chapterIndex,
      charOffset: charOffset,
      updatedAt: DateTime.now().toUtc(),
    );
    await ref.read(readingStoreProvider).write(position);
    if (!mounted) return;
    ref
        .read(progressSyncServiceProvider.notifier)
        .reportReadingProgress(position);
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
    await _persistPosition(page.chapterIndex, page.startChar);
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.horizontal || _chapters.length <= 1) {
      return false;
    }
    if (notification is ScrollStartNotification ||
        notification is ScrollEndNotification) {
      _overscrollDelta = 0.0;
      return false;
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        !_switchingChapter) {
      _overscrollDelta += notification.overscroll;
      final arrayIdx = _currentChapterArrayIdx();
      if (_overscrollDelta >= 48.0 && arrayIdx + 1 < _chapters.length) {
        _jumpToChapterArrayIndex(arrayIdx + 1);
      } else if (_overscrollDelta <= -48.0 && arrayIdx > 0) {
        _jumpToChapterArrayIndex(arrayIdx - 1, jumpToLastPage: true);
      }
    }
    return false;
  }

  int _computeBookProgressPercent() {
    if (_chapters.isEmpty || _pages.isEmpty) return 0;
    final arrayIdx = _currentChapterArrayIdx();
    var totalChars = 0;
    var beforeChars = 0;
    for (var i = 0; i < _chapters.length; i++) {
      final len = math.max(1, _chapters[i].chars);
      if (i < arrayIdx) {
        beforeChars += len;
      }
      totalChars += len;
    }
    final curLen = math.max(1, _chapters[arrayIdx].chars);
    final chFrac = (_currentPage + 1) / _pages.length;
    final readChars = beforeChars + curLen * chFrac;
    return ((readChars / totalChars) * 100).round().clamp(1, 100);
  }

  /// 排版设置面板（字号滑块 / 行距滑块 / 护眼底色 / 阅读防锁屏）。
  void _showTypographySheet() {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final textTheme = Theme.of(sheetCtx).textTheme;
          final keepScreenOn = ref.read(standaloneConfigProvider).keepScreenOnWhileReading;
          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                key: const Key('reader_typography_sheet'),
                padding: const EdgeInsets.fromLTRB(
                  EchoMetrics.pagePadding,
                  4,
                  EchoMetrics.pagePadding,
                  EchoMetrics.space3,
                ),
                child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const EchoSheetDragHandle(),
                  Text(
                    '阅读排版',
                    style: textTheme.titleMedium?.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: FontWeight.w600,
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
                  const SizedBox(height: EchoMetrics.space1),
                  SwitchListTile(
                    key: const Key('reader_keep_screen_on_switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '阅读时屏幕常亮',
                      style: textTheme.bodyMedium?.copyWith(
                        color: tokens.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      '阻止阅读或边听边看期间自动熄屏锁屏',
                      style: textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                    value: keepScreenOn,
                    onChanged: (enabled) async {
                      await ref
                          .read(standaloneConfigProvider.notifier)
                          .setKeepScreenOnWhileReading(enabled);
                      await _screenKeepAlive.setEnabled(enabled);
                      if (sheetCtx.mounted) {
                        setSheetState(() {});
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        );
        },
      ),
    );
  }

  /// 边听边看：从当前可见页首句起播/续播，若正在朗读本页则切换暂停/播放。
  Future<void> _createHighlight({
    required ReaderPage page,
    required int localStart,
    required int localEnd,
    required ReadingHighlightColor color,
  }) async {
    final safeStart = localStart.clamp(0, page.text.length);
    final safeEnd = localEnd.clamp(0, page.text.length);
    if (safeStart >= safeEnd) return;
    final quote = page.text.substring(safeStart, safeEnd).trim();
    if (quote.isEmpty) return;

    setState(() => _lastHighlightColor = color);
    final created = await ref
        .read(bookAnnotationsProvider(widget.book.id).notifier)
        .add(
          chapterIndex: page.chapterIndex,
          startOffset: page.startChar + safeStart,
          endOffset: page.startChar + safeEnd,
          quote: quote,
          color: color,
          chapterTitle: page.chapterTitle,
        );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: const Text('已划线'),
        action: SnackBarAction(
          label: '写笔记',
          onPressed: () {
            if (mounted) {
              unawaited(_openAnnotationEditor(existing: created));
            }
          },
        ),
      ),
    );
  }

  Future<void> _openAnnotationEditor({
    ReadingAnnotation? existing,
    ReaderPage? page,
    int? localStart,
    int? localEnd,
  }) async {
    final String quote;
    final String chapterTitle;
    if (existing != null) {
      quote = existing.quote;
      chapterTitle = existing.chapterTitle;
    } else {
      if (page == null || localStart == null || localEnd == null) return;
      final s = localStart.clamp(0, page.text.length);
      final e = localEnd.clamp(0, page.text.length);
      if (s >= e) return;
      quote = page.text.substring(s, e).trim();
      if (quote.isEmpty) return;
      chapterTitle = page.chapterTitle;
    }

    final notifier = ref.read(bookAnnotationsProvider(widget.book.id).notifier);
    await showAnnotationEditorSheet(
      context: context,
      quote: quote,
      existing: existing,
      initialColor: existing?.color ?? _lastHighlightColor,
      chapterTitle: chapterTitle,
      onSave: (color, note) async {
        if (mounted) {
          setState(() => _lastHighlightColor = color);
        }
        if (existing != null) {
          await notifier.update(existing.copyWith(color: color, note: note));
        } else if (page != null && localStart != null && localEnd != null) {
          await notifier.add(
            chapterIndex: page.chapterIndex,
            startOffset: page.startChar + localStart,
            endOffset: page.startChar + localEnd,
            quote: quote,
            note: note,
            color: color,
            chapterTitle: chapterTitle,
          );
        }
      },
      onDelete: existing == null ? null : () => notifier.remove(existing.id),
    );
  }

  void _jumpToAnnotation(ReadingAnnotation ann) {
    if (_chapters.isEmpty) return;
    final targetArrayIdx = _findChapterArrayIdx(_chapters, ann.chapterIndex);
    final targetChapter = _chapters[targetArrayIdx];
    if (targetChapter.index == _chapterIndex &&
        _pages.isNotEmpty &&
        _pageController.hasClients) {
      final pageIdx = pageIndexForOffset(
        _pages,
        targetChapter.index,
        ann.startOffset,
      );
      setState(() => _charOffset = ann.startOffset);
      _animateOrJumpToPage(pageIdx);
      unawaited(_persistPosition(targetChapter.index, ann.startOffset));
      return;
    }
    _jumpToChapterArrayIndex(targetArrayIdx, charOffset: ann.startOffset);
  }

  Future<void> _showBookNotes() async {
    await showBookAnnotationsSheet(
      context: context,
      bookId: widget.book.id,
      onJumpTo: _jumpToAnnotation,
      onEdit: (ann) => _openAnnotationEditor(existing: ann),
      onDelete: (ann) => ref
          .read(bookAnnotationsProvider(widget.book.id).notifier)
          .remove(ann.id),
    );
  }

  Future<void> _listenFromHere({
    bool openFullPlayer = false,
    int? overrideChapterArrayIdx,
    int? overrideCharOffset,
  }) async {
    if (_listening) return;
    setState(() => _listening = true);
    try {
      await _listenFromHereInner(
        openFullPlayer: openFullPlayer,
        overrideChapterArrayIdx: overrideChapterArrayIdx,
        overrideCharOffset: overrideCharOffset,
      );
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _listenFromHereInner({
    required bool openFullPlayer,
    int? overrideChapterArrayIdx,
    int? overrideCharOffset,
  }) async {
    final playerState = ref.read(chunkedPlayerProvider);
    final controller = ref.read(chunkedPlayerProvider.notifier);
    final liveState = ref.read(liveTtsPlayerProvider);
    final liveCtrl = ref.read(liveTtsPlayerProvider.notifier);

    final arrayIdx = overrideChapterArrayIdx ?? _currentChapterArrayIdx();
    final page = (_currentPage >= 0 && _currentPage < _pages.length)
        ? _pages[_currentPage]
        : null;

    if (overrideCharOffset != null) {
      if (playerState.hasBook && playerState.isPlaying) {
        await controller.togglePlayPause();
      }
      await liveCtrl.playBookChapter(
        widget.book,
        chapterIndex: arrayIdx,
        startCharOffset: overrideCharOffset,
      );
      final err = ref.read(liveTtsPlayerProvider).error;
      if (err != null && mounted) {
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
      return;
    }

    // 1. 若本书正在进行端侧「边听边生成」实时朗读：
    //    - 仍停留在正在朗读的同一页时：原地切换播放/暂停；
    //    - 若已手动翻到其他页/章：直接从当前可见页首句续播。
    if (liveState.hasBook && liveState.book?.id == widget.book.id) {
      final curSentence = liveState.currentSentence;
      final isOnSpokenPage =
          page != null &&
          liveState.chapterIndex == arrayIdx &&
          curSentence != null &&
          curSentence.startOffset < page.endChar &&
          curSentence.endOffset > page.startChar;
      if (!isOnSpokenPage && page != null) {
        await liveCtrl.playBookChapter(
          widget.book,
          chapterIndex: arrayIdx,
          startCharOffset: page.startChar,
        );
      } else {
        await liveCtrl.togglePlayPause();
      }
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
      // 4. 否则直接启动端侧「边听边生成」实时流式朗读（从当前可见页首句起播）
      if (playerState.hasBook && playerState.isPlaying) {
        await controller.togglePlayPause();
      }
      final startOffset = page?.startChar ?? _charOffset;
      await liveCtrl.playBookChapter(
        widget.book,
        chapterIndex: arrayIdx,
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

  /// 离线有声书听看跟随：跨章切换或同章自动翻页。
  void _syncPageWithActiveCue(ChunkedPlayerState playerState) {
    if (playerState.audiobook?.bookId != widget.book.id) return;
    if (!mounted || _chapters.isEmpty) return;

    final targetChapter = playerState.currentChunk?.chapterIndex;
    final cueText = (playerState.activeCue?.text ?? '').trim();
    if (cueText.isEmpty || cueText == _lastAutoPagedCue) return;

    if (targetChapter != null && targetChapter != _chapterIndex) {
      _lastAutoPagedCue = cueText;
      final idx = _findChapterArrayIdx(_chapters, targetChapter);
      final offset = _chapters[idx].text.indexOf(cueText);
      _jumpToChapterArrayIndex(idx, charOffset: offset >= 0 ? offset : 0);
      return;
    }

    if (!_pageController.hasClients || _pages.isEmpty) return;
    if (_currentPage >= 0 &&
        _currentPage < _pages.length &&
        findCueSpanInPage(_pages[_currentPage].text, cueText) != null) {
      _lastAutoPagedCue = cueText;
      return;
    }
    for (var i = 0; i < _pages.length; i++) {
      if (findCueSpanInPage(_pages[i].text, cueText) != null) {
        _lastAutoPagedCue = cueText;
        _animateOrJumpToPage(i);
        break;
      }
    }
  }

  /// 实时 TTS 听看跟随：精准按字符区间判断跨页/跨章，不误退回上一页。
  void _syncPageWithLiveState(LiveTtsState next) {
    if (!mounted || _chapters.isEmpty) return;
    if (next.chapterIndex == _lastSyncedLiveChapter &&
        next.sentenceIndex == _lastSyncedLiveSentence) {
      return;
    }

    final sentence = next.currentSentence;
    final targetArrayIdx = next.chapterIndex.clamp(0, _chapters.length - 1);
    final currentArrayIdx = _currentChapterArrayIdx();

    _lastSyncedLiveChapter = next.chapterIndex;
    _lastSyncedLiveSentence = next.sentenceIndex;

    if (targetArrayIdx != currentArrayIdx) {
      _jumpToChapterArrayIndex(
        targetArrayIdx,
        charOffset: sentence?.startOffset ?? 0,
      );
      return;
    }

    if (_pages.isEmpty || !_pageController.hasClients) {
      if (sentence != null) {
        _charOffset = sentence.startOffset;
      }
      return;
    }

    if (sentence != null) {
      if (_currentPage >= 0 && _currentPage < _pages.length) {
        final curPage = _pages[_currentPage];
        final overlapsCurrent =
            sentence.startOffset < curPage.endChar &&
            sentence.endOffset > curPage.startChar;
        if (overlapsCurrent) return;
      }
      final chapterObj = _chapters[targetArrayIdx];
      final targetPage = pageIndexForOffset(
        _pages,
        chapterObj.index,
        sentence.startOffset,
      );
      if (targetPage != _currentPage) {
        _animateOrJumpToPage(targetPage);
      }
    } else if (next.currentCueText.trim().isNotEmpty) {
      final cue = next.currentCueText.trim();
      for (var i = 0; i < _pages.length; i++) {
        if (findCueSpanInPage(_pages[i].text, cue) != null) {
          if (i != _currentPage) {
            _animateOrJumpToPage(i);
          }
          break;
        }
      }
    }
  }

  void _animateOrJumpToPage(int targetPage) {
    if (!mounted || !_pageController.hasClients) return;
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

  Widget _buildCompactLiveControls(
    EchoTokens tokens,
    ({Color bg, Color fg, Color secondary}) palette,
    LiveTtsState liveState,
  ) {
    final liveCtrl = ref.read(liveTtsPlayerProvider.notifier);
    const btnConstraints = BoxConstraints.tightFor(width: 34, height: 34);
    return Row(
      key: const Key('reader_live_control_bar'),
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('reader_live_prev_sentence'),
          tooltip: '上一句',
          padding: EdgeInsets.zero,
          constraints: btnConstraints,
          visualDensity: VisualDensity.compact,
          onPressed: liveCtrl.prevSentence,
          icon: Icon(Icons.skip_previous_rounded, size: 20, color: palette.fg),
        ),
        IconButton(
          key: const Key('reader_live_toggle_play'),
          tooltip: liveState.isPlaying ? '暂停朗读' : '继续朗读',
          padding: EdgeInsets.zero,
          constraints: btnConstraints,
          visualDensity: VisualDensity.compact,
          onPressed: liveCtrl.togglePlayPause,
          icon: liveState.isSynthesizing
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: tokens.primary,
                  ),
                )
              : Icon(
                  liveState.isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  size: 22,
                  color: tokens.primary,
                ),
        ),
        IconButton(
          key: const Key('reader_live_next_sentence'),
          tooltip: '下一句',
          padding: EdgeInsets.zero,
          constraints: btnConstraints,
          visualDensity: VisualDensity.compact,
          onPressed: liveCtrl.nextSentence,
          icon: Icon(Icons.skip_next_rounded, size: 20, color: palette.fg),
        ),
        IconButton(
          key: const Key('reader_live_stop'),
          tooltip: '停止听书',
          padding: EdgeInsets.zero,
          constraints: btnConstraints,
          visualDensity: VisualDensity.compact,
          onPressed: liveCtrl.stop,
          icon: Icon(Icons.close, size: 18, color: palette.secondary),
        ),
      ],
    );
  }

  Widget _buildUnifiedBottomBar({
    required EchoTokens tokens,
    required TextTheme textTheme,
    required ({Color bg, Color fg, Color secondary}) palette,
    required int currentArrayIdx,
    required ReaderPage? page,
    required int bookPct,
    required bool isLiveThisBook,
    required LiveTtsState liveState,
    required bool isThisBookLoaded,
    required bool isPlayingThisBook,
    required bool hasAudio,
  }) {
    final compactLabelStyle = textTheme.labelSmall?.copyWith(
      color: palette.secondary,
    );
    return Container(
      key: const Key('reader_bottom_bar'),
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(
          top: BorderSide(color: palette.secondary.withValues(alpha: 0.16)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: EchoMetrics.space2),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          '第 ${currentArrayIdx + 1}/${_chapters.length} 章 · '
                          '${page?.pageInChapter ?? 1}/${page?.pageCountInChapter ?? 1} 页',
                          key: const Key('reader_page_indicator'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: compactLabelStyle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '全书 $bookPct%',
                        key: const Key('reader_global_indicator'),
                        style: compactLabelStyle,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                if (isLiveThisBook)
                  _buildCompactLiveControls(tokens, palette, liveState)
                else if (isThisBookLoaded)
                  TextButton.icon(
                    key: const Key('reader_open_player'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => openPlayer(context),
                    icon: Icon(
                      isPlayingThisBook
                          ? Icons.graphic_eq
                          : Icons.play_circle_outline,
                      size: 16,
                    ),
                    label: const Text('全屏播放器'),
                  )
                else if (hasAudio)
                  TextButton.icon(
                    key: const Key('reader_listen_here'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => _listenFromHere(),
                    icon: const Icon(Icons.play_circle_outline, size: 16),
                    label: const Text('边听边看'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final palette = _themeColors(tokens);
    final playerState = ref.watch(chunkedPlayerProvider);
    final liveState = ref.watch(liveTtsPlayerProvider);
    final annotations = ref.watch(bookAnnotationsProvider(widget.book.id));
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
    final activeSentence =
        (isLiveThisBook &&
            liveState.chapterIndex == _currentChapterArrayIdx())
        ? liveState.currentSentence
        : null;

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
      if (prev?.sentenceIndex != next.sentenceIndex ||
          prev?.chapterIndex != next.chapterIndex ||
          prev?.currentCueText != next.currentCueText) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _syncPageWithLiveState(next);
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
    final currentArrayIdx = _currentChapterArrayIdx();
    final curChapterObj =
        _chapters.isNotEmpty ? _chapters[currentArrayIdx] : null;
    final headerChapterTitle =
        page?.chapterTitle ??
        (curChapterObj == null
            ? ''
            : (curChapterObj.title.isNotEmpty
                  ? curChapterObj.title
                  : '第 ${currentArrayIdx + 1} 章'));
    final bookPct = _computeBookProgressPercent();

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
              headerChapterTitle,
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
            visualDensity: VisualDensity.compact,
            onPressed: _loading || _chapters.isEmpty ? null : _showToc,
            icon: Icon(Icons.list, color: palette.fg),
          ),
          IconButton(
            key: const Key('reader_notes_button'),
            tooltip: '划线与笔记',
            visualDensity: VisualDensity.compact,
            onPressed: _loading ? null : _showBookNotes,
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(Icons.edit_note_outlined, color: palette.fg),
                if (annotations.isNotEmpty)
                  Positioned(
                    right: -2,
                    top: -1,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: tokens.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            key: const Key('reader_font_button'),
            tooltip: '排版设置',
            visualDensity: VisualDensity.compact,
            onPressed: _loading ? null : _showTypographySheet,
            icon: Text(
              'Aa',
              style: textTheme.labelLarge?.copyWith(color: palette.fg),
            ),
          ),
          IconButton(
            key: const Key('reader_play_button'),
            tooltip: isPlayingThisBook ? '从本页听书 / 暂停' : '边听边看',
            visualDensity: VisualDensity.compact,
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
                '本书暂无可读章节（支持 EPUB / TXT 格式）',
                style: textTheme.bodyLarge?.copyWith(
                  color: palette.secondary,
                ),
              ),
            )
          : _ReaderBody(
              pages: _pages,
              pageViewEpoch: _pageViewEpoch,
              pageController: _pageController,
              textStyle: DefaultTextStyle.of(
                context,
              ).style.merge(_textStyle(tokens)),
              highlightColor: tokens.readingHighlight,
              activeSentence: activeSentence,
              activeCueText: activeCueText,
              annotations: annotations,
              lastHighlightColor: _lastHighlightColor,
              hasTextSelection: _hasTextSelection,
              layoutSize: _layoutSize,
              onNeedPagination: _paginateCurrentChapter,
              onPageChanged: _onPageChanged,
              onScrollNotification: _onScrollNotification,
              onSelectionActiveChanged: (active) {
                if (mounted && _hasTextSelection != active) {
                  setState(() => _hasTextSelection = active);
                }
              },
              onQuickHighlight: (page, localStart, localEnd, color) {
                unawaited(
                  _createHighlight(
                    page: page,
                    localStart: localStart,
                    localEnd: localEnd,
                    color: color,
                  ),
                );
              },
              onOpenNoteEditor: (page, localStart, localEnd) {
                unawaited(
                  _openAnnotationEditor(
                    page: page,
                    localStart: localStart,
                    localEnd: localEnd,
                  ),
                );
              },
              onTapAnnotation: (ann) {
                unawaited(_openAnnotationEditor(existing: ann));
              },
              onListenFromSelection: hasAudio
                  ? (page, localStart) {
                      final idx = _findChapterArrayIdx(
                        _chapters,
                        page.chapterIndex,
                      );
                      unawaited(
                        _listenFromHere(
                          overrideChapterArrayIdx: idx,
                          overrideCharOffset: page.startChar + localStart,
                        ),
                      );
                    }
                  : null,
            ),
      bottomNavigationBar: _loading || _pages.isEmpty
          ? null
          : _buildUnifiedBottomBar(
              tokens: tokens,
              textTheme: textTheme,
              palette: palette,
              currentArrayIdx: currentArrayIdx,
              page: page,
              bookPct: bookPct,
              isLiveThisBook: isLiveThisBook,
              liveState: liveState,
              isThisBookLoaded: isThisBookLoaded,
              isPlayingThisBook: isPlayingThisBook,
              hasAudio: hasAudio,
            ),
    );
  }
}

/// 版心：用 LayoutBuilder 拿到可用宽高，宽屏约束最大宽度 680dp（45–75ch），按章精确分页。
class _ReaderBody extends StatelessWidget {
  const _ReaderBody({
    required this.pages,
    required this.pageViewEpoch,
    required this.pageController,
    required this.textStyle,
    required this.highlightColor,
    required this.activeSentence,
    required this.activeCueText,
    required this.annotations,
    required this.lastHighlightColor,
    required this.hasTextSelection,
    required this.layoutSize,
    required this.onNeedPagination,
    required this.onPageChanged,
    required this.onScrollNotification,
    required this.onSelectionActiveChanged,
    required this.onQuickHighlight,
    required this.onOpenNoteEditor,
    required this.onTapAnnotation,
    this.onListenFromSelection,
  });

  final List<ReaderPage> pages;
  final int pageViewEpoch;
  final PageController pageController;
  final TextStyle textStyle;
  final Color highlightColor;
  final TextSentence? activeSentence;
  final String? activeCueText;
  final List<ReadingAnnotation> annotations;
  final ReadingHighlightColor lastHighlightColor;
  final bool hasTextSelection;
  final Size? layoutSize;
  final Future<void> Function(Size size, EchoTokens tokens) onNeedPagination;
  final ValueChanged<int> onPageChanged;
  final bool Function(ScrollNotification) onScrollNotification;
  final ValueChanged<bool> onSelectionActiveChanged;
  final void Function(
    ReaderPage page,
    int localStart,
    int localEnd,
    ReadingHighlightColor color,
  )
  onQuickHighlight;
  final void Function(ReaderPage page, int localStart, int localEnd)
  onOpenNoteEditor;
  final ValueChanged<ReadingAnnotation> onTapAnnotation;
  final void Function(ReaderPage page, int localStart)? onListenFromSelection;

  static const double _maxReadingWidth = 680.0;

  static const EdgeInsets _insets = EdgeInsets.fromLTRB(
    EchoMetrics.space3,
    EchoMetrics.space2,
    EchoMetrics.space3,
    EchoMetrics.space2,
  );

  ({int start, int end})? _resolveHighlightSpan(ReaderPage page) {
    final sentence = activeSentence;
    if (sentence != null) {
      final overlapStart = math.max(sentence.startOffset, page.startChar);
      final overlapEnd = math.min(sentence.endOffset, page.endChar);
      if (overlapStart < overlapEnd) {
        final localStart =
            (overlapStart - page.startChar).clamp(0, page.text.length);
        final localEnd =
            (overlapEnd - page.startChar).clamp(0, page.text.length);
        if (localStart < localEnd) {
          return (start: localStart, end: localEnd);
        }
      }
    }
    final cue = activeCueText;
    if (cue != null && cue.isNotEmpty) {
      return findCueSpanInPage(page.text, cue);
    }
    return null;
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
          math.max(0.0, effectiveWidth - _insets.horizontal),
          math.max(0.0, constraints.maxHeight - _insets.vertical - 4.0),
        );
        // 尺寸变化（首次布局/旋转/字号/行距）触发按章重新分页
        if (layoutSize == null ||
            (layoutSize!.width - available.width).abs() > 0.5 ||
            (layoutSize!.height - available.height).abs() > 0.5) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            onNeedPagination(available, tokens);
          });
        }
        if (pages.isEmpty) {
          return Center(
            child: CircularProgressIndicator(color: tokens.primary),
          );
        }
        return NotificationListener<ScrollNotification>(
          onNotification: onScrollNotification,
          child: KeyedSubtree(
            key: ValueKey<int>(pageViewEpoch),
            child: PageView.builder(
              key: const Key('reader_pageview'),
              physics: hasTextSelection
                  ? const NeverScrollableScrollPhysics()
                  : const ClampingScrollPhysics(),
              controller: pageController,
              onPageChanged: onPageChanged,
              itemCount: pages.length,
              itemBuilder: (context, index) {
                final page = pages[index];
                return Center(
                  child: ConstrainedBox(
                    key: index == 0
                        ? const Key('reader_column_constraint')
                        : null,
                    constraints: const BoxConstraints(maxWidth: _maxReadingWidth),
                    child: SizedBox(
                      width: effectiveWidth,
                      height: constraints.maxHeight,
                      child: Padding(
                        padding: _insets,
                        child: _SelectableReaderPage(
                          index: index,
                          page: page,
                          textStyle: textStyle,
                          highlightColor: highlightColor,
                          activeCueSpan: _resolveHighlightSpan(page),
                          annotations: annotations,
                          lastHighlightColor: lastHighlightColor,
                          onSelectionActiveChanged: onSelectionActiveChanged,
                          onQuickHighlight: onQuickHighlight,
                          onOpenNoteEditor: onOpenNoteEditor,
                          onTapAnnotation: onTapAnnotation,
                          onListenFromSelection: onListenFromSelection,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _SelectableReaderPage extends StatefulWidget {
  const _SelectableReaderPage({
    required this.index,
    required this.page,
    required this.textStyle,
    required this.highlightColor,
    required this.activeCueSpan,
    required this.annotations,
    required this.lastHighlightColor,
    required this.onSelectionActiveChanged,
    required this.onQuickHighlight,
    required this.onOpenNoteEditor,
    required this.onTapAnnotation,
    this.onListenFromSelection,
  });

  final int index;
  final ReaderPage page;
  final TextStyle textStyle;
  final Color highlightColor;
  final ({int start, int end})? activeCueSpan;
  final List<ReadingAnnotation> annotations;
  final ReadingHighlightColor lastHighlightColor;
  final ValueChanged<bool> onSelectionActiveChanged;
  final void Function(
    ReaderPage page,
    int localStart,
    int localEnd,
    ReadingHighlightColor color,
  )
  onQuickHighlight;
  final void Function(ReaderPage page, int localStart, int localEnd)
  onOpenNoteEditor;
  final ValueChanged<ReadingAnnotation> onTapAnnotation;
  final void Function(ReaderPage page, int localStart)? onListenFromSelection;

  @override
  State<_SelectableReaderPage> createState() => _SelectableReaderPageState();
}

class _SelectableReaderPageState extends State<_SelectableReaderPage> {
  final GlobalKey _textKey = GlobalKey();
  final Map<String, TapGestureRecognizer> _annotationRecognizers =
      <String, TapGestureRecognizer>{};
  int? _selStart;
  int? _selEnd;
  int? _dragAnchor;
  OverlayEntry? _toolbarEntry;
  bool _lastReportedActive = false;

  bool get _hasSelection =>
      _selStart != null && _selEnd != null && _selStart! < _selEnd!;

  @override
  void didUpdateWidget(_SelectableReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.chapterIndex != widget.page.chapterIndex ||
        oldWidget.page.startChar != widget.page.startChar ||
        oldWidget.page.text != widget.page.text) {
      _clearSelection(notifyState: false);
    }
  }

  @override
  void dispose() {
    _toolbarEntry?.remove();
    _toolbarEntry = null;
    for (final recognizer in _annotationRecognizers.values) {
      recognizer.dispose();
    }
    _annotationRecognizers.clear();
    if (_lastReportedActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onSelectionActiveChanged(false);
      });
    }
    super.dispose();
  }

  RenderParagraph? _findRenderParagraph() {
    final root = _textKey.currentContext;
    if (root is! Element) return null;
    RenderParagraph? found;
    void visit(Element element) {
      if (found != null) return;
      final ro = element.renderObject;
      if (ro is RenderParagraph) {
        found = ro;
        return;
      }
      element.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  void _reportSelectionActive(bool active) {
    if (active == _lastReportedActive) return;
    _lastReportedActive = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onSelectionActiveChanged(active);
    });
  }

  void _clearSelection({bool notifyState = true}) {
    _toolbarEntry?.remove();
    _toolbarEntry = null;
    _selStart = null;
    _selEnd = null;
    _dragAnchor = null;
    _reportSelectionActive(false);
    if (notifyState && mounted) {
      setState(() {});
    }
  }

  int _hitTestOffset(RenderParagraph paragraph, Offset globalPos) {
    final local = paragraph.globalToLocal(globalPos);
    final clamped = Offset(
      local.dx.clamp(0.0, paragraph.size.width),
      local.dy.clamp(0.0, paragraph.size.height),
    );
    return paragraph.getPositionForOffset(clamped).offset;
  }

  List<TextBox> _computeSelectionBoxes(RenderParagraph? paragraph) {
    if (!_hasSelection ||
        paragraph == null ||
        !paragraph.attached ||
        !paragraph.hasSize) {
      return const <TextBox>[];
    }
    return paragraph.getBoxesForSelection(
      TextSelection(baseOffset: _selStart!, extentOffset: _selEnd!),
    );
  }

  void _onLongPressStart(LongPressStartDetails details) {
    final paragraph = _findRenderParagraph();
    if (paragraph == null || widget.page.text.isEmpty) return;
    final offset = _hitTestOffset(paragraph, details.globalPosition);
    final span = expandInitialSelection(widget.page.text, offset);
    if (span == null) return;
    setState(() {
      _selStart = span.start;
      _selEnd = span.end;
      _dragAnchor = span.start;
    });
    _reportSelectionActive(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showOrUpdateToolbar();
    });
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    final anchor = _dragAnchor;
    final paragraph = _findRenderParagraph();
    final textLen = widget.page.text.length;
    if (anchor == null || paragraph == null || textLen == 0) return;
    final raw = _hitTestOffset(
      paragraph,
      details.globalPosition,
    ).clamp(0, textLen);
    var start = math.min(anchor, raw);
    var end = math.max(anchor, raw);
    if (start == end) {
      if (end < textLen) {
        end++;
      } else if (start > 0) {
        start--;
      }
    }
    if (start == _selStart && end == _selEnd) return;
    setState(() {
      _selStart = start;
      _selEnd = end;
    });
    _showOrUpdateToolbar();
  }

  void _updateHandle({required bool isStart, required Offset globalPosition}) {
    final paragraph = _findRenderParagraph();
    final curStart = _selStart;
    final curEnd = _selEnd;
    final textLen = widget.page.text.length;
    if (paragraph == null ||
        curStart == null ||
        curEnd == null ||
        textLen == 0) {
      return;
    }
    final offset = _hitTestOffset(paragraph, globalPosition).clamp(0, textLen);
    var nextStart = curStart;
    var nextEnd = curEnd;
    if (isStart) {
      if (offset < curEnd) {
        nextStart = offset;
      } else if (offset > curEnd) {
        nextStart = curEnd;
        nextEnd = offset;
      } else {
        nextStart = math.max(0, curEnd - 1);
      }
    } else {
      if (offset > curStart) {
        nextEnd = offset;
      } else if (offset < curStart) {
        nextEnd = curStart;
        nextStart = offset;
      } else {
        nextEnd = math.min(textLen, curStart + 1);
      }
    }
    if (nextStart == curStart && nextEnd == curEnd) return;
    setState(() {
      _selStart = nextStart;
      _selEnd = nextEnd;
    });
    _showOrUpdateToolbar();
  }

  void _showOrUpdateToolbar() {
    if (!mounted || !_hasSelection) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    if (_toolbarEntry == null) {
      _toolbarEntry = OverlayEntry(builder: _buildToolbarOverlay);
      overlay.insert(_toolbarEntry!);
    } else {
      _toolbarEntry!.markNeedsBuild();
    }
  }

  Widget _buildToolbarOverlay(BuildContext overlayContext) {
    final s = _selStart;
    final e = _selEnd;
    final paragraph = _findRenderParagraph();
    if (s == null || e == null || s >= e || paragraph == null) {
      return const SizedBox.shrink();
    }
    final boxes = _computeSelectionBoxes(paragraph);
    if (boxes.isEmpty) return const SizedBox.shrink();
    final firstBox = boxes.first;
    final lastBox = boxes.last;
    final anchorAbove = paragraph.localToGlobal(
      Offset((firstBox.left + firstBox.right) / 2, firstBox.top - 8),
    );
    final anchorBelow = paragraph.localToGlobal(
      Offset((lastBox.left + lastBox.right) / 2, lastBox.bottom + 34),
    );

    return EchoSelectionToolbar(
      anchors: TextSelectionToolbarAnchors(
        primaryAnchor: anchorAbove,
        secondaryAnchor: anchorBelow,
      ),
      selectedColor: widget.lastHighlightColor,
      onSelectColor: (color) {
        _clearSelection();
        widget.onQuickHighlight(widget.page, s, e, color);
      },
      onHighlight: () {
        _clearSelection();
        widget.onQuickHighlight(
          widget.page,
          s,
          e,
          widget.lastHighlightColor,
        );
      },
      onNote: () {
        _clearSelection();
        widget.onOpenNoteEditor(widget.page, s, e);
      },
      onCopy: () {
        final text = widget.page.text.substring(s, e);
        _clearSelection();
        unawaited(Clipboard.setData(ClipboardData(text: text)));
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('已复制所选文字')),
        );
      },
      onListenFromHere: widget.onListenFromSelection == null
          ? null
          : () {
              _clearSelection();
              widget.onListenFromSelection!(widget.page, s);
            },
    );
  }

  TapGestureRecognizer _recognizerFor(ReadingAnnotation ann) {
    final existing = _annotationRecognizers[ann.id];
    if (existing != null) {
      existing.onTap = () => widget.onTapAnnotation(ann);
      return existing;
    }
    final created = TapGestureRecognizer()
      ..onTap = () => widget.onTapAnnotation(ann);
    _annotationRecognizers[ann.id] = created;
    return created;
  }

  Widget _buildPageText(BuildContext context) {
    final segments = buildStyledPageSegments(
      page: widget.page,
      annotations: widget.annotations,
      activeCueSpan: widget.activeCueSpan,
    );

    final activeIds = <String>{
      for (final seg in segments)
        if (seg.annotation != null) seg.annotation!.id,
    };
    _annotationRecognizers.removeWhere((id, recognizer) {
      if (activeIds.contains(id)) return false;
      recognizer.dispose();
      return true;
    });

    if (segments.length <= 1 &&
        (segments.isEmpty ||
            (segments.first.annotation == null && !segments.first.isActiveCue))) {
      return Text(
        widget.page.text,
        key: Key('reader_page_text_${widget.index}'),
        style: widget.textStyle,
        textHeightBehavior: _kReaderTextHeightBehavior,
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text.rich(
      key: Key('reader_page_text_${widget.index}'),
      style: widget.textStyle,
      textHeightBehavior: _kReaderTextHeightBehavior,
      TextSpan(
        style: widget.textStyle,
        children: <InlineSpan>[
          for (final seg in segments)
            () {
              final ann = seg.annotation;
              var spanStyle = widget.textStyle;
              TapGestureRecognizer? recognizer;
              if (ann != null) {
                recognizer = _recognizerFor(ann);
                spanStyle = spanStyle.copyWith(
                  decoration: TextDecoration.underline,
                  decorationColor: ann.color.color,
                  decorationThickness: ann.hasNote ? 2.2 : 1.8,
                  decorationStyle: ann.hasNote
                      ? TextDecorationStyle.double
                      : TextDecorationStyle.solid,
                  backgroundColor: ann.color.color.withValues(
                    alpha: ann.hasNote
                        ? (isDark ? 0.22 : 0.24)
                        : (isDark ? 0.12 : 0.14),
                  ),
                );
              }
              if (seg.isActiveCue) {
                spanStyle = spanStyle.copyWith(
                  backgroundColor: widget.highlightColor,
                );
              }
              return TextSpan(
                text: seg.text,
                style: (ann != null || seg.isActiveCue) ? spanStyle : null,
                recognizer: recognizer,
              );
            }(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final boxes = _computeSelectionBoxes(_findRenderParagraph());
    final firstBox = boxes.isNotEmpty ? boxes.first : null;
    final lastBox = boxes.isNotEmpty ? boxes.last : null;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _hasSelection ? _clearSelection : null,
      onLongPressStart: _onLongPressStart,
      onLongPressMoveUpdate: _onLongPressMoveUpdate,
      onLongPressEnd: (_) {
        if (_hasSelection) _showOrUpdateToolbar();
      },
      child: Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          if (boxes.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _SelectionHighlightPainter(
                    boxes: boxes,
                    color: tokens.primary.withValues(
                      alpha: isDark ? 0.28 : 0.24,
                    ),
                    edgeColor: tokens.primary,
                  ),
                ),
              ),
            ),
          KeyedSubtree(key: _textKey, child: _buildPageText(context)),
          if (firstBox != null)
            Positioned(
              left: firstBox.left - 18,
              top: firstBox.bottom - 4,
              child: _SelectionHandle(
                handleKey: const Key('reader_selection_handle_start'),
                color: tokens.primary,
                isStart: true,
                onDragUpdate: (d) => _updateHandle(
                  isStart: true,
                  globalPosition: d.globalPosition,
                ),
              ),
            ),
          if (lastBox != null)
            Positioned(
              left: lastBox.right - 18,
              top: lastBox.bottom - 4,
              child: _SelectionHandle(
                handleKey: const Key('reader_selection_handle_end'),
                color: tokens.primary,
                isStart: false,
                onDragUpdate: (d) => _updateHandle(
                  isStart: false,
                  globalPosition: d.globalPosition,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SelectionHighlightPainter extends CustomPainter {
  const _SelectionHighlightPainter({
    required this.boxes,
    required this.color,
    required this.edgeColor,
  });

  final List<TextBox> boxes;
  final Color color;
  final Color edgeColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (boxes.isEmpty) return;
    final fillPaint = Paint()..color = color;
    final edgePaint = Paint()
      ..color = edgeColor.withValues(alpha: 0.75)
      ..strokeWidth = 1.6;
    for (final box in boxes) {
      final rect = box.toRect();
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        fillPaint,
      );
      canvas.drawLine(rect.bottomLeft, rect.bottomRight, edgePaint);
    }
    final firstRect = boxes.first.toRect();
    final lastRect = boxes.last.toRect();
    canvas.drawLine(firstRect.topLeft, firstRect.bottomLeft, edgePaint);
    canvas.drawLine(lastRect.topRight, lastRect.bottomRight, edgePaint);
  }

  @override
  bool shouldRepaint(_SelectionHighlightPainter oldDelegate) =>
      oldDelegate.boxes != boxes ||
      oldDelegate.color != color ||
      oldDelegate.edgeColor != edgeColor;
}

class _SelectionHandle extends StatelessWidget {
  const _SelectionHandle({
    required this.handleKey,
    required this.color,
    required this.isStart,
    required this.onDragUpdate,
  });

  final Key handleKey;
  final Color color;
  final bool isStart;
  final GestureDragUpdateCallback onDragUpdate;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: handleKey,
      behavior: HitTestBehavior.opaque,
      onPanUpdate: onDragUpdate,
      child: SizedBox(
        width: 36,
        height: 36,
        child: Center(
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.only(
                topLeft: isStart ? const Radius.circular(7) : Radius.zero,
                topRight: isStart ? Radius.zero : const Radius.circular(7),
                bottomLeft: const Radius.circular(7),
                bottomRight: const Radius.circular(7),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 兼容旧引用名。
typedef ReaderPageWidget = ReaderPageView;
