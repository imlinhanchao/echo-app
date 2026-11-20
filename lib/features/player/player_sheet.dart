import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/chunked_player_controller.dart';
import '../../design/book_cover.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../library/library_controller.dart';

String formatDurationMs(int ms) {
  final totalSeconds = (ms / 1000).floor().clamp(0, 86400 * 10);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}

/// 全屏打开播放器（上滑过渡）：设计图为整屏页，不用 bottom sheet，
/// 避免书架内容从顶部露出。
Future<void> openPlayer(BuildContext context) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, _, _) => const PlayerSheet(),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
            .animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
        child: child,
      ),
    ),
  );
}

/// 悬浮胶囊迷你播放条（设计图 ui-mobile-library 底部）。
/// 点击展开 v3 全屏播放器。
class MiniPlayerBar extends ConsumerWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chunkedPlayerProvider);
    if (!state.hasBook) return const SizedBox.shrink();

    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final libState = ref.watch(libraryControllerProvider);
    final bookId = state.audiobook?.bookId ?? 0;
    final cover = libState.books
        .where((b) => b.id == bookId)
        .map((b) => b.coverUrl)
        .firstOrNull;

    final title = (state.audiobook?.bookTitle.isNotEmpty ?? false)
        ? state.audiobook!.bookTitle
        : '有声书 #${state.audiobook?.id ?? 0}';
    final chunk = state.currentChunk;
    final subtitle =
        state.activeCue?.text ??
        (chunk?.title.isNotEmpty == true
            ? chunk!.title
            : '第 ${state.currentChunkIndex + 1} 章');

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        EchoMetrics.space2,
        EchoMetrics.space1,
        EchoMetrics.space2,
        EchoMetrics.space1,
      ),
      child: Material(
        key: const Key('mini_player_bar'),
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(EchoMetrics.radiusSheet),
          onTap: () => openPlayer(context),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: EchoMetrics.space1,
              vertical: EchoMetrics.space1,
            ),
            decoration: BoxDecoration(
              color: tokens.surfaceElevated.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(EchoMetrics.radiusSheet),
              border: Border.all(color: tokens.surfaceSubtle),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                BookCover(url: cover, width: 40, height: 40),
                const SizedBox(width: EchoMetrics.space1),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelLarge?.copyWith(
                          color: tokens.textPrimary,
                        ),
                      ),
                      Text(
                        subtitle,
                        key: const Key('mini_player_subtitle'),
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
                  key: const Key('mini_player_prev_chunk'),
                  tooltip: '上一章',
                  onPressed: () =>
                      ref.read(chunkedPlayerProvider.notifier).previousChunk(),
                  icon: Icon(Icons.skip_previous, color: tokens.primary),
                ),
                IconButton(
                  key: const Key('mini_player_toggle'),
                  tooltip: state.isPlaying ? '暂停' : '播放',
                  onPressed: () => ref
                      .read(chunkedPlayerProvider.notifier)
                      .togglePlayPause(),
                  icon: Icon(
                    state.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: tokens.primary,
                    size: 30,
                  ),
                ),
                IconButton(
                  key: const Key('mini_player_forward_15'),
                  tooltip: '下一章',
                  onPressed: () =>
                      ref.read(chunkedPlayerProvider.notifier).nextChunk(),
                  icon: Icon(Icons.skip_next, color: tokens.primary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Echo 播放器 v3（对齐设计图 ui-mobile-player-v3）：
/// 深蓝渐变底 → 顶部封面/书名/章节 + 上下章 → 跟读正文（当前句主色高亮、自动滚动）
/// → 底部悬浮圆角控制卡（时间 + 带章节刻度点的进度条 + 五枚圆形按键 + 倍速/睡眠/章节）。
class PlayerSheet extends ConsumerStatefulWidget {
  const PlayerSheet({super.key});

  @override
  ConsumerState<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends ConsumerState<PlayerSheet> {
  static const List<double> _speeds = <double>[1.0, 1.25, 1.5, 2.0];
  final ScrollController _textScroll = ScrollController();

  /// 每条字幕的锚点：用于把当前朗读句精确滚到屏幕垂直中线。
  /// （旧实现按比例估算滚动位置，句子长短不一时会越来越偏，最后贴底。）
  final Map<int, GlobalKey> _cueKeys = <int, GlobalKey>{};
  int _lastScrolledCue = -1;

  @override
  void dispose() {
    _textScroll.dispose();
    super.dispose();
  }

  /// 当前朗读句滚动到视口垂直居中。
  ///
  /// 难点：ListView 懒构建，目标句在屏幕外时其 element 还不存在，
  /// 直接 ensureVisible 无效。因此分两段：
  /// 1) 按索引比例把列表粗跳到目标附近，让它进入构建范围；
  /// 2) 目标 element 出现后用 ensureVisible(alignment: 0.5) 精确居中。
  void _scrollToActiveCue(int active, int totalCues) {
    if (active < 0 || active == _lastScrolledCue) return;
    _lastScrolledCue = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerCue(active, totalCues);
    });
  }

  void _centerCue(int active, int totalCues, {int attempt = 0}) {
    if (!mounted) return;
    final ctx = _cueKeys[active]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: Duration(milliseconds: attempt == 0 ? 320 : 200),
        curve: Curves.easeOut,
      );
      return;
    }
    if (attempt >= 3 || !_textScroll.hasClients || totalCues <= 1) return;
    final position = _textScroll.position;
    final fraction = (active / (totalCues - 1)).clamp(0.0, 1.0);
    final target =
        (position.maxScrollExtent * fraction).clamp(0.0, position.maxScrollExtent);
    // 第一跳直达估计位置，之后逐帧微调靠近目标
    final next = attempt == 0
        ? target
        : position.pixels + (target - position.pixels) * 0.5;
    _textScroll.jumpTo(next.clamp(0.0, position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerCue(active, totalCues, attempt: attempt + 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chunkedPlayerProvider);
    final controller = ref.read(chunkedPlayerProvider.notifier);
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final libState = ref.watch(libraryControllerProvider);
    final cover = libState.books
        .where((b) => b.id == (state.audiobook?.bookId ?? 0))
        .map((b) => b.coverUrl)
        .firstOrNull;

    final bookTitle = (state.audiobook?.bookTitle.isNotEmpty ?? false)
        ? state.audiobook!.bookTitle
        : '有声书 #${state.audiobook?.id ?? 0}';
    final chunk = state.currentChunk;
    final chapterTitle = (chunk?.title.isNotEmpty ?? false)
        ? chunk!.title
        : '第 ${state.currentChunkIndex + 1} 章';
    final durationMs = state.currentChunkDurationMs;
    final totalMs = state.totalDurationMs;
    final progress = totalMs > 0
        ? (state.globalPositionMs / totalMs).clamp(0.0, 1.0)
        : 0.0;

    _scrollToActiveCue(state.activeCueIndex, state.cues.length);

    return Scaffold(
      key: const Key('player_sheet'),
      backgroundColor: tokens.surfaceBase,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              tokens.primary.withValues(alpha: 0.16),
              tokens.surfaceBase,
              tokens.surfaceBase,
            ],
            stops: const <double>[0.0, 0.42, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // ---- 顶栏：封面 + 书名/章节 + 收起/上下章 ----
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  EchoMetrics.space1,
                  EchoMetrics.space1,
                  EchoMetrics.space2,
                  EchoMetrics.space2,
                ),
                child: Row(
                  children: [
                    IconButton(
                      key: const Key('player_collapse'),
                      tooltip: '收起播放器',
                      icon: Icon(
                        Icons.keyboard_arrow_down,
                        color: tokens.textPrimary,
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    BookCover(url: cover, width: 52, height: 52),
                    const SizedBox(width: EchoMetrics.space2),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            bookTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleMedium?.copyWith(
                              color: tokens.textPrimary,
                            ),
                          ),
                          Text(
                            '${state.currentChunkIndex + 1}/${state.chunks.length} · $chapterTitle',
                            key: const Key('player_chapter_label'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall?.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _CircleAction(
                      key: const Key('player_top_prev_chapter'),
                      icon: Icons.chevron_left,
                      onPressed: state.hasPreviousChunk
                          ? controller.previousChunk
                          : null,
                    ),
                    const SizedBox(width: EchoMetrics.space1),
                    _CircleAction(
                      key: const Key('player_top_next_chapter'),
                      icon: Icons.chevron_right,
                      onPressed: state.hasNextChunk
                          ? controller.nextChunk
                          : null,
                    ),
                  ],
                ),
              ),

              // ---- 跟读正文（左右滑翻章）----
              Expanded(
                child: Stack(
                  children: [
                    GestureDetector(
                      onHorizontalDragEnd: (details) {
                        final v = details.primaryVelocity ?? 0;
                        if (v < -300 && state.hasNextChunk) {
                          controller.nextChunk();
                        } else if (v > 300 && state.hasPreviousChunk) {
                          controller.previousChunk();
                        }
                      },
                      child: state.cues.isNotEmpty
                          ? ListView.builder(
                              controller: _textScroll,
                              key: const Key('player_srt_list'),
                              padding: const EdgeInsets.fromLTRB(
                                EchoMetrics.space3,
                                0,
                                EchoMetrics.space3,
                                EchoMetrics.space3,
                              ),
                              itemCount: state.cues.length,
                              itemBuilder: (context, index) {
                                final cue = state.cues[index];
                                final isActive = index == state.activeCueIndex;
                                final isPast =
                                    state.activeCueIndex >= 0 &&
                                    index < state.activeCueIndex;
                                return GestureDetector(
                                  key: _cueKeys.putIfAbsent(
                                    index,
                                    () => GlobalKey(),
                                  ),
                                  onTap: () => controller.seekToCue(cue),
                                  behavior: HitTestBehavior.opaque,
                                  child: Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: EchoMetrics.space2,
                                    ),
                                    child: Text(
                                      cue.text,
                                      style: TextStyle(
                                        fontSize: isActive ? 19 : 17.5,
                                        height: 1.62,
                                        fontWeight: isActive
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: isActive
                                            ? tokens.primary
                                            : (isPast
                                                  ? tokens.textPrimary
                                                        .withValues(alpha: 0.92)
                                                  : tokens.textSecondary
                                                        .withValues(
                                                          alpha: 0.75,
                                                        )),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            )
                          : _CoverFallbackView(
                              bookTitle: bookTitle,
                              chapterTitle: chapterTitle,
                              cover: cover,
                              isLoading: state.isLoading,
                              error: state.error,
                              onRetry: () => controller.reload(),
                            ),
                    ),
                    // 两侧翻页提示箭头
                    if (state.cues.isNotEmpty)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(left: 2),
                                child: Icon(
                                  Icons.chevron_left,
                                  size: 20,
                                  color: tokens.textSecondary.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(right: 2),
                                child: Icon(
                                  Icons.chevron_right,
                                  size: 20,
                                  color: tokens.textSecondary.withValues(
                                    alpha: 0.5,
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

              // ---- 底部悬浮控制卡 ----
              Container(
                margin: const EdgeInsets.fromLTRB(
                  EchoMetrics.space2,
                  0,
                  EchoMetrics.space2,
                  EchoMetrics.space2,
                ),
                padding: const EdgeInsets.fromLTRB(
                  EchoMetrics.space2,
                  EchoMetrics.space2,
                  EchoMetrics.space2,
                  EchoMetrics.space1,
                ),
                decoration: BoxDecoration(
                  color: tokens.surfaceElevated,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: tokens.surfaceSubtle),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 时间 + 进度条 + 章节刻度点
                    Row(
                      children: [
                        SizedBox(
                          width: 44,
                          child: Text(
                            formatDurationMs(state.positionMs),
                            key: const Key('player_position_text'),
                            style: textTheme.labelSmall?.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                        ),
                        Expanded(
                          child: _ChapterTickProgress(
                            key: const Key('player_progress_slider'),
                            progress: progress,
                            chunkCount: state.chunks.length,
                            currentChunk: state.currentChunkIndex,
                            onSeekFraction: (f) {
                              final ms = (totalMs * f).round();
                              final chunk = state.chunks.firstWhere(
                                (c) =>
                                    ms >= (c.startS * 1000).round() &&
                                    ms < (c.endS * 1000).round(),
                                orElse: () =>
                                    state.chunks[state.currentChunkIndex],
                              );
                              final local = ms - (chunk.startS * 1000).round();
                              final idx = state.chunks.indexOf(chunk);
                              if (idx == state.currentChunkIndex) {
                                controller.seekToMs(local.clamp(0, 1 << 30));
                              } else {
                                controller.selectChunkAt(idx, local);
                              }
                            },
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            formatDurationMs(durationMs),
                            key: const Key('player_duration_text'),
                            textAlign: TextAlign.right,
                            style: textTheme.labelSmall?.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: EchoMetrics.space2),

                    // 五枚圆形按键：上一章 | -15s | 播放 | +15s | 下一章
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _CircleTextAction(
                          key: const Key('player_prev_chunk'),
                          label: '上一章',
                          onPressed: controller.previousChunk,
                        ),
                        _CircleTextAction(
                          key: const Key('player_back_15'),
                          label: '-15s',
                          onPressed: () =>
                              controller.skipBy(const Duration(seconds: -15)),
                        ),
                        SizedBox(
                          width: 64,
                          height: 64,
                          child: FilledButton(
                            key: const Key('player_toggle_play'),
                            style: FilledButton.styleFrom(
                              shape: const CircleBorder(),
                              padding: EdgeInsets.zero,
                              backgroundColor: tokens.primary,
                            ),
                            onPressed: controller.togglePlayPause,
                            child: Icon(
                              state.isPlaying ? Icons.pause : Icons.play_arrow,
                              size: 34,
                              color: tokens.textOnPrimary,
                            ),
                          ),
                        ),
                        _CircleTextAction(
                          key: const Key('player_forward_15'),
                          label: '+15s',
                          onPressed: () =>
                              controller.skipBy(const Duration(seconds: 15)),
                        ),
                        _CircleTextAction(
                          key: const Key('player_next_chunk'),
                          label: '下一章',
                          onPressed: state.hasNextChunk
                              ? controller.nextChunk
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: EchoMetrics.space1),

                    // 次级入口：倍速 / 睡眠定时 / 章节列表
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _SecondaryAction(
                          key: const Key('player_speed_button'),
                          icon: Icons.speed,
                          label: '倍速 ${state.speed}x',
                          onTap: () {
                            final idx = _speeds.indexOf(state.speed);
                            controller.setSpeed(
                              _speeds[(idx + 1) % _speeds.length],
                            );
                          },
                        ),
                        _SecondaryAction(
                          key: const Key('player_sleep_button'),
                          icon: Icons.bedtime_outlined,
                          label: state.sleepUntil == null
                              ? '睡眠定时'
                              : '至 ${state.sleepUntil!.toLocal().hour.toString().padLeft(2, '0')}:'
                                    '${state.sleepUntil!.toLocal().minute.toString().padLeft(2, '0')}',
                          onTap: () => _showSleepDialog(context, ref),
                        ),
                        _SecondaryAction(
                          key: const Key('player_chapters_button'),
                          icon: Icons.list,
                          label: '章节列表',
                          onTap: () => _showChaptersDrawer(context, ref),
                        ),
                      ],
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

  void _showSleepDialog(BuildContext context, WidgetRef ref) {
    final controller = ref.read(chunkedPlayerProvider.notifier);
    void pick(Duration? duration) {
      duration == null
          ? controller.cancelSleepTimer()
          : controller.setSleepTimer(duration);
      Navigator.of(context).pop();
    }

    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: EchoMetrics.space2),
            ListTile(
              key: const Key('sleep_option_off'),
              leading: const Icon(Icons.bedtime_off),
              title: const Text('关闭定时'),
              onTap: () => pick(null),
            ),
            for (final minutes in const [15, 30, 60, 90])
              ListTile(
                key: Key('sleep_option_${minutes}min'),
                leading: const Icon(Icons.bedtime),
                title: Text('$minutes 分钟后暂停'),
                onTap: () => pick(Duration(minutes: minutes)),
              ),
            const SizedBox(height: EchoMetrics.space2),
          ],
        ),
      ),
    );
  }

  void _showChaptersDrawer(BuildContext context, WidgetRef ref) {
    final state = ref.read(chunkedPlayerProvider);
    final controller = ref.read(chunkedPlayerProvider.notifier);
    final tokens = Theme.of(context).extension<EchoTokens>()!;

    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => ListView.builder(
        key: const Key('chapters_drawer_list'),
        padding: const EdgeInsets.all(EchoMetrics.space2),
        itemCount: state.chunks.length,
        itemBuilder: (_, index) {
          final c = state.chunks[index];
          final selected = index == state.currentChunkIndex;
          return ListTile(
            key: Key('chapter_item_$index'),
            selected: selected,
            selectedTileColor: tokens.primary.withValues(alpha: 0.12),
            leading: Icon(
              selected ? Icons.volume_up : Icons.menu_book_outlined,
              color: selected ? tokens.primary : tokens.textSecondary,
            ),
            title: Text(
              c.title.isNotEmpty ? c.title : '第 ${index + 1} 章',
              style: TextStyle(
                color: selected ? tokens.primary : tokens.textPrimary,
              ),
            ),
            trailing: Text(
              formatDurationMs((c.durationS * 1000).round()),
              style: TextStyle(color: tokens.textSecondary),
            ),
            onTap: () {
              Navigator.of(sheetCtx).pop();
              controller.selectChunk(index);
            },
          );
        },
      ),
    );
  }
}

/// 圆形描边小按键（-15s / ±章）。
class _CircleTextAction extends StatelessWidget {
  const _CircleTextAction({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final enabled = onPressed != null;
    return SizedBox(
      width: 60,
      height: 60,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          side: BorderSide(
            color: enabled
                ? tokens.surfaceSubtle
                : tokens.surfaceSubtle.withValues(alpha: 0.4),
          ),
          foregroundColor: tokens.textPrimary,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: enabled ? tokens.textPrimary : tokens.textDisabled,
          ),
        ),
      ),
    );
  }
}

/// 顶栏圆形描边图标按钮。
class _CircleAction extends StatelessWidget {
  const _CircleAction({super.key, required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return SizedBox(
      width: 38,
      height: 38,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          side: BorderSide(color: tokens.surfaceSubtle),
          foregroundColor: tokens.textPrimary,
        ),
        child: Icon(icon, size: 20),
      ),
    );
  }
}

/// 控制卡次级入口（倍速 / 睡眠 / 章节）。
class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: EchoMetrics.space1,
          vertical: EchoMetrics.space1,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: tokens.textSecondary),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// 带章节刻度点的进度条（设计图：细线进度 + 均布圆点）。
class _ChapterTickProgress extends StatelessWidget {
  const _ChapterTickProgress({
    super.key,
    required this.progress,
    required this.chunkCount,
    required this.currentChunk,
    required this.onSeekFraction,
  });

  final double progress;
  final int chunkCount;
  final int currentChunk;
  final ValueChanged<double> onSeekFraction;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final dots = chunkCount.clamp(1, 24);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void seek(Offset local) {
          final f = (local.dx / width).clamp(0.0, 1.0);
          onSeekFraction(f);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => seek(d.localPosition),
          onHorizontalDragUpdate: (d) => seek(d.localPosition),
          child: SizedBox(
            height: 26,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 轨道
                Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: tokens.surfaceSubtle,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                // 已播进度
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: progress.clamp(0.0, 1.0),
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: tokens.primary,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
                // 章节刻度点
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List<Widget>.generate(dots, (i) {
                    final passed = (i / dots) <= progress;
                    return Container(
                      width: i == currentChunk ? 6 : 4,
                      height: i == currentChunk ? 6 : 4,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == currentChunk
                            ? tokens.textOnPrimary
                            : (passed
                                  ? tokens.textOnPrimary.withValues(alpha: 0.9)
                                  : tokens.textDisabled.withValues(alpha: 0.7)),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 无字幕/加载中/加载失败的封面视图（设计图封面卡 + 状态提示）。
class _CoverFallbackView extends StatelessWidget {
  const _CoverFallbackView({
    required this.bookTitle,
    required this.chapterTitle,
    required this.cover,
    required this.isLoading,
    required this.error,
    required this.onRetry,
  });

  final String bookTitle;
  final String chapterTitle;
  final String? cover;
  final bool isLoading;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      key: const Key('player_cover_fallback'),
      child: Padding(
        padding: const EdgeInsets.all(EchoMetrics.space4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            BookCover(url: cover, width: 168, height: 168),
            const SizedBox(height: EchoMetrics.space3),
            Text(
              bookTitle,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleLarge?.copyWith(color: tokens.textPrimary),
            ),
            const SizedBox(height: EchoMetrics.space1),
            Text(
              chapterTitle,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: tokens.textSecondary,
              ),
            ),
            const SizedBox(height: EchoMetrics.space3),
            if (isLoading)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: tokens.primary,
                    ),
                  ),
                  const SizedBox(width: EchoMetrics.space1),
                  Text(
                    '正在加载音频…',
                    key: const Key('player_loading_label'),
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              )
            else if (error != null)
              Column(
                children: [
                  Text(
                    error!,
                    key: const Key('player_error_label'),
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(color: tokens.error),
                  ),
                  const SizedBox(height: EchoMetrics.space1),
                  FilledButton.tonalIcon(
                    key: const Key('player_retry'),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              )
            else
              Text(
                '该书暂无同步字幕，进入纯封面收听模式',
                style: textTheme.bodySmall?.copyWith(
                  color: tokens.textDisabled,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
