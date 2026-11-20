import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../jobs/jobs_controller.dart';
import '../providers/provider_account_page.dart';
import 'search_controller.dart';

/// 发现 Tab：跨书源搜索（zlib）→ 搜索历史 / 结果列表 → 详情弹层 / 一键下载。
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
    return ref
        .read(searchControllerProvider.notifier)
        .search(query)
        .then((_) {
      if (!mounted) return;
      FocusScope.of(context).unfocus();
    });
  }

  Future<void> _download(String bookRef, String provider) async {
    if (_pendingRefs.contains(bookRef)) return;
    setState(() => _pendingRefs.add(bookRef));
    try {
      await ref
          .read(echoApiProvider)
          .downloadBook(provider: provider, ref: bookRef);
      await ref.read(jobsControllerProvider.notifier).refresh();
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('已加入下载任务，可在「任务」页查看进度')),
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _pendingRefs.remove(bookRef));
      }
    }
  }

  /// 搜索结果详情弹层（设计图 ui-mobile-search：行点击看简介再下载）。
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(searchControllerProvider);
    final controller = ref.read(searchControllerProvider.notifier);

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
                style: textTheme.headlineSmall
                    ?.copyWith(color: tokens.textPrimary),
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
                    SearchFilters(
                      extensions: v ? const ['EPUB'] : const [],
                    ),
                  );
                },
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
                        style: textTheme.bodySmall
                            ?.copyWith(color: tokens.error),
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
              : ListView.separated(
                  key: const Key('search_results'),
                  padding: const EdgeInsets.all(EchoMetrics.space2),
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
                            onPressed:
                                state.isLoading ? null : controller.loadMore,
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
                        borderRadius:
                            BorderRadius.circular(EchoMetrics.radiusCard),
                        onTap: () => _showDetail(book),
                        child: Padding(
                          padding: const EdgeInsets.all(EchoMetrics.space2),
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor:
                                    tokens.accent.withValues(alpha: 0.2),
                                child: Icon(Icons.auto_stories,
                                    color: tokens.accent),
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
                                          color: tokens.textPrimary),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '$authorText · ${book.year}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodySmall?.copyWith(
                                          color: tokens.textSecondary),
                                    ),
                                    const SizedBox(height: EchoMetrics.space1),
                                    // 来源 / 格式标签胶囊（设计图 ui-mobile-search）。
                                    Wrap(
                                      spacing: EchoMetrics.spaceHalf,
                                      runSpacing: EchoMetrics.spaceHalf,
                                      children: [
                                        _MetaPill(
                                          key: Key('search_pill_format_${book.ref}'),
                                          label: book.format.toUpperCase(),
                                        ),
                                        _MetaPill(
                                          key: Key('search_pill_size_${book.ref}'),
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
                                          strokeWidth: 2),
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
  const _MetaPill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: EchoMetrics.space1,
        vertical: 2,
      ),
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
          style: textTheme.labelLarge
              ?.copyWith(color: tokens.textSecondary),
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

/// 搜索结果详情弹层：书源侧详情（providerBook）+ 简介 + 下载。
class _SearchDetailSheet extends ConsumerStatefulWidget {
  const _SearchDetailSheet({required this.book, required this.onDownload});

  final SearchBook book;
  final VoidCallback onDownload;

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
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: tokens.accent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(EchoMetrics.radiusCard),
                  ),
                  child: Icon(Icons.auto_stories, size: 40, color: tokens.accent),
                ),
                const SizedBox(height: EchoMetrics.space2),
                Text(
                  data.title,
                  key: const Key('search_detail_title'),
                  style: textTheme.titleLarge
                      ?.copyWith(color: tokens.textPrimary),
                ),
                const SizedBox(height: EchoMetrics.spaceHalf),
                Text(
                  authorText,
                  style: textTheme.bodyMedium
                      ?.copyWith(color: tokens.textSecondary),
                ),
                const SizedBox(height: EchoMetrics.space2),
                Wrap(
                  spacing: EchoMetrics.spaceHalf,
                  runSpacing: EchoMetrics.spaceHalf,
                  children: [
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
                    style: textTheme.labelLarge
                        ?.copyWith(color: tokens.textSecondary),
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
                FilledButton.icon(
                  key: const Key('search_detail_download'),
                  onPressed: widget.onDownload,
                  icon: const Icon(Icons.download),
                  label: const Text('下载到书库'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
