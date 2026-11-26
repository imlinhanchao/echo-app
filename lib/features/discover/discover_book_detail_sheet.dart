import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/discover/discover_models.dart';
import '../../core/discover/discover_repository.dart';
import '../../design/book_cover.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';

/// 打开荐书单本详情路由页：支持懒加载详情、按规则动态渲染扩展区块、按书名/ISBN 搜索或复制书名。
Future<void> openDiscoverBookDetailPage(
  BuildContext context, {
  required DiscoverBook book,
  required bool searchAvailable,
  ValueChanged<String>? onSearchBook,
  VoidCallback? onConfigureEbookApi,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => DiscoverBookDetailPage(
        book: book,
        searchAvailable: searchAvailable,
        onSearchBook: onSearchBook,
        onConfigureEbookApi: onConfigureEbookApi,
      ),
    ),
  );
}

/// 兼容旧调用名的转发函数（已改为标准路由页，支持返回上一级页面）。
Future<void> showDiscoverBookDetailSheet(
  BuildContext context, {
  required DiscoverBook book,
  required bool searchAvailable,
  ValueChanged<String>? onSearchBook,
  VoidCallback? onConfigureEbookApi,
}) => openDiscoverBookDetailPage(
  context,
  book: book,
  searchAvailable: searchAvailable,
  onSearchBook: onSearchBook,
  onConfigureEbookApi: onConfigureEbookApi,
);

/// 荐书单本详情路由页。
class DiscoverBookDetailPage extends ConsumerStatefulWidget {
  const DiscoverBookDetailPage({
    super.key,
    required this.book,
    required this.searchAvailable,
    this.onSearchBook,
    this.onConfigureEbookApi,
  });

  final DiscoverBook book;
  final bool searchAvailable;
  final ValueChanged<String>? onSearchBook;
  final VoidCallback? onConfigureEbookApi;

  @override
  ConsumerState<DiscoverBookDetailPage> createState() =>
      _DiscoverBookDetailPageState();
}

