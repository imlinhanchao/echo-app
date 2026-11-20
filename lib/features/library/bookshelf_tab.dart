import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../design/book_cover.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../player/player_sheet.dart' show formatDurationMs, openPlayer;
import '../reader/reader_page.dart';
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
        // 顶部预留状态栏高度（首页无 AppBar，避免问候语被状态栏压住）
        padding: EdgeInsets.fromLTRB(
          EchoMetrics.space3,
          MediaQuery.paddingOf(context).top + EchoMetrics.space2,
          EchoMetrics.space2,
          EchoMetrics.space2,
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
          if (libState.isLoading && libState.audiobooks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: EchoMetrics.space4),
              child: Center(
                child: CircularProgressIndicator(color: tokens.primary),
              ),
            )
          else if (libState.audiobooks.isEmpty)
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
            for (final item in libState.audiobooks)
              _AudiobookRow(item: item, books: libState.books),

          if (libState.books.isNotEmpty) ...[
            const SizedBox(height: EchoMetrics.space3),
            Text(
              '书库',
              style: textTheme.titleSmall?.copyWith(
                color: tokens.textSecondary,
              ),
            ),
            const SizedBox(height: EchoMetrics.space1),
            for (final book in libState.books) _BookRow(book: book),
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
    return InkWell(
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

    return GestureDetector(
      key: const Key('now_playing_hero_card'),
      onTap: () => openPlayer(context),
      child: Container(
        padding: const EdgeInsets.all(EchoMetrics.space2),
        decoration: BoxDecoration(
          color: tokens.surfaceElevated,
          borderRadius: BorderRadius.circular(EchoMetrics.radiusSheet),
          border: Border.all(color: tokens.surfaceSubtle),
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
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          key: const Key('now_playing_progress_ring'),
                          value: totalMs > 0
                              ? (state.globalPositionMs / totalMs).clamp(
                                  0.0,
                                  1.0,
                                )
                              : 0,
                          minHeight: 4,
                          backgroundColor: tokens.surfaceSubtle,
                          color: tokens.primary,
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
    final cover = books
        .where((b) => b.id == item.bookId)
        .map((b) => b.coverUrl)
        .firstOrNull;
    final title = item.bookTitle.isNotEmpty
        ? item.bookTitle
        : '有声书 #${item.id}';
    final duration = formatDurationMs((item.durationS * 1000).round());

    return InkWell(
      key: Key('audiobook_card_${item.id}'),
      borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
      onTap: item.isReady
          ? () async {
              await ref
                  .read(chunkedPlayerProvider.notifier)
                  .loadAudiobook(item);
              if (context.mounted) await openPlayer(context);
            }
          : null,
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
                        ? '时长 $duration · ${item.model}'
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
                    .loadAudiobook(item),
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
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => ReaderPageView(book: book))),
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
                MaterialPageRoute<void>(builder: (_) => ReaderPageView(book: book)),
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
