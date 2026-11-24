import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/chunked_player_controller.dart';
import '../../core/audio/live_tts_player_controller.dart';
import '../../design/book_cover.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_glass.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../reader/reader_page.dart';
import 'playback_speed_sheet.dart';

/// 端侧「边听边生成」悬浮迷你播控条：
/// 当实时 TTS 正在朗读且离线分块播放器未激活时显示，点击可直达阅读器定位到当前句。
class LiveTtsMiniBar extends ConsumerWidget {
  const LiveTtsMiniBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chunkedHasBook = ref.watch(
      chunkedPlayerProvider.select((s) => s.hasBook),
    );
    if (chunkedHasBook) return const SizedBox.shrink();

    final state = ref.watch(liveTtsPlayerProvider);
    if (!state.hasBook || state.book == null) return const SizedBox.shrink();

    final ctrl = ref.read(liveTtsPlayerProvider.notifier);
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final book = state.book!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(EchoMetrics.radiusCard);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        12,
        0,
        12,
        EchoMetrics.space1,
      ),
      child: Material(
        color: Colors.transparent,
        child: EchoGlassSurface(
          borderRadius: radius,
          opacity: isDark ? 0.86 : 0.92,
          border: Border.all(
            color: echoHairlineColor(context, darkAlpha: 0.10),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.36 : 0.10),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
          child: InkWell(
            key: const Key('live_tts_mini_bar'),
            borderRadius: radius,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ReaderPageView(
                    book: book,
                    initialChapterIndex: state.chapterIndex,
                    initialCharOffset: state.currentSentence?.startOffset ?? 0,
                  ),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  BookCover(
                    url: book.coverUrl,
                    title: book.title,
                    width: 34,
                    height: 48,
                    borderRadius: 6,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: tokens.primary.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                state.isSynthesizing ? '合成中' : '朗读',
                                style: textTheme.labelSmall?.copyWith(
                                  fontSize: 10.5,
                                  color: tokens.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                book.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.labelLarge?.copyWith(
                                  fontSize: 13.5,
                                  color: tokens.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          state.currentCueText.isNotEmpty
                              ? state.currentCueText
                              : state.chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelSmall?.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  buildCompactSpeedPill(
                    key: const Key('live_tts_mini_speed'),
                    speed: state.speed,
                    accentColor: tokens.primary,
                    textColor: tokens.textPrimary,
                    borderColor: echoHairlineColor(context, darkAlpha: 0.16),
                    onTap: () => showPlaybackSpeedSheet(
                      context,
                      initialSpeed: state.speed,
                      title: '朗读语速',
                      onChanged: (s) => unawaited(ctrl.setSpeed(s)),
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: state.isPlaying ? '暂停' : '继续朗读',
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: EdgeInsets.zero,
                    ),
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    onPressed: ctrl.togglePlayPause,
                    icon: state.isSynthesizing
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tokens.primary,
                            ),
                          )
                        : Icon(
                            state.isPlaying
                                ? Icons.pause_circle_filled_rounded
                                : Icons.play_circle_filled_rounded,
                            color: tokens.primary,
                            size: 28,
                          ),
                  ),
                  IconButton(
                    tooltip: '下一句',
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: EdgeInsets.zero,
                    ),
                    constraints: const BoxConstraints.tightFor(
                      width: 34,
                      height: 34,
                    ),
                    onPressed: ctrl.nextSentence,
                    icon: Icon(
                      Icons.skip_next_rounded,
                      size: 20,
                      color: tokens.textPrimary,
                    ),
                  ),
                  IconButton(
                    tooltip: '停止朗读',
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: EdgeInsets.zero,
                    ),
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                    onPressed: ctrl.stop,
                    icon: Icon(
                      Icons.close_rounded,
                      color: tokens.textSecondary,
                      size: 18,
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
