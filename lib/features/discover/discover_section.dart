import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/discover/discover_models.dart';
import '../../design/book_cover.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import '../settings/discover_settings_page.dart';
import 'booklist_detail_page.dart';
import 'discover_book_detail_sheet.dart';
import 'discover_controller.dart';

/// 「发现」页默认展示的远程规则驱动荐书区块（榜单 + 主题书单）。
class DiscoverSection extends ConsumerStatefulWidget {
  const DiscoverSection({
    super.key,
    required this.searchAvailable,
    this.onSearchBook,
    this.onConfigureEbookApi,
  });

  final bool searchAvailable;
  final ValueChanged<String>? onSearchBook;
  final VoidCallback? onConfigureEbookApi;

  @override
  ConsumerState<DiscoverSection> createState() => _DiscoverSectionState();
}

class _DiscoverSectionState extends ConsumerState<DiscoverSection> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() {
      if (!mounted) return;
      ref.read(discoverControllerProvider.notifier).ensureLoaded();
    });
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DiscoverSettingsPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(discoverControllerProvider);
    final controller = ref.read(discoverControllerProvider.notifier);
    final sources = state.enabledSources;
    final activeSource = state.activeSource;
    final feeds = activeSource?.feeds ?? const [];
    final feedData = state.feedData;
    final hairline = echoHairlineColor(context, darkAlpha: 0.06);

    final disableAnimations = MediaQuery.disableAnimationsOf(context);

    return Column(
      key: const Key('discover_section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: sources.isEmpty
                  ? Text(
                      '精选荐书',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium?.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var i = 0; i < sources.length; i++) ...[
                            _EditorialSourceTab(
                              key: Key('discover_source_chip_${sources[i].id}'),
                              label: sources[i].name,
                              isSelected: sources[i].id == activeSource?.id,
                              disableAnimations: disableAnimations,
                              onTap: () => controller.selectSource(sources[i].id),
                            ),
                            if (i < sources.length - 1)
                              const SizedBox(width: EchoMetrics.space1),
                          ],
                        ],
                      ),
                    ),
            ),
            const SizedBox(width: EchoMetrics.spaceHalf),
            IconButton(
              key: const Key('discover_refresh_button'),
              tooltip: '刷新荐书',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              visualDensity: VisualDensity.compact,
              onPressed: state.isLoading ? null : controller.refreshFeed,
              icon: Icon(
                Icons.refresh_rounded,
                size: 19,
                color: tokens.textSecondary,
              ),
            ),
            IconButton(
              key: const Key('discover_settings_button'),
              tooltip: '荐书源配置',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              visualDensity: VisualDensity.compact,
              onPressed: _openSettings,
              icon: Icon(
                Icons.tune_rounded,
                size: 19,
                color: tokens.textSecondary,
              ),
            ),
          ],
        ),
        if (feeds.isNotEmpty) ...[
          const SizedBox(height: EchoMetrics.space1),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < feeds.length; i++) ...[
                  _CompactFeedPill(
                    key: Key('discover_feed_chip_${feeds[i].id}'),
                    label: feeds[i].title,
                    selected: feeds[i].id == state.activeFeedId,
                    disableAnimations: disableAnimations,
                    onTap: () => controller.selectFeed(feeds[i].id),
                  ),
                  if (i < feeds.length - 1)
                    const SizedBox(width: EchoMetrics.space1),
                ],
              ],
            ),
          ),
        ],
        if (state.notice != null && state.notice!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: echoElevatedCardDecoration(
              context,
              radius: 10,
              color: tokens.warning.withValues(alpha: 0.08),
              borderColor: tokens.warning.withValues(alpha: 0.25),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: tokens.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.notice!,
                    style: textTheme.bodySmall?.copyWith(color: tokens.warning),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: EchoMetrics.space1),
        if (state.isLoading && (feedData == null || feedData.isEmpty))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: tokens.primary,
              ),
            ),
          )
        else if (state.error != null && (feedData == null || feedData.isEmpty))
          Container(
            key: const Key('discover_error_card'),
            width: double.infinity,
            padding: const EdgeInsets.all(EchoMetrics.space2),
            decoration: echoElevatedCardDecoration(context, radius: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  state.error!,
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall?.copyWith(
                    color: tokens.textSecondary,
                  ),
                ),
                const SizedBox(height: EchoMetrics.space1),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    EchoSecondaryButton(
                      key: const Key('discover_retry_button'),
                      icon: Icons.refresh_rounded,
                      label: '重试加载',
                      onPressed: controller.refreshFeed,
                    ),
                    EchoSecondaryButton(
                      icon: Icons.settings_outlined,
                      label: '规则设置',
                      onPressed: _openSettings,
                    ),
                  ],
                ),
              ],
            ),
          )
        else if (feedData == null || feedData.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                '暂无荐书内容，可点击右上角刷新或更新规则',
                style: textTheme.bodySmall?.copyWith(
                  color: tokens.textSecondary,
                ),
              ),
            ),
          )
        else if (feedData.isBooklists)
          Column(
            children: [
              for (var i = 0; i < feedData.booklists.length; i++) ...[
                _DiscoverBooklistCard(
                  key: Key('discover_booklist_card_$i'),
                  booklist: feedData.booklists[i],
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => BooklistDetailPage(
                          booklist: feedData.booklists[i],
                          searchAvailable: widget.searchAvailable,
                          onSearchBook: widget.onSearchBook,
                          onConfigureEbookApi: widget.onConfigureEbookApi,
                        ),
                      ),
                    );
                  },
                ),
                if (i < feedData.booklists.length - 1)
                  const SizedBox(height: EchoMetrics.space1),
              ],
            ],
          )
        else
          Column(
            children: [
              for (var i = 0; i < feedData.books.length; i++) ...[
                _DiscoverBookRow(
                  key: Key('discover_book_card_$i'),
                  book: feedData.books[i],
                  onTap: () => openDiscoverBookDetailPage(
                    context,
                    book: feedData.books[i],
                    searchAvailable: widget.searchAvailable,
                    onSearchBook: widget.onSearchBook,
                    onConfigureEbookApi: widget.onConfigureEbookApi,
                  ),
                ),
                if (i < feedData.books.length - 1)
                  Divider(height: 1, thickness: 0.6, color: hairline),
              ],
            ],
          ),
      ],
    );
  }
}

