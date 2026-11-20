import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/chunked_player_controller.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';

String formatDurationMs(int ms) {
  final totalSeconds = (ms / 1000).floor().clamp(0, 86400 * 10);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}

/// 底部常驻迷你播放条：点击展开全屏 v3 播放器。
class MiniPlayerBar extends ConsumerWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chunkedPlayerProvider);
    if (!state.hasBook) return const SizedBox.shrink();

    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final bookTitle = state.audiobook?.bookTitle.isNotEmpty == true
        ? state.audiobook!.bookTitle
        : '有声书 #${state.audiobook?.id ?? 0}';
    final chunkTitle = state.currentChunk?.title.isNotEmpty == true
        ? state.currentChunk!.title
        : '第 ${state.currentChunkIndex + 1} 章';
    final subtitle = state.activeCue?.text ?? chunkTitle;

    return Material(
      key: const Key('mini_player_bar'),
      color: tokens.surfaceElevated,
      child: InkWell(
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => const PlayerSheet(),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: EchoMetrics.space2,
            vertical: EchoMetrics.space1,
          ),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: tokens.surfaceSubtle, width: 1),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: tokens.accent.withValues(alpha: 0.2),
                  borderRadius:
                      BorderRadius.circular(EchoMetrics.radiusControl),
                ),
                child: Icon(Icons.graphic_eq, color: tokens.accent),
              ),
              const SizedBox(width: EchoMetrics.space2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      bookTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelLarge
                          ?.copyWith(color: tokens.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      key: const Key('mini_player_subtitle'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall
                          ?.copyWith(color: tokens.textSecondary),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const Key('mini_player_toggle'),
                tooltip: state.isPlaying ? '暂停' : '播放',
                onPressed: () =>
                    ref.read(chunkedPlayerProvider.notifier).togglePlayPause(),
                icon: Icon(
                  state.isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  color: tokens.primary,
                  size: 32,
                ),
              ),
              IconButton(
                key: const Key('mini_player_forward_15'),
                tooltip: '前进 15 秒',
                onPressed: () => ref
                    .read(chunkedPlayerProvider.notifier)
                    .skipBy(const Duration(seconds: 15)),
                icon: Icon(Icons.fast_forward, color: tokens.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Echo 播放器 v3（四区布局）：
/// 1. 弱化顶栏（书名 + 章节名 + 快捷上/下章）；
/// 2. 跟读文本主体（句级 SRT 高亮、点句跳转；无字幕时自动降级封面模式）；
/// 3. 进度条 + 章节刻度点；
/// 4. 底部对称播控簇（上一章 | -15s | 播放/暂停 | +15s | 下一章）与倍速/章节抽屉。
class PlayerSheet extends ConsumerWidget {
  const PlayerSheet({super.key});

  static const List<double> _speeds = <double>[1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chunkedPlayerProvider);
    final controller = ref.read(chunkedPlayerProvider.notifier);
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    final bookTitle = state.audiobook?.bookTitle.isNotEmpty == true
        ? state.audiobook!.bookTitle
        : '有声书 #${state.audiobook?.id ?? 0}';
    final chunk = state.currentChunk;
    final chapterTitle = chunk?.title.isNotEmpty == true
        ? chunk!.title
        : '第 ${state.currentChunkIndex + 1} 章';
    final durationMs = state.currentChunkDurationMs;
    final sliderMax = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final sliderValue =
        state.positionMs.clamp(0, durationMs > 0 ? durationMs : 1).toDouble();

    return Scaffold(
      key: const Key('player_sheet'),
      backgroundColor: tokens.surfaceBase,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          tooltip: '收起播放器',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              bookTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleSmall?.copyWith(color: tokens.textPrimary),
            ),
            Text(
              '${state.currentChunkIndex + 1}/${state.chunks.length} · $chapterTitle',
              key: const Key('player_chapter_label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('player_top_prev_chapter'),
            tooltip: '上一章',
            onPressed: state.hasPreviousChunk ? controller.previousChunk : null,
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            key: const Key('player_top_next_chapter'),
            tooltip: '下一章',
            onPressed: state.hasNextChunk ? controller.nextChunk : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
      body: Column(
        children: [
          // ---- 第 2 区：跟读文本主体（左右滑快速翻章）----
          Expanded(
            child: GestureDetector(
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
                      key: const Key('player_srt_list'),
                      padding: const EdgeInsets.all(EchoMetrics.space3),
                      itemCount: state.cues.length,
                      itemBuilder: (context, index) {
                        final cue = state.cues[index];
                        final isActive = index == state.activeCueIndex;
                        return InkWell(
                          key: Key('player_cue_$index'),
                          borderRadius:
                              BorderRadius.circular(EchoMetrics.radiusControl),
                          onTap: () => controller.seekToCue(cue),
                          child: AnimatedContainer(
                            duration: EchoMetrics.motionFast,
                            curve: EchoMetrics.easeEnter,
                            margin: const EdgeInsets.only(
                              bottom: EchoMetrics.space1,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: EchoMetrics.space2,
                              vertical: EchoMetrics.space1,
                            ),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? tokens.readingHighlight
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(
                                EchoMetrics.radiusControl,
                              ),
                            ),
                            child: Text(
                              cue.text,
                              style: (isActive
                                      ? textTheme.titleMedium
                                      : textTheme.bodyLarge)
                                  ?.copyWith(
                                color: isActive
                                    ? tokens.textPrimary
                                    : tokens.textSecondary,
                                fontWeight: isActive
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                height: 1.6,
                              ),
                            ),
                          ),
                        );
                      },
                    )
                  : _CoverFallbackView(
                      bookTitle: bookTitle,
                      chapterTitle: chapterTitle,
                    ),
            ),
          ),

          // ---- 第 3 & 4 区：底部固定控制栏 ----
          Container(
            padding: const EdgeInsets.fromLTRB(
              EchoMetrics.space3,
              EchoMetrics.space2,
              EchoMetrics.space3,
              EchoMetrics.space3,
            ),
            decoration: BoxDecoration(
              color: tokens.surfaceElevated,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(EchoMetrics.radiusSheet),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 章节刻度点
                if (state.chunks.length > 1)
                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: EchoMetrics.spaceHalf),
                    child: Row(
                      key: const Key('player_chapter_ticks'),
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List<Widget>.generate(
                        state.chunks.length,
                        (i) => GestureDetector(
                          onTap: () => controller.selectChunk(i),
                          child: Container(
                            width: i == state.currentChunkIndex ? 16 : 6,
                            height: 6,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              color: i == state.currentChunkIndex
                                  ? tokens.primary
                                  : tokens.surfaceSubtle,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // 进度条 + 时间
                Slider(
                  key: const Key('player_progress_slider'),
                  value: sliderValue,
                  max: sliderMax,
                  activeColor: tokens.primary,
                  inactiveColor: tokens.surfaceSubtle,
                  onChanged: (v) => controller.seekToMs(v.round()),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: EchoMetrics.space1,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatDurationMs(state.positionMs),
                        key: const Key('player_position_text'),
                        style: textTheme.bodySmall
                            ?.copyWith(color: tokens.textSecondary),
                      ),
                      Text(
                        formatDurationMs(durationMs),
                        key: const Key('player_duration_text'),
                        style: textTheme.bodySmall
                            ?.copyWith(color: tokens.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: EchoMetrics.space1),

                // 对称主播控簇：上一章 | -15s | 播放/暂停 | +15s | 下一章
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      key: const Key('player_prev_chunk'),
                      tooltip: '上一章',
                      onPressed: controller.previousChunk,
                      icon: const Icon(Icons.skip_previous),
                    ),
                    IconButton(
                      key: const Key('player_back_15'),
                      tooltip: '后退 15 秒',
                      onPressed: () =>
                          controller.skipBy(const Duration(seconds: -15)),
                      icon: Text(
                        '-15s',
                        style: textTheme.labelLarge
                            ?.copyWith(color: tokens.textPrimary),
                      ),
                    ),
                    FilledButton(
                      key: const Key('player_toggle_play'),
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        padding: const EdgeInsets.all(EchoMetrics.space2),
                      ),
                      onPressed: controller.togglePlayPause,
                      child: Icon(
                        state.isPlaying ? Icons.pause : Icons.play_arrow,
                        size: 32,
                      ),
                    ),
                    IconButton(
                      key: const Key('player_forward_15'),
                      tooltip: '前进 15 秒',
                      onPressed: () =>
                          controller.skipBy(const Duration(seconds: 15)),
                      icon: Text(
                        '+15s',
                        style: textTheme.labelLarge
                            ?.copyWith(color: tokens.textPrimary),
                      ),
                    ),
                    IconButton(
                      key: const Key('player_next_chunk'),
                      tooltip: '下一章',
                      onPressed:
                          state.hasNextChunk ? controller.nextChunk : null,
                      icon: const Icon(Icons.skip_next),
                    ),
                  ],
                ),
                const SizedBox(height: EchoMetrics.space1),

                // 次级入口：倍速 + 睡眠定时 + 章节抽屉
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      key: const Key('player_speed_button'),
                      onPressed: () {
                        final idx = _speeds.indexOf(state.speed);
                        final next = _speeds[(idx + 1) % _speeds.length];
                        controller.setSpeed(next);
                      },
                      icon: const Icon(Icons.speed, size: 18),
                      label: Text('${state.speed}x'),
                    ),
                    TextButton.icon(
                      key: const Key('player_sleep_button'),
                      onPressed: () => _showSleepDialog(context, ref),
                      icon: const Icon(Icons.bedtime, size: 18),
                      label: Text(
                        key: const Key('player_sleep_label'),
                        state.sleepUntil == null
                            ? '睡眠定时'
                            : '至 ${state.sleepUntil!.toLocal().hour.toString().padLeft(2, '0')}:'
                                '${state.sleepUntil!.toLocal().minute.toString().padLeft(2, '0')}',
                      ),
                    ),
                    TextButton.icon(
                      key: const Key('player_chapters_button'),
                      onPressed: () => _showChaptersDrawer(context, ref),
                      icon: const Icon(Icons.list, size: 18),
                      label: Text('章节 (${state.chunks.length})'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 睡眠定时：到点自动暂停（设计文档 §5.1 播放器次级入口）。
  void _showSleepDialog(BuildContext context, WidgetRef ref) {
    final controller = ref.read(chunkedPlayerProvider.notifier);
    final active = ref.read(chunkedPlayerProvider).sleepUntil != null;

    void pick(Duration? duration) {
      if (duration == null) {
        controller.cancelSleepTimer();
      } else {
        controller.setSleepTimer(duration);
      }
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
            if (active)
              Padding(
                padding: const EdgeInsets.all(EchoMetrics.space2),
                child: Builder(
                  builder: (ctx) {
                    final tokens = Theme.of(ctx).extension<EchoTokens>()!;
                    return Text(
                      '当前定时生效中',
                      style: Theme.of(ctx)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: tokens.textSecondary),
                    );
                  },
                ),
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
            selectedTileColor: tokens.readingHighlight,
            leading: Icon(
              selected ? Icons.volume_up : Icons.menu_book_outlined,
              color: selected ? tokens.primary : tokens.textSecondary,
            ),
            title: Text(
              c.title.isNotEmpty ? c.title : '第 ${index + 1} 章',
              style: TextStyle(
                color: selected ? tokens.textPrimary : tokens.textSecondary,
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

class _CoverFallbackView extends StatelessWidget {
  const _CoverFallbackView({
    required this.bookTitle,
    required this.chapterTitle,
  });

  final String bookTitle;
  final String chapterTitle;

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
            Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                color: tokens.surfaceElevated,
                borderRadius: BorderRadius.circular(EchoMetrics.radiusCard),
              ),
              child: Icon(
                Icons.headphones,
                size: 72,
                color: tokens.accent,
              ),
            ),
            const SizedBox(height: EchoMetrics.space3),
            Text(
              bookTitle,
              textAlign: TextAlign.center,
              style:
                  textTheme.headlineSmall?.copyWith(color: tokens.textPrimary),
            ),
            const SizedBox(height: EchoMetrics.space1),
            Text(
              chapterTitle,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
