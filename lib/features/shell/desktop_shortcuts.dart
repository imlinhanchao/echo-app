import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/chunked_player_controller.dart';
import '../../core/notes/note_store.dart';
import '../../core/sync/progress_sync_service.dart';

class PlayPauseIntent extends Intent {
  const PlayPauseIntent();
}

class PreviousChunkIntent extends Intent {
  const PreviousChunkIntent();
}

class NextChunkIntent extends Intent {
  const NextChunkIntent();
}

class SeekRelativeIntent extends Intent {
  const SeekRelativeIntent(this.offsetMs);
  final int offsetMs;
}

class AddNoteIntent extends Intent {
  const AddNoteIntent();
}

class SkimChapterIntent extends Intent {
  const SkimChapterIntent(this.delta);
  final int delta;
}

/// 桌面全局快捷键包装器（对齐设计 §5.1）：
/// - Space: 播放 / 暂停
/// - [ / ]: 快退 15s / 快进 15s
/// - Left / Right 或 Alt+Left / Alt+Right: 上一章 / 下一章
/// - Shift+Left / Shift+Right: 跨章略读模式（每章预览 30s）
/// - Ctrl+M / Cmd+M: 当前播放点快速插入时间戳笔记
class DesktopShortcutsWrapper extends ConsumerWidget {
  const DesktopShortcutsWrapper({
    super.key,
    required this.child,
    this.onAddNotePrompt,
  });

  final Widget child;
  final VoidCallback? onAddNotePrompt;

  static bool _isTextInputFocused() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return false;
    final ctx = focus.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.space):
            const PlayPauseIntent(),
        const SingleActivator(LogicalKeyboardKey.bracketLeft):
            const SeekRelativeIntent(-15000),
        const SingleActivator(LogicalKeyboardKey.bracketRight):
            const SeekRelativeIntent(15000),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const PreviousChunkIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const NextChunkIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
            const PreviousChunkIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
            const NextChunkIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
            const SkimChapterIntent(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
            const SkimChapterIntent(1),
        const SingleActivator(LogicalKeyboardKey.keyM, control: true):
            const AddNoteIntent(),
        const SingleActivator(LogicalKeyboardKey.keyM, meta: true):
            const AddNoteIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          PlayPauseIntent: CallbackAction<PlayPauseIntent>(
            onInvoke: (_) {
              if (_isTextInputFocused()) return null;
              final controller = ref.read(chunkedPlayerProvider.notifier);
              controller.cancelSkim();
              controller.togglePlay();
              return null;
            },
          ),
          PreviousChunkIntent: CallbackAction<PreviousChunkIntent>(
            onInvoke: (_) {
              if (_isTextInputFocused()) return null;
              final controller = ref.read(chunkedPlayerProvider.notifier);
              controller.cancelSkim();
              controller.previousChunk();
              return null;
            },
          ),
          NextChunkIntent: CallbackAction<NextChunkIntent>(
            onInvoke: (_) {
              if (_isTextInputFocused()) return null;
              final controller = ref.read(chunkedPlayerProvider.notifier);
              controller.cancelSkim();
              controller.nextChunk();
              return null;
            },
          ),
          SkimChapterIntent: CallbackAction<SkimChapterIntent>(
            onInvoke: (intent) {
              if (_isTextInputFocused()) return null;
              ref
                  .read(chunkedPlayerProvider.notifier)
                  .skimChapter(intent.delta);
              return null;
            },
          ),
          SeekRelativeIntent: CallbackAction<SeekRelativeIntent>(
            onInvoke: (intent) {
              if (_isTextInputFocused()) return null;
              final controller = ref.read(chunkedPlayerProvider.notifier);
              controller.cancelSkim();
              controller.seekByRelativeMs(intent.offsetMs);
              return null;
            },
          ),
          AddNoteIntent: CallbackAction<AddNoteIntent>(
            onInvoke: (_) async {
              if (onAddNotePrompt != null) {
                onAddNotePrompt!();
                return null;
              }
              final player = ref.read(chunkedPlayerProvider);
              final audiobookId = player.audiobook?.id ?? 0;
              if (audiobookId == 0) return null;
              final note = await NoteStore.instance.add(
                audiobookId: audiobookId,
                positionMs: player.positionMs,
                text: '快捷键书签打点',
                chapterTitle: player.currentChunk?.title ?? '',
              );
              ref
                  .read(progressSyncServiceProvider.notifier)
                  .reportNoteCreated(note);
              if (context.mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 2),
                    content: Text('已在 ${note.positionLabel} 插入时间戳笔记'),
                  ),
                );
              }
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}