class _DiscoverBookRow extends StatelessWidget {
  const _DiscoverBookRow({
    super.key,
    required this.book,
    required this.onTap,
  });

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
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookCover(
              url: book.coverUrl,
              headers: book.imageHeaders,
              title: book.title,
              author: book.author,
              width: 48,
              height: 68,
              borderRadius: 7,
            ),
            const SizedBox(width: 12),
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
                    const SizedBox(height: 3),
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
                  if (book.summary.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      book.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 12.5,
                        color: tokens.textSecondary.withValues(alpha: 0.9),
                        height: 1.45,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: tokens.textDisabled,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoverBooklistCard extends StatelessWidget {
  const _DiscoverBooklistCard({
    super.key,
    required this.booklist,
    required this.onTap,
  });

  final DiscoverBooklist booklist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final previewCovers = booklist.covers.take(3).toList(growable: false);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: echoElevatedCardDecoration(context, radius: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            booklist.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleSmall?.copyWith(
                              color: tokens.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (booklist.meta.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      EchoPillBadge(
                        label: booklist.meta,
                        color: tokens.primary,
                      ),
                    ],
                    if (booklist.summary.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        booklist.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (previewCovers.isNotEmpty) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: 36.0 + (previewCovers.length - 1) * 14.0,
                  height: 54,
                  child: Stack(
                    children: [
                      for (var i = 0; i < previewCovers.length; i++)
                        Positioned(
                          left: i * 14.0,
                          top: 0,
                          child: BookCover(
                            url: previewCovers[i],
                            headers: booklist.imageHeaders,
                            title: booklist.title,
                            width: 36,
                            height: 52,
                            borderRadius: 5,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 荐书来源顶部编辑态切换标签（替代「标题 + 徽章 + 重复胶囊」三层堆叠）。
class _EditorialSourceTab extends StatelessWidget {
  const _EditorialSourceTab({
    super.key,
    required this.label,
    required this.isSelected,
    required this.disableAnimations,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final bool disableAnimations;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: textTheme.titleMedium?.copyWith(
                    fontSize: isSelected ? 16 : 15,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected
                        ? tokens.textPrimary
                        : tokens.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                AnimatedContainer(
                  duration: disableAnimations
                      ? Duration.zero
                      : EchoMetrics.motionFast,
                  curve: EchoMetrics.easeEnter,
                  width: isSelected ? 20 : 0,
                  height: 2.5,
                  decoration: BoxDecoration(
                    color: isSelected ? tokens.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 紧凑型二级榜单/标签胶囊。
class _CompactFeedPill extends StatelessWidget {
  const _CompactFeedPill({
    super.key,
    required this.label,
    required this.selected,
    required this.disableAnimations,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool disableAnimations;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
          onTap: onTap,
          child: AnimatedContainer(
            duration: disableAnimations ? Duration.zero : EchoMetrics.motionFast,
            curve: EchoMetrics.easeEnter,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: selected
                  ? tokens.primary.withValues(alpha: 0.14)
                  : tokens.surfaceElevated,
              borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
              border: Border.all(
                color: selected
                    ? tokens.primary.withValues(alpha: 0.45)
                    : echoHairlineColor(context),
                width: 0.9,
              ),
            ),
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: textTheme.labelMedium?.copyWith(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? tokens.primary : tokens.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
