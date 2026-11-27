import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/standalone_echo_api.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../core/book_sources/book_source_manager.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../book_sources/book_sources_page.dart';
import '../discover/discover_section.dart';
import '../library/bookshelf_tab.dart' show importLocalBook;
import 'search_controller.dart';
import 'search_results_page.dart';

/// 发现 Tab（极简书房 Editorial Minimalism）：
/// 紧凑顶栏 + 书源状态入口 → 圆角搜索条（按需展开筛选） → 单行历史 → 精选荐书（点击进入路由页）。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  final _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(_onSearchFocusChanged);
  }

  void _onSearchFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchFocusNode
      ..removeListener(_onSearchFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _submit() => _openSearchResults(_controller.text);

  void _openSearchResults(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty || !ref.read(onlineSearchAvailableProvider)) {
      return;
    }
    FocusScope.of(context).unfocus();
    if (_controller.text.isNotEmpty) {
      _controller.clear();
      setState(() {});
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SearchResultsPage(initialQuery: trimmed),
      ),
    );
  }

  void _openBookSourcesPage() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const BookSourcesPage()),
    );
  }

  void _openSourcePickerOrSettings() {
    final api = ref.read(echoApiProvider);
    final useMgr = api is StandaloneEchoApi && api.usesBookSourceManager;
    if (!useMgr) {
      _openBookSourcesPage();
      return;
    }
    showBookSourceSwitcherSheet(context, ref);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(searchControllerProvider);
    final controller = ref.read(searchControllerProvider.notifier);
    final searchAvailable = ref.watch(onlineSearchAvailableProvider);
    final api = ref.watch(echoApiProvider);
    final useBookSourceMgr =
        api is StandaloneEchoApi && api.usesBookSourceManager;
    final bsState = ref.watch(bookSourceControllerProvider);
    final activeSource = useBookSourceMgr ? bsState.activeSource : null;
    final filterCaps = useBookSourceMgr
        ? activeSource?.filterCapabilities
        : null;
    final supportsExtensions =
        !useBookSourceMgr || (filterCaps?.supportsExtensions ?? false);
    final supportsAnyFilter =
        !useBookSourceMgr || (filterCaps?.hasAnyFilter ?? false);

    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final bottomPadding = ref.watch(chunkedPlayerProvider).hasBook
        ? 112.0
        : EchoMetrics.space3;
    final epubOnly = controller.filters.extensions.contains('EPUB');
    final showSearchFilters =
        (supportsExtensions || supportsAnyFilter) &&
        (_searchFocusNode.hasFocus ||
            _controller.text.isNotEmpty ||
            controller.filters.activeCount > 0);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              EchoMetrics.pagePadding,
              EchoMetrics.space1,
              EchoMetrics.pagePadding,
              EchoMetrics.space1,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '发现',
                    key: const Key('search_title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.headlineSmall?.copyWith(
                      fontSize: 22,
                      color: tokens.textPrimary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                const SizedBox(width: EchoMetrics.space1),
                Semantics(
                  button: true,
                  label: searchAvailable
                      ? (activeSource != null
                            ? '当前书源：${activeSource.name}'
                            : '书源服务已就绪')
                      : '配置书源',
                  child: InkWell(
                    key: const Key('search_source_switcher_pill'),
                    borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
                    onTap: _openSourcePickerOrSettings,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: echoElevatedCardDecoration(
                        context,
                        radius: EchoMetrics.radiusPill,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: searchAvailable
                                  ? tokens.success
                                  : tokens.warning,
                            ),
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 120),
                            child: Text(
                              searchAvailable
                                  ? (activeSource?.name ?? '书源服务')
                                  : '配置书源',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelSmall?.copyWith(
                                color: tokens.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (useBookSourceMgr &&
                              bsState.enabledSources.isNotEmpty) ...[
                            const SizedBox(width: 2),
                            Icon(
                              Icons.expand_more_rounded,
                              size: 14,
                              color: tokens.textSecondary,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!searchAvailable)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              EchoMetrics.pagePadding,
              EchoMetrics.space1,
              EchoMetrics.pagePadding,
              bottomPadding,
            ),
            sliver: SliverList.list(
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Container(
                      key: const Key('search_source_disabled_card'),
                      padding: const EdgeInsets.all(EchoMetrics.space2),
                      decoration: echoElevatedCardDecoration(
                        context,
                        radius: 18,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: tokens.primary.withValues(alpha: 0.12),
                              ),
                              child: Icon(
                                Icons.travel_explore_outlined,
                                size: 22,
                                color: tokens.primary,
                              ),
                            ),
                          ),
                          const SizedBox(height: EchoMetrics.space1),
                          Text(
                            '已停用在线书源，暂无法使用搜索',
                            textAlign: TextAlign.center,
                            style: textTheme.titleMedium?.copyWith(
                              color: tokens.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: EchoMetrics.spaceHalf),
                          Text(
                            '你仍可直接导入本地 EPUB / TXT 书籍进行阅读与听书，或先逛逛下方精选荐书；如需在线搜书下载，可在「书源管理」启用内置公版源或导入书源。',
                            textAlign: TextAlign.center,
                            style: textTheme.bodySmall?.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                          const SizedBox(height: EchoMetrics.space2),
                          EchoPrimaryButton(
                            key: const Key('search_disabled_import_button'),
                            icon: Icons.file_upload_outlined,
                            label: '导入本地书籍（EPUB / TXT）',
                            onPressed: () => importLocalBook(
                              context,
                              ref,
                              switchToBookshelf: true,
                            ),
                          ),
                          const SizedBox(height: EchoMetrics.space1),
                          EchoSecondaryButton(
                            key: const Key('search_disabled_configure_button'),
                            icon: Icons.source_outlined,
                            label: '管理与启用书源',
                            onPressed: _openBookSourcesPage,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: EchoMetrics.space2),
                DiscoverSection(
                  searchAvailable: false,
                  onConfigureEbookApi: _openBookSourcesPage,
                ),
              ],
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                EchoMetrics.pagePadding,
                0,
                EchoMetrics.pagePadding,
                EchoMetrics.space1,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('search_field'),
                          controller: _controller,
                          focusNode: _searchFocusNode,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _submit(),
                          decoration: InputDecoration(
                            hintText: activeSource != null
                                ? '搜索书名、作者（${activeSource.name}）'
                                : '搜索书名、作者',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              size: 19,
                            ),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            suffixIconConstraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            suffixIcon: ValueListenableBuilder<TextEditingValue>(
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
                                      key: const Key('search_clear_button'),
                                      tooltip: '清空搜索',
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 17,
                                      ),
                                      onPressed: () {
                                        _controller.clear();
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
                      if (!showSearchFilters && supportsAnyFilter) ...[
                        const SizedBox(width: EchoMetrics.space1),
                        _InlineFilterButton(
                          key: const Key('search_filter_button'),
                          activeCount: controller.filters.activeCount,
                          onTap: () => showSearchFiltersSheet(
                            context,
                            controller,
                            triggerSearch: false,
                            filterCapabilities: filterCaps,
                          ),
                        ),
                      ],
                    ],
                  ),
                  AnimatedSize(
                    duration: disableAnimations
                        ? Duration.zero
                        : EchoMetrics.motionFast,
                    curve: EchoMetrics.easeEnter,
                    alignment: Alignment.topCenter,
                    child: showSearchFilters
                        ? Padding(
                            padding: const EdgeInsets.only(
                              top: EchoMetrics.space1,
                            ),
                            child: Row(
                              children: [
                                if (supportsExtensions) ...[
                                  FilterChip(
                                    key: const Key('search_epub_filter'),
                                    visualDensity: VisualDensity.compact,
                                    label: const Text('仅 EPUB'),
                                    selected: epubOnly,
                                    onSelected: (v) {
                                      controller.setFilters(
                                        controller.filters.copyWith(
                                          extensions: v
                                              ? const ['EPUB']
                                              : const [],
                                        ),
                                        triggerSearch: false,
                                      );
                                      setState(() {});
                                    },
                                  ),
                                  const SizedBox(width: EchoMetrics.space1),
                                ],
                                if (supportsAnyFilter)
                                  ActionChip(
                                    key: const Key('search_filter_button'),
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
                                      triggerSearch: false,
                                      filterCapabilities: filterCaps,
                                    ),
                                  ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              EchoMetrics.pagePadding,
              0,
              EchoMetrics.pagePadding,
              bottomPadding,
            ),
            sliver: SliverList.list(
              children: [
                if (state.history.isNotEmpty) ...[
                  _HistoryBlock(
                    key: const Key('search_history'),
                    history: state.history,
                    onPick: _openSearchResults,
                    onRemove: controller.removeHistory,
                  ),
                  const SizedBox(height: EchoMetrics.space1),
                ],
                const SizedBox(height: EchoMetrics.spaceHalf),
                DiscoverSection(
                  searchAvailable: true,
                  onSearchBook: _openSearchResults,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 搜索框右侧紧凑筛选按钮（筛选条件折叠时显示）。
class _InlineFilterButton extends StatelessWidget {
  const _InlineFilterButton({
    super.key,
    required this.activeCount,
    required this.onTap,
  });

  final int activeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;

    return Semantics(
      button: true,
      label: activeCount > 0 ? '搜索筛选，已选 $activeCount 项' : '搜索筛选',
      child: Tooltip(
        message: '筛选条件',
        child: Material(
          color: activeCount > 0
              ? tokens.primary.withValues(alpha: 0.14)
              : tokens.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
            side: BorderSide(
              color: activeCount > 0
                  ? tokens.primary.withValues(alpha: 0.45)
                  : echoHairlineColor(context),
              width: 0.9,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.tune_rounded,
                    size: 19,
                    color: activeCount > 0
                        ? tokens.primary
                        : tokens.textSecondary,
                  ),
                  if (activeCount > 0)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: tokens.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 搜索历史条（单行横向滚动，保持发现页首屏紧凑）。
class _HistoryBlock extends StatelessWidget {
  const _HistoryBlock({
    super.key,
    required this.history,
    required this.onPick,
    required this.onRemove,
  });

  final List<String> history;
  final ValueChanged<String> onPick;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final borderColor = echoHairlineColor(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Tooltip(
          message: '搜索历史',
          child: Icon(
            Icons.history_rounded,
            size: 16,
            color: tokens.textSecondary,
          ),
        ),
        const SizedBox(width: EchoMetrics.space1),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var index = 0; index < history.length; index++) ...[
                  Material(
                    key: Key('search_history_chip_${history[index]}'),
                    color: tokens.surfaceElevated,
                    shape: StadiumBorder(
                      side: BorderSide(color: borderColor, width: 0.8),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: () => onPick(history[index]),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
                            child: Text(
                              history[index],
                              maxLines: 1,
                              softWrap: false,
                              style: textTheme.labelMedium?.copyWith(
                                fontSize: 12.5,
                                color: tokens.textPrimary,
                              ),
                            ),
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: '删除搜索历史 ${history[index]}',
                          child: InkWell(
                            onTap: () => onRemove(history[index]),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(2, 5, 8, 5),
                              child: Icon(
                                Icons.close_rounded,
                                size: 14,
                                color: tokens.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (index < history.length - 1)
                    const SizedBox(width: EchoMetrics.space1),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
