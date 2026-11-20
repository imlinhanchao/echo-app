import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../jobs/jobs_controller.dart';
import '../providers/provider_account_page.dart';
import 'search_controller.dart';

/// 发现 Tab：跨书源搜索（zlib）→ 结果列表 → 一键发起下载任务。
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
              ? Center(
                  key: const Key('search_empty'),
                  child: Text(
                    state.lastQuery.isEmpty ? '输入关键词，搜一本想听的书' : '没有找到相关书籍',
                    style: textTheme.bodyLarge
                        ?.copyWith(color: tokens.textSecondary),
                  ),
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
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              tokens.accent.withValues(alpha: 0.2),
                          child:
                              Icon(Icons.auto_stories, color: tokens.accent),
                        ),
                        title: Text(
                          book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleMedium
                              ?.copyWith(color: tokens.textPrimary),
                        ),
                        subtitle: Text(
                          '$authorText · ${book.year} · ${book.format} ${book.size}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall
                              ?.copyWith(color: tokens.textSecondary),
                        ),
                        trailing: _pendingRefs.contains(book.ref)
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
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
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
