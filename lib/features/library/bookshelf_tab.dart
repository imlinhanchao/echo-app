import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../reader/reader_page.dart';
import 'convert_sheet.dart';
import 'library_controller.dart';

String formatDurationMs(int ms) {
  final totalSeconds = (ms / 1000).floor().clamp(0, 86400 * 10);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}

/// 书架 Tab：有声书 / 书库 双列表 + 发起转换入口。
class BookshelfTab extends ConsumerWidget {
  const BookshelfTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final libState = ref.watch(libraryControllerProvider);
    final libController = ref.read(libraryControllerProvider.notifier);

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              EchoMetrics.space2,
              EchoMetrics.space1,
              EchoMetrics.space1,
              0,
            ),
            child: Row(
              children: [
                Text(
                  'Echo',
                  key: const Key('echo_title'),
                  style: textTheme.headlineSmall?.copyWith(
                    color: tokens.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: EchoMetrics.space1),
                Text(
                  '回声',
                  style: textTheme.bodySmall
                      ?.copyWith(color: tokens.textSecondary),
                ),
                const Spacer(),
                IconButton(
                  key: const Key('library_refresh'),
                  tooltip: '刷新书架',
                  onPressed: libState.isLoading ? null : libController.refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          if (libState.error != null)
            Container(
              key: const Key('library_error_banner'),
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
          TabBar(
            labelColor: tokens.primary,
            unselectedLabelColor: tokens.textSecondary,
            indicatorColor: tokens.primary,
            tabs: [
              Tab(
                key: const Key('tab_audiobooks'),
                text: '有声书 (${libState.audiobooks.length})',
              ),
              Tab(
                key: const Key('tab_books'),
                text: '书库 (${libState.books.length})',
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _AudiobooksList(
                  audiobooks: libState.audiobooks,
                  isLoading: libState.isLoading,
                ),
                _BooksList(
                  books: libState.books,
                  isLoading: libState.isLoading,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AudiobooksList extends ConsumerWidget {
  const _AudiobooksList({
    required this.audiobooks,
    required this.isLoading,
  });

  final List<AudiobookInfo> audiobooks;
  final bool isLoading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    if (isLoading && audiobooks.isEmpty) {
      return Center(child: CircularProgressIndicator(color: tokens.primary));
    }

    if (audiobooks.isEmpty) {
      return Center(
        key: const Key('audiobooks_empty'),
        child: Text(
          '暂无有声书。去「发现」搜索并转一本吧。',
          style: textTheme.bodyLarge?.copyWith(color: tokens.textSecondary),
        ),
      );
    }

    return ListView.separated(
      key: const Key('audiobooks_list'),
      padding: const EdgeInsets.all(EchoMetrics.space2),
      itemCount: audiobooks.length,
      separatorBuilder: (_, _) => const SizedBox(height: EchoMetrics.space1),
      itemBuilder: (context, index) {
        final item = audiobooks[index];
        final title =
            item.bookTitle.isNotEmpty ? item.bookTitle : '有声书 #${item.id}';
        final durationLabel = formatDurationMs((item.durationS * 1000).round());
        return Card(
          key: Key('audiobook_card_${item.id}'),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: item.isReady
                  ? tokens.primary.withValues(alpha: 0.2)
                  : tokens.surfaceSubtle,
              child: Icon(
                item.isReady ? Icons.headphones : Icons.hourglass_top,
                color: item.isReady ? tokens.primary : tokens.textSecondary,
              ),
            ),
            title: Text(
              title,
              style: textTheme.titleMedium?.copyWith(color: tokens.textPrimary),
            ),
            subtitle: Text(
              item.isReady
                  ? '${item.model} · ${item.voice} · $durationLabel'
                  : '状态：${item.status} (${item.progress}%)',
              style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.isReady)
                  IconButton(
                    key: Key('audiobook_play_${item.id}'),
                    tooltip: '播放',
                    icon: Icon(Icons.play_arrow, color: tokens.primary),
                    onPressed: () => ref
                        .read(chunkedPlayerProvider.notifier)
                        .loadAudiobook(item),
                  ),
                IconButton(
                  key: Key('audiobook_delete_${item.id}'),
                  tooltip: '删除',
                  icon: Icon(Icons.delete_outline, color: tokens.textSecondary),
                  onPressed: () => ref
                      .read(libraryControllerProvider.notifier)
                      .deleteAudiobook(item.id),
                ),
              ],
            ),
            onTap: item.isReady
                ? () => ref
                    .read(chunkedPlayerProvider.notifier)
                    .loadAudiobook(item)
                : null,
          ),
        );
      },
    );
  }
}

class _BooksList extends ConsumerWidget {
  const _BooksList({
    required this.books,
    required this.isLoading,
  });

  final List<LibraryBook> books;
  final bool isLoading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    if (isLoading && books.isEmpty) {
      return Center(child: CircularProgressIndicator(color: tokens.primary));
    }

    if (books.isEmpty) {
      return Center(
        key: const Key('books_empty'),
        child: Text(
          '书库为空',
          style: textTheme.bodyLarge?.copyWith(color: tokens.textSecondary),
        ),
      );
    }

    return ListView.separated(
      key: const Key('books_list'),
      padding: const EdgeInsets.all(EchoMetrics.space2),
      itemCount: books.length,
      separatorBuilder: (_, _) => const SizedBox(height: EchoMetrics.space1),
      itemBuilder: (context, index) {
        final book = books[index];
        final authorText =
            book.authors.isNotEmpty ? book.authors.join(', ') : '未知作者';
        final isEpub = book.format.toLowerCase() == 'epub';
        return Card(
          key: Key('book_card_${book.id}'),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: tokens.accent.withValues(alpha: 0.2),
              child: Icon(Icons.menu_book, color: tokens.accent),
            ),
            title: Text(
              book.title,
              style: textTheme.titleMedium?.copyWith(color: tokens.textPrimary),
            ),
            subtitle: Text(
              '$authorText · ${book.format.toUpperCase()}',
              style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('book_read_${book.id}'),
                  tooltip: '阅读',
                  icon: Icon(
                    Icons.menu_book_outlined,
                    color: tokens.textPrimary,
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ReaderPage(book: book),
                    ),
                  ),
                ),
                if (isEpub)
                  IconButton(
                    key: Key('book_convert_${book.id}'),
                    tooltip: '转有声书',
                    icon: Icon(Icons.graphic_eq, color: tokens.primary),
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      builder: (_) => ConvertSheet(book: book),
                    ),
                  ),
                IconButton(
                  key: Key('book_delete_${book.id}'),
                  tooltip: '删除',
                  icon: Icon(Icons.delete_outline, color: tokens.textSecondary),
                  onPressed: () => ref
                      .read(libraryControllerProvider.notifier)
                      .deleteBook(book.id),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
