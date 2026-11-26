import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../design/book_cover.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../jobs/jobs_controller.dart';
import '../providers/provider_account_page.dart';
import 'search_controller.dart';

/// 弹出高级筛选条件（语言 / 年份 / 排序），支持控制应用后是否立即重新发起搜索。
Future<void> showSearchFiltersSheet(
  BuildContext context,
  SearchControllerImpl controller, {
  bool triggerSearch = true,
}) async {
  final tokens = Theme.of(context).extension<EchoTokens>()!;
  var languages = List<String>.of(controller.filters.languages);
  var yearFrom = controller.filters.yearFrom;
  var yearTo = controller.filters.yearTo;
  var order = controller.filters.order;

  const languageOptions = <String, String>{
    'chinese': '中文',
    'english': '英文',
    'japanese': '日文',
    'german': '德文',
    'french': '法文',
    'spanish': '西班牙文',
    'russian': '俄文',
  };
  const orderOptions = <String, String>{
    '': '相关度',
    'popular': '最热',
    'date': '最新',
  };

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) => SafeArea(
        child: Padding(
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
                '筛选条件',
                style: Theme.of(sheetCtx).textTheme.titleMedium?.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: EchoMetrics.space2),
              Text(
                '语言',
                style: Theme.of(sheetCtx).textTheme.labelMedium?.copyWith(
                  color: tokens.textSecondary,
                ),
              ),
              const SizedBox(height: EchoMetrics.space1),
              Wrap(
                spacing: EchoMetrics.space1,
                runSpacing: EchoMetrics.space1,
                children: [
                  for (final entry in languageOptions.entries)
                    FilterChip(
                      key: Key('filter_lang_${entry.key}'),
                      label: Text(entry.value),
                      selected: languages.contains(entry.key),
                      onSelected: (v) => setSheetState(() {
                        v
                            ? languages.add(entry.key)
                            : languages.remove(entry.key);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: EchoMetrics.space2),
              Text(
                '出版年份',
                style: Theme.of(sheetCtx).textTheme.labelMedium?.copyWith(
                  color: tokens.textSecondary,
                ),
              ),
              const SizedBox(height: EchoMetrics.space1),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const Key('filter_year_from'),
                      initialValue: yearFrom > 0 ? '$yearFrom' : '',
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: '起始年'),
                      onChanged: (v) => yearFrom = int.tryParse(v) ?? 0,
                    ),
                  ),
                  const SizedBox(width: EchoMetrics.space2),
                  Expanded(
                    child: TextFormField(
                      key: const Key('filter_year_to'),
                      initialValue: yearTo > 0 ? '$yearTo' : '',
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: '结束年'),
                      onChanged: (v) => yearTo = int.tryParse(v) ?? 0,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: EchoMetrics.space2),
              Text(
                '排序',
                style: Theme.of(sheetCtx).textTheme.labelMedium?.copyWith(
                  color: tokens.textSecondary,
                ),
              ),
              const SizedBox(height: EchoMetrics.space1),
              Wrap(
                spacing: EchoMetrics.space1,
                children: [
                  for (final entry in orderOptions.entries)
                    ChoiceChip(
                      key: Key(
                        'filter_order_${entry.key.isEmpty ? 'relevance' : entry.key}',
                      ),
                      label: Text(entry.value),
                      selected: order == entry.key,
                      onSelected: (_) => setSheetState(() => order = entry.key),
                    ),
                ],
              ),
              const SizedBox(height: EchoMetrics.space3),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('filter_reset'),
                      onPressed: () => setSheetState(() {
                        languages = <String>[];
                        yearFrom = 0;
                        yearTo = 0;
                        order = '';
                      }),
                      child: const Text('重置'),
                    ),
                  ),
                  const SizedBox(width: EchoMetrics.space2),
                  Expanded(
                    child: FilledButton(
                      key: const Key('filter_apply'),
                      onPressed: () {
                        Navigator.of(sheetCtx).pop();
                        controller.setFilters(
                          controller.filters.copyWith(
                            languages: languages,
                            yearFrom: yearFrom,
                            yearTo: yearTo,
                            order: order,
                          ),
                          triggerSearch: triggerSearch,
                        );
                      },
                      child: const Text('应用'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 书源在线搜索结果路由页：支持顶部搜索框、筛选条件、分页加载及跳转搜索详情页。
class SearchResultsPage extends ConsumerStatefulWidget {
  const SearchResultsPage({
    super.key,
    this.initialQuery = '',
    this.autoFocus = false,
  });

  final String initialQuery;
  final bool autoFocus;

  @override
  ConsumerState<SearchResultsPage> createState() => _SearchResultsPageState();
}

class _SearchResultsPageState extends ConsumerState<SearchResultsPage> {
  final _controller = TextEditingController();
  final _searchFocusNode = FocusNode();
  final Set<String> _pendingRefs = <String>{};

  @override
  void initState() {
    super.initState();
    final trimmed = widget.initialQuery.trim();
    _controller.text = trimmed;
    if (trimmed.isNotEmpty) {
      Future<void>.microtask(() {
        if (!mounted) return;
        final current = ref.read(searchControllerProvider);
        final notifier = ref.read(searchControllerProvider.notifier);
        if (current.lastQuery != trimmed) {
          notifier.clearSearch();
        }
        notifier.search(trimmed);
      });
    } else if (widget.autoFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() {
    if (!ref.read(onlineSearchAvailableProvider)) {
      return Future<void>.value();
    }
    final query = _controller.text;
    return ref.read(searchControllerProvider.notifier).search(query).then((_) {
      if (!mounted) return;
      FocusScope.of(context).unfocus();
    });
  }

  Future<void> _download(
    String bookRef,
    String provider, {
    bool autoConvert = false,
  }) async {
    if (_pendingRefs.contains(bookRef)) return;
    setState(() => _pendingRefs.add(bookRef));
    try {
      final job = await ref
          .read(echoApiProvider)
          .downloadBook(provider: provider, ref: bookRef);
      final jobsNotifier = ref.read(jobsControllerProvider.notifier);
      if (autoConvert) {
        jobsNotifier.registerAutoConvert(job.id);
      } else {
        await jobsNotifier.refresh();
      }
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              autoConvert
                  ? '已加入下载队列，下载完成后将自动转有声书'
                  : '已加入下载任务，可在「任务」页查看进度',
            ),
          ),
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) {
        setState(() => _pendingRefs.remove(bookRef));
      }
    }
  }

  Future<void> _openDetail(SearchBook book) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SearchBookDetailPage(
          book: book,
          onDownload: () => _download(book.ref, book.provider),
          onDownloadAndConvert: () =>
              _download(book.ref, book.provider, autoConvert: true),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(searchControllerProvider);
    final controller = ref.read(searchControllerProvider.notifier);
    final hairline = echoHairlineColor(context, darkAlpha: 0.06);
    final epubOnly = controller.filters.extensions.contains('EPUB');
    final bottomPadding = ref.watch(chunkedPlayerProvider).hasBook
        ? 112.0
        : EchoMetrics.space3;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: EchoMetrics.pagePadding),
          child: TextField(
            key: const Key('search_results_field'),
            controller: _controller,
            focusNode: _searchFocusNode,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: '搜索书名、作者、ISBN',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 9,
              ),
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 38,
                minHeight: 38,
              ),
              suffixIconConstraints: const BoxConstraints(
                minWidth: 38,
                minHeight: 38,
              ),
              suffixIcon: state.isLoading
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: tokens.primary,
                        ),
                      ),
                    )
                  : ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _controller,
                      builder: (context, value, _) {
                        if (value.text.isEmpty) {
                          return IconButton(
                            icon: const Icon(
                              Icons.arrow_forward_rounded,
                              size: 18,
                            ),
                            onPressed: _submit,
                          );
                        }
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: const Key('search_results_clear_button'),
                              tooltip: '清空搜索',
                              icon: const Icon(Icons.close_rounded, size: 17),
                              onPressed: () {
                                _controller.clear();
                                controller.clearSearch();
                                _searchFocusNode.requestFocus();
                                setState(() {});
                              },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.arrow_forward_rounded,
                                size: 18,
                              ),
                              onPressed: _submit,
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ),
        ),
      ),
      body: EchoAmbientBackground(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                EchoMetrics.pagePadding,
                4,
                EchoMetrics.pagePadding,
                6,
              ),
              child: Row(
                children: [
                  FilterChip(
                    key: const Key('search_results_epub_filter'),
                    visualDensity: VisualDensity.compact,
                    label: const Text('仅 EPUB'),
                    selected: epubOnly,
                    onSelected: (v) {
                      controller.setFilters(
                        controller.filters.copyWith(
                          extensions: v ? const ['EPUB'] : const [],
                        ),
                        triggerSearch: true,
                      );
                      setState(() {});
                    },
                  ),
                  const SizedBox(width: EchoMetrics.space1),
                  ActionChip(
                    key: const Key('search_results_filter_button'),
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(
                      Icons.tune_rounded,
                      size: 16,
                      color: controller.filters.activeCount > 0
                          ? tokens.primary
                          : tokens.textSecondary,
                    ),
                    label: Text(
                      controller.filters.activeCount == 0
                          ? '筛选'
                          : '筛选 ${controller.filters.activeCount}',
                    ),
                    onPressed: () => showSearchFiltersSheet(
                      context,
                      controller,
                      triggerSearch: true,
                    ),
                  ),
                ],
              ),
            ),
            if (state.error != null)
              Container(
                key: const Key('search_error_banner'),
                margin: const EdgeInsets.fromLTRB(
                  EchoMetrics.pagePadding,
                  EchoMetrics.spaceHalf,
                  EchoMetrics.pagePadding,
                  EchoMetrics.space1,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: echoElevatedCardDecoration(
                  context,
                  radius: 14,
                  color: tokens.error.withValues(alpha: 0.08),
                  borderColor: tokens.error.withValues(alpha: 0.25),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        state.error!,
                        style: textTheme.bodySmall?.copyWith(
                          color: tokens.error,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const Key('search_go_configure'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ProviderAccountPage(),
                        ),
                      ),
                      child: const Text('去配置账号'),
                    ),
                  ],
                ),
              ),
            if (state.isLoading && state.books.isNotEmpty)
              LinearProgressIndicator(
                minHeight: 2,
                color: tokens.primary,
                backgroundColor: tokens.surfaceSubtle,
              ),
            Expanded(
              child: state.books.isEmpty && state.isLoading
                  ? Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: tokens.primary,
                      ),
                    )
                  : state.books.isEmpty && state.lastQuery.isNotEmpty
                  ? Center(
                      key: const Key('search_no_results'),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '没有找到相关书籍',
                            style: textTheme.bodyMedium?.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                          const SizedBox(height: EchoMetrics.space1),
                          TextButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            child: const Text('返回上一页'),
                          ),
                        ],
                      ),
                    )
                  : state.books.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(EchoMetrics.pagePadding),
                      children: [
                        if (state.history.isNotEmpty) ...[
                          Text(
                            '搜索历史',
                            style: textTheme.labelMedium?.copyWith(
                              color: tokens.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: EchoMetrics.space1),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final q in state.history)
                                InputChip(
                                  label: Text(q),
                                  onPressed: () {
                                    _controller.text = q;
                                    _submit();
                                  },
                                  onDeleted: () => controller.removeHistory(q),
                                  backgroundColor: tokens.surfaceElevated,
                                  side: BorderSide(
                                    color: echoHairlineColor(context),
                                    width: 0.8,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    )
                  : ListView.separated(
                      key: const Key('search_results'),
                      padding: EdgeInsets.fromLTRB(
                        EchoMetrics.pagePadding,
                        EchoMetrics.spaceHalf,
                        EchoMetrics.pagePadding,
                        bottomPadding,
                      ),
                      itemCount: state.books.length + (state.hasMore ? 1 : 0),
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, thickness: 0.6, color: hairline),
                      itemBuilder: (context, index) {
                        if (index >= state.books.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Center(
                              child: EchoSecondaryButton(
                                key: const Key('search_load_more'),
                                onPressed: state.isLoading
                                    ? null
                                    : controller.loadMore,
                                icon: Icons.expand_more_rounded,
                                label: '加载更多',
                              ),
                            ),
                          );
                        }
                        final book = state.books[index];
                        final authorText = book.authors.isNotEmpty
                            ? book.authors.join(', ')
                            : '未知作者';
                        return InkWell(
                          key: Key('search_result_${book.ref}'),
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => _openDetail(book),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(
                              children: [
                                BookCover(
                                  url: book.coverUrl,
                                  title: book.title,
                                  author: authorText,
                                  width: 50,
                                  height: 70,
                                  borderRadius: 7,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        book.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.titleSmall?.copyWith(
                                          color: tokens.textPrimary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        book.year.isNotEmpty
                                            ? '$authorText · ${book.year}'
                                            : authorText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.bodySmall?.copyWith(
                                          fontSize: 13,
                                          color: tokens.textSecondary,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          if (book.provider.isNotEmpty)
                                            _SearchMetaPill(
                                              key: Key(
                                                'search_pill_provider_${book.ref}',
                                              ),
                                              label: book.provider
                                                  .toUpperCase(),
                                              highlighted: true,
                                            ),
                                          _SearchMetaPill(
                                            key: Key(
                                              'search_pill_format_${book.ref}',
                                            ),
                                            label: book.format.toUpperCase(),
                                          ),
                                          if (book.size.isNotEmpty)
                                            _SearchMetaPill(
                                              key: Key(
                                                'search_pill_size_${book.ref}',
                                              ),
                                              label: book.size,
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _pendingRefs.contains(book.ref)
                                    ? SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: tokens.primary,
                                        ),
                                      )
                                    : IconButton(
                                        key: Key(
                                          'search_download_${book.ref}',
                                        ),
                                        tooltip: '下载到书库',
                                        style: IconButton.styleFrom(
                                          backgroundColor: tokens.primary
                                              .withValues(alpha: 0.12),
                                          foregroundColor: tokens.primary,
                                        ),
                                        icon: const Icon(
                                          Icons.download_rounded,
                                          size: 20,
                                        ),
                                        onPressed: () => _download(
                                          book.ref,
                                          book.provider,
                                        ),
                                      ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 搜索结果书籍详情路由页（支持返回结果列表页与下载操作）。
class SearchBookDetailPage extends ConsumerStatefulWidget {
  const SearchBookDetailPage({
    super.key,
    required this.book,
    required this.onDownload,
    required this.onDownloadAndConvert,
  });

  final SearchBook book;
  final VoidCallback onDownload;
  final VoidCallback onDownloadAndConvert;

  @override
  ConsumerState<SearchBookDetailPage> createState() =>
      _SearchBookDetailPageState();
}

class _SearchBookDetailPageState extends ConsumerState<SearchBookDetailPage> {
  late Future<SearchBook> _detail;

  @override
  void initState() {
    super.initState();
    _detail = ref
        .read(echoApiProvider)
        .providerBook(providerId: widget.book.provider, ref: widget.book.ref)
        .catchError((_) => widget.book);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    return FutureBuilder<SearchBook>(
      future: _detail,
      builder: (context, snapshot) {
        final data = snapshot.data ?? widget.book;
        final authorText = data.authors.isNotEmpty
            ? data.authors.join(', ')
            : '未知作者';
        final fmt = data.format.toLowerCase();
        final canConvert = fmt == 'epub' || fmt == 'txt';

        return Scaffold(
          appBar: AppBar(title: const Text('书籍详情')),
          bottomNavigationBar: SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(
                EchoMetrics.pagePadding,
                10,
                EchoMetrics.pagePadding,
                12,
              ),
              decoration: BoxDecoration(
                color: tokens.surfaceElevated,
                border: Border(
                  top: BorderSide(color: echoHairlineColor(context), width: 0.8),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (canConvert) ...[
                    EchoPrimaryButton(
                      key: const Key('search_detail_download_convert'),
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onDownloadAndConvert();
                      },
                      icon: Icons.graphic_eq_rounded,
                      label: '下载并转有声书',
                    ),
                    const SizedBox(height: 10),
                    EchoSecondaryButton(
                      key: const Key('search_detail_download'),
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onDownload();
                      },
                      icon: Icons.download_rounded,
                      label: '直接下载（可看）',
                    ),
                  ] else
                    EchoPrimaryButton(
                      key: const Key('search_detail_download'),
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onDownload();
                      },
                      icon: Icons.download_rounded,
                      label: '下载到书库',
                    ),
                ],
              ),
            ),
          ),
          body: EchoAmbientBackground(
            child: ListView(
              key: const Key('search_detail_sheet'),
              padding: const EdgeInsets.fromLTRB(
                EchoMetrics.pagePadding,
                EchoMetrics.space2,
                EchoMetrics.pagePadding,
                EchoMetrics.space3,
              ),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    BookCover(
                      url: data.coverUrl,
                      title: data.title,
                      author: authorText,
                      width: 88,
                      height: 126,
                      borderRadius: 10,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            data.title,
                            key: const Key('search_detail_title'),
                            style: textTheme.titleLarge?.copyWith(
                              color: tokens.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            authorText,
                            style: textTheme.bodySmall?.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (data.provider.isNotEmpty)
                                _SearchMetaPill(
                                  label: data.provider.toUpperCase(),
                                  highlighted: true,
                                ),
                              if (data.year.isNotEmpty)
                                _SearchMetaPill(label: data.year),
                              if (data.publisher.isNotEmpty)
                                _SearchMetaPill(label: data.publisher),
                              if (data.language.isNotEmpty)
                                _SearchMetaPill(label: data.language),
                              if (data.format.isNotEmpty)
                                _SearchMetaPill(
                                  label: data.format.toUpperCase(),
                                ),
                              if (data.size.isNotEmpty)
                                _SearchMetaPill(label: data.size),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: EchoMetrics.space3),
                if (data.description.isNotEmpty) ...[
                  const EchoSectionHeader(title: '内容简介'),
                  const SizedBox(height: 8),
                  Text(
                    data.description,
                    key: const Key('search_detail_description'),
                    style: textTheme.bodyMedium?.copyWith(
                      fontSize: 14.5,
                      color: tokens.textPrimary,
                      height: 1.7,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SearchMetaPill extends StatelessWidget {
  const _SearchMetaPill({
    super.key,
    required this.label,
    this.highlighted = false,
  });

  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return EchoPillBadge(
      label: label,
      color: highlighted ? tokens.primary : tokens.textSecondary,
    );
  }
}