class _DiscoverBookDetailPageState
    extends ConsumerState<DiscoverBookDetailPage> {
  late DiscoverBook _book = widget.book;
  bool _isLoadingDetail = false;
  String? _detailError;

  @override
  void initState() {
    super.initState();
    if (_book.detailUrl.trim().isNotEmpty &&
        _book.sourceId.trim().isNotEmpty) {
      _isLoadingDetail = true;
      unawaited(_fetchDetail(fromInit: true));
    }
  }

  Future<void> _fetchDetail({
    bool forceRefresh = false,
    bool fromInit = false,
  }) async {
    if (!fromInit && mounted) {
      setState(() {
        _isLoadingDetail = true;
        _detailError = null;
      });
    }
    try {
      final enriched = await ref
          .read(discoverRepositoryProvider)
          .loadBookDetail(_book, forceRefresh: forceRefresh);
      if (!mounted) return;
      setState(() {
        _book = enriched;
        _isLoadingDetail = false;
        _detailError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingDetail = false;
        _detailError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final subtitle = _book.displaySubtitle;
    final hasNoteInExtras = _book.extraSections.any(
      (s) => s.text == _book.note,
    );
    final hasSearchButton =
        widget.searchAvailable && widget.onSearchBook != null;
    final hasConfigureButton =
        !hasSearchButton && widget.onConfigureEbookApi != null;

    final copyButton = EchoSecondaryButton(
      key: const Key('discover_detail_copy_button'),
      icon: Icons.copy_rounded,
      label: '复制书名',
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: _book.searchQuery));
        if (!context.mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('已复制书名「${_book.searchQuery}」')),
        );
      },
    );

    final canRefreshDetail =
        _book.detailUrl.trim().isNotEmpty && _book.sourceId.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('书籍详情'),
        actions: [
          if (canRefreshDetail)
            IconButton(
              key: const Key('discover_detail_refresh_button'),
              tooltip: '刷新详情',
              onPressed: _isLoadingDetail
                  ? null
                  : () => _fetchDetail(forceRefresh: true),
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
        ],
      ),
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
          child: Row(
            children: [
              if (hasSearchButton) ...[
                Expanded(
                  child: EchoPrimaryButton(
                    key: const Key('discover_detail_search_button'),
                    icon: Icons.search_rounded,
                    label: '在书源中搜索此书',
                    onPressed: () => widget.onSearchBook!(_book.searchQuery),
                  ),
                ),
                const SizedBox(width: EchoMetrics.space1),
                copyButton,
              ] else if (hasConfigureButton) ...[
                Expanded(
                  child: EchoPrimaryButton(
                    key: const Key('discover_detail_configure_button'),
                    icon: Icons.dns_outlined,
                    label: '配置书源服务后搜索',
                    onPressed: widget.onConfigureEbookApi,
                  ),
                ),
                const SizedBox(width: EchoMetrics.space1),
                copyButton,
              ] else
                Expanded(child: copyButton),
            ],
          ),
        ),
      ),
      body: EchoAmbientBackground(
        child: ListView(
          key: const Key('discover_book_detail_sheet'),
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
                  url: _book.coverUrl,
                  headers: _book.imageHeaders,
                  title: _book.title,
                  author: _book.author,
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
                        _book.title,
                        key: const Key('discover_detail_title'),
                        style: textTheme.titleLarge?.copyWith(
                          color: tokens.textPrimary,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          subtitle,
                          style: textTheme.bodySmall?.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (_book.score.isNotEmpty)
                            EchoPillBadge(
                              label: '评分 ${_book.score}',
                              color: tokens.primary,
                            ),
                          if (_book.year.isNotEmpty)
                            EchoPillBadge(
                              label: _book.year,
                              color: tokens.textSecondary,
                            ),
                          if (_book.publisher.isNotEmpty)
                            EchoPillBadge(
                              label: _book.publisher,
                              color: tokens.textSecondary,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: EchoMetrics.space2),
            if (_book.hasBookStats) ...[
              _BookBasicMetaStrip(
                key: const Key('discover_detail_meta_strip'),
                book: _book,
                canSearchByIsbn: hasSearchButton,
                onSearchIsbn: hasSearchButton
                    ? () => widget.onSearchBook!(_book.isbnSearchQuery)
                    : null,
              ),
              const SizedBox(height: EchoMetrics.space2),
            ],
            if (_isLoadingDetail)
              Padding(
                key: const Key('discover_detail_loading'),
                padding: const EdgeInsets.only(bottom: EchoMetrics.space2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: tokens.primary,
                      ),
                    ),
                    const SizedBox(width: EchoMetrics.space1),
                    Text(
                      '正在加载简介与推荐信息…',
                      style: textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            if (_detailError != null &&
                !_isLoadingDetail &&
                _book.summary.isEmpty &&
                _book.extraSections.isEmpty)
              Container(
                key: const Key('discover_detail_error'),
                margin: const EdgeInsets.only(bottom: EchoMetrics.space2),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: tokens.surfaceSubtle,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: echoHairlineColor(context),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: tokens.textSecondary,
                    ),
                    const SizedBox(width: EchoMetrics.space1),
                    Expanded(
                      child: Text(
                        '详情简介暂未获取到（${_detailError!}）',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _fetchDetail(forceRefresh: true),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            if (_book.note.isNotEmpty && !hasNoteInExtras) ...[
              _DiscoverExtraSectionView(
                section: DiscoverExtraSection(
                  key: 'legacy_note',
                  label: '编辑荐语',
                  style: 'quote',
                  text: _book.note,
                ),
              ),
            ],
            if (_book.summary.isNotEmpty) ...[
              const EchoSectionHeader(title: '内容简介'),
              const SizedBox(height: 8),
              Text(
                _book.summary,
                key: const Key('discover_detail_summary'),
                style: textTheme.bodyMedium?.copyWith(
                  fontSize: 14.5,
                  color: tokens.textPrimary,
                  height: 1.7,
                ),
              ),
              const SizedBox(height: EchoMetrics.space3),
            ],
            for (final section in _book.extraSections)
              _DiscoverExtraSectionView(
                key: Key('discover_extra_${section.key}'),
                section: section,
              ),
          ],
        ),
      ),
    );
  }
}

/// 按规则声明的 `style` 动态渲染荐书源扩展字段。
class _DiscoverExtraSectionView extends StatelessWidget {
  const _DiscoverExtraSectionView({
    super.key,
    required this.section,
  });

  final DiscoverExtraSection section;

