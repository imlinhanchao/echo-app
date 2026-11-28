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
import '../../core/translation/bilingual_phrase_aligner.dart';
import '../../core/translation/language_detector.dart';
import '../../core/translation/translation_cache_store.dart';
import '../../core/translation/translation_model_manager.dart';
import '../../core/translation/translation_models.dart';
import '../../core/translation/translation_scheduler.dart';
import '../../core/tts/sentence_splitter.dart';
import '../../core/tts/tts_model_manager.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_glass.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../library/library_controller.dart';
import '../player/playback_speed_sheet.dart';
import '../player/player_sheet.dart' show openPlayer;
import '../settings/translation_model_page.dart';
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

@immutable
class _ReaderPalette {
  const _ReaderPalette({
    required this.bg,
    required this.fg,
    required this.secondary,
    required this.chromeBg,
    required this.hairline,
    required this.accent,
    required this.onAccent,
    required this.isDarkSurface,
  });

  final Color bg;
  final Color fg;
  final Color secondary;
  final Color chromeBg;
  final Color hairline;
  final Color accent;
  final Color onAccent;
  final bool isDarkSurface;
}

const TextHeightBehavior _kReaderTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: true,
  applyHeightToLastDescent: true,
);

class _ReaderPageState extends ConsumerState<ReaderPageView>
    with SingleTickerProviderStateMixin {
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

  /// 阅读沉浸态控制：默认隐藏工具栏，点击正文后显露工具栏并隐藏章节/页码信息。
  bool _chromeVisible = false;
  late final AnimationController _chromeController;

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
  bool _isUserDragging = false;
  bool _scrollStartedAtStart = false;
  bool _scrollStartedAtEnd = false;
  bool _deferredRepaginateAfterDrag = false;
  bool _deferredRepaginateImmediate = false;
  bool _hasTextSelection = false;
  ReadingHighlightColor _lastHighlightColor = ReadingHighlightColor.gold;

  /// 已处理过的离线字幕/实时朗读位置，防止重复触发翻页。
  String? _lastAutoPagedCue;
  int _lastSyncedLiveChapter = -1;
  int _lastSyncedLiveSentence = -1;

  late final ScreenKeepAliveService _screenKeepAlive;

  BilingualDisplayMode _displayMode = BilingualDisplayMode.original;
  bool _showForeignBanner = false;
  bool _dismissedForeignPrompt = false;
  Timer? _bilingualRepaginateDebounce;
  Timer? _nextChapterPrewarmTimer;
  int _prewarmGen = 0;
  final Map<int, List<ParagraphSegment>> _chapterParagraphsCache =
      <int, List<ParagraphSegment>>{};
  Map<String, String> _lastObservedChapterTranslations =
      const <String, String>{};
  final Set<String> _alignmentInFlightIds = <String>{};
  final Set<String> _alignmentSessionDoneIds = <String>{};

  @override
  void initState() {
    super.initState();
    _chromeController = AnimationController(
      vsync: this,
      duration: EchoMetrics.motionBase,
      reverseDuration: EchoMetrics.motionFast,
      value: 0.0,
    );
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
      unawaited(_initBookTranslationPrefs());
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
    _prewarmGen++;
    _bilingualRepaginateDebounce?.cancel();
    _nextChapterPrewarmTimer?.cancel();
    unawaited(_screenKeepAlive.setEnabled(false));
    _chromeController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _setChromeVisible(bool visible) {
    if (!mounted || visible == _chromeVisible) return;
    setState(() => _chromeVisible = visible);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      _chromeController.value = visible ? 1.0 : 0.0;
    } else if (visible) {
      _chromeController.forward();
    } else {
      _chromeController.reverse();
    }
  }

  void _toggleChrome() {
    _setChromeVisible(!_chromeVisible);
  }

  List<ParagraphSegment> _paragraphsForChapter(ChapterPreview chapter) {
    return _chapterParagraphsCache.putIfAbsent(
      chapter.index,
      () => splitChapterSentences(chapter.text),
    );
  }

  Future<void> _initBookTranslationPrefs() async {
    if (!mounted || _chapters.isEmpty) return;
    final cacheStore = ref.read(translationCacheStoreProvider);
    final prefs = await cacheStore.readBookPrefs(widget.book.id);
    if (!mounted) return;

    final targetLang = TranslationTargetLanguage.fromCode(
      ref.read(standaloneConfigProvider).translationTargetLang,
    );
    final samples = _chapters
        .take(2)
        .map((c) => c.text)
        .where((t) => t.trim().isNotEmpty)
        .toList(growable: false);
    final isForeign = isForeignBookForTarget(samples, targetLang);

    final effectiveMode = prefs.displayMode;
    final shouldShowBanner =
        isForeign &&
        !prefs.dismissedForeignPrompt &&
        effectiveMode == BilingualDisplayMode.original;

    final modeChanged = effectiveMode != _displayMode;
    setState(() {
      _displayMode = effectiveMode;
      _dismissedForeignPrompt = prefs.dismissedForeignPrompt;
      _showForeignBanner = shouldShowBanner;
      if (modeChanged) {
        _layoutSize = null;
      }
    });

    if (effectiveMode != BilingualDisplayMode.original) {
      final arrayIdx = _currentChapterArrayIdx();
      final ch = _chapters[arrayIdx];
      await ref
          .read(translationSchedulerProvider.notifier)
          .ensureChapterLoaded(bookId: widget.book.id, chapterIndex: ch.index);
      if (mounted && _layoutSize != null) {
        final tokens = Theme.of(context).extension<EchoTokens>()!;
        unawaited(_paginateCurrentChapter(_layoutSize!, tokens));
      }
    }
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

  _ReaderPalette _themeColors(EchoTokens tokens) => switch (_readerTheme) {
    _ReaderTheme.warmDark => _ReaderPalette(
      bg: tokens.paperWarm,
      fg: tokens.paperText,
      secondary: tokens.textSecondary,
      chromeBg: Color.lerp(tokens.surfaceElevated, tokens.paperWarm, 0.15)!,
      hairline: Colors.white.withValues(alpha: 0.09),
      accent: const Color(0xFFD4AE74),
      onAccent: const Color(0xFF14120F),
      isDarkSurface: true,
    ),
    _ReaderTheme.pureBlack => _ReaderPalette(
      bg: const Color(0xFF000000),
      fg: const Color(0xFFE6E4DE),
      secondary: const Color(0xFF9A9791),
      chromeBg: const Color(0xFF141416),
      hairline: Colors.white.withValues(alpha: 0.09),
      accent: const Color(0xFFD4AE74),
      onAccent: const Color(0xFF14120F),
      isDarkSurface: true,
    ),
    _ReaderTheme.lightPaper => _ReaderPalette(
      bg: const Color(0xFFF6F1E7),
      fg: const Color(0xFF1E1B18),
      secondary: const Color(0xFF6B655D),
      chromeBg: const Color(0xFFFDFBF7),
      hairline: const Color(0xFF1E1B18).withValues(alpha: 0.09),
      accent: const Color(0xFF8F6836),
      onAccent: const Color(0xFFFDFBF7),
      isDarkSurface: false,
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
      unawaited(_initBookTranslationPrefs());
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _onLayoutSizeChanged(Size size, EchoTokens tokens) async {
    if (!mounted) return;
    if (_layoutSize != null &&
        (_layoutSize!.width - size.width).abs() <= 0.5 &&
        (_layoutSize!.height - size.height).abs() <= 0.5) {
      return;
    }
    await _paginateCurrentChapter(size, tokens);
  }

  /// 按当前章 + 当前版心尺寸懒分页（原文/双语均走 LRU 缓存；双语/仅译文按段落对照排版并锚定原文偏移防跳页）。
  Future<void> _paginateCurrentChapter(
    Size size,
    EchoTokens tokens, {
    bool jumpToLastPage = false,
    bool triggerEnqueue = true,
    bool keepPageAnchor = false,
  }) async {
    if (_chapters.isEmpty) return;
    final useLastPage = jumpToLastPage || _pendingJumpToLastPage;
    _layoutSize = size;
    final gen = ++_paginationGen;
    try {
      final style = DefaultTextStyle.of(context).style.merge(_textStyle(tokens));
      final textScaler = MediaQuery.textScalerOf(context);
      final locale = Localizations.maybeLocaleOf(context);
      final textScaleFactor = textScaler.scale(10.0) / 10.0;

      final arrayIdx = _currentChapterArrayIdx();
      final targetChapter = _chapters[arrayIdx];
      final chapterTitle = targetChapter.title.isNotEmpty
          ? targetChapter.title
          : '第 ${arrayIdx + 1} 章';

      final currentVisibleStart =
          (_currentPage >= 0 && _currentPage < _pages.length)
              ? _pages[_currentPage].startChar
              : _charOffset;
      final shouldKeepAnchor = keepPageAnchor &&
          !useLastPage &&
          !_switchingChapter &&
          _pages.isNotEmpty &&
          _pages.first.chapterIndex == targetChapter.index;
      final int? anchorCharOffset =
          (shouldKeepAnchor && currentVisibleStart > 0)
              ? currentVisibleStart
              : null;

      List<ReaderPage>? pages;
      List<ParagraphSegment>? chapterSegs;
      var activeHashes = const <String>{};

      if (_displayMode == BilingualDisplayMode.original) {
        final cacheKey = ChapterPaginationKey(
          bookId: widget.book.id,
          chapterIndex: targetChapter.index,
          maxWidth: size.width,
          maxHeight: size.height,
          fontSize: _fontSize,
          lineHeight: _lineHeight,
          textScaleFactor: textScaleFactor,
        );

        pages = ChapterPaginationCache.instance.get(cacheKey);
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
      } else {
        chapterSegs = _paragraphsForChapter(targetChapter);
        final scheduler = ref.read(translationSchedulerProvider.notifier);
        final cfg = ref.read(standaloneConfigProvider);
        final translationsMap = await scheduler.ensureChapterLoaded(
          bookId: widget.book.id,
          chapterIndex: targetChapter.index,
          targetLangCode: cfg.translationTargetLang,
          modelId: cfg.activeTranslationModelId,
        );
        if (!mounted || gen != _paginationGen) return;
        _lastObservedChapterTranslations = translationsMap;

        final schedState = ref.read(translationSchedulerProvider);
        final chapterKeyPrefix =
            '${widget.book.id}::${targetChapter.index}::${cfg.translationTargetLang}::'
            '${cfg.activeTranslationModelId.isEmpty ? "default" : cfg.activeTranslationModelId}::';
        activeHashes = <String>{
          for (final k in schedState.activeParagraphKeys)
            if (k.startsWith(chapterKeyPrefix))
              k.substring(chapterKeyPrefix.length),
        };

        final sig = computeBilingualPaginationSignature(
          segments: chapterSegs,
          translationsByHash: translationsMap,
        );
        final biCacheKey = BilingualChapterPaginationKey(
          bookId: widget.book.id,
          chapterIndex: targetChapter.index,
          mode: _displayMode,
          maxWidth: size.width,
          maxHeight: size.height,
          fontSize: _fontSize,
          lineHeight: _lineHeight,
          textScaleFactor: textScaleFactor,
          sigA: sig.sigA,
          sigB: sig.sigB,
          translatedCount: sig.translatedCount,
          anchorCharOffset: anchorCharOffset ?? -1,
        );

        pages = BilingualChapterPaginationCache.instance.get(biCacheKey);
        if (pages == null) {
          pages = await paginateBilingualChapterBySizeAsync(
            chapterIndex: targetChapter.index,
            chapterTitle: chapterTitle,
            segments: chapterSegs,
            translationsByHash: translationsMap,
            activeTranslatingHashes: const <String>{},
            mode: _displayMode,
            style: style,
            secondaryColor: _themeColors(tokens).secondary,
            textScaler: textScaler,
            maxWidth: size.width,
            maxHeight: size.height,
            locale: locale,
            textHeightBehavior: _kReaderTextHeightBehavior,
            isCancelled: () => !mounted || gen != _paginationGen,
            anchorCharOffset: anchorCharOffset,
          );
          if (!mounted || gen != _paginationGen) return;
          if (pages.isNotEmpty) {
            BilingualChapterPaginationCache.instance.put(biCacheKey, pages);
          }
        }
      }

      if (!mounted || gen != _paginationGen || pages.isEmpty) return;

      final lookupOffset = shouldKeepAnchor ? currentVisibleStart : _charOffset;
      final targetPage = useLastPage
          ? pages.length - 1
          : pageIndexForOffset(pages, targetChapter.index, lookupOffset);

      final reuseController =
          _pageController.hasClients &&
          targetPage == _currentPage &&
          !_switchingChapter;

      if (reuseController) {
        setState(() {
          _pages = pages!;
          _currentPage = targetPage;
          _chapterIndex = targetChapter.index;
          if (useLastPage) {
            _charOffset = pages[targetPage].startChar;
          }
          _pendingJumpToLastPage = false;
          _switchingChapter = false;
        });
      } else {
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
          _pendingJumpToLastPage = false;
          _switchingChapter = false;
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          oldController.dispose();
        });
      }

      if (_displayMode != BilingualDisplayMode.original && chapterSegs != null) {
        final schedState = ref.read(translationSchedulerProvider);
        final targetBlocks =
            pages[targetPage].blocks ?? const <BilingualPageBlock>[];
        final shouldEnqueue = triggerEnqueue ||
            (schedState.lastError == null &&
                targetBlocks.any(
                  (b) =>
                      !b.hasTranslation &&
                      !activeHashes.contains(b.paragraphHash),
                ));
        if (shouldEnqueue) {
          unawaited(
            _enqueueTranslationForPage(
              targetPage,
              pages,
              chapterSegs,
              targetChapter.index,
            ),
          );
        }
        if (targetPage >= pages.length - 2) {
          _scheduleNextChapterPrewarm();
        }
      }
      if (_displayMode == BilingualDisplayMode.bilingual && mounted) {
        _schedulePhraseAlignmentForCurrentPage(
          ref.read(bookAnnotationsProvider(widget.book.id)),
        );
      }
    } finally {
      if (mounted && gen == _paginationGen && _switchingChapter) {
        setState(() => _switchingChapter = false);
      }
    }
  }

  /// 在接近本章末尾时于后台提前预载并预排版下一章的双语分页缓存，确保尾页向下翻章瞬间切换不卡顿。
  void _scheduleNextChapterPrewarm() {
    if (!mounted ||
        _displayMode == BilingualDisplayMode.original ||
        _switchingChapter ||
        _layoutSize == null) {
      return;
    }
    final nextArrayIdx = _currentChapterArrayIdx() + 1;
    if (nextArrayIdx >= _chapters.length) return;
    final size = _layoutSize!;
    final targetMode = _displayMode;
    final targetChapter = _chapters[nextArrayIdx];
    final chapterTitle = targetChapter.title.isNotEmpty
        ? targetChapter.title
        : '第 ${nextArrayIdx + 1} 章';

    _nextChapterPrewarmTimer?.cancel();
    final prewarmGen = ++_prewarmGen;
    _nextChapterPrewarmTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(() async {
        if (!mounted ||
            prewarmGen != _prewarmGen ||
            _switchingChapter ||
            _displayMode != targetMode ||
            _displayMode == BilingualDisplayMode.original) {
          return;
        }
        final tokens = Theme.of(context).extension<EchoTokens>();
        if (tokens == null) return;
        final style = DefaultTextStyle.of(context).style.merge(_textStyle(tokens));
        final textScaler = MediaQuery.textScalerOf(context);
        final locale = Localizations.maybeLocaleOf(context);
        final textScaleFactor = textScaler.scale(10.0) / 10.0;
        final secondaryColor = _themeColors(tokens).secondary;
        final cfg = ref.read(standaloneConfigProvider);
        final scheduler = ref.read(translationSchedulerProvider.notifier);

        final segs = _paragraphsForChapter(targetChapter);
        final translationsMap = await scheduler.ensureChapterLoaded(
          bookId: widget.book.id,
          chapterIndex: targetChapter.index,
          targetLangCode: cfg.translationTargetLang,
          modelId: cfg.activeTranslationModelId,
        );
        if (!mounted ||
            prewarmGen != _prewarmGen ||
            _switchingChapter ||
            _displayMode != targetMode) {
          return;
        }

        final sig = computeBilingualPaginationSignature(
          segments: segs,
          translationsByHash: translationsMap,
        );
        final nextKey = BilingualChapterPaginationKey(
          bookId: widget.book.id,
          chapterIndex: targetChapter.index,
          mode: targetMode,
          maxWidth: size.width,
          maxHeight: size.height,
          fontSize: _fontSize,
          lineHeight: _lineHeight,
          textScaleFactor: textScaleFactor,
          sigA: sig.sigA,
          sigB: sig.sigB,
          translatedCount: sig.translatedCount,
        );
        if (BilingualChapterPaginationCache.instance.get(nextKey) != null) {
          return;
        }

        final pages = await paginateBilingualChapterBySizeAsync(
          chapterIndex: targetChapter.index,
          chapterTitle: chapterTitle,
          segments: segs,
          translationsByHash: translationsMap,
          activeTranslatingHashes: const <String>{},
          mode: targetMode,
          style: style,
          secondaryColor: secondaryColor,
          textScaler: textScaler,
          maxWidth: size.width,
          maxHeight: size.height,
          locale: locale,
          textHeightBehavior: _kReaderTextHeightBehavior,
          isCancelled: () =>
              !mounted ||
              prewarmGen != _prewarmGen ||
              _switchingChapter ||
              _displayMode != targetMode,
        );
        if (!mounted ||
            prewarmGen != _prewarmGen ||
            _switchingChapter ||
            _displayMode != targetMode ||
            pages.isEmpty) {
          return;
        }
        BilingualChapterPaginationCache.instance.put(nextKey, pages);
      }());
    });
  }

  Future<void> _enqueueTranslationForPage(
    int pageIndex,
    List<ReaderPage> pages,
    List<ParagraphSegment> chapterSegs,
    int chapterIndex,
  ) async {
    if (!mounted || pageIndex < 0 || pageIndex >= pages.length) return;
    final page = pages[pageIndex];
    final blocks = page.blocks;
    if (blocks == null || blocks.isEmpty) return;
    final seen = <int>{};
    final visibleSegs = <ParagraphSegment>[];
    for (final b in blocks) {
      if (b.paragraphIndex >= 0 &&
          b.paragraphIndex < chapterSegs.length &&
          seen.add(b.paragraphIndex)) {
        visibleSegs.add(chapterSegs[b.paragraphIndex]);
      }
    }
    await ref
        .read(translationSchedulerProvider.notifier)
        .enqueuePageAndPrefetch(
          bookId: widget.book.id,
          chapterIndex: chapterIndex,
          visibleSegments: visibleSegs,
          chapterSegments: chapterSegs,
        );
  }

  void _scheduleBilingualRepaginate({
    required bool immediate,
    Duration debounce = const Duration(milliseconds: 350),
    bool triggerEnqueue = true,
  }) {
    if (_isUserDragging) {
      _deferredRepaginateAfterDrag = true;
      _deferredRepaginateImmediate = _deferredRepaginateImmediate || immediate;
      return;
    }
    _bilingualRepaginateDebounce?.cancel();
    if (!mounted ||
        _layoutSize == null ||
        _displayMode == BilingualDisplayMode.original) {
      return;
    }
    void run() {
      if (!mounted ||
          _layoutSize == null ||
          _displayMode == BilingualDisplayMode.original) {
        return;
      }
      final tokens = Theme.of(context).extension<EchoTokens>();
      if (tokens == null) return;
      unawaited(
        _paginateCurrentChapter(
          _layoutSize!,
          tokens,
          triggerEnqueue: triggerEnqueue,
          keepPageAnchor: true,
        ),
      );
    }

    _bilingualRepaginateDebounce = Timer(
      immediate ? Duration.zero : debounce,
      run,
    );
  }

  Future<void> _switchDisplayMode(BilingualDisplayMode nextMode) async {
    if (nextMode != BilingualDisplayMode.original) {
      final modelPath = await ref
          .read(translationModelManagerProvider.notifier)
          .ensureInitializedAndGetActiveModelPath();
      if (!mounted) return;
      if (modelPath == null || modelPath.isEmpty) {
        final goDownload = await showDialog<bool>(
          context: context,
          builder: (dCtx) => AlertDialog(
            title: const Text('需先下载离线翻译模型'),
            content: const Text(
              '双语翻译完全在手机本地离线运行。推荐下载腾讯 HY-MT1.5-1.8B 1.25-bit 模型（约 440MB），是否立即前往下载或导入？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dCtx).pop(false),
                child: const Text('稍后再说'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dCtx).pop(true),
                child: const Text('去模型管理'),
              ),
            ],
          ),
        );
        if (goDownload == true && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const TranslationModelPage(),
            ),
          );
          if (!mounted) return;
          final readyAfter = await ref
              .read(translationModelManagerProvider.notifier)
              .ensureInitializedAndGetActiveModelPath();
          if (!mounted) return;
          if (readyAfter == null || readyAfter.isEmpty) return;
        } else {
          return;
        }
      }
    }

    final cacheStore = ref.read(translationCacheStoreProvider);
    await cacheStore.writeBookPrefs(
      widget.book.id,
      BookTranslationPrefs(
        displayMode: nextMode,
        dismissedForeignPrompt: _dismissedForeignPrompt,
      ),
    );
    if (!mounted) return;

    _bilingualRepaginateDebounce?.cancel();
    _nextChapterPrewarmTimer?.cancel();
    _prewarmGen++;
    if (nextMode == BilingualDisplayMode.original) {
      ref.read(translationSchedulerProvider.notifier).pauseLiveQueue();
    }

    setState(() {
      _isUserDragging = false;
      _scrollStartedAtStart = false;
      _scrollStartedAtEnd = false;
      _deferredRepaginateAfterDrag = false;
      _deferredRepaginateImmediate = false;
      _displayMode = nextMode;
      if (nextMode != BilingualDisplayMode.original) {
        _showForeignBanner = false;
      }
      _layoutSize = null;
    });

    final liveState = ref.read(liveTtsPlayerProvider);
    if (liveState.hasBook && liveState.book?.id == widget.book.id) {
      unawaited(
        ref
            .read(liveTtsPlayerProvider.notifier)
            .setSpeakTranslated(nextMode != BilingualDisplayMode.original),
      );
    }
  }

  Future<void> _dismissForeignBanner() async {
    setState(() {
      _showForeignBanner = false;
      _dismissedForeignPrompt = true;
    });
    await ref.read(translationCacheStoreProvider).writeBookPrefs(
      widget.book.id,
      BookTranslationPrefs(
        displayMode: _displayMode,
        dismissedForeignPrompt: true,
      ),
    );
  }

  void _jumpToChapterArrayIndex(
    int arrayIdx, {
    int charOffset = 0,
    bool jumpToLastPage = false,
  }) {
    if (arrayIdx < 0 || arrayIdx >= _chapters.length) return;
    final chapter = _chapters[arrayIdx];
    _bilingualRepaginateDebounce?.cancel();
    _nextChapterPrewarmTimer?.cancel();
    _prewarmGen++;
    _isUserDragging = false;
    _scrollStartedAtStart = false;
    _scrollStartedAtEnd = false;
    _deferredRepaginateAfterDrag = false;
    _deferredRepaginateImmediate = false;
    _lastObservedChapterTranslations = const <String, String>{};

    setState(() {
      _switchingChapter = true;
      _overscrollDelta = 0.0;
      _chapterIndex = chapter.index;
      _charOffset = charOffset;
      _pendingJumpToLastPage = jumpToLastPage;
    });

    // 切章时立刻释放旧章占用的本地翻译算力，避免后台推理与新章分页抢占 CPU
    if (_displayMode != BilingualDisplayMode.original) {
      ref.read(translationSchedulerProvider.notifier).pauseLiveQueue();
    }
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
                      _setChromeVisible(false);
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

    if (_displayMode != BilingualDisplayMode.original && _chapters.isNotEmpty) {
      final ch = _chapters[_findChapterArrayIdx(_chapters, page.chapterIndex)];
      unawaited(
        _enqueueTranslationForPage(
          index,
          _pages,
          _paragraphsForChapter(ch),
          ch.index,
        ),
      );
      if (index >= _pages.length - 2) {
        _scheduleNextChapterPrewarm();
      }
      if (_displayMode == BilingualDisplayMode.bilingual && mounted) {
        _schedulePhraseAlignmentForCurrentPage(
          ref.read(bookAnnotationsProvider(widget.book.id)),
        );
      }
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _isUserDragging = notification.dragDetails != null;
      if (_isUserDragging && _chromeVisible) {
        _setChromeVisible(false);
      }
      _overscrollDelta = 0.0;
      final metrics = notification.metrics;
      _scrollStartedAtStart = metrics.pixels <= metrics.minScrollExtent + 1.0;
      _scrollStartedAtEnd = metrics.pixels >= metrics.maxScrollExtent - 1.0;
      return false;
    }
    if (!_isUserDragging &&
        ((notification is ScrollUpdateNotification &&
                notification.dragDetails != null) ||
            (notification is OverscrollNotification &&
                notification.dragDetails != null))) {
      _isUserDragging = true;
      final metrics = notification.metrics;
      _scrollStartedAtStart = metrics.pixels <= metrics.minScrollExtent + 1.0;
      _scrollStartedAtEnd = metrics.pixels >= metrics.maxScrollExtent - 1.0;
    }
    if (notification is ScrollEndNotification) {
      final wasDragging = _isUserDragging;
      final startedAtStart = _scrollStartedAtStart;
      final startedAtEnd = _scrollStartedAtEnd;
      final overscroll = _overscrollDelta;
      final primaryVelocity = notification.dragDetails?.primaryVelocity ?? 0.0;
      _isUserDragging = false;
      _overscrollDelta = 0.0;
      _scrollStartedAtStart = false;
      _scrollStartedAtEnd = false;

      if (wasDragging && !_switchingChapter && _chapters.length > 1) {
        final arrayIdx = _currentChapterArrayIdx();
        // 尾页向左快划或拖过阈值跳下一章；首页向右快划或拖过阈值跳上一章末页
        final forwardFlick = startedAtEnd &&
            ((overscroll >= 6.0 && primaryVelocity <= -240.0) ||
                (overscroll >= 0.0 && primaryVelocity <= -450.0));
        final backwardFlick = startedAtStart &&
            ((overscroll <= -6.0 && primaryVelocity >= 240.0) ||
                (overscroll <= 0.0 && primaryVelocity >= 450.0));
        if (forwardFlick && arrayIdx + 1 < _chapters.length) {
          _jumpToChapterArrayIndex(arrayIdx + 1);
          return false;
        }
        if (backwardFlick && arrayIdx > 0) {
          _jumpToChapterArrayIndex(arrayIdx - 1, jumpToLastPage: true);
          return false;
        }
      }

      if (_deferredRepaginateAfterDrag && !_switchingChapter) {
        final immediate = _deferredRepaginateImmediate;
        _deferredRepaginateAfterDrag = false;
        _deferredRepaginateImmediate = false;
        _scheduleBilingualRepaginate(
          immediate: immediate,
          triggerEnqueue: false,
        );
      }
      return false;
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        !_switchingChapter &&
        _chapters.length > 1) {
      _overscrollDelta += notification.overscroll;
      final arrayIdx = _currentChapterArrayIdx();
      final forwardThreshold = _scrollStartedAtEnd ? 32.0 : 64.0;
      final backwardThreshold = _scrollStartedAtStart ? 32.0 : 64.0;
      if (_overscrollDelta >= forwardThreshold &&
          arrayIdx + 1 < _chapters.length) {
        _jumpToChapterArrayIndex(arrayIdx + 1);
      } else if (_overscrollDelta <= -backwardThreshold && arrayIdx > 0) {
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

  Widget _themeSwatchAvatar(Color bg, Color border) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(color: border.withValues(alpha: 0.45), width: 1),
      ),
    );
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
                        avatar: _themeSwatchAvatar(tokens.paperWarm, tokens.paperText),
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
                        avatar: _themeSwatchAvatar(
                          const Color(0xFF000000),
                          const Color(0xFFE6E4DE),
                        ),
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
                        avatar: _themeSwatchAvatar(
                          const Color(0xFFF6F1E7),
                          const Color(0xFF1E1B18),
                        ),
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

  /// 翻译与双语对照控制面板（三态切换 / 目标语种 / 预翻译 / 模型管理）。
  void _showTranslationSheet() {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => Consumer(
        builder: (sheetCtx, sheetRef, _) {
          final textTheme = Theme.of(sheetCtx).textTheme;
          final cfg = sheetRef.watch(standaloneConfigProvider);
          final mtState = sheetRef.watch(translationModelManagerProvider);
          final schedState = sheetRef.watch(translationSchedulerProvider);
          final targetLang =
              TranslationTargetLanguage.fromCode(cfg.translationTargetLang);
          final activeEntry = mtState.activeEntry;
          final modelReady =
              mtState.activeModelPath != null &&
              mtState.activeModelPath!.isNotEmpty;

          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                key: const Key('reader_translation_sheet'),
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
                    Row(
                      children: [
                        Icon(
                          Icons.translate_rounded,
                          color: tokens.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '离线双语阅读（HY-MT1.5）',
                            style: textTheme.titleMedium?.copyWith(
                              color: tokens.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: EchoMetrics.space2),
                    Text(
                      '显示模式',
                      style: textTheme.labelMedium?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          key: const Key('reader_mode_original'),
                          label: const Text('原文'),
                          selected:
                              _displayMode == BilingualDisplayMode.original,
                          onSelected: (_) {
                            Navigator.of(sheetCtx).pop();
                            unawaited(
                              _switchDisplayMode(BilingualDisplayMode.original),
                            );
                          },
                        ),
                        ChoiceChip(
                          key: const Key('reader_mode_bilingual'),
                          label: const Text('双语对照'),
                          selected:
                              _displayMode == BilingualDisplayMode.bilingual,
                          onSelected: (_) {
                            Navigator.of(sheetCtx).pop();
                            unawaited(
                              _switchDisplayMode(
                                BilingualDisplayMode.bilingual,
                              ),
                            );
                          },
                        ),
                        ChoiceChip(
                          key: const Key('reader_mode_translatedOnly'),
                          label: const Text('仅译文'),
                          selected:
                              _displayMode ==
                              BilingualDisplayMode.translatedOnly,
                          onSelected: (_) {
                            Navigator.of(sheetCtx).pop();
                            unawaited(
                              _switchDisplayMode(
                                BilingualDisplayMode.translatedOnly,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: EchoMetrics.space2),
                    Text(
                      '翻译目标语言',
                      style: textTheme.labelMedium?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final lang in TranslationTargetLanguage.values)
                          ChoiceChip(
                            key: Key('reader_target_lang_${lang.code}'),
                            label: Text(lang.label),
                            selected: targetLang == lang,
                            onSelected: (_) async {
                              if (lang == targetLang) return;
                              await ref
                                  .read(standaloneConfigProvider.notifier)
                                  .setTranslationTargetLang(lang.code);
                              if (mounted &&
                                  _displayMode !=
                                      BilingualDisplayMode.original) {
                                _scheduleBilingualRepaginate(immediate: true);
                              }
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: EchoMetrics.space2),
                    if (schedState.pretranslateRunning) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: tokens.surfaceSubtle,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  schedState.pretranslateTitle,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: tokens.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '${schedState.pretranslateCompleted}/${schedState.pretranslateTotal}',
                                  style: textTheme.labelSmall?.copyWith(
                                    color: tokens.primary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: schedState.pretranslateTotal > 0
                                  ? schedState.pretranslateCompleted /
                                        schedState.pretranslateTotal
                                  : null,
                              color: tokens.primary,
                              backgroundColor: tokens.surfaceBase,
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                key: const Key(
                                  'reader_cancel_pretranslate_button',
                                ),
                                onPressed: () => unawaited(
                                  ref
                                      .read(
                                        translationSchedulerProvider.notifier,
                                      )
                                      .cancelPretranslate(),
                                ),
                                child: Text(
                                  '取消预翻译',
                                  style: TextStyle(color: tokens.error),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      Row(
                        children: [
                          Expanded(
                            child: EchoSecondaryButton(
                              key: const Key(
                                'reader_pretranslate_chapter_button',
                              ),
                              label: '预翻译本章',
                              icon: Icons.article_outlined,
                              onPressed: _chapters.isEmpty
                                  ? null
                                  : () async {
                                      if (!modelReady) {
                                        Navigator.of(sheetCtx).pop();
                                        unawaited(
                                          _switchDisplayMode(
                                            BilingualDisplayMode.bilingual,
                                          ),
                                        );
                                        return;
                                      }
                                      final cur =
                                          _chapters[_currentChapterArrayIdx()];
                                      Navigator.of(sheetCtx).pop();
                                      await ref
                                          .read(
                                            translationSchedulerProvider
                                                .notifier,
                                          )
                                          .startPretranslate(
                                            bookId: widget.book.id,
                                            bookTitle: widget.book.title,
                                            chapterIndices: <int>[cur.index],
                                            loadChapterContent: (idx) async {
                                              final arr = _findChapterArrayIdx(
                                                _chapters,
                                                idx,
                                              );
                                              return _chapters[arr].text;
                                            },
                                          );
                                    },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: EchoSecondaryButton(
                              key: const Key('reader_pretranslate_book_button'),
                              label: '预翻译整书',
                              icon: Icons.auto_stories_outlined,
                              onPressed: _chapters.isEmpty
                                  ? null
                                  : () async {
                                      if (!modelReady) {
                                        Navigator.of(sheetCtx).pop();
                                        unawaited(
                                          _switchDisplayMode(
                                            BilingualDisplayMode.bilingual,
                                          ),
                                        );
                                        return;
                                      }
                                      final startArr = _currentChapterArrayIdx();
                                      final indices = <int>[
                                        for (
                                          var i = startArr;
                                          i < _chapters.length;
                                          i++
                                        )
                                          _chapters[i].index,
                                        for (var i = 0; i < startArr; i++)
                                          _chapters[i].index,
                                      ];
                                      Navigator.of(sheetCtx).pop();
                                      await ref
                                          .read(
                                            translationSchedulerProvider
                                                .notifier,
                                          )
                                          .startPretranslate(
                                            bookId: widget.book.id,
                                            bookTitle: widget.book.title,
                                            chapterIndices: indices,
                                            loadChapterContent: (idx) async {
                                              final arr = _findChapterArrayIdx(
                                                _chapters,
                                                idx,
                                              );
                                              return _chapters[arr].text;
                                            },
                                          );
                                    },
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    if (schedState.lastError != null &&
                        schedState.lastError!.isNotEmpty) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: tokens.error.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: tokens.error.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          schedState.lastError!,
                          style: textTheme.bodySmall?.copyWith(
                            color: tokens.error,
                          ),
                        ),
                      ),
                    ],
                    ListTile(
                      key: const Key('reader_translation_model_entry'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        modelReady
                            ? Icons.check_circle_outline_rounded
                            : Icons.download_for_offline_outlined,
                        color: modelReady ? tokens.success : tokens.primary,
                      ),
                      title: Text(
                        modelReady && activeEntry != null
                            ? activeEntry.spec.name
                            : '管理离线翻译模型（HY-MT1.5）',
                        style: textTheme.bodyMedium?.copyWith(
                          color: tokens.textPrimary,
                        ),
                      ),
                      subtitle: Text(
                        modelReady ? '端侧模型已就绪 · 点击切换或清理缓存' : '尚未下载模型（推荐 440MB 1.25-bit）',
                        style: textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        color: tokens.textDisabled,
                      ),
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const TranslationModelPage(),
                          ),
                        );
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

  List<SentenceAlignmentPair> _sentenceAlignmentPairsForRange(
    int chapterIndex,
    int startOffset,
    int endOffset,
  ) {
    if (_chapters.isEmpty) return const <SentenceAlignmentPair>[];
    final arrayIdx = _findChapterArrayIdx(_chapters, chapterIndex);
    if (arrayIdx < 0 || arrayIdx >= _chapters.length) {
      return const <SentenceAlignmentPair>[];
    }
    final ch = _chapters[arrayIdx];
    if (ch.index != chapterIndex) {
      return const <SentenceAlignmentPair>[];
    }
    final segs = _paragraphsForChapter(ch);
    final cfg = ref.read(standaloneConfigProvider);
    final transMap = ref
        .read(translationSchedulerProvider)
        .chapterMapFor(
          bookId: widget.book.id,
          chapterIndex: chapterIndex,
          targetLangCode: cfg.translationTargetLang,
          modelId: cfg.activeTranslationModelId,
        );
    final pairs = <SentenceAlignmentPair>[];
    for (final s in segs) {
      if (endOffset <= s.startChar || startOffset >= s.endChar) continue;
      final tr = transMap[s.hash]?.trim() ?? '';
      if (tr.isEmpty) {
        return const <SentenceAlignmentPair>[];
      }
      pairs.add(
        SentenceAlignmentPair(
          origStartChar: s.startChar,
          origEndChar: s.endChar,
          origText: s.text,
          transText: tr,
        ),
      );
    }
    return pairs;
  }

  ({int? start, int? end}) _tryInstantAlignmentForSelection({
    required ReaderPage page,
    required ({
      int startOffset,
      int endOffset,
      String quote,
      bool isTranslation,
      int? transStartInFirst,
      int? transEndInLast,
    })
    mapped,
  }) {
    if (!page.isBilingual || !mapped.isTranslation) {
      return (start: null, end: null);
    }
    final pairs = _sentenceAlignmentPairsForRange(
      page.chapterIndex,
      mapped.startOffset,
      mapped.endOffset,
    );
    if (pairs.isEmpty) return (start: null, end: null);
    final now = DateTime.now().toUtc();
    final probe = ReadingAnnotation(
      id: '_probe',
      bookId: widget.book.id,
      chapterIndex: page.chapterIndex,
      startOffset: mapped.startOffset,
      endOffset: mapped.endOffset,
      quote: mapped.quote,
      target: ReadingAnnotationTarget.translation,
      transStartInFirst: mapped.transStartInFirst,
      transEndInLast: mapped.transEndInLast,
      createdAt: now,
      updatedAt: now,
    );
    final instant = tryInstantPhraseAlign(annotation: probe, sentences: pairs);
    if (instant == null) return (start: null, end: null);
    return (start: instant.alignedOrigStart, end: instant.alignedOrigEnd);
  }

  Future<void> _alignAnnotationInBackground(ReadingAnnotation ann) async {
    if (!mounted ||
        _displayMode != BilingualDisplayMode.bilingual ||
        ann.hasAlignedOrigRange ||
        ann.target == ReadingAnnotationTarget.original ||
        _alignmentInFlightIds.contains(ann.id) ||
        _alignmentSessionDoneIds.contains(ann.id)) {
      return;
    }
    final pairs = _sentenceAlignmentPairsForRange(
      ann.chapterIndex,
      ann.startOffset,
      ann.endOffset,
    );
    if (pairs.isEmpty) return;

    _alignmentInFlightIds.add(ann.id);
    try {
      final scheduler = ref.read(translationSchedulerProvider.notifier);
      final result = await alignChineseAnnotationToOriginal(
        annotation: ann,
        sentences: pairs,
        backTranslatePhrase: (phrase, targetLang) =>
            scheduler.translatePhraseForAlignment(
              phrase: phrase,
              targetLang: targetLang,
            ),
      );
      if (!mounted) return;
      if (result == null) {
        final modelPath = ref
            .read(translationModelManagerProvider)
            .activeModelPath;
        if (modelPath == null || modelPath.isEmpty) {
          _alignmentSessionDoneIds.add(ann.id);
        }
        return;
      }
      await ref
          .read(bookAnnotationsProvider(widget.book.id).notifier)
          .setAlignedOriginalRange(
            annotationId: ann.id,
            alignedOrigStart: result.alignedOrigStart,
            alignedOrigEnd: result.alignedOrigEnd,
          );
      _alignmentSessionDoneIds.add(ann.id);
    } finally {
      _alignmentInFlightIds.remove(ann.id);
    }
  }

  void _schedulePhraseAlignmentForCurrentPage(
    List<ReadingAnnotation> annotations,
  ) {
    if (!mounted ||
        _displayMode != BilingualDisplayMode.bilingual ||
        _pages.isEmpty ||
        _currentPage < 0 ||
        _currentPage >= _pages.length) {
      return;
    }
    final curPage = _pages[_currentPage];
    for (final ann in annotations) {
      if (ann.chapterIndex != curPage.chapterIndex ||
          ann.hasAlignedOrigRange ||
          ann.target == ReadingAnnotationTarget.original ||
          _alignmentInFlightIds.contains(ann.id) ||
          _alignmentSessionDoneIds.contains(ann.id)) {
        continue;
      }
      if (ann.endOffset <= curPage.startChar ||
          ann.startOffset >= curPage.endChar) {
        continue;
      }
      unawaited(_alignAnnotationInBackground(ann));
    }
  }

  /// 边听边看：从当前可见页首句起播/续播，若正在朗读本页则切换暂停/播放。
  Future<void> _createHighlight({
    required ReaderPage page,
    required int localStart,
    required int localEnd,
    required ReadingHighlightColor color,
  }) async {
    final mapped = resolveOriginalSelectionForPage(page, localStart, localEnd);
    if (mapped.quote.isEmpty || mapped.startOffset >= mapped.endOffset) return;

    final instantAlign = _tryInstantAlignmentForSelection(
      page: page,
      mapped: mapped,
    );
    setState(() => _lastHighlightColor = color);
    final created = await ref
        .read(bookAnnotationsProvider(widget.book.id).notifier)
        .add(
          chapterIndex: page.chapterIndex,
          startOffset: mapped.startOffset,
          endOffset: mapped.endOffset,
          quote: mapped.quote,
          color: color,
          chapterTitle: page.chapterTitle,
          target: page.isBilingual
              ? (mapped.isTranslation
                    ? ReadingAnnotationTarget.translation
                    : ReadingAnnotationTarget.original)
              : ReadingAnnotationTarget.original,
          transStartInFirst: mapped.transStartInFirst,
          transEndInLast: mapped.transEndInLast,
          alignedOrigStart: instantAlign.start,
          alignedOrigEnd: instantAlign.end,
        );
    if (page.isBilingual &&
        mapped.isTranslation &&
        !created.hasAlignedOrigRange) {
      unawaited(_alignAnnotationInBackground(created));
    }
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
      final mapped = resolveOriginalSelectionForPage(page, localStart, localEnd);
      if (mapped.quote.isEmpty || mapped.startOffset >= mapped.endOffset) return;
      quote = mapped.quote;
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
          final mapped = resolveOriginalSelectionForPage(
            page,
            localStart,
            localEnd,
          );
          final instantAlign = _tryInstantAlignmentForSelection(
            page: page,
            mapped: mapped,
          );
          final created = await notifier.add(
            chapterIndex: page.chapterIndex,
            startOffset: mapped.startOffset,
            endOffset: mapped.endOffset,
            quote: quote,
            note: note,
            color: color,
            chapterTitle: chapterTitle,
            target: page.isBilingual
                ? (mapped.isTranslation
                      ? ReadingAnnotationTarget.translation
                      : ReadingAnnotationTarget.original)
                : ReadingAnnotationTarget.original,
            transStartInFirst: mapped.transStartInFirst,
            transEndInLast: mapped.transEndInLast,
            alignedOrigStart: instantAlign.start,
            alignedOrigEnd: instantAlign.end,
          );
          if (page.isBilingual &&
              mapped.isTranslation &&
              !created.hasAlignedOrigRange) {
            unawaited(_alignAnnotationInBackground(created));
          }
        }
      },
      onDelete: existing == null ? null : () => notifier.remove(existing.id),
    );
  }

  void _jumpToAnnotation(ReadingAnnotation ann) {
    if (_chapters.isEmpty) return;
    _setChromeVisible(false);
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
        speakTranslated: _displayMode != BilingualDisplayMode.original,
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
          speakTranslated: _displayMode != BilingualDisplayMode.original,
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
        speakTranslated: _displayMode != BilingualDisplayMode.original,
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

  void _openSpeedSheet({
    required double initialSpeed,
    required String title,
    required _ReaderPalette palette,
    required ValueChanged<double> onChanged,
  }) {
    showPlaybackSpeedSheet(
      context,
      initialSpeed: initialSpeed,
      title: title,
      backgroundColor: palette.bg,
      foregroundColor: palette.fg,
      secondaryColor: palette.secondary,
      onChanged: onChanged,
    );
  }

  Widget _buildLiveAudioStrip(
    _ReaderPalette palette,
    LiveTtsState liveState,
  ) {
    final liveCtrl = ref.read(liveTtsPlayerProvider.notifier);
    const navConstraints = BoxConstraints.tightFor(width: 38, height: 38);
    const playConstraints = BoxConstraints.tightFor(width: 40, height: 40);
    return SizedBox(
      key: const Key('reader_live_control_bar'),
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_displayMode != BilingualDisplayMode.original) ...[
                      InkWell(
                        key: const Key('reader_live_lang_toggle'),
                        borderRadius: BorderRadius.circular(
                          EchoMetrics.radiusPill,
                        ),
                        onTap: () => unawaited(
                          liveCtrl.setSpeakTranslated(
                            !liveState.speakTranslated,
                          ),
                        ),
                        child: Container(
                          height: 28,
                          padding: const EdgeInsets.symmetric(horizontal: 9),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: liveState.speakTranslated
                                ? palette.accent.withValues(alpha: 0.12)
                                : palette.fg.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(
                              EchoMetrics.radiusPill,
                            ),
                            border: Border.all(
                              color: liveState.speakTranslated
                                  ? palette.accent.withValues(alpha: 0.42)
                                  : palette.hairline,
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            liveState.speakTranslated ? '译' : '原',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.1,
                              fontWeight: FontWeight.w600,
                              color: liveState.speakTranslated
                                  ? palette.accent
                                  : palette.fg,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    buildCompactSpeedPill(
                      key: const Key('reader_live_speed_button'),
                      speed: liveState.speed,
                      accentColor: palette.accent,
                      textColor: palette.fg,
                      borderColor: palette.secondary,
                      onTap: () => _openSpeedSheet(
                        initialSpeed: liveState.speed,
                        title: '朗读语速',
                        palette: palette,
                        onChanged: (s) => unawaited(liveCtrl.setSpeed(s)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const Key('reader_live_prev_sentence'),
                  tooltip: '上一句',
                  padding: EdgeInsets.zero,
                  constraints: navConstraints,
                  visualDensity: VisualDensity.compact,
                  onPressed: liveCtrl.prevSentence,
                  icon: Icon(
                    Icons.skip_previous_rounded,
                    size: 22,
                    color: palette.fg,
                  ),
                ),
                const SizedBox(width: 4),
                Material(
                  color: palette.accent.withValues(alpha: 0.16),
                  shape: const CircleBorder(),
                  child: IconButton(
                    key: const Key('reader_live_toggle_play'),
                    tooltip: liveState.isPlaying ? '暂停朗读' : '继续朗读',
                    padding: EdgeInsets.zero,
                    constraints: playConstraints,
                    visualDensity: VisualDensity.compact,
                    onPressed: liveCtrl.togglePlayPause,
                    icon: liveState.isSynthesizing
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: palette.accent,
                            ),
                          )
                        : Icon(
                            liveState.isPlaying
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_filled,
                            size: 26,
                            color: palette.accent,
                          ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('reader_live_next_sentence'),
                  tooltip: '下一句',
                  padding: EdgeInsets.zero,
                  constraints: navConstraints,
                  visualDensity: VisualDensity.compact,
                  onPressed: liveCtrl.nextSentence,
                  icon: Icon(
                    Icons.skip_next_rounded,
                    size: 22,
                    color: palette.fg,
                  ),
                ),
              ],
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  key: const Key('reader_live_stop'),
                  tooltip: '停止听书',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: liveCtrl.stop,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 19,
                    color: palette.secondary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChunkedAudioStrip(
    _ReaderPalette palette,
    double chunkedSpeed,
    bool isPlayingThisBook,
  ) {
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            buildCompactSpeedPill(
              key: const Key('reader_chunked_speed_button'),
              speed: chunkedSpeed,
              accentColor: palette.accent,
              textColor: palette.fg,
              borderColor: palette.secondary.withValues(alpha: 0.30),
              onTap: () => _openSpeedSheet(
                initialSpeed: chunkedSpeed,
                title: '播放倍速',
                palette: palette,
                onChanged: (s) => unawaited(
                  ref.read(chunkedPlayerProvider.notifier).setSpeed(s),
                ),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              key: const Key('reader_open_player'),
              style: TextButton.styleFrom(
                foregroundColor: palette.accent,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => openPlayer(context),
              icon: Icon(
                isPlayingThisBook ? Icons.graphic_eq : Icons.play_circle_outline,
                size: 17,
              ),
              label: const Text('全屏播放器'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopToolBar({
    required _ReaderPalette palette,
    required TextTheme textTheme,
    required bool hasReadableContent,
    required bool isPlayingThisBook,
    required bool hasAudio,
  }) {
    return EchoGlassSurface(
      surfaceColor: palette.chromeBg,
      opacity: palette.isDarkSurface ? 0.90 : 0.95,
      border: Border(
        bottom: BorderSide(color: palette.hairline, width: 0.8),
      ),
      child: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SizedBox(
              key: const Key('reader_top_bar'),
              height: 56,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    IconButton(
                      key: const Key('reader_back_button'),
                      tooltip: '返回',
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: Icon(
                        Icons.arrow_back_rounded,
                        color: palette.fg,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        widget.book.title,
                        key: const Key('reader_book_title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleMedium?.copyWith(
                          color: palette.fg,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (hasReadableContent) ...[
                      const SizedBox(width: 8),
                      Tooltip(
                        message: isPlayingThisBook ? '从本页听书 / 暂停' : '边听边看',
                        child: Material(
                          type: MaterialType.transparency,
                          child: InkWell(
                            key: const Key('reader_play_button'),
                            borderRadius: BorderRadius.circular(
                              EchoMetrics.radiusPill,
                            ),
                            onTap: _loading ? null : () => _listenFromHere(),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minHeight: 40,
                                minWidth: 48,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: isPlayingThisBook
                                        ? palette.accent.withValues(alpha: 0.16)
                                        : palette.fg.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(
                                      EchoMetrics.radiusPill,
                                    ),
                                    border: Border.all(
                                      color: isPlayingThisBook
                                          ? palette.accent.withValues(alpha: 0.55)
                                          : palette.hairline,
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          isPlayingThisBook
                                              ? Icons.pause_circle_filled
                                              : Icons.headphones,
                                          size: 18,
                                          color: isPlayingThisBook
                                              ? palette.accent
                                              : (hasAudio
                                                    ? palette.fg
                                                    : palette.secondary
                                                          .withValues(
                                                            alpha: 0.55,
                                                          )),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          isPlayingThisBook ? '朗读中' : '听书',
                                          style: textTheme.labelMedium?.copyWith(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                            color: isPlayingThisBook
                                                ? palette.accent
                                                : (hasAudio
                                                      ? palette.fg
                                                      : palette.secondary
                                                            .withValues(
                                                              alpha: 0.65,
                                                            )),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingToolDock({
    required _ReaderPalette palette,
    required TextTheme textTheme,
    required List<ReadingAnnotation> annotations,
    required bool isLiveThisBook,
    required LiveTtsState liveState,
    required bool isThisBookLoaded,
    required bool isPlayingThisBook,
    required double chunkedSpeed,
  }) {
    final translateLabel = switch (_displayMode) {
      BilingualDisplayMode.original => '双语',
      BilingualDisplayMode.bilingual => '双语中',
      BilingualDisplayMode.translatedOnly => '仅译文',
    };
    final translateActive = _displayMode != BilingualDisplayMode.original;
    final hasAudioStrip = isLiveThisBook || isThisBookLoaded;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Material(
              color: Colors.transparent,
              child: EchoGlassSurface(
                borderRadius: BorderRadius.circular(20),
                surfaceColor: palette.chromeBg,
                opacity: palette.isDarkSurface ? 0.90 : 0.95,
                border: Border.all(color: palette.hairline, width: 0.8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: palette.isDarkSurface ? 0.42 : 0.10,
                    ),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
                child: Column(
                  key: const Key('reader_bottom_bar'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasAudioStrip) ...[
                      if (isLiveThisBook)
                        _buildLiveAudioStrip(palette, liveState)
                      else
                        _buildChunkedAudioStrip(
                          palette,
                          chunkedSpeed,
                          isPlayingThisBook,
                        ),
                      Divider(
                        height: 1,
                        thickness: 0.8,
                        indent: 12,
                        endIndent: 12,
                        color: palette.hairline,
                      ),
                    ],
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _ReaderDockItem(
                              itemKey: const Key('reader_toc_button'),
                              tooltip: '目录',
                              icon: Icons.format_list_bulleted_rounded,
                              label: '目录',
                              fgColor: palette.fg,
                              accentColor: palette.accent,
                              onTap: _loading || _chapters.isEmpty
                                  ? null
                                  : _showToc,
                            ),
                          ),
                          Expanded(
                            child: _ReaderDockItem(
                              itemKey: const Key('reader_notes_button'),
                              tooltip: '划线与笔记',
                              icon: Icons.edit_note_rounded,
                              label: '笔记',
                              showBadgeDot: annotations.isNotEmpty,
                              fgColor: palette.fg,
                              accentColor: palette.accent,
                              onTap: _loading ? null : _showBookNotes,
                            ),
                          ),
                          Expanded(
                            child: _ReaderDockItem(
                              itemKey: const Key('reader_translate_button'),
                              tooltip: '双语翻译',
                              icon: Icons.translate_rounded,
                              label: translateLabel,
                              active: translateActive,
                              fgColor: palette.fg,
                              accentColor: palette.accent,
                              onTap: _loading || _chapters.isEmpty
                                  ? null
                                  : _showTranslationSheet,
                            ),
                          ),
                          Expanded(
                            child: _ReaderDockItem(
                              itemKey: const Key('reader_font_button'),
                              tooltip: '排版设置',
                              label: '排版',
                              fgColor: palette.fg,
                              accentColor: palette.accent,
                              customIcon: SizedBox(
                                width: 22,
                                height: 22,
                                child: Center(
                                  child: Text(
                                    'Aa',
                                    style: textTheme.labelLarge?.copyWith(
                                      fontFamily: 'serif',
                                      fontSize: 16,
                                      height: 1.0,
                                      fontWeight: FontWeight.w700,
                                      color: palette.fg,
                                    ),
                                  ),
                                ),
                              ),
                              onTap: _loading ? null : _showTypographySheet,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
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
        (isLiveThisBook && (liveState.isPlaying || liveState.isSynthesizing));
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

    ref.listen<TranslationSchedulerState>(translationSchedulerProvider, (
      prev,
      next,
    ) {
      if (!mounted ||
          _switchingChapter ||
          _displayMode == BilingualDisplayMode.original ||
          _chapters.isEmpty) {
        return;
      }
      final cfg = ref.read(standaloneConfigProvider);
      final curCh = _chapters[_currentChapterArrayIdx()].index;
      final nextMap = next.chapterMapFor(
        bookId: widget.book.id,
        chapterIndex: curCh,
        targetLangCode: cfg.translationTargetLang,
        modelId: cfg.activeTranslationModelId,
      );
      final curPage = (_currentPage >= 0 && _currentPage < _pages.length)
          ? _pages[_currentPage]
          : null;
      final nextPage =
          (_currentPage + 1 >= 0 && _currentPage + 1 < _pages.length)
              ? _pages[_currentPage + 1]
              : null;

      final translationsChanged =
          nextMap.length != _lastObservedChapterTranslations.length ||
          !nextMap.keys.every(
            (k) => _lastObservedChapterTranslations[k] == nextMap[k],
          );
      if (translationsChanged) {
        final addedHashes = nextMap.keys
            .where((k) => _lastObservedChapterTranslations[k] != nextMap[k])
            .toSet();
        _lastObservedChapterTranslations = nextMap;
        if (addedHashes.isNotEmpty) {
          final hitsVisiblePage =
              curPage?.blocks?.any(
                (b) => addedHashes.contains(b.paragraphHash),
              ) ??
              false;
          final hitsNextPage =
              nextPage?.blocks?.any(
                (b) => addedHashes.contains(b.paragraphHash),
              ) ??
              false;
          _scheduleBilingualRepaginate(
            immediate: hitsVisiblePage,
            debounce: hitsNextPage
                ? const Duration(milliseconds: 450)
                : const Duration(milliseconds: 1400),
            triggerEnqueue: false,
          );
        }
      }
    });

    ref.listen<List<ReadingAnnotation>>(bookAnnotationsProvider(widget.book.id), (
      prev,
      next,
    ) {
      if (!mounted ||
          _displayMode != BilingualDisplayMode.bilingual ||
          _pages.isEmpty) {
        return;
      }
      Future<void>.microtask(() {
        if (mounted) {
          _schedulePhraseAlignmentForCurrentPage(next);
        }
      });
    });

    final translationError = _displayMode != BilingualDisplayMode.original
        ? ref.watch(translationSchedulerProvider.select((s) => s.lastError))
        : null;

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
    final activeCountForCurChapter =
        _displayMode != BilingualDisplayMode.original && curChapterObj != null
            ? ref.watch(
                translationSchedulerProvider.select((s) {
                  final cfg = ref.read(standaloneConfigProvider);
                  final prefix =
                      '${widget.book.id}::${curChapterObj.index}::${cfg.translationTargetLang}::'
                      '${cfg.activeTranslationModelId.isEmpty ? "default" : cfg.activeTranslationModelId}::';
                  return s.activeParagraphKeys
                      .where((k) => k.startsWith(prefix))
                      .length;
                }),
              )
            : 0;
    final activeTranslatingHashForCurChapter =
        _displayMode != BilingualDisplayMode.original && curChapterObj != null
            ? ref.watch(
                translationSchedulerProvider.select((s) {
                  final key = s.currentTranslatingKey;
                  if (key == null) return null;
                  final cfg = ref.read(standaloneConfigProvider);
                  final prefix =
                      '${widget.book.id}::${curChapterObj.index}::${cfg.translationTargetLang}::'
                      '${cfg.activeTranslationModelId.isEmpty ? "default" : cfg.activeTranslationModelId}::';
                  return key.startsWith(prefix)
                      ? key.substring(prefix.length)
                      : null;
                }),
              )
            : null;
    final pageBlocks = page?.blocks ?? const <BilingualPageBlock>[];
    final totalOnPage = pageBlocks.length;
    final doneOnPage = pageBlocks.where((b) => b.hasTranslation).length;
    final showProgressStrip =
        _displayMode != BilingualDisplayMode.original &&
        (translationError == null || translationError.isEmpty) &&
        totalOnPage > 0 &&
        doneOnPage < totalOnPage &&
        activeCountForCurChapter > 0;
    final headerChapterTitle =
        page?.chapterTitle ??
        (curChapterObj == null
            ? ''
            : (curChapterObj.title.isNotEmpty
                  ? curChapterObj.title
                  : '第 ${currentArrayIdx + 1} 章'));
    final bookPct = _computeBookProgressPercent();

    final hasReadableContent =
        !_loading && _error == null && _chapters.isNotEmpty;
    final overlayStyle = palette.isDarkSurface
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    final readingMetaStyle = textTheme.labelSmall?.copyWith(
      fontSize: 12,
      color: palette.secondary.withValues(alpha: 0.72),
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_chromeVisible) _setChromeVisible(false);
        },
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: Scaffold(
          key: const Key('reader_page'),
          backgroundColor: palette.bg,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // Layer 1: 恒定几何尺寸的正文画布（顶部/底部仅在阅读态渲染章节与进度信息）
              if (_loading)
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 56),
                    child: Center(
                      child: CircularProgressIndicator(color: tokens.primary),
                    ),
                  ),
                )
              else if (_error != null)
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 56),
                    child: Center(
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
                    ),
                  ),
                )
              else if (_chapters.isEmpty)
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 56),
                    child: Center(
                      key: const Key('reader_empty'),
                      child: Text(
                        '本书暂无可读章节（支持 EPUB / TXT 格式）',
                        style: textTheme.bodyLarge?.copyWith(
                          color: palette.secondary,
                        ),
                      ),
                    ),
                  ),
                )
              else
                SafeArea(
                  child: Column(
                    children: [
                      // 顶部静默阅读章名区（工具栏展开时完全隐藏）
                      SizedBox(
                        height: 32,
                        child: AnimatedBuilder(
                          animation: _chromeController,
                          builder: (context, _) {
                            if (_chromeController.value >= 1.0) {
                              return const SizedBox.shrink();
                            }
                            final opacity =
                                (1.0 - _chromeController.value).clamp(0.0, 1.0);
                            return Opacity(
                              key: const Key('reader_reading_header'),
                              opacity: opacity,
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 680,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: EchoMetrics.space3,
                                    ),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        headerChapterTitle,
                                        key: const Key('reader_chapter_label'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: readingMetaStyle,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      if (_showForeignBanner &&
                          _displayMode == BilingualDisplayMode.original)
                        _buildForeignPromptBanner(
                          tokens: tokens,
                          textTheme: textTheme,
                          palette: palette,
                        ),
                      if (translationError != null &&
                          translationError.isNotEmpty)
                        _buildTranslationErrorBanner(
                          errorText: translationError,
                          tokens: tokens,
                          textTheme: textTheme,
                          palette: palette,
                        ),
                      if (_displayMode != BilingualDisplayMode.original)
                        SizedBox(
                          height: 26,
                          child: showProgressStrip && !_switchingChapter
                              ? _buildBilingualProgressStrip(
                                  doneOnPage: doneOnPage,
                                  totalOnPage: totalOnPage,
                                  tokens: tokens,
                                  textTheme: textTheme,
                                  palette: palette,
                                )
                              : (_switchingChapter
                                    ? Align(
                                        alignment: Alignment.topCenter,
                                        child: SizedBox(
                                          height: 2,
                                          child: LinearProgressIndicator(
                                            color: tokens.primary,
                                            backgroundColor: palette.secondary
                                                .withValues(alpha: 0.14),
                                          ),
                                        ),
                                      )
                                    : null),
                        ),
                      Expanded(
                        child: _ReaderBody(
                          pages: _pages,
                          pageViewEpoch: _pageViewEpoch,
                          pageController: _pageController,
                          textStyle: DefaultTextStyle.of(
                            context,
                          ).style.merge(_textStyle(tokens)),
                          secondaryColor: palette.secondary,
                          highlightColor: tokens.readingHighlight,
                          activeSentence: activeSentence,
                          activeCueText: activeCueText,
                          speakTranslated:
                              isLiveThisBook && liveState.speakTranslated,
                          annotations: annotations,
                          activeTranslatingHash:
                              activeTranslatingHashForCurChapter,
                          lastHighlightColor: _lastHighlightColor,
                          hasTextSelection: _hasTextSelection,
                          layoutSize: _layoutSize,
                          onTapCanvas: _toggleChrome,
                          onNeedPagination: _onLayoutSizeChanged,
                          onPageChanged: _onPageChanged,
                          onScrollNotification: _onScrollNotification,
                          onSelectionActiveChanged: (active) {
                            if (active && _chromeVisible) {
                              _setChromeVisible(false);
                            }
                            if (mounted && _hasTextSelection != active) {
                              setState(() => _hasTextSelection = active);
                            }
                          },
                          onQuickHighlight:
                              (page, localStart, localEnd, color) {
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
                                  final mapped =
                                      resolveOriginalSelectionForPage(
                                        page,
                                        localStart,
                                        math.min(
                                          page.text.length,
                                          localStart + 1,
                                        ),
                                      );
                                  unawaited(
                                    _listenFromHere(
                                      overrideChapterArrayIdx: idx,
                                      overrideCharOffset: mapped.startOffset,
                                    ),
                                  );
                                }
                              : null,
                        ),
                      ),
                      // 底部静默阅读进度区（工具栏展开时完全隐藏）
                      SizedBox(
                        height: 32,
                        child: AnimatedBuilder(
                          animation: _chromeController,
                          builder: (context, _) {
                            if (_pages.isEmpty ||
                                _chromeController.value >= 1.0) {
                              return const SizedBox.shrink();
                            }
                            final opacity =
                                (1.0 - _chromeController.value).clamp(0.0, 1.0);
                            return Opacity(
                              key: const Key('reader_reading_footer'),
                              opacity: opacity,
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 680,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: EchoMetrics.space3,
                                    ),
                                    child: Row(
                                      children: [
                                        if (isPlayingThisBook) ...[
                                          Container(
                                            width: 6,
                                            height: 6,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: palette.accent,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                        ],
                                        Flexible(
                                          child: Text(
                                            '第 ${currentArrayIdx + 1}/${_chapters.length} 章 · '
                                            '${page?.pageInChapter ?? 1}/${page?.pageCountInChapter ?? 1} 页',
                                            key: const Key(
                                              'reader_page_indicator',
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: readingMetaStyle,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '全书 $bookPct%',
                                          key: const Key(
                                            'reader_global_indicator',
                                          ),
                                          style: readingMetaStyle,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),

              // Layer 2: 工具栏展开时的轻触收起拦截层（水平滑动仍直接透传给 PageView）
              if (hasReadableContent && _chromeVisible)
                Positioned.fill(
                  child: GestureDetector(
                    key: const Key('reader_chrome_scrim'),
                    behavior: HitTestBehavior.translucent,
                    onTap: () => _setChromeVisible(false),
                  ),
                ),

              // Layer 3: 顶部工具栏浮层（仅书名 + 返回 + 听书入口；加载/异常态常驻以防困住用户）
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: !hasReadableContent
                    ? _buildTopToolBar(
                        palette: palette,
                        textTheme: textTheme,
                        hasReadableContent: false,
                        isPlayingThisBook: isPlayingThisBook,
                        hasAudio: hasAudio,
                      )
                    : AnimatedBuilder(
                        animation: _chromeController,
                        builder: (context, child) {
                          if (_chromeController.value <= 0.0) {
                            return const SizedBox.shrink();
                          }
                          final curve = _chromeController.status ==
                                  AnimationStatus.reverse
                              ? Curves.easeInCubic
                              : Curves.easeOutCubic;
                          final t = curve.transform(_chromeController.value);
                          return Opacity(
                            opacity: t,
                            child: FractionalTranslation(
                              translation: Offset(0, -(1 - t) * 0.35),
                              child: child,
                            ),
                          );
                        },
                        child: _buildTopToolBar(
                          palette: palette,
                          textTheme: textTheme,
                          hasReadableContent: true,
                          isPlayingThisBook: isPlayingThisBook,
                          hasAudio: hasAudio,
                        ),
                      ),
              ),

              // Layer 4: 底部悬浮工具坞浮层（按需点击唤起）
              if (hasReadableContent && _pages.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: AnimatedBuilder(
                    animation: _chromeController,
                    builder: (context, child) {
                      if (_chromeController.value <= 0.0) {
                        return const SizedBox.shrink();
                      }
                      final curve =
                          _chromeController.status == AnimationStatus.reverse
                              ? Curves.easeInCubic
                              : Curves.easeOutCubic;
                      final t = curve.transform(_chromeController.value);
                      return Opacity(
                        opacity: t,
                        child: FractionalTranslation(
                          translation: Offset(0, (1 - t) * 0.35),
                          child: child,
                        ),
                      );
                    },
                    child: _buildFloatingToolDock(
                      palette: palette,
                      textTheme: textTheme,
                      annotations: annotations,
                      isLiveThisBook: isLiveThisBook,
                      liveState: liveState,
                      isThisBookLoaded: isThisBookLoaded,
                      isPlayingThisBook: isPlayingThisBook,
                      chunkedSpeed: playerState.speed,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForeignPromptBanner({
    required EchoTokens tokens,
    required TextTheme textTheme,
    required _ReaderPalette palette,
  }) {
    return Container(
      key: const Key('reader_foreign_prompt_banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: tokens.primary.withValues(alpha: 0.12),
        border: Border(
          bottom: BorderSide(color: palette.secondary.withValues(alpha: 0.18)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.translate_rounded, size: 16, color: tokens.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '检测到外文书籍，可开启离线双语阅读',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: palette.fg,
                fontSize: 12.5,
              ),
            ),
          ),
          TextButton(
            key: const Key('reader_foreign_dismiss_button'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _dismissForeignBanner,
            child: Text(
              '不再提示',
              style: TextStyle(color: palette.secondary, fontSize: 12),
            ),
          ),
          const SizedBox(width: 4),
          FilledButton(
            key: const Key('reader_foreign_enable_button'),
            style: FilledButton.styleFrom(
              backgroundColor: tokens.primary,
              foregroundColor: tokens.textOnPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () =>
                unawaited(_switchDisplayMode(BilingualDisplayMode.bilingual)),
            child: const Text('开启双语', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildTranslationErrorBanner({
    required String errorText,
    required EchoTokens tokens,
    required TextTheme textTheme,
    required _ReaderPalette palette,
  }) {
    return Container(
      key: const Key('reader_translation_error_banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: tokens.error.withValues(alpha: 0.12),
        border: Border(
          bottom: BorderSide(color: palette.secondary.withValues(alpha: 0.18)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 16, color: tokens.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              errorText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: palette.fg,
                fontSize: 12,
              ),
            ),
          ),
          TextButton(
            key: const Key('reader_translation_retry_button'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              ref.read(translationSchedulerProvider.notifier).clearError();
              if (_chapters.isNotEmpty &&
                  _pages.isNotEmpty &&
                  _currentPage >= 0 &&
                  _currentPage < _pages.length) {
                final ch = _chapters[_currentChapterArrayIdx()];
                unawaited(
                  _enqueueTranslationForPage(
                    _currentPage,
                    _pages,
                    _paragraphsForChapter(ch),
                    ch.index,
                  ),
                );
              } else if (_layoutSize != null) {
                unawaited(_paginateCurrentChapter(_layoutSize!, tokens));
              }
            },
            child: Text(
              '重试',
              style: TextStyle(color: tokens.primary, fontSize: 12),
            ),
          ),
          TextButton(
            key: const Key('reader_translation_error_model_button'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const TranslationModelPage(),
                ),
              );
              if (!mounted) return;
              ref.read(translationSchedulerProvider.notifier).clearError();
              if (_layoutSize != null &&
                  _displayMode != BilingualDisplayMode.original) {
                unawaited(_paginateCurrentChapter(_layoutSize!, tokens));
              }
            },
            child: Text(
              '模型管理',
              style: TextStyle(color: palette.secondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBilingualProgressStrip({
    required int doneOnPage,
    required int totalOnPage,
    required EchoTokens tokens,
    required TextTheme textTheme,
    required _ReaderPalette palette,
  }) {
    final progress = totalOnPage > 0 ? doneOnPage / totalOnPage : null;
    return Container(
      key: const Key('reader_bilingual_progress_strip'),
      width: double.infinity,
      height: 26,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          tokens.primary.withValues(alpha: 0.06),
          palette.bg,
        ),
        border: Border(
          bottom: BorderSide(color: palette.secondary.withValues(alpha: 0.12)),
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(
                    Icons.translate_rounded,
                    size: 13,
                    color: tokens.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '逐句翻译中 · $doneOnPage/$totalOnPage 句',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textScaler: TextScaler.noScaling,
                      style: textTheme.labelSmall?.copyWith(
                        color: palette.secondary,
                        fontSize: 11.5,
                        height: 1.15,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: 2,
            child: LinearProgressIndicator(
              value: progress,
              color: tokens.primary,
              backgroundColor: palette.secondary.withValues(alpha: 0.14),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReaderDockItem extends StatelessWidget {
  const _ReaderDockItem({
    required this.itemKey,
    required this.tooltip,
    required this.label,
    required this.fgColor,
    required this.accentColor,
    required this.onTap,
    this.icon,
    this.customIcon,
    this.active = false,
    this.showBadgeDot = false,
  });

  final Key itemKey;
  final String tooltip;
  final String label;
  final Color fgColor;
  final Color accentColor;
  final VoidCallback? onTap;
  final IconData? icon;
  final Widget? customIcon;
  final bool active;
  final bool showBadgeDot;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final enabled = onTap != null;
    final tone = !enabled
        ? fgColor.withValues(alpha: 0.35)
        : (active ? accentColor : fgColor);

    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: itemKey,
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 50),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? accentColor.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  if (customIcon != null)
                    customIcon!
                  else
                    Icon(icon, size: 22, color: tone),
                  if (showBadgeDot)
                    Positioned(
                      right: -4,
                      top: -2,
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accentColor,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(
                  fontSize: 11.5,
                  height: 1.15,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: tone,
                ),
              ),
            ],
          ),
        ),
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
    required this.secondaryColor,
    required this.highlightColor,
    required this.activeSentence,
    required this.activeCueText,
    required this.speakTranslated,
    required this.annotations,
    this.activeTranslatingHash,
    required this.lastHighlightColor,
    required this.hasTextSelection,
    required this.layoutSize,
    required this.onTapCanvas,
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
  final Color secondaryColor;
  final Color highlightColor;
  final TextSentence? activeSentence;
  final String? activeCueText;
  final bool speakTranslated;
  final List<ReadingAnnotation> annotations;
  final String? activeTranslatingHash;
  final ReadingHighlightColor lastHighlightColor;
  final bool hasTextSelection;
  final Size? layoutSize;
  final VoidCallback onTapCanvas;
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

  List<({int start, int end})> _findCueInConcatRuns(
    String pageText,
    List<BilingualDisplayRun> targetRuns,
    String cue,
  ) {
    if (targetRuns.isEmpty || cue.isEmpty) {
      return const <({int start, int end})>[];
    }
    final concatBuf = StringBuffer();
    final segs = <({BilingualDisplayRun run, int concatStart, int concatEnd})>[];
    for (final r in targetRuns) {
      final cs = concatBuf.length;
      concatBuf.write(pageText.substring(r.displayStart, r.displayEnd));
      segs.add((run: r, concatStart: cs, concatEnd: concatBuf.length));
    }
    final hit = findCueSpanInPage(concatBuf.toString(), cue);
    if (hit == null) return const <({int start, int end})>[];

    final spans = <({int start, int end})>[];
    for (final seg in segs) {
      final ovS = math.max(hit.start, seg.concatStart);
      final ovE = math.min(hit.end, seg.concatEnd);
      if (ovS < ovE) {
        final ds = seg.run.displayStart + (ovS - seg.concatStart);
        final de = seg.run.displayStart + (ovE - seg.concatStart);
        if (ds < de) {
          spans.add((start: ds, end: de));
        }
      }
    }
    return spans;
  }

  List<({int start, int end})> _resolveHighlightSpans(ReaderPage page) {
    final blocks = page.blocks;
    if (blocks == null) {
      final sentence = activeSentence;
      if (sentence != null) {
        final overlapStart = math.max(sentence.startOffset, page.startChar);
        final overlapEnd = math.min(sentence.endOffset, page.endChar);
        if (overlapStart < overlapEnd) {
          final localStart = (overlapStart - page.startChar).clamp(
            0,
            page.text.length,
          );
          final localEnd = (overlapEnd - page.startChar).clamp(
            0,
            page.text.length,
          );
          if (localStart < localEnd) {
            return <({int start, int end})>[(start: localStart, end: localEnd)];
          }
        }
      }
      final cue = activeCueText;
      if (cue != null && cue.isNotEmpty) {
        final hit = findCueSpanInPage(page.text, cue);
        if (hit != null) return <({int start, int end})>[hit];
      }
      return const <({int start, int end})>[];
    }

    // 双语 / 仅译文行间模式下按当前朗读语种联动投影高亮至对应视觉片段
    final sentence = activeSentence;
    final cue = activeCueText?.trim() ?? '';
    final runs = page.displayRuns;
    if (runs != null && runs.isNotEmpty) {
      if (speakTranslated) {
        final matchingTrans = <BilingualDisplayRun>[
          for (final r in runs)
            if (r.kind == BilingualRunKind.transPrimary &&
                r.origStartChar >= 0 &&
                (sentence == null ||
                    (r.origStartChar < sentence.endOffset &&
                        r.origEndChar > sentence.startOffset)))
              r,
        ];
        if (matchingTrans.isNotEmpty) {
          if (cue.isNotEmpty) {
            final subSpans = _findCueInConcatRuns(
              page.text,
              matchingTrans,
              cue,
            );
            if (subSpans.isNotEmpty) return subSpans;
          }
          if (sentence != null) {
            return <({int start, int end})>[
              for (final r in matchingTrans)
                (start: r.displayStart, end: r.displayEnd),
            ];
          }
        }
      } else {
        if (sentence != null) {
          final origSpans = <({int start, int end})>[];
          for (final r in runs) {
            if ((r.kind != BilingualRunKind.origSubtitle &&
                    r.kind != BilingualRunKind.untranslatedOrig) ||
                r.origStartChar < 0 ||
                r.origEndChar <= sentence.startOffset ||
                r.origStartChar >= sentence.endOffset) {
              continue;
            }
            if (r.exactOrigMapping) {
              final ovS = math.max(sentence.startOffset, r.origStartChar);
              final ovE = math.min(sentence.endOffset, r.origEndChar);
              if (ovS < ovE) {
                final ds = (r.displayStart + (ovS - r.origStartChar)).clamp(
                  r.displayStart,
                  r.displayEnd,
                );
                final de = (r.displayStart + (ovE - r.origStartChar)).clamp(
                  ds,
                  r.displayEnd,
                );
                if (ds < de) {
                  origSpans.add((start: ds, end: de));
                }
              }
            } else {
              origSpans.add((start: r.displayStart, end: r.displayEnd));
            }
          }
          if (origSpans.isNotEmpty) return origSpans;
        }
      }

      // 回退 1：未译句在译文朗读模式下降级读原文时高亮对应待译原文片段
      if (sentence != null) {
        final fallbackSpans = <({int start, int end})>[];
        for (final r in runs) {
          if (r.kind != BilingualRunKind.untranslatedOrig ||
              r.origStartChar < 0 ||
              r.origEndChar <= sentence.startOffset ||
              r.origStartChar >= sentence.endOffset) {
            continue;
          }
          final ovS = math.max(sentence.startOffset, r.origStartChar);
          final ovE = math.min(sentence.endOffset, r.origEndChar);
          if (ovS < ovE) {
            final ds = (r.displayStart + (ovS - r.origStartChar)).clamp(
              r.displayStart,
              r.displayEnd,
            );
            final de = (r.displayStart + (ovE - r.origStartChar)).clamp(
              ds,
              r.displayEnd,
            );
            if (ds < de) {
              fallbackSpans.add((start: ds, end: de));
            }
          }
        }
        if (fallbackSpans.isNotEmpty) return fallbackSpans;
      }

      // 回退 2：离线音频字幕仅提供 cue 文本时匹配原文片段
      if (cue.isNotEmpty) {
        final origRuns = <BilingualDisplayRun>[
          for (final r in runs)
            if (r.kind == BilingualRunKind.origSubtitle ||
                r.kind == BilingualRunKind.untranslatedOrig)
              r,
        ];
        final hitSpans = _findCueInConcatRuns(page.text, origRuns, cue);
        if (hitSpans.isNotEmpty) return hitSpans;
      }
    }

    if (speakTranslated && cue.isNotEmpty) {
      for (final b in blocks) {
        if (b.transDisplayEnd <= b.transDisplayStart) continue;
        if (sentence != null &&
            (sentence.endOffset <= b.origStartChar ||
                sentence.startOffset >= b.origEndChar)) {
          continue;
        }
        final transSlice = page.text.substring(
          b.transDisplayStart,
          b.transDisplayEnd,
        );
        final hit = findCueSpanInPage(transSlice, cue);
        if (hit != null) {
          return <({int start, int end})>[
            (
              start: b.transDisplayStart + hit.start,
              end: b.transDisplayStart + hit.end,
            ),
          ];
        }
      }
    }

    if (sentence != null) {
      for (final b in blocks) {
        if (b.origDisplayEnd <= b.origDisplayStart) continue;
        final ovS = math.max(sentence.startOffset, b.origStartChar);
        final ovE = math.min(sentence.endOffset, b.origEndChar);
        if (ovS < ovE) {
          final s = b.origDisplayStart + (ovS - b.origStartChar);
          final e = b.origDisplayStart + (ovE - b.origStartChar);
          if (s < e) {
            return <({int start, int end})>[
              (
                start: s.clamp(0, page.text.length),
                end: e.clamp(0, page.text.length),
              ),
            ];
          }
        }
      }
    }
    if (cue.isNotEmpty) {
      final hit = findCueSpanInPage(page.text, cue);
      if (hit != null) return <({int start, int end})>[hit];
    }
    return const <({int start, int end})>[];
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
                  : const AlwaysScrollableScrollPhysics(
                      parent: ClampingScrollPhysics(),
                    ),
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
                          secondaryColor: secondaryColor,
                          highlightColor: highlightColor,
                          activeCueSpans: _resolveHighlightSpans(page),
                          annotations: annotations,
                          activeTranslatingHash: activeTranslatingHash,
                          lastHighlightColor: lastHighlightColor,
                          onTapCanvas: onTapCanvas,
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
    required this.secondaryColor,
    required this.highlightColor,
    required this.activeCueSpans,
    required this.annotations,
    this.activeTranslatingHash,
    required this.lastHighlightColor,
    required this.onTapCanvas,
    required this.onSelectionActiveChanged,
    required this.onQuickHighlight,
    required this.onOpenNoteEditor,
    required this.onTapAnnotation,
    this.onListenFromSelection,
  });

  final int index;
  final ReaderPage page;
  final TextStyle textStyle;
  final Color secondaryColor;
  final Color highlightColor;
  final List<({int start, int end})> activeCueSpans;
  final List<ReadingAnnotation> annotations;
  final String? activeTranslatingHash;
  final ReadingHighlightColor lastHighlightColor;
  final VoidCallback onTapCanvas;
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
    if (widget.page.isBilingual &&
        (widget.page.displayRuns?.isNotEmpty ?? false)) {
      final resolved = resolveBilingualSelectionHits(
        widget.page,
        _selStart!,
        _selEnd!,
      );
      if (resolved.hits.isNotEmpty) {
        final boxes = <TextBox>[];
        for (final hit in resolved.hits) {
          boxes.addAll(
            paragraph.getBoxesForSelection(
              TextSelection(baseOffset: hit.start, extentOffset: hit.end),
            ),
          );
        }
        if (boxes.isNotEmpty) return boxes;
      }
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

    var minLeft = boxes.first.left;
    var minTop = boxes.first.top;
    var maxRight = boxes.first.right;
    var maxBottom = boxes.first.bottom;
    for (final box in boxes.skip(1)) {
      minLeft = math.min(minLeft, box.left);
      minTop = math.min(minTop, box.top);
      maxRight = math.max(maxRight, box.right);
      maxBottom = math.max(maxBottom, box.bottom);
    }

    final overlayBox =
        Overlay.maybeOf(overlayContext)?.context.findRenderObject()
            as RenderBox?;
    final topLeft = overlayBox != null
        ? paragraph.localToGlobal(Offset(minLeft, minTop), ancestor: overlayBox)
        : paragraph.localToGlobal(Offset(minLeft, minTop));
    final bottomRight = overlayBox != null
        ? paragraph.localToGlobal(
            Offset(maxRight, maxBottom),
            ancestor: overlayBox,
          )
        : paragraph.localToGlobal(Offset(maxRight, maxBottom));

    final mediaPadding = MediaQuery.paddingOf(overlayContext);
    final selectionRect = Rect.fromPoints(topLeft, bottomRight);

    return EchoSelectionToolbar(
      selectionRect: selectionRect,
      safeTop: mediaPadding.top + 4,
      safeBottom: mediaPadding.bottom + 4,
      topClearance: mediaPadding.top + 32 + 4,
      bottomClearance: mediaPadding.bottom + 32 + 4,
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
        final rawText = widget.page.text.substring(s, e);
        final text = widget.page.isBilingual
            ? () {
                final mapped = resolveOriginalSelectionForPage(
                  widget.page,
                  s,
                  e,
                );
                return mapped.quote.isNotEmpty ? mapped.quote : rawText;
              }()
            : rawText;
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (widget.page.isBilingual) {
      return _buildBilingualPageText(context, isDark);
    }

    final segments = buildStyledPageSegments(
      page: widget.page,
      annotations: widget.annotations,
      activeCueSpan:
          widget.activeCueSpans.isNotEmpty ? widget.activeCueSpans.first : null,
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
                spanStyle = _applyAnnotationStyle(spanStyle, ann, isDark);
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

  TextStyle _applyAnnotationStyle(
    TextStyle base,
    ReadingAnnotation ann,
    bool isDark,
  ) {
    return base.copyWith(
      decoration: TextDecoration.underline,
      decorationColor: ann.color.color,
      decorationThickness: ann.hasNote ? 2.2 : 1.8,
      decorationStyle:
          ann.hasNote ? TextDecorationStyle.double : TextDecorationStyle.solid,
      backgroundColor: ann.color.color.withValues(
        alpha: ann.hasNote ? (isDark ? 0.22 : 0.24) : (isDark ? 0.12 : 0.14),
      ),
    );
  }

  /// 双语伴随高亮：中文已划线对应的英文副标采用同色系淡底色与提亮字色（不加下划线，保持主次层次）。
  TextStyle _applyCompanionHighlightStyle(
    TextStyle base,
    ReadingAnnotation ann,
    bool isDark,
  ) {
    final accent = ann.color.color;
    final primaryInk =
        widget.textStyle.color ?? (isDark ? Colors.white : Colors.black);
    final liftedColor = Color.lerp(primaryInk, accent, isDark ? 0.45 : 0.28)!;
    return base.copyWith(
      color: liftedColor,
      backgroundColor: accent.withValues(
        alpha: ann.hasNote ? (isDark ? 0.22 : 0.26) : (isDark ? 0.18 : 0.22),
      ),
    );
  }

  Widget _buildBilingualPageText(BuildContext context, bool isDark) {
    final blocks = widget.page.blocks ?? const <BilingualPageBlock>[];
    final runs = widget.page.displayRuns;
    final pageText = widget.page.text;
    final styles = bilingualTypographyStyles(
      origStyle: widget.textStyle,
      secondaryColor: widget.secondaryColor,
    );
    final tokens = Theme.of(context).extension<EchoTokens>();
    final activeTintColor = (tokens?.primary ?? widget.secondaryColor)
        .withValues(alpha: isDark ? 0.14 : 0.11);
    final activeTranslatingParagraphIndices = <int>{
      if (widget.activeTranslatingHash != null)
        for (final b in blocks)
          if (!b.hasTranslation &&
              b.paragraphHash == widget.activeTranslatingHash)
            b.paragraphIndex,
    };

    // 投影批注到展示坐标：严格按划线语种与句内精确偏移回显，并附带对应英文伴随高亮
    final projectedAnns = projectBilingualAnnotationsForPage(
      page: widget.page,
      annotations: widget.annotations,
    );
    final activeIds = <String>{
      for (final p in projectedAnns) p.annotation.id,
    };

    _annotationRecognizers.removeWhere((id, recognizer) {
      if (activeIds.contains(id)) return false;
      recognizer.dispose();
      return true;
    });

    final cueSpans = widget.activeCueSpans;
    final children = <InlineSpan>[];

    void emitRange(int start, int end, TextStyle baseStyle) {
      if (start >= end || end > pageText.length) return;
      final points = <int>{start, end};
      for (final p in projectedAnns) {
        final s = p.start.clamp(start, end);
        final e = p.end.clamp(start, end);
        if (s < e) {
          points.add(s);
          points.add(e);
        }
      }
      for (final cue in cueSpans) {
        final cs = cue.start.clamp(start, end);
        final ce = cue.end.clamp(start, end);
        if (cs < ce) {
          points.add(cs);
          points.add(ce);
        }
      }
      final sorted = points.toList()..sort();
      ReadingAnnotation pickHigherAnnotation(
        ReadingAnnotation? current,
        ReadingAnnotation candidate,
      ) {
        if (current == null) return candidate;
        final curRank = current.hasNote ? 1 : 0;
        final nextRank = candidate.hasNote ? 1 : 0;
        if (nextRank > curRank ||
            (nextRank == curRank &&
                candidate.updatedAt.isAfter(current.updatedAt))) {
          return candidate;
        }
        return current;
      }

      for (var i = 0; i + 1 < sorted.length; i++) {
        final s = sorted[i];
        final e = sorted[i + 1];
        if (s >= e) continue;
        ReadingAnnotation? bestPrimaryAnn;
        ReadingAnnotation? bestCompanionAnn;
        for (final p in projectedAnns) {
          if (p.start <= s && p.end >= e) {
            if (!p.isCompanion) {
              bestPrimaryAnn = pickHigherAnnotation(
                bestPrimaryAnn,
                p.annotation,
              );
            } else {
              bestCompanionAnn = pickHigherAnnotation(
                bestCompanionAnn,
                p.annotation,
              );
            }
          }
        }
        final isCue = cueSpans.any((c) => c.start <= s && c.end >= e);
        var spanStyle = baseStyle;
        TapGestureRecognizer? recognizer;
        if (bestPrimaryAnn != null) {
          recognizer = _recognizerFor(bestPrimaryAnn);
          spanStyle = _applyAnnotationStyle(spanStyle, bestPrimaryAnn, isDark);
        } else if (bestCompanionAnn != null) {
          recognizer = _recognizerFor(bestCompanionAnn);
          spanStyle = _applyCompanionHighlightStyle(
            spanStyle,
            bestCompanionAnn,
            isDark,
          );
        }
        if (isCue) {
          spanStyle = spanStyle.copyWith(backgroundColor: widget.highlightColor);
        }
        children.add(
          TextSpan(
            text: pageText.substring(s, e),
            style: spanStyle,
            recognizer: recognizer,
          ),
        );
      }
    }

    if (runs != null && runs.isNotEmpty) {
      for (final r in runs) {
        final ds = r.displayStart.clamp(0, pageText.length);
        final de = r.displayEnd.clamp(ds, pageText.length);
        if (ds >= de) continue;
        switch (r.kind) {
          case BilingualRunKind.innerBreak:
            children.add(
              TextSpan(
                text: pageText.substring(ds, de),
                style: styles.innerBreakStyle,
              ),
            );
          case BilingualRunKind.pairGapBreak:
            children.add(
              TextSpan(
                text: pageText.substring(ds, de),
                style: styles.pairGapBreakStyle,
              ),
            );
          case BilingualRunKind.sentenceBreak:
            children.add(
              TextSpan(
                text: pageText.substring(ds, de),
                style: styles.sentenceBreakStyle,
              ),
            );
          case BilingualRunKind.paragraphBreak:
            children.add(
              TextSpan(
                text: pageText.substring(ds, de),
                style: styles.paragraphBreakStyle,
              ),
            );
          case BilingualRunKind.transPrimary:
            emitRange(ds, de, styles.transPrimaryStyle);
          case BilingualRunKind.origSubtitle:
            emitRange(ds, de, styles.origSubtitleStyle);
          case BilingualRunKind.untranslatedOrig:
            final isActiveTranslating = r.isTranslating ||
                activeTranslatingParagraphIndices.contains(r.paragraphIndex);
            final untransStyle = isActiveTranslating
                ? styles.untranslatedOrigStyle.copyWith(
                    color: widget.textStyle.color,
                    backgroundColor: activeTintColor,
                  )
                : styles.untranslatedOrigStyle;
            emitRange(ds, de, untransStyle);
        }
      }
    } else {
      var cursor = 0;
      for (var i = 0; i < blocks.length; i++) {
        final b = blocks[i];
        if (i > 0) {
          final gapEnd = math.min(pageText.length, cursor + 2);
          if (cursor < gapEnd) {
            children.add(
              TextSpan(
                text: pageText.substring(cursor, gapEnd),
                style: blocks[i - 1].isParagraphEnd
                    ? styles.paragraphBreakStyle
                    : styles.sentenceBreakStyle,
              ),
            );
            cursor = gapEnd;
          }
        }
        final isBlockActive = b.isTranslating ||
            (!b.hasTranslation &&
                widget.activeTranslatingHash != null &&
                b.paragraphHash == widget.activeTranslatingHash);
        if (b.mode == BilingualDisplayMode.translatedOnly) {
          if (b.hasTranslation) {
            emitRange(
              b.transDisplayStart,
              b.transDisplayEnd,
              styles.transPrimaryStyle,
            );
            cursor = b.transDisplayEnd;
          } else {
            final untransStyle = isBlockActive
                ? styles.untranslatedOrigStyle.copyWith(
                    color: widget.textStyle.color,
                    backgroundColor: activeTintColor,
                  )
                : styles.untranslatedOrigStyle;
            emitRange(b.origDisplayStart, b.origDisplayEnd, untransStyle);
            cursor = b.origDisplayEnd;
          }
        } else {
          if (b.hasTranslation) {
            emitRange(
              b.transDisplayStart,
              b.transDisplayEnd,
              styles.transPrimaryStyle,
            );
            final innerEnd = b.origDisplayStart;
            if (b.transDisplayEnd < innerEnd) {
              children.add(
                TextSpan(
                  text: pageText.substring(b.transDisplayEnd, innerEnd),
                  style: styles.innerBreakStyle,
                ),
              );
            }
            emitRange(
              b.origDisplayStart,
              b.origDisplayEnd,
              styles.origSubtitleStyle,
            );
            cursor = b.origDisplayEnd;
          } else {
            final untransStyle = isBlockActive
                ? styles.untranslatedOrigStyle.copyWith(
                    color: widget.textStyle.color,
                    backgroundColor: activeTintColor,
                  )
                : styles.untranslatedOrigStyle;
            emitRange(b.origDisplayStart, b.origDisplayEnd, untransStyle);
            cursor = b.origDisplayEnd;
          }
        }
      }
    }

    return Text.rich(
      key: Key('reader_page_text_${widget.index}'),
      style: widget.textStyle,
      textHeightBehavior: _kReaderTextHeightBehavior,
      TextSpan(style: widget.textStyle, children: children),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final boxes = _computeSelectionBoxes(_findRenderParagraph());
    final firstBox = boxes.isNotEmpty ? boxes.first : null;
    final lastBox = boxes.isNotEmpty ? boxes.last : null;

    final pageContent = Stack(
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
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _hasSelection ? _clearSelection : widget.onTapCanvas,
      onLongPressStart: _onLongPressStart,
      onLongPressMoveUpdate: _onLongPressMoveUpdate,
      onLongPressEnd: (_) {
        if (_hasSelection) _showOrUpdateToolbar();
      },
      child: widget.page.isBilingual
          ? SingleChildScrollView(
              physics: _hasSelection
                  ? const NeverScrollableScrollPhysics()
                  : const ClampingScrollPhysics(),
              child: pageContent,
            )
          : pageContent,
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
