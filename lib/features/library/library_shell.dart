import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../player/player_sheet.dart';
import 'library_controller.dart';

/// Phase 1 已登录主界面：有声书与书库双视图 + 底部常驻迷你播放条。
class LibraryShell extends ConsumerWidget {
  const LibraryShell({super.key, required this.user});

  final EchoUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final libState = ref.watch(libraryControllerProvider);
    final libController = ref.read(libraryControllerProvider.notifier);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        key: const Key('echo_home'),
        appBar: AppBar(
          title: Row(
            children: [
              Text(
                'Echo',
                key: const Key('echo_title'),
                style: textTheme.headlineSmall?.copyWith(
                  color: tokens.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: EchoMetrics.space2),
              Expanded(
                child: Text(
                  user.email,
                  key: const Key('echo_user_email'),
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: tokens.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              key: const Key('library_refresh'),
              tooltip: '刷新书架',
              onPressed: libState.isLoading ? null : libController.refresh,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              key: const Key('echo_logout'),
              tooltip: '登出',
              onPressed: () =>
                  ref.read(authControllerProvider.notifier).logout(),
              icon: const Icon(Icons.logout),
            ),
          ],
          bottom: TabBar(
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
        ),
        body: Column(
          children: [
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
            Expanded(
              child: TabBarView(
                children: [
                  _AudiobooksTab(
                    audiobooks: libState.audiobooks,
                    isLoading: libState.isLoading,
                  ),
                  _BooksTab(
                    books: libState.books,
                    isLoading: libState.isLoading,
                  ),
                ],
              ),
            ),
            const MiniPlayerBar(),
          ],
        ),
      ),
    );
  }
}

class _AudiobooksTab extends ConsumerWidget {
  const _AudiobooksTab({
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
      return Center(
        child: CircularProgressIndicator(color: tokens.primary),
      );
    }

    if (audiobooks.isEmpty) {
      return Center(
        key: const Key('audiobooks_empty'),
        child: Text(
          '暂无有声书',
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
        final title = item.bookTitle.isNotEmpty
            ? item.bookTitle
            : '有声书 #${item.id}';
        final durationLabel =
            formatDurationMs((item.durationS * 1000).round());
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

class _BooksTab extends ConsumerWidget {
  const _BooksTab({
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
      return Center(
        child: CircularProgressIndicator(color: tokens.primary),
      );
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
            trailing: IconButton(
              key: Key('book_delete_${book.id}'),
              tooltip: '删除',
              icon: Icon(Icons.delete_outline, color: tokens.textSecondary),
              onPressed: () => ref
                  .read(libraryControllerProvider.notifier)
                  .deleteBook(book.id),
            ),
          ),
        );
      },
    );
  }
}
