import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../core/audio/live_tts_player_controller.dart';
import '../../core/books/local_library_store.dart';
import '../../design/book_cover.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import '../player/player_sheet.dart' show formatDurationMs, openPlayer;
import '../reader/reader_page.dart';
import '../shell/echo_shell.dart' show EchoShell;
import 'book_detail_page.dart';
import 'convert_sheet.dart';
import 'library_controller.dart';

/// 从手机本地选择 EPUB / TXT 文件导入单机书库。
Future<void> _importLocalBook(BuildContext context, WidgetRef ref) async {
  try {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['epub', 'txt'],
    );
    final filePath = picked?.files.single.path;
    if (filePath == null || filePath.isEmpty) return;
    final store = ref.read(localLibraryStoreProvider);
    final book = await store.importFile(File(filePath));
    await ref.read(libraryControllerProvider.notifier).refresh();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导入《${book.title}》')),
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('导入失败：$e')),
    );
  }
}

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
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      ) ??
      false;
}

/// 书架 Tab（极简书房 Editorial Minimalism + 2:3 精致封面网格）：
/// 留白问候语 → 胶囊搜索入口 → 「正在收听」叙事卡 → 有声书 → 2:3 真实比例封面网格书库。
class BookshelfTab extends ConsumerWidget {
  const BookshelfTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final libState = ref.watch(libraryControllerProvider);
    final libController = ref.read(libraryControllerProvider.notifier);
    final playerState = ref.watch(chunkedPlayerProvider);
    final liveTtsState = ref.watch(liveTtsPlayerProvider);
    final hasAnyPlayer = playerState.hasBook || liveTtsState.hasBook;
    final shelfAudios = libState.audiobooks
        .where((a) => a.showOnShelf)
        .toList();

    final hour = DateTime.now().hour;
    final greeting = hour < 6
        ? '夜深了，听一段文字'
        : hour < 11
        ? '早安，今日共读'
        : hour < 14
        ? '午后清闲，翻几页书'
        : hour < 19
        ? '下午好，静候有声'
        : '夜读时刻，伴你入眠';

    final bookCount = libState.books.length;
    final audioCount = shelfAudios.length;
    final readyBookIds = <int>{
      for (final a in shelfAudios)
        if (a.isPlayable) a.bookId,
    };

