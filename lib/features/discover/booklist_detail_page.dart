import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/discover/discover_models.dart';
import '../../core/discover/discover_repository.dart';
import '../../design/book_cover.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import 'discover_book_detail_sheet.dart';

/// 主题书单详情页：按需懒加载书单内的推荐图书及编辑导语。
class BooklistDetailPage extends ConsumerStatefulWidget {
  const BooklistDetailPage({
    super.key,
    required this.booklist,
    required this.searchAvailable,
    this.onSearchBook,
    this.onConfigureEbookApi,
  });

  final DiscoverBooklist booklist;
  final bool searchAvailable;
  final ValueChanged<String>? onSearchBook;
  final VoidCallback? onConfigureEbookApi;

  @override
  ConsumerState<BooklistDetailPage> createState() => _BooklistDetailPageState();
}

class _BooklistDetailPageState extends ConsumerState<BooklistDetailPage> {
  DiscoverFeedData? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(forceRefresh: false);
  }

  Future<void> _load({required bool forceRefresh}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(discoverRepositoryProvider)
          .loadBooklistDetail(
            widget.booklist.sourceId,
            widget.booklist.detailUrl,
            title: widget.booklist.title,
            forceRefresh: forceRefresh,
          );
      if (!mounted) return;
      setState(() {
        _data = result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final hairline = echoHairlineColor(context, darkAlpha: 0.06);
    final books = _data?.books ?? const <DiscoverBook>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.booklist.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '刷新书单',
            onPressed: _loading ? null : () => _load(forceRefresh: true),
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: EchoAmbientBackground(
        child: ListView(
          key: const Key('booklist_detail_page'),
          padding: const EdgeInsets.fromLTRB(
            EchoMetrics.pagePadding,
            EchoMetrics.space2,
            EchoMetrics.pagePadding,
            EchoMetrics.space4,
          ),
          children: [
            Container(
              padding: const EdgeInsets.all(EchoMetrics.space2),
              decoration: echoElevatedCardDecoration(context, radius: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.booklist.title,
                          style: textTheme.titleMedium?.copyWith(
                            color: tokens.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (widget.booklist.meta.isNotEmpty)
                        EchoPillBadge(
                          label: widget.booklist.meta,
                          color: tokens.primary,
                        ),
                    ],
                  ),
                  if (widget.booklist.summary.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      widget.booklist.summary,
                      style: textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                        height: 1.65,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: EchoMetrics.space3),
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: tokens.primary,
                  ),
                ),
              )
            else if (_error != null && books.isEmpty)
              Container(
                padding: const EdgeInsets.all(EchoMetrics.space3),
                decoration: echoElevatedCardDecoration(context, radius: 16),
                child: Column(
                  children: [
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: textTheme.bodySmall?.copyWith(color: tokens.error),
                    ),
                    const SizedBox(height: 12),
                    EchoSecondaryButton(
                      icon: Icons.refresh_rounded,
                      label: '重新加载',
                      onPressed: () => _load(forceRefresh: true),
                    ),
                  ],
                ),
              )
            else if (books.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    '该书单暂未解析到图书条目',
                    style: textTheme.bodyMedium?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ),
              )
            else ...[
              EchoSectionHeader(
                title: '书单推荐图书',
                subtitle: '${books.length} 本',
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < books.length; i++) ...[
                _BooklistEntryRow(
                  book: books[i],
                  onTap: () => openDiscoverBookDetailPage(
                    context,
                    book: books[i],
                    searchAvailable: widget.searchAvailable,
                    onSearchBook: widget.onSearchBook,
                    onConfigureEbookApi: widget.onConfigureEbookApi,
                  ),
                ),
                if (i < books.length - 1)
                  Divider(height: 1, thickness: 0.6, color: hairline),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _BooklistEntryRow extends StatelessWidget {
  const _BooklistEntryRow({required this.book, required this.onTap});

  final DiscoverBook book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final subtitle = book.displaySubtitle;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookCover(
              url: book.coverUrl,
              headers: book.imageHeaders,
              title: book.title,
              author: book.author,
              width: 52,
              height: 74,
              borderRadius: 8,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleSmall?.copyWith(
                            color: tokens.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (book.score.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        EchoPillBadge(
                          label: '${book.score}★',
                          color: tokens.primary,
                        ),
                      ],
                    ],
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 12.5,
                        color: tokens.textSecondary,
                      ),
                    ),
                  ],
                  if (book.note.isNotEmpty || book.summary.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      book.note.isNotEmpty ? book.note : book.summary,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 12.8,
                        color: tokens.textPrimary.withValues(alpha: 0.85),
                        height: 1.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
