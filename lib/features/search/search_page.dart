import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../core/settings/standalone_config_store.dart';
import '../../design/book_cover.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../jobs/jobs_controller.dart';
import '../providers/provider_account_page.dart';
import '../settings/ebook_api_settings_page.dart';
import 'search_controller.dart';

// flutter/material 自带同名 SearchController，这里显式指向本项目的控制器类型
typedef Record = void;

/// 发现 Tab：跨书源搜索（zlib）→ 搜索历史 / 结果列表 → 详情弹层 / 一键下载与转有声书。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  bool _epubOnly = false;
  final Set<String> _pendingRefs = <String>{};

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() {
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

  /// 高级筛选：语言 / 年份 / 排序。
  Future<void> _showFilters(SearchControllerImpl controller) async {
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
            padding: const EdgeInsets.all(EchoMetrics.space3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '筛选',
                  style: Theme.of(
                    sheetCtx,
                  ).textTheme.titleMedium?.copyWith(color: tokens.textPrimary),
                ),
                const SizedBox(height: EchoMetrics.space2),
                Text(
                  '语言',
                  style: Theme.of(
                    sheetCtx,
                  ).textTheme.labelLarge?.copyWith(color: tokens.textSecondary),
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
                  style: Theme.of(
                    sheetCtx,
                  ).textTheme.labelLarge?.copyWith(color: tokens.textSecondary),
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
                  style: Theme.of(
                    sheetCtx,
                  ).textTheme.labelLarge?.copyWith(color: tokens.textSecondary),
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
                        onSelected: (_) =>
                            setSheetState(() => order = entry.key),
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

  /// 搜索结果详情弹层（设计图 ui-mobile-search：行点击看简介 → 直接下载 / 下载并转有声书）。
  Future<void> _showDetail(SearchBook book) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetCtx) => _SearchDetailSheet(
        book: book,
        onDownload: () {
          Navigator.of(sheetCtx).pop();
          _download(book.ref, book.provider);
        },
        onDownloadAndConvert: () {
          Navigator.of(sheetCtx).pop();
          _download(book.ref, book.provider, autoConvert: true);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(searchControllerProvider);
    final controller = ref.read(searchControllerProvider.notifier);
    final standaloneCfg = ref.watch(standaloneConfigProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            EchoMetrics.space2,
            EchoMetrics.space2,
            EchoMetrics.space2,
            0,
          ),
          child: Row(
            children: [
              Text(
                '发现',
                key: const Key('search_title'),
                style: textTheme.headlineSmall?.copyWith(
                  color: tokens.textPrimary,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const EbookApiSettingsPage(),
                  ),
                ),
                icon: const Icon(Icons.dns_outlined, size: 16),
                label: Text(standaloneCfg.hasEbookApi ? '书源服务' : '配置服务'),
              ),
            ],
          ),
        ),
        if (!standaloneCfg.hasEbookApi)
          Container(
            key: const Key('search_ebook_api_banner'),
            margin: const EdgeInsets.fromLTRB(
              EchoMetrics.space2,
              EchoMetrics.space1,
              EchoMetrics.space2,
              0,
            ),
            padding: const EdgeInsets.all(EchoMetrics.space2),
            decoration: BoxDecoration(
              color: tokens.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: tokens.primary.withValues(alpha: 0.28),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: tokens.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '尚未配置 ebook-api 服务地址，配置后即可在线搜书下载',
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textPrimary,
                    ),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const EbookApiSettingsPage(),
                    ),
                  ),
                  child: const Text('去配置'),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(EchoMetrics.space2),
          child: TextField(
            key: const Key('search_field'),
            controller: _controller,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: '搜索书名、作者（zlib 书源）',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: state.isLoading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: _submit,
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: EchoMetrics.space2),
          child: Row(
            children: [
              FilterChip(
                key: const Key('search_epub_filter'),
                label: const Text('仅 EPUB'),
                selected: _epubOnly,
                onSelected: (v) {
                  setState(() => _epubOnly = v);
                  controller.setFilters(
                    controller.filters.copyWith(
                      extensions: v ? const ['EPUB'] : const [],
                    ),
                  );
                },
              ),
              const SizedBox(width: EchoMetrics.space1),
              ActionChip(
                key: const Key('search_filter_button'),
                avatar: const Icon(Icons.tune, size: 16),
                label: Text(
                  controller.filters.activeCount == 0
                      ? '筛选'
                      : '筛选 ${controller.filters.activeCount}',
                ),
                onPressed: () => _showFilters(controller),
              ),
            ],
          ),
        ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.all(EchoMetrics.space2),
            child: Card(
              key: const Key('search_error_banner'),
              child: Padding(
                padding: const EdgeInsets.all(EchoMetrics.space2),
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
            ),
          ),
        if (state.isLoading && state.books.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: state.books.isEmpty && !state.isLoading
              ? _EmptyOrHistory(
                  hasSearched: state.lastQuery.isNotEmpty,
                  history: state.history,
                  onPick: (q) {
                    _controller.text = q;
                    _submit();
                  },
                  onRemove: controller.removeHistory,
                )
              : state.books.isEmpty && state.isLoading
              ? const Center(child: CircularProgressIndicator())
              : ListView.separated(
                  key: const Key('search_results'),
                  padding: EdgeInsets.fromLTRB(
                    EchoMetrics.space2,
                    EchoMetrics.space2,
                    EchoMetrics.space2,
                    ref.watch(chunkedPlayerProvider).hasBook
                        ? 104
                        : EchoMetrics.space2,
                  ),
                  itemCount: state.books.length + (state.hasMore ? 1 : 0),
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: EchoMetrics.space1),
                  itemBuilder: (context, index) {
                    if (index >= state.books.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: EchoMetrics.space1,
                        ),
                        child: Center(
                          child: FilledButton.tonalIcon(
                            key: const Key('search_load_more'),
                            onPressed: state.isLoading
                                ? null
                                : controller.loadMore,
                            icon: const Icon(Icons.expand_more),
                            label: const Text('加载更多'),
                          ),
                        ),
                      );
                    }
                    final book = state.books[index];
                    final authorText = book.authors.isNotEmpty
                        ? book.authors.join(', ')
                        : '未知作者';
                    return Card(
                      key: Key('search_result_${book.ref}'),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(
                          EchoMetrics.radiusCard,
                        ),
                        onTap: () => _showDetail(book),
                        child: Padding(
                          padding: const EdgeInsets.all(EchoMetrics.space2),
                          child: Row(
                            children: [
                              BookCover(
                                url: book.coverUrl,
                                width: 48,
                                height: 64,
                              ),
                              const SizedBox(width: EchoMetrics.space2),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      book.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.titleMedium?.copyWith(
                                        color: tokens.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '$authorText · ${book.year}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodySmall?.copyWith(
                                        color: tokens.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(height: EchoMetrics.space1),
                                    // 来源 / 格式标签胶囊（设计图 ui-mobile-search）。
                                    Wrap(
                                      spacing: EchoMetrics.spaceHalf,
                                      runSpacing: EchoMetrics.spaceHalf,
                                      children: [
                                        if (book.provider.isNotEmpty)
                                          _MetaPill(
                                            key: Key(
                                              'search_pill_provider_${book.ref}',
                                            ),
                                            label: book.provider.toUpperCase(),
                                            highlighted: true,
                                          ),
                                        _MetaPill(
                                          key: Key(
                                            'search_pill_format_${book.ref}',
                                          ),
                                          label: book.format.toUpperCase(),
                                        ),
                                        if (book.size.isNotEmpty)
                                          _MetaPill(
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
                              _pendingRefs.contains(book.ref)
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : IconButton(
                                      key: Key('search_download_${book.ref}'),
                                      tooltip: '下载到书库',
                                      icon: Icon(
                                        Icons.download,
                                        color: tokens.primary,
                                      ),
                                      onPressed: () =>
                                          _download(book.ref, book.provider),
                                    ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 元信息小胶囊。
class _MetaPill extends StatelessWidget {
  const _MetaPill({
    super.key,
    required this.label,
    this.highlighted = false,
  });

  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: EchoMetrics.space1,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: highlighted
            ? tokens.primary.withValues(alpha: 0.16)
            : tokens.surfaceSubtle,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: highlighted ? tokens.primary : tokens.textSecondary,
          fontWeight: highlighted ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}

/// 空态：未搜索时展示搜索历史（设计图：历史关键词胶囊，可点选、可删除）。
class _EmptyOrHistory extends StatelessWidget {
  const _EmptyOrHistory({
    required this.hasSearched,
    required this.history,
    required this.onPick,
    required this.onRemove,
  });

  final bool hasSearched;
  final List<String> history;
  final ValueChanged<String> onPick;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    if (!hasSearched && history.isEmpty) {
      return Center(
        key: const Key('search_empty'),
        child: Text(
          '输入关键词，搜一本想听的书',
          style: textTheme.bodyLarge?.copyWith(color: tokens.textSecondary),
        ),
      );
    }

    if (hasSearched && history.isEmpty) {
      return Center(
        key: const Key('search_no_results'),
        child: Text(
          '没有找到相关书籍',
          style: textTheme.bodyLarge?.copyWith(color: tokens.textSecondary),
        ),
      );
    }

    return ListView(
      key: const Key('search_history'),
      padding: const EdgeInsets.all(EchoMetrics.space2),
      children: [
        Text(
          '搜索历史',
          style: textTheme.labelLarge?.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: EchoMetrics.space1),
        Wrap(
          spacing: EchoMetrics.space1,
          runSpacing: EchoMetrics.space1,
          children: [
            for (final q in history)
              InputChip(
                key: Key('search_history_chip_$q'),
                label: Text(q),
                onPressed: () => onPick(q),
                onDeleted: () => onRemove(q),
                backgroundColor: tokens.surfaceElevated,
                side: BorderSide(color: tokens.surfaceSubtle),
              ),
          ],
        ),
      ],
    );
  }
}

/// 搜索结果详情弹层：书源侧详情（providerBook）+ 简介 + 直接下载 / 下载并转有声书。
class _SearchDetailSheet extends ConsumerStatefulWidget {
  const _SearchDetailSheet({
    required this.book,
    required this.onDownload,
    required this.onDownloadAndConvert,
  });

  final SearchBook book;
  final VoidCallback onDownload;
  final VoidCallback onDownloadAndConvert;

  @override
  ConsumerState<_SearchDetailSheet> createState() => _SearchDetailSheetState();
}

class _SearchDetailSheetState extends ConsumerState<_SearchDetailSheet> {
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

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollController) => Scaffold(
        backgroundColor: tokens.surfaceBase,
        body: FutureBuilder<SearchBook>(
          future: _detail,
          builder: (context, snapshot) {
            final data = snapshot.data ?? widget.book;
            final authorText = data.authors.isNotEmpty
                ? data.authors.join(', ')
                : '未知作者';
            final isEpub = data.format.toLowerCase() == 'epub';
            return ListView(
              controller: scrollController,
              key: const Key('search_detail_sheet'),
              padding: const EdgeInsets.all(EchoMetrics.space3),
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: EchoMetrics.space2),
                    decoration: BoxDecoration(
                      color: tokens.surfaceSubtle,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: BookCover(url: data.coverUrl, width: 96, height: 128),
                ),
                const SizedBox(height: EchoMetrics.space2),
                Text(
                  data.title,
                  key: const Key('search_detail_title'),
                  style: textTheme.titleLarge?.copyWith(
                    color: tokens.textPrimary,
                  ),
                ),
                const SizedBox(height: EchoMetrics.spaceHalf),
                Text(
                  authorText,
                  style: textTheme.bodyMedium?.copyWith(
                    color: tokens.textSecondary,
                  ),
                ),
                const SizedBox(height: EchoMetrics.space2),
                Wrap(
                  spacing: EchoMetrics.spaceHalf,
                  runSpacing: EchoMetrics.spaceHalf,
                  children: [
                    if (data.provider.isNotEmpty)
                      _MetaPill(
                        label: data.provider.toUpperCase(),
                        highlighted: true,
                      ),
                    if (data.year.isNotEmpty) _MetaPill(label: data.year),
                    if (data.publisher.isNotEmpty)
                      _MetaPill(label: data.publisher),
                    if (data.language.isNotEmpty)
                      _MetaPill(label: data.language),
                    if (data.format.isNotEmpty)
                      _MetaPill(label: data.format.toUpperCase()),
                    if (data.size.isNotEmpty) _MetaPill(label: data.size),
                  ],
                ),
                const SizedBox(height: EchoMetrics.space2),
                if (data.description.isNotEmpty) ...[
                  Text(
                    '简介',
                    style: textTheme.labelLarge?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space1),
                  Text(
                    data.description,
                    key: const Key('search_detail_description'),
                    style: textTheme.bodyMedium?.copyWith(
                      color: tokens.textPrimary,
                      height: 1.7,
                    ),
                  ),
                ],
                const SizedBox(height: EchoMetrics.space3),
                if (isEpub) ...[
                  EchoPrimaryButton(
                    key: const Key('search_detail_download_convert'),
                    onPressed: widget.onDownloadAndConvert,
                    icon: Icons.graphic_eq,
                    label: '下载并转有声书',
                  ),
                  const SizedBox(height: EchoMetrics.space1),
                  EchoSecondaryButton(
                    key: const Key('search_detail_download'),
                    onPressed: widget.onDownload,
                    icon: Icons.download,
                    label: '直接下载（可看）',
                  ),
                ] else
                  EchoPrimaryButton(
                    key: const Key('search_detail_download'),
                    onPressed: widget.onDownload,
                    icon: Icons.download,
                    label: '下载到书库',
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
