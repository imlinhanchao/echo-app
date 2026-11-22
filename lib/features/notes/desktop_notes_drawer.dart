import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/chunked_player_controller.dart';
import '../../core/export/book_exporter.dart';
import '../../core/notes/note_store.dart';
import '../../core/sync/progress_sync_service.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import 'desktop_notes_focus_page.dart';

/// 桌面端时间戳笔记侧栏抽屉（对齐设计图 ui-desktop-notes）。
class DesktopNotesDrawer extends ConsumerStatefulWidget {
  const DesktopNotesDrawer({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<DesktopNotesDrawer> createState() => _DesktopNotesDrawerState();
}

class _DesktopNotesDrawerState extends ConsumerState<DesktopNotesDrawer> {
  final _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _addNote() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    final playerState = ref.read(chunkedPlayerProvider);
    final audiobookId = playerState.audiobook?.id ?? 0;
    if (audiobookId == 0) return;

    final chapterTitle = playerState.currentChunk?.title ?? '';
    final note = await NoteStore.instance.add(
      audiobookId: audiobookId,
      positionMs: playerState.positionMs,
      text: text,
      chapterTitle: chapterTitle,
    );
    ref.read(progressSyncServiceProvider.notifier).reportNoteCreated(note);
    _textController.clear();
    setState(() {});
  }

  Future<void> _exportNotes() async {
    final playerState = ref.read(chunkedPlayerProvider);
    final book = playerState.audiobook;
    if (book == null) return;
    final notes = NoteStore.instance.notesFor(book.id);
    if (notes.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前书籍暂无笔记可导出')));
      return;
    }
    final path = await BookExporter.exportNotes(
      bookTitle: book.bookTitle,
      notes: notes,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已导出笔记至：$path')));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final playerState = ref.watch(chunkedPlayerProvider);
    final audiobookId = playerState.audiobook?.id ?? 0;

    final notes = audiobookId > 0
        ? NoteStore.instance.notesFor(audiobookId)
        : NoteStore.instance.allNotes;

    return Container(
      key: const Key('desktop_notes_drawer'),
      width: 320,
      decoration: BoxDecoration(
        color: tokens.surfaceBase,
        border: Border(left: BorderSide(color: tokens.surfaceSubtle)),
      ),
      child: Column(
        children: [
          // 顶栏
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: EchoMetrics.space2,
              vertical: EchoMetrics.space1,
            ),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: tokens.surfaceSubtle)),
            ),
            child: Row(
              children: [
                Icon(Icons.edit_note, color: tokens.primary, size: 22),
                const SizedBox(width: EchoMetrics.space1),
                Text(
                  '时间戳笔记',
                  style: textTheme.titleSmall?.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  key: const Key('desktop_notes_focus_button'),
                  iconSize: 20,
                  tooltip: '进入笔记专注模式',
                  icon: const Icon(Icons.open_in_full),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DesktopNotesFocusPage(),
                    ),
                  ),
                ),
                if (audiobookId > 0)
                  IconButton(
                    iconSize: 20,
                    tooltip: '导出 Markdown',
                    icon: const Icon(Icons.file_download_outlined),
                    onPressed: _exportNotes,
                  ),
                IconButton(
                  iconSize: 20,
                  tooltip: '关闭面板',
                  icon: const Icon(Icons.close),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),

          // 快速打点输入区（当有有声书播放时可用）
          if (audiobookId > 0)
            Padding(
              padding: const EdgeInsets.all(EchoMetrics.space2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('desktop_note_input'),
                    controller: _textController,
                    maxLines: 2,
                    decoration: InputDecoration(
                      hintText: '记录此刻思考（快捷键 Cmd/Ctrl+M）...',
                      hintStyle: textTheme.bodySmall?.copyWith(
                        color: tokens.textDisabled,
                      ),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          EchoMetrics.radiusInput,
                        ),
                      ),
                    ),
                    onSubmitted: (_) => _addNote(),
                  ),
                  const SizedBox(height: EchoMetrics.space1),
                  FilledButton.tonalIcon(
                    key: const Key('desktop_note_submit'),
                    onPressed: _addNote,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('插入当前时间戳笔记'),
                  ),
                ],
              ),
            ),

          // 笔记列表
          Expanded(
            child: notes.isEmpty
                ? Center(
                    child: Text(
                      '暂无时间戳笔记\n在播放中随时打点记录',
                      textAlign: TextAlign.center,
                      style: textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(EchoMetrics.space2),
                    itemCount: notes.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: EchoMetrics.space1),
                    itemBuilder: (context, index) {
                      final note = notes[index];
                      return Container(
                        padding: const EdgeInsets.all(EchoMetrics.space2),
                        decoration: BoxDecoration(
                          color: tokens.surfaceElevated,
                          borderRadius: BorderRadius.circular(
                            EchoMetrics.radiusCard,
                          ),
                          border: Border.all(color: tokens.surfaceSubtle),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                // 时间戳胶囊（点击 seek 到对应秒数）
                                InkWell(
                                  borderRadius: BorderRadius.circular(4),
                                  onTap: () {
                                    ref
                                        .read(chunkedPlayerProvider.notifier)
                                        .seekTo(note.positionMs);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: tokens.primary.withValues(
                                        alpha: 0.15,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.play_arrow,
                                          size: 12,
                                          color: tokens.primary,
                                        ),
                                        const SizedBox(width: 2),
                                        Text(
                                          note.positionLabel,
                                          style: textTheme.labelSmall?.copyWith(
                                            color: tokens.primary,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: EchoMetrics.space1),
                                if (note.chapterTitle.isNotEmpty)
                                  Expanded(
                                    child: Text(
                                      note.chapterTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.labelSmall?.copyWith(
                                        color: tokens.textSecondary,
                                      ),
                                    ),
                                  ),
                                IconButton(
                                  iconSize: 16,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  tooltip: '删除笔记',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () {
                                    NoteStore.instance.remove(note.id);
                                    ref
                                        .read(
                                          progressSyncServiceProvider.notifier,
                                        )
                                        .reportNoteDeleted(note.id);
                                    setState(() {});
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: EchoMetrics.space1),
                            Text(
                              note.text,
                              style: textTheme.bodyMedium?.copyWith(
                                color: tokens.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
