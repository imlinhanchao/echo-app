import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/chunked_player_controller.dart';
import '../../design/book_cover.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../library/library_controller.dart';
import 'player_sheet.dart' show formatDurationMs, openPlayer;

/// 桌面端全宽底部专业播控台（极简书房 Editorial Minimalism）。
class DesktopPlayerBar extends ConsumerStatefulWidget {
  const DesktopPlayerBar({
    super.key,
    this.onToggleNotes,
    this.isNotesOpen = false,
  });

  final VoidCallback? onToggleNotes;
  final bool isNotesOpen;

  @override
  ConsumerState<DesktopPlayerBar> createState() => _DesktopPlayerBarState();
}

class _DesktopPlayerBarState extends ConsumerState<DesktopPlayerBar> {
  double _lastNonZeroVolume = 1.0;

  void _toggleMute(double currentVolume) {
    final controller = ref.read(chunkedPlayerProvider.notifier);
    if (currentVolume > 0) {
      _lastNonZeroVolume = currentVolume;
      controller.setVolume(0);
    } else {
      controller.setVolume(_lastNonZeroVolume > 0 ? _lastNonZeroVolume : 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chunkedPlayerProvider);
    if (!state.hasBook) return const SizedBox.shrink();

    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final hairline = echoHairlineColor(context, darkAlpha: 0.08);
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

    final chunkDurationMs = chunk?.durationMs ?? 0;
    final posMs = state.positionMs
        .clamp(0, chunkDurationMs > 0 ? chunkDurationMs : 1)
        .toInt();
    final progress = chunkDurationMs > 0
        ? (posMs / chunkDurationMs).clamp(0.0, 1.0)
        : 0.0;
    final volume = state.volume;

    return Container(
      key: const Key('desktop_player_bar'),
      height: 76,
      decoration: BoxDecoration(
        color: tokens.surfaceElevated,
        border: Border(top: BorderSide(color: hairline, width: 0.7)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: EchoMetrics.space3),
      child: Row(
        children: [
          // 左侧：封面 + 书名/章节
          InkWell(
            borderRadius: BorderRadius.circular(EchoMetrics.radiusControl),
            onTap: () => openPlayer(context),
            child: Padding(
              padding: const EdgeInsets.all(4.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BookCover(
                    url: cover,
                    title: title,
                    width: 38,
                    height: 54,
                    borderRadius: 6,
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 180,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelLarge?.copyWith(
                            color: tokens.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
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

          const SizedBox(width: EchoMetrics.space2),

          // 中间：播控簇与进度条
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      iconSize: 20,
                      tooltip: '上一章',
                      color: tokens.textSecondary,
                      icon: const Icon(Icons.skip_previous_rounded),
                      onPressed: () => ref
                          .read(chunkedPlayerProvider.notifier)
                          .previousChunk(),
                    ),
                    IconButton(
                      iconSize: 20,
                      tooltip: '快退 15 秒',
                      color: tokens.textSecondary,
                      icon: const Icon(Icons.replay_10_rounded),
                      onPressed: () => ref
                          .read(chunkedPlayerProvider.notifier)
                          .seekByRelativeMs(-15000),
                    ),
                    const SizedBox(width: EchoMetrics.space1),
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: tokens.primary,
                      child: IconButton(
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        color: tokens.textOnPrimary,
                        tooltip: state.isPlaying ? '暂停' : '播放',
                        icon: Icon(
                          state.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        onPressed: () => ref
                            .read(chunkedPlayerProvider.notifier)
                            .togglePlay(),
                      ),
                    ),
                    const SizedBox(width: EchoMetrics.space1),
                    IconButton(
                      iconSize: 20,
                      tooltip: '快进 15 秒',
                      color: tokens.textSecondary,
                      icon: const Icon(Icons.forward_10_rounded),
                      onPressed: () => ref
                          .read(chunkedPlayerProvider.notifier)
                          .seekByRelativeMs(15000),
                    ),
                    IconButton(
                      iconSize: 20,
                      tooltip: '下一章',
                      color: tokens.textSecondary,
                      icon: const Icon(Icons.skip_next_rounded),
                      onPressed: () =>
                          ref.read(chunkedPlayerProvider.notifier).nextChunk(),
                    ),
                  ],
                ),

                Row(
                  children: [
                    Text(
                      formatDurationMs(posMs),
                      style: textTheme.labelSmall?.copyWith(
                        color: tokens.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2.5,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 4.5,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 10,
                          ),
                          activeTrackColor: tokens.primary,
                          inactiveTrackColor: tokens.surfaceSubtle,
                          thumbColor: tokens.primary,
                        ),
                        child: Slider(
                          value: progress,
                          onChanged: (val) {
                            if (chunkDurationMs > 0) {
                              final target = (val * chunkDurationMs).toInt();
                              ref
                                  .read(chunkedPlayerProvider.notifier)
                                  .seekTo(target);
                            }
                          },
                        ),
                      ),
                    ),
                    Text(
                      formatDurationMs(chunkDurationMs),
                      style: textTheme.labelSmall?.copyWith(
                        color: tokens.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: EchoMetrics.space2),

          // 右侧：倍速、全屏、笔记切换、音量
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PopupMenuButton<double>(
                tooltip: '播放倍速',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${state.speed.toStringAsFixed(state.speed == state.speed.toInt() ? 1 : 2)}x',
                    style: textTheme.labelSmall?.copyWith(
                      color: tokens.primary,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 0.75, child: Text('0.75x')),
                  PopupMenuItem(value: 1.0, child: Text('1.0x (原速)')),
                  PopupMenuItem(value: 1.25, child: Text('1.25x')),
                  PopupMenuItem(value: 1.5, child: Text('1.5x')),
                  PopupMenuItem(value: 2.0, child: Text('2.0x')),
                ],
                onSelected: (s) =>
                    ref.read(chunkedPlayerProvider.notifier).setSpeed(s),
              ),

              IconButton(
                iconSize: 20,
                tooltip: '全屏跟读视图',
                color: tokens.textSecondary,
                icon: const Icon(Icons.open_in_full_rounded),
                onPressed: () => openPlayer(context),
              ),

              if (widget.onToggleNotes != null)
                IconButton(
                  iconSize: 20,
                  tooltip: widget.isNotesOpen ? '关闭笔记面板' : '展开笔记面板',
                  color: widget.isNotesOpen
                      ? tokens.primary
                      : tokens.textSecondary,
                  icon: const Icon(Icons.edit_note_rounded),
                  onPressed: widget.onToggleNotes,
                ),

              const SizedBox(width: 4),
              IconButton(
                key: const Key('desktop_volume_mute'),
                iconSize: 18,
                tooltip: volume == 0 ? '取消静音' : '静音',
                color: tokens.textSecondary,
                icon: Icon(
                  volume == 0
                      ? Icons.volume_off_rounded
                      : volume < 0.5
                      ? Icons.volume_down_rounded
                      : Icons.volume_up_rounded,
                ),
                onPressed: () => _toggleMute(volume),
              ),
              SizedBox(
                width: 75,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 4,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 8,
                    ),
                    activeTrackColor: tokens.textPrimary,
                    inactiveTrackColor: tokens.surfaceSubtle,
                    thumbColor: tokens.textPrimary,
                  ),
                  child: Slider(
                    key: const Key('desktop_volume_slider'),
                    value: volume,
                    onChanged: (val) {
                      if (val > 0) _lastNonZeroVolume = val;
                      ref.read(chunkedPlayerProvider.notifier).setVolume(val);
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
