import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../design/book_cover.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../player/player_sheet.dart' show formatDurationMs, openPlayer;
import '../reader/reader_page.dart';
import 'book_detail_page.dart';
import '../shell/echo_shell.dart' show EchoShell;
import 'convert_sheet.dart';
import 'library_controller.dart';

/// 删除二次确认（防误触：文件删除不可恢复）。
Future<bool> confirmDelete(
  BuildContext context,
  String title,
  String message,
) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(
                  dialogCtx,
                ).extension<EchoTokens>()?.error,
              ),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      ) ??
      false;
}

/// 书架 Tab（对齐设计图 ui-mobile-library）：
/// 问候语 → 搜索入口 → 「正在收听」大封面卡 → 书籍列表（真实封面 + 剩余时长 + 更多菜单）。
class BookshelfTab extends ConsumerWidget {
  const BookshelfTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final libState = ref.watch(libraryControllerProvider);
    final libController = ref.read(libraryControllerProvider.notifier);
    final playerState = ref.watch(chunkedPlayerProvider);
    // 只看真正有意义的条目：完成 / 转换中；失败与取消的不占首页
    final shelfAudios = libState.audiobooks
        .where((a) => a.showOnShelf)
        .toList();

    final hour = DateTime.now().hour;
    final greeting = hour < 6
        ? '夜深了，要听点什么？'
        : hour < 11
        ? '早上好，今天想听点什么？'
        : hour < 14
        ? '中午好，歇一会儿再听'
        : hour < 19
        ? '下午好，来点声音陪伴'
        : '晚上好，今晚听点什么？';