  @override
  Widget build(BuildContext context) {
    if (section.isEmpty) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: EchoMetrics.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EchoSectionHeader(title: section.label),
          const SizedBox(height: 8),
          _buildBody(context, tokens, textTheme),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    EchoTokens tokens,
    TextTheme textTheme,
  ) {
    switch (section.style) {
      case 'quote':
        final quoteText = section.text.isNotEmpty
            ? section.text
            : section.items.join('\n\n');
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: tokens.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: tokens.primary.withValues(alpha: 0.22),
              width: 0.8,
            ),
          ),
          child: Text(
            quoteText,
            style: textTheme.bodyMedium?.copyWith(
              fontSize: 14.5,
              color: tokens.textPrimary,
              height: 1.65,
            ),
          ),
        );
      case 'positive_list':
        return _buildIconListCard(
          tokens: tokens,
          textTheme: textTheme,
          bgColor: tokens.success.withValues(alpha: 0.08),
          borderColor: tokens.success.withValues(alpha: 0.24),
          icon: Icons.check_circle_outline_rounded,
          iconColor: tokens.success,
        );
      case 'negative_list':
        return _buildIconListCard(
          tokens: tokens,
          textTheme: textTheme,
          bgColor: tokens.warning.withValues(alpha: 0.08),
          borderColor: tokens.warning.withValues(alpha: 0.24),
          icon: Icons.remove_circle_outline_rounded,
          iconColor: tokens.warning,
        );
      case 'list':
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: tokens.surfaceSubtle,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: echoHairlineColor(context), width: 0.8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < section.items.length; i++) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: tokens.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        section.items[i],
                        style: textTheme.bodyMedium?.copyWith(
                          fontSize: 14,
                          color: tokens.textPrimary,
                          height: 1.55,
                        ),
                      ),
                    ),
                  ],
                ),
                if (i < section.items.length - 1) const SizedBox(height: 8),
              ],
            ],
          ),
        );
      case 'tags':
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final tag in section.items)
              EchoPillBadge(label: tag, color: tokens.textSecondary),
          ],
        );
      case 'text':
      default:
        final bodyText = section.text.isNotEmpty
            ? section.text
            : section.items.join('\n\n');
        return Text(
          bodyText,
          style: textTheme.bodyMedium?.copyWith(
            fontSize: 14.5,
            color: tokens.textPrimary,
            height: 1.68,
          ),
        );
    }
  }

  Widget _buildIconListCard({
    required EchoTokens tokens,
    required TextTheme textTheme,
    required Color bgColor,
    required Color borderColor,
    required IconData icon,
    required Color iconColor,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < section.items.length; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Icon(icon, size: 16, color: iconColor),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    section.items[i],
                    style: textTheme.bodyMedium?.copyWith(
                      fontSize: 14,
                      color: tokens.textPrimary,
                      height: 1.55,
                    ),
                  ),
                ),
              ],
            ),
            if (i < section.items.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// 书籍基础信息条：展示页数、字数、章节数及可点击一键搜书/复制的 ISBN。
class _BookBasicMetaStrip extends StatelessWidget {
  const _BookBasicMetaStrip({
    super.key,
    required this.book,
    required this.canSearchByIsbn,
    this.onSearchIsbn,
  });

  final DiscoverBook book;
  final bool canSearchByIsbn;
  final VoidCallback? onSearchIsbn;

  Future<void> _copyIsbn(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('已复制 ISBN $value')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final hairline = echoHairlineColor(context);

    final stats = <({String label, String value})>[
      if (book.pages.isNotEmpty)
        (
          label: '页数',
          value: RegExp(r'^\d+$').hasMatch(book.pages)
              ? '${book.pages} 页'
              : book.pages,
        ),
      if (book.wordCount.isNotEmpty)
        (
          label: '字数',
          value: RegExp(r'^\d+(?:\.\d+)?$').hasMatch(book.wordCount)
              ? '${book.wordCount} 字'
              : book.wordCount,
        ),
      if (book.chapterCount.isNotEmpty)
        (
          label: '章节数',
          value: RegExp(r'^\d+$').hasMatch(book.chapterCount)
              ? '${book.chapterCount} 章'
              : book.chapterCount,
        ),
    ];

    final isbnSearchValue = book.isbnSearchQuery;
    final isbnCopyValue = isbnSearchValue.isNotEmpty
        ? isbnSearchValue
        : book.isbn;
    final searchable = canSearchByIsbn &&
        onSearchIsbn != null &&
        isbnSearchValue.isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.surfaceSubtle,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: hairline, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stats.isNotEmpty)
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                for (final item in stats)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        item.label,
                        style: textTheme.labelSmall?.copyWith(
                          fontSize: 11.5,
                          color: tokens.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        item.value,
                        style: textTheme.bodySmall?.copyWith(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: tokens.textPrimary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          if (stats.isNotEmpty && book.isbn.isNotEmpty)
            Divider(height: 16, thickness: 0.6, color: hairline),
          if (book.isbn.isNotEmpty)
            Semantics(
              button: true,
              label: searchable
                  ? '按 ISBN ${book.isbn} 搜索此书'
                  : '复制 ISBN ${book.isbn}',
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  key: const Key('discover_detail_isbn_button'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    if (searchable) {
                      onSearchIsbn!();
                    } else {
                      _copyIsbn(context, isbnCopyValue);
                    }
                  },
                  onLongPress: () => _copyIsbn(context, isbnCopyValue),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 3,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.qr_code_2_rounded,
                          size: 16,
                          color: tokens.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'ISBN',
                          style: textTheme.labelSmall?.copyWith(
                            fontSize: 11.5,
                            color: tokens.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            book.isbn,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall?.copyWith(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: tokens.textPrimary,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: searchable
                                ? tokens.primary.withValues(alpha: 0.14)
                                : tokens.surfaceElevated,
                            borderRadius: BorderRadius.circular(
                              EchoMetrics.radiusPill,
                            ),
                            border: Border.all(
                              color: searchable
                                  ? tokens.primary.withValues(alpha: 0.35)
                                  : hairline,
                              width: 0.8,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                searchable
                                    ? Icons.search_rounded
                                    : Icons.copy_rounded,
                                size: 13,
                                color: searchable
                                    ? tokens.primary
                                    : tokens.textSecondary,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                searchable ? '搜 ISBN' : '复制',
                                style: textTheme.labelSmall?.copyWith(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: searchable
                                      ? tokens.primary
                                      : tokens.textSecondary,
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
        ],
      ),
    );
  }
}