    return RefreshIndicator(
      onRefresh: libController.refresh,
      child: ListView(
        key: const Key('bookshelf_scroll'),
        padding: EdgeInsets.fromLTRB(
          EchoMetrics.pagePadding,
          MediaQuery.paddingOf(context).top + EchoMetrics.space2,
          EchoMetrics.pagePadding,
          hasAnyPlayer ? 112 : EchoMetrics.space4,
        ),
        children: [
          // 顶部问候与导入按钮
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      greeting,
                      key: const Key('echo_greeting'),
                      style: textTheme.headlineSmall?.copyWith(
                        fontSize: 25,
                        color: tokens.textPrimary,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                    if (bookCount > 0 || audioCount > 0) ...[
                      const SizedBox(height: 3),
                      Text(
                        audioCount > 0
                            ? '$bookCount 册藏书 · $audioCount 部有声书'
                            : '$bookCount 册藏书',
                        style: textTheme.labelMedium?.copyWith(
                          color: tokens.textSecondary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              InkWell(
                key: const Key('bookshelf_import_local_button'),
                borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
                onTap: () => _importLocalBook(context, ref),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  decoration: echoElevatedCardDecoration(
                    context,
                    radius: EchoMetrics.radiusPill,
                    borderColor: echoHairlineColor(context, darkAlpha: 0.11),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.add_rounded,
                        size: 18,
                        color: tokens.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '导入',
                        style: textTheme.labelMedium?.copyWith(
                          color: tokens.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: EchoMetrics.space2),

          // 胶囊搜索入口（点击切到「发现」Tab）
          _SearchEntry(onTap: () => EchoShell.switchTab(context, 1)),
          const SizedBox(height: EchoMetrics.space3),

          // 「正在收听」精致卡（2:3 书封左置，右置标题/当前句/进度与纯净圆形播放键）
          if (playerState.hasBook) ...[
            _NowPlayingHeroCard(state: playerState, books: libState.books),
            const SizedBox(height: EchoMetrics.space3),
          ],

          if (libState.error != null)
            Container(
              key: const Key('library_error_banner'),
              margin: const EdgeInsets.only(bottom: EchoMetrics.space2),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: echoElevatedCardDecoration(
                context,
                radius: EchoMetrics.radiusControl,
                color: tokens.error.withValues(alpha: 0.10),
                borderColor: tokens.error.withValues(alpha: 0.25),
              ),
              child: Text(
                libState.error!,
                style: textTheme.bodySmall?.copyWith(color: tokens.error),
              ),
            ),

          // 有声书分区
          if (libState.isLoading && shelfAudios.isEmpty && libState.books.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: EchoMetrics.space5),
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: tokens.primary,
                ),
              ),
            )
          else if (shelfAudios.isEmpty && libState.books.isEmpty)
            Container(
              key: const Key('audiobooks_empty'),
              padding: const EdgeInsets.symmetric(
                horizontal: EchoMetrics.space3,
                vertical: EchoMetrics.space5,
              ),
              decoration: echoElevatedCardDecoration(context, radius: 18),
              child: Column(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: tokens.primary.withValues(alpha: 0.12),
                    ),
                    child: Icon(
                      Icons.auto_stories_outlined,
                      size: 24,
                      color: tokens.primary,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                  Text(
                    '书房还是空的',
                    style: textTheme.titleMedium?.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '导入手机里的 EPUB / TXT，或去「发现」搜索好书',
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space3),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: EchoPrimaryButton(
                          key: const Key('bookshelf_go_discover'),
                          icon: Icons.search_rounded,
                          label: '去发现找书',
                          onPressed: () => EchoShell.switchTab(context, 1),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            )
          else ...[
            if (shelfAudios.isNotEmpty) ...[
              EchoSectionHeader(
                title: '有声书',
                subtitle: '${shelfAudios.length} 部',
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cols = constraints.maxWidth >= 960
                      ? 3
                      : (constraints.maxWidth >= 600 ? 2 : 1);
                  if (cols == 1) {
                    return Column(
                      key: const Key('bookshelf_audiobooks_grid'),
                      children: [
                        for (var i = 0; i < shelfAudios.length; i++) ...[
                          if (i > 0) const SizedBox(height: 10),
                          _AudiobookTileCard(
                            item: shelfAudios[i],
                            books: libState.books,
                          ),
                        ],
                      ],
                    );
                  }
                  return GridView.builder(
                    key: const Key('bookshelf_audiobooks_grid'),
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: shelfAudios.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 12,
                      mainAxisExtent: 88,
                    ),
                    itemBuilder: (_, index) => _AudiobookTileCard(
                      item: shelfAudios[index],
                      books: libState.books,
                    ),
                  );
                },
              ),
            ] else ...[
              // 仅有电子书、尚未转有声书时保留轻量引导锚点
              Container(
                key: const Key('audiobooks_empty'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: echoElevatedCardDecoration(context, radius: 14),
                child: Row(
                  children: [
                    Icon(
                      Icons.headphones_outlined,
                      size: 20,
                      color: tokens.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '任选一册进入阅读即可「边听边看」，或制作离线有声书',
                        style: textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      key: const Key('bookshelf_go_discover'),
                      onPressed: () => EchoShell.switchTab(context, 1),
                      child: const Text('去发现'),
                    ),
                  ],
                ),
              ),
            ],

            if (libState.books.isNotEmpty) ...[
              const SizedBox(height: EchoMetrics.space3),
              EchoSectionHeader(
                title: '书库',
                subtitle: '${libState.books.length} 册',
              ),
              const SizedBox(height: 14),
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final cols = width >= 1040
                      ? 5
                      : (width >= 760
                            ? 4
                            : (width >= 520 ? 3 : 2));
                  const spacing = 16.0;
                  final colWidth = (width - spacing * (cols - 1)) / cols;
                  final coverHeight = colWidth * 1.42;
                  const metaHeight = 72.0;

                  return GridView.builder(
                    key: const Key('bookshelf_books_grid'),
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: libState.books.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      crossAxisSpacing: spacing,
                      mainAxisSpacing: 20,
                      mainAxisExtent: coverHeight + metaHeight,
                    ),
                    itemBuilder: (_, index) {
                      final book = libState.books[index];
                      return _BookCoverTile(
                        book: book,
                        coverWidth: colWidth,
                        coverHeight: coverHeight,
                        hasReadyAudio: readyBookIds.contains(book.id),
                      );
                    },
                  );
                },
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// 极简搜索触发栏（无霓虹描边，细边框胶囊）。
class _SearchEntry extends StatelessWidget {
  const _SearchEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return Semantics(
      button: true,
      label: '搜索书架或在线书源',
      child: InkWell(
        key: const Key('bookshelf_search_entry'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: echoElevatedCardDecoration(
            context,
            radius: EchoMetrics.radiusControl,
          ),
          child: Row(
            children: [
              Icon(
                Icons.search_rounded,
                color: tokens.textSecondary,
                size: 19,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '搜索书架或在线书源…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: tokens.textSecondary,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_forward_rounded,
                size: 16,
                color: tokens.textDisabled,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「正在收听」精致卡：纯净 2:3 封面左置 + 当前朗读句/剩余时长 + 细进度条 + 圆形播放键。
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

    final cueText = state.activeCue?.text.trim() ?? '';
    final subtitleText = cueText.isNotEmpty
        ? cueText
        : (state.currentChunk?.title.isNotEmpty == true
              ? state.currentChunk!.title
              : remaining);

    final progressValue = totalMs > 0
        ? (state.globalPositionMs / totalMs).clamp(0.0, 1.0)
        : 0.0;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      key: const Key('now_playing_hero_card'),
      decoration: echoElevatedCardDecoration(
        context,
        radius: EchoMetrics.radiusCard,
      ),
      child: InkWell(
        key: const Key('now_playing_open'),
        borderRadius: BorderRadius.circular(EchoMetrics.radiusCard),
        onTap: () => openPlayer(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.14),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: BookCover(
                  url: cover,
                  title: title,
                  width: 62,
                  height: 88,
                  borderRadius: 8,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const EchoPillBadge(label: '正在收听'),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$remaining · ${(progressValue * 100).round()}%',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.labelSmall?.copyWith(
                              color: tokens.textSecondary,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      key: const Key('now_playing_title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium?.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitleText,
                      key: const Key('now_playing_subtitle'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        key: const Key('now_playing_progress_ring'),
                        value: progressValue,
                        minHeight: 3,
                        backgroundColor: tokens.surfaceSubtle,
                        color: tokens.primary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  key: const Key('now_playing_toggle'),
                  customBorder: const CircleBorder(),
                  onTap: controller.togglePlayPause,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: tokens.primary,
                    ),
                    child: Icon(
                      state.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: tokens.textOnPrimary,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 精简有声书卡（2:3 迷你封面 + 标题/元信息 + 明确播放键 + 更多菜单），适配所有屏幕宽度且无遮挡。
class _AudiobookTileCard extends ConsumerWidget {
  const _AudiobookTileCard({required this.item, required this.books});

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
    final book = books.where((b) => b.id == item.bookId).firstOrNull;
    final cover = book?.coverUrl;
    final title = item.bookTitle.isNotEmpty
        ? item.bookTitle
        : '有声书 #${item.id}';
    final duration = formatDurationMs((item.durationS * 1000).round());
    final isCurrent = playerState.audiobook?.id == item.id;

    String metaText() {
      if (isCurrent && playerState.totalDurationMs > 0) {
        final remSec =
            ((playerState.totalDurationMs - playerState.globalPositionMs) /
                    1000)
                .floor();
        if (remSec > 60) {
          return '剩余 ${(remSec / 60).floor()} 分钟 · ${item.model}';
        }
        return remSec > 0 ? '剩余 $remSec 秒 · ${item.model}' : '已听完 · ${item.model}';
      }
      if (item.isReady) {
        if (savedProgress != null && savedProgress.offsetMs > 0) {
          return '第 ${savedProgress.chapterIndex + 1} 章 · $duration';
        }
        return '$duration · ${item.model}';
      }
      if (item.isPlayable) return '转换中 ${item.progress}% · 可抢先听';
      return '状态：${item.status} (${item.progress}%)';
    }

    return Container(
      key: Key('audiobook_card_${item.id}'),
      decoration: echoElevatedCardDecoration(
        context,
        radius: 14,
        borderColor: isCurrent
            ? tokens.primary.withValues(alpha: 0.45)
            : echoHairlineColor(context),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (book == null) return;
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => BookDetailPage(book: book, audiobook: item),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              BookCover(
                url: cover,
                title: title,
                width: 44,
                height: 62,
                borderRadius: 7,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      metaText(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(
                        color: isCurrent || (item.isPlayable && !item.isReady)
                            ? tokens.primary
                            : tokens.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              if (item.isPlayable) ...[
                const SizedBox(width: 6),
                IconButton(
                  key: Key('audiobook_play_${item.id}'),
                  tooltip: item.isReady ? '播放' : '抢先收听',
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: tokens.primary.withValues(alpha: 0.14),
                    foregroundColor: tokens.primary,
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
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 22,
                  ),
                ),
              ],
              PopupMenuButton<String>(
                key: Key('audiobook_menu_${item.id}'),
                tooltip: '更多操作',
                icon: Icon(
                  Icons.more_horiz_rounded,
                  size: 20,
                  color: tokens.textSecondary,
                ),
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
                      title: Text('删除有声书'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 书库 2:3 精致封面网格卡（Apple Books 式干净装帧 + 角标 + 右上角收纳菜单）。
class _BookCoverTile extends ConsumerWidget {
  const _BookCoverTile({
    required this.book,
    required this.coverWidth,
    required this.coverHeight,
    required this.hasReadyAudio,
  });

  final LibraryBook book;
  final double coverWidth;
  final double coverHeight;
  final bool hasReadyAudio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fmt = book.format.toLowerCase();
    final isReadable = fmt == 'epub' || fmt == 'txt';
    final authorText = book.authors.isNotEmpty
        ? book.authors.join(', ')
        : '未知作者';

    return InkWell(
      key: Key('book_card_${book.id}'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => BookDetailPage(book: book)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: coverWidth,
            height: coverHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.36 : 0.14,
                        ),
                        blurRadius: 14,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: BookCover(
                    url: book.coverUrl,
                    title: book.title,
                    author: authorText,
                    width: coverWidth,
                    height: coverHeight,
                    borderRadius: 10,
                  ),
                ),
                // 左下角精致格式/有声微徽章
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _CoverMicroTag(
                        label: book.format.isNotEmpty
                            ? book.format.toUpperCase()
                            : 'BOOK',
                      ),
                      if (hasReadyAudio) ...[
                        const SizedBox(width: 4),
                        const _CoverMicroTag(icon: Icons.headphones_rounded),
                      ],
                    ],
                  ),
                ),
                // 右上角收敛操作菜单
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.14),
                        width: 0.6,
                      ),
                    ),
                    child: PopupMenuButton<String>(
                      key: Key('book_menu_${book.id}'),
                      tooltip: '书籍操作',
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      icon: const Icon(
                        Icons.more_horiz_rounded,
                        color: Color(0xFFF3EFE8),
                        size: 16,
                      ),
                      onSelected: (value) async {
                        if (value == 'read') {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ReaderPageView(book: book),
                            ),
                          );
                        } else if (value == 'convert') {
                          await showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            useSafeArea: true,
                            builder: (_) => ConvertSheet(book: book),
                          );
                        } else if (value == 'delete') {
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
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          key: Key('book_read_${book.id}'),
                          value: 'read',
                          child: const ListTile(
                            dense: true,
                            leading: Icon(Icons.menu_book_outlined),
                            title: Text('开始阅读'),
                          ),
                        ),
                        if (isReadable)
                          PopupMenuItem(
                            key: Key('book_convert_${book.id}'),
                            value: 'convert',
                            child: const ListTile(
                              dense: true,
                              leading: Icon(Icons.graphic_eq_rounded),
                              title: Text('制作有声书'),
                            ),
                          ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.delete_outline),
                            title: Text('删除书籍'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.titleSmall?.copyWith(
              fontSize: 14,
              color: tokens.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            authorText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelSmall?.copyWith(
              fontSize: 12,
              color: tokens.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverMicroTag extends StatelessWidget {
  const _CoverMicroTag({this.label, this.icon});

  final String? label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: icon != null ? 5 : 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.54),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.14),
          width: 0.5,
        ),
      ),
      child: icon != null
          ? Icon(icon, size: 11, color: const Color(0xFFF3EFE8))
          : Text(
              label ?? '',
              style: const TextStyle(
                fontSize: 10,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: Color(0xFFF3EFE8),
                letterSpacing: 0.4,
              ),
            ),
    );
  }
}