    return RefreshIndicator(
      onRefresh: libController.refresh,
      child: ListView(
        key: const Key('bookshelf_scroll'),
        // 顶部预留状态栏高度；底部在迷你播放条悬浮时预留 104dp，让末项也能滚出播放条上方
        padding: EdgeInsets.fromLTRB(
          EchoMetrics.space3,
          MediaQuery.paddingOf(context).top + EchoMetrics.space2,
          EchoMetrics.space3,
          playerState.hasBook ? 104 : EchoMetrics.space3,
        ),
        children: [
          // 问候语
          Text(
            greeting,
            key: const Key('echo_greeting'),
            style: textTheme.headlineSmall?.copyWith(
              color: tokens.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: EchoMetrics.space2),

          // 搜索入口（点击切到「发现」Tab）
          _SearchEntry(onTap: () => EchoShell.switchTab(context, 1)),
          const SizedBox(height: EchoMetrics.space3),

          // 「正在收听」大封面卡
          if (playerState.hasBook) ...[
            _NowPlayingHeroCard(state: playerState, books: libState.books),
            const SizedBox(height: EchoMetrics.space3),
          ],

          if (libState.error != null)
            Container(
              key: const Key('library_error_banner'),
              margin: const EdgeInsets.only(bottom: EchoMetrics.space2),
              width: double.infinity,
              color: tokens.error.withValues(alpha: 0.15),
              padding: const EdgeInsets.symmetric(
                horizontal: EchoMetrics.space2,
                vertical: EchoMetrics.space1,
              ),
              child: Text(
                libState.error!,
                style: textTheme.bodySmall?.copyWith(color: tokens.error),
              ),
            ),

          // 有声书列表（主列表，对齐设计图）
          if (libState.isLoading && shelfAudios.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: EchoMetrics.space4),
              child: Center(
                child: CircularProgressIndicator(color: tokens.primary),
              ),
            )
          else if (shelfAudios.isEmpty)
            Padding(
              key: const Key('audiobooks_empty'),
              padding: const EdgeInsets.symmetric(vertical: EchoMetrics.space4),
              child: Column(
                children: [
                  Icon(
                    Icons.library_music_outlined,
                    size: 44,
                    color: tokens.textDisabled,
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                  Text(
                    '还没有有声书',
                    style: textTheme.titleSmall?.copyWith(
                      color: tokens.textPrimary,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.spaceHalf),
                  Text(
                    '去「发现」搜索一本书，转成有声书吧',
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                  FilledButton.tonalIcon(
                    key: const Key('bookshelf_go_discover'),
                    onPressed: () => EchoShell.switchTab(context, 1),
                    icon: const Icon(Icons.search),
                    label: const Text('去发现'),
                  ),
                ],
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 600;
                if (!isWide) {
                  return Column(
                    children: [
                      for (final item in shelfAudios)
                        _AudiobookRow(item: item, books: libState.books),
                    ],
                  );
                }
                return GridView.builder(
                  key: const Key('bookshelf_audiobooks_grid'),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: shelfAudios.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 196,
                    mainAxisSpacing: EchoMetrics.space2,
                    crossAxisSpacing: EchoMetrics.space2,
                    childAspectRatio: 0.66,
                  ),
                  itemBuilder: (_, index) => _AudiobookGridCard(
                    item: shelfAudios[index],
                    books: libState.books,
                  ),
                );
              },
            ),

          if (libState.books.isNotEmpty) ...[
            const SizedBox(height: EchoMetrics.space3),
            Text(
              '书库',
              style: textTheme.titleSmall?.copyWith(
                color: tokens.textSecondary,
              ),
            ),
            const SizedBox(height: EchoMetrics.space1),
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 600;
                if (!isWide) {
                  return Column(
                    children: [
                      for (final book in libState.books) _BookRow(book: book),
                    ],
                  );
                }
                return GridView.builder(
                  key: const Key('bookshelf_books_grid'),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: libState.books.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 196,
                    mainAxisSpacing: EchoMetrics.space2,
                    crossAxisSpacing: EchoMetrics.space2,
                    childAspectRatio: 0.66,
                  ),
                  itemBuilder: (_, index) =>
                      _BookGridCard(book: libState.books[index]),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// 搜索入口（设计图：圆角搜索条）。
class _SearchEntry extends StatelessWidget {
  const _SearchEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return Semantics(
      button: true,
      label: '搜索有声书',
      child: InkWell(
        key: const Key('bookshelf_search_entry'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(EchoMetrics.radiusCard),
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: EchoMetrics.space2),
          decoration: BoxDecoration(
            color: tokens.surfaceElevated,
            borderRadius: BorderRadius.circular(EchoMetrics.radiusCard),
            border: Border.all(color: tokens.primary.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              Icon(Icons.search, color: tokens.primary, size: 20),
              const SizedBox(width: EchoMetrics.space1),
              Text(
                '搜索有声书…',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「正在收听」大卡：封面 + 圆形播放按钮覆盖 + 标题/剩余时长 + 右箭头。
class _NowPlayingHeroCard extends ConsumerWidget {
  const _NowPlayingHeroCard({required this.state, required this.books});

  final ChunkedPlayerState state;
  final List<LibraryBook> books;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final controller = ref.read(chunkedPlayerProvider.notifier);
    final bookId = state.audiobook?.bookId ?? 0;
    final cover = books
        .where((b) => b.id == bookId)
        .map((b) => b.coverUrl)
        .firstOrNull;

    final title = (state.audiobook?.bookTitle.isNotEmpty ?? false)
        ? state.audiobook!.bookTitle
        : '有声书 #${state.audiobook?.id ?? 0}';
    final totalMs = state.totalDurationMs;
    final remainingSec = ((totalMs - state.globalPositionMs) / 1000).floor();
    final remaining = remainingSec > 60
        ? '剩余 ${(remainingSec / 60).floor()} 分钟'
        : remainingSec > 0
        ? '剩余 $remainingSec 秒'
        : '已听完';

    final progressValue = totalMs > 0
        ? (state.globalPositionMs / totalMs).clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      key: const Key('now_playing_hero_card'),
      onTap: () => openPlayer(context),
      child: Container(
        padding: const EdgeInsets.all(EchoMetrics.space2),
        decoration: echoElevatedCardDecoration(
          context,
          radius: EchoMetrics.radiusSheet,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '正在收听',
                  style: textTheme.titleMedium?.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                InkWell(
                  key: const Key('now_playing_open'),
                  onTap: () => openPlayer(context),
                  child: Icon(Icons.chevron_right, color: tokens.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: EchoMetrics.space1),
            Row(
              children: [
                SizedBox(
                  width: 104,
                  height: 104,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      BookCover(url: cover, width: 104, height: 104),
                      // 圆形进度环 + 播放按钮（对齐设计 §4.1）
                      SizedBox(
                        width: 58,
                        height: 58,
                        child: CircularProgressIndicator(
                          key: const Key('now_playing_progress_ring'),
                          value: progressValue,
                          strokeWidth: 3.5,
                          backgroundColor: tokens.surfaceBase.withValues(
                            alpha: 0.55,
                          ),
                          color: tokens.primary,
                        ),
                      ),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: const Key('now_playing_toggle'),
                          customBorder: const CircleBorder(),
                          onTap: controller.togglePlayPause,
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: tokens.primary.withValues(alpha: 0.92),
                              border: Border.all(
                                color: tokens.textOnPrimary.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                            child: Icon(
                              state.isPlaying ? Icons.pause : Icons.play_arrow,
                              color: tokens.textOnPrimary,
                              size: 28,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: EchoMetrics.space2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        key: const Key('now_playing_title'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleMedium?.copyWith(
                          color: tokens.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        remaining,
                        key: const Key('now_playing_subtitle'),
                        style: textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                      const SizedBox(height: EchoMetrics.space1),
                      Text(
                        '${(progressValue * 100).round()}% 已听',
                        style: textTheme.labelSmall?.copyWith(
                          color: tokens.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 有声书行（设计图：封面缩略 + 粗体标题 + 剩余时长 + 更多菜单）。
class _AudiobookRow extends ConsumerWidget {
  const _AudiobookRow({required this.item, required this.books});

  final AudiobookInfo item;
  final List<LibraryBook> books;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final playerState = ref.watch(chunkedPlayerProvider);
    final savedProgress = ref.watch(
      libraryControllerProvider.select((s) => s.progressMap[item.id]),
    );
    final cover = books
        .where((b) => b.id == item.bookId)
        .map((b) => b.coverUrl)
        .firstOrNull;
    final title = item.bookTitle.isNotEmpty
        ? item.bookTitle
        : '有声书 #${item.id}';
    final duration = formatDurationMs((item.durationS * 1000).round());

    String readySubtitle() {
      if (playerState.audiobook?.id == item.id &&
          playerState.totalDurationMs > 0) {
        final remSec =
            ((playerState.totalDurationMs - playerState.globalPositionMs) /
                    1000)
                .floor();
        if (remSec > 60) {
          return '剩余 ${(remSec / 60).floor()} 分钟 · ${item.model}';
        }
        return remSec > 0 ? '剩余 $remSec 秒 · ${item.model}' : '已听完 · ${item.model}';
      }
      if (savedProgress != null && savedProgress.offsetMs > 0) {
        return '第 ${savedProgress.chapterIndex + 1} 章 · 时长 $duration';
      }
      return '时长 $duration · ${item.model}';
    }

    return InkWell(
      key: Key('audiobook_card_${item.id}'),
      borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
      onTap: () {
        final book = books.where((b) => b.id == item.bookId).firstOrNull;
        if (book == null) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => BookDetailPage(book: book, audiobook: item),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: EchoMetrics.space1),
        child: Row(
          children: [
            BookCover(url: cover, width: 56, height: 56),
            const SizedBox(width: EchoMetrics.space2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleMedium?.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.isReady
                        ? readySubtitle()
                        : '状态：${item.status} (${item.progress}%)',
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (item.isReady)
              IconButton(
                key: Key('audiobook_play_${item.id}'),
                tooltip: '播放',
                onPressed: () => ref
                    .read(chunkedPlayerProvider.notifier)
                    .loadAudiobook(item, coverUrl: cover),
                icon: Icon(Icons.play_arrow, color: tokens.primary),
              ),
            PopupMenuButton<String>(
              key: Key('audiobook_menu_${item.id}'),
              icon: Icon(Icons.more_vert, color: tokens.textSecondary),
              onSelected: (value) async {
                if (value == 'delete') {
                  final ok = await confirmDelete(
                    context,
                    '删除有声书',
                    '将删除《${item.bookTitle}》的音频与字幕，不可恢复。',
                  );
                  if (ok && context.mounted) {
                    await ref
                        .read(libraryControllerProvider.notifier)
                        .deleteAudiobook(item.id);
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.delete_outline),
                    title: Text('删除'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 书籍行（可读/可转有声书）。
class _BookRow extends ConsumerWidget {
  const _BookRow({required this.book});

  final LibraryBook book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final isEpub = book.format.toLowerCase() == 'epub';

    return InkWell(
      key: Key('book_card_${book.id}'),
      borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => BookDetailPage(book: book)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: EchoMetrics.space1),
        child: Row(
          children: [
            BookCover(url: book.coverUrl, width: 44, height: 58),
            const SizedBox(width: EchoMetrics.space2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleSmall?.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${book.authors.isNotEmpty ? book.authors.join(', ') : '未知作者'} · ${book.format.toUpperCase()}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: Key('book_read_${book.id}'),
              tooltip: '阅读',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ReaderPageView(book: book),
                ),
              ),
              icon: Icon(Icons.menu_book_outlined, color: tokens.textPrimary),
            ),
            if (isEpub)
              IconButton(
                key: Key('book_convert_${book.id}'),
                tooltip: '转有声书',
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (_) => ConvertSheet(book: book),
                ),
                icon: Icon(Icons.graphic_eq, color: tokens.primary),
              ),
            PopupMenuButton<String>(
              key: Key('book_menu_${book.id}'),
              icon: Icon(Icons.more_vert, color: tokens.textSecondary),
              onSelected: (value) async {
                if (value == 'delete') {
                  final ok = await confirmDelete(
                    context,
                    '删除书籍',
                    '将删除《${book.title}》及其文件，关联有声书一并删除。',
                  );
                  if (ok && context.mounted) {
                    await ref
                        .read(libraryControllerProvider.notifier)
                        .deleteBook(book.id);
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.delete_outline),
                    title: Text('删除'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 平板/桌面端有声书封面网格卡片（对齐设计图 ui-tablet-main / ui-desktop-main）：
/// hover 浮现半透明蒙层 + 播放按钮 + 圆形进度环。
class _AudiobookGridCard extends ConsumerStatefulWidget {
  const _AudiobookGridCard({required this.item, required this.books});

  final AudiobookInfo item;
  final List<LibraryBook> books;

  @override
  ConsumerState<_AudiobookGridCard> createState() => _AudiobookGridCardState();
}

class _AudiobookGridCardState extends ConsumerState<_AudiobookGridCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final playerState = ref.watch(chunkedPlayerProvider);
    final item = widget.item;
    final book = widget.books.where((b) => b.id == item.bookId).firstOrNull;
    final cover = book?.coverUrl;
    final title = item.bookTitle.isNotEmpty
        ? item.bookTitle
        : '有声书 #${item.id}';
    final duration = formatDurationMs((item.durationS * 1000).round());
    final isCurrent = playerState.audiobook?.id == item.id;
    final progressValue = isCurrent && playerState.totalDurationMs > 0
        ? (playerState.globalPositionMs / playerState.totalDurationMs).clamp(
            0.0,
            1.0,
          )
        : (item.isReady ? 0.0 : (item.progress / 100).clamp(0.0, 1.0));

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Card(
        key: Key('audiobook_card_${item.id}'),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (book == null) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BookDetailPage(book: book, audiobook: item),
              ),
            );
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    BookCover(
                      url: cover,
                      width: double.infinity,
                      height: double.infinity,
                    ),
                    // 左上角资产角标
                    Positioned(
                      left: EchoMetrics.space1,
                      top: EchoMetrics.space1,
                      child: _AssetBadge(
                        label: item.isReady ? '可听' : '${item.progress}%',
                        color: tokens.primary,
                      ),
                    ),
                    // hover 或当前播放态浮现播放按钮 + 圆形进度环
                    if (item.isReady)
                      AnimatedOpacity(
                        duration: EchoMetrics.motionFast,
                        opacity: (_hovered || isCurrent) ? 1.0 : 0.0,
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.45),
                          alignment: Alignment.center,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox(
                                width: 54,
                                height: 54,
                                child: CircularProgressIndicator(
                                  value: progressValue,
                                  strokeWidth: 3,
                                  backgroundColor: Colors.white24,
                                  color: tokens.primary,
                                ),
                              ),
                              Material(
                                color: Colors.transparent,
                                child: IconButton(
                                  key: Key('audiobook_play_${item.id}'),
                                  tooltip: '播放',
                                  style: IconButton.styleFrom(
                                    backgroundColor: tokens.primary,
                                    foregroundColor: tokens.textOnPrimary,
                                  ),
                                  onPressed: () {
                                    if (isCurrent) {
                                      ref
                                          .read(chunkedPlayerProvider.notifier)
                                          .togglePlayPause();
                                    } else {
                                      ref
                                          .read(chunkedPlayerProvider.notifier)
                                          .loadAudiobook(item, coverUrl: cover);
                                    }
                                  },
                                  icon: Icon(
                                    (isCurrent && playerState.isPlaying)
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(EchoMetrics.space1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        color: tokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.isReady
                          ? '$duration · ${item.model}'
                          : '转换中 ${item.progress}%',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 平板/桌面端电子书封面网格卡片。
class _BookGridCard extends ConsumerStatefulWidget {
  const _BookGridCard({required this.book});

  final LibraryBook book;

  @override
  ConsumerState<_BookGridCard> createState() => _BookGridCardState();
}

class _BookGridCardState extends ConsumerState<_BookGridCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final book = widget.book;
    final isEpub = book.format.toLowerCase() == 'epub';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Card(
        key: Key('book_card_${book.id}'),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => BookDetailPage(book: book)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    BookCover(
                      url: book.coverUrl,
                      width: double.infinity,
                      height: double.infinity,
                    ),
                    Positioned(
                      left: EchoMetrics.space1,
                      top: EchoMetrics.space1,
                      child: _AssetBadge(
                        label: isEpub ? '可看' : book.format.toUpperCase(),
                        color: tokens.surfaceElevated,
                        textColor: tokens.textPrimary,
                      ),
                    ),
                    AnimatedOpacity(
                      duration: EchoMetrics.motionFast,
                      opacity: _hovered ? 1.0 : 0.0,
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.45),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              key: Key('book_read_${book.id}'),
                              tooltip: '阅读',
                              style: IconButton.styleFrom(
                                backgroundColor: tokens.surfaceElevated,
                                foregroundColor: tokens.textPrimary,
                              ),
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ReaderPageView(book: book),
                                ),
                              ),
                              icon: const Icon(Icons.menu_book_outlined),
                            ),
                            if (isEpub) ...[
                              const SizedBox(width: EchoMetrics.space1),
                              IconButton(
                                key: Key('book_convert_${book.id}'),
                                tooltip: '转有声书',
                                style: IconButton.styleFrom(
                                  backgroundColor: tokens.primary,
                                  foregroundColor: tokens.textOnPrimary,
                                ),
                                onPressed: () => showModalBottomSheet<void>(
                                  context: context,
                                  isScrollControlled: true,
                                  useSafeArea: true,
                                  builder: (_) => ConvertSheet(book: book),
                                ),
                                icon: const Icon(Icons.graphic_eq),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(EchoMetrics.space1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        color: tokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      book.authors.isNotEmpty
                          ? book.authors.join(', ')
                          : '未知作者',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssetBadge extends StatelessWidget {
  const _AssetBadge({
    required this.label,
    required this.color,
    this.textColor,
  });

  final String label;
  final Color color;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: textColor ?? tokens.textOnPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
