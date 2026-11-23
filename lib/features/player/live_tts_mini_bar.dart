import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/chunked_player_controller.dart';
import '../../core/audio/live_tts_player_controller.dart';
import '../../design/book_cover.dart';
import '../../design/echo_glass.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../reader/reader_page.dart';

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

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        EchoMetrics.space2,
        0,
        EchoMetrics.space2,
        EchoMetrics.space2,
      ),
      child: EchoGlassSurface(
        borderRadius: BorderRadius.circular(18),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: InkWell(
          key: const Key('live_tts_mini_bar'),
          borderRadius: BorderRadius.circular(14),
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
          child: Row(
            children: [
              BookCover(url: book.coverUrl, width: 38, height: 50),
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
                            color: tokens.primary.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            state.isSynthesizing ? '合成中' : '实时朗读',
                            style: textTheme.labelSmall?.copyWith(
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
                              color: tokens.textPrimary,
                              fontWeight: FontWeight.w700,
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
                      style: textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: state.isPlaying ? '暂停' : '继续朗读',
                onPressed: ctrl.togglePlayPause,
                icon: state.isSynthesizing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        state.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        color: tokens.primary,
                        size: 30,
                      ),
              ),
              IconButton(
                tooltip: '下一句',
                onPressed: ctrl.nextSentence,
                icon: Icon(
                  Icons.skip_next_rounded,
                  color: tokens.textPrimary,
                ),
              ),
              IconButton(
                tooltip: '停止朗读',
                onPressed: ctrl.stop,
                icon: Icon(Icons.close, color: tokens.textSecondary, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
