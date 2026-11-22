import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/chunked_player_controller.dart';
import '../../core/export/book_exporter.dart';
import '../../core/notes/note_store.dart';
import '../../core/sync/progress_sync_service.dart';
import '../../design/book_cover.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../library/library_controller.dart';
import '../player/player_sheet.dart' show formatDurationMs;

/// 桌面端双栏笔记专注模式（对齐设计图 ui-desktop-notes）：
/// 左栏：封面 + 章节列表 + 播放控制；
/// 右栏：快捷格式工具栏 + 时间戳笔记输入 + 按章节分组的笔记流（支持 Markdown 导出）。
class DesktopNotesFocusPage extends ConsumerStatefulWidget {
  const DesktopNotesFocusPage({super.key});

  @override
  ConsumerState<DesktopNotesFocusPage> createState() =>
      _DesktopNotesFocusPageState();
}

class _DesktopNotesFocusPageState extends ConsumerState<DesktopNotesFocusPage> {
  final TextEditingController _inputController = TextEditingController();

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  void _insertSnippet(String prefix, [String suffix = '']) {
    final text = _inputController.text;
    final sel = _inputController.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final selected = text.substring(start, end);
    final next =
        text.substring(0, start) + prefix + selected + suffix + text.substring(end);
    _inputController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: start + prefix.length + selected.length,
      ),
    );
  }

  Future<void> _submitNote() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    final playerState = ref.read(chunkedPlayerProvider);
    final audiobookId = playerState.audiobook?.id ?? 0;
    if (audiobookId == 0) return;

    final note = await NoteStore.instance.add(
      audiobookId: audiobookId,
      positionMs: playerState.positionMs,
      text: text,
      chapterTitle: playerState.currentChunk?.title ?? '',
    );
    ref.read(progressSyncServiceProvider.notifier).reportNoteCreated(note);
    _inputController.clear();
    setState(() {});
  }

  Future<void> _exportNotes() async {
    final book = ref.read(chunkedPlayerProvider).audiobook;
    if (book == null) return;
    final notes = NoteStore.instance.notesFor(book.id);
    if (notes.isEmpty) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('当前书籍暂无笔记可导出')));
      return;
    }
    final path = await BookExporter.exportNotes(
      bookTitle: book.bookTitle,
      notes: notes,
    );
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('已导出笔记至：$path')));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final playerState = ref.watch(chunkedPlayerProvider);
    final playerController = ref.read(chunkedPlayerProvider.notifier);
    final libState = ref.watch(libraryControllerProvider);
    final audiobookId = playerState.audiobook?.id ?? 0;
    final cover = libState.books
        .where((b) => b.id == (playerState.audiobook?.bookId ?? 0))
        .map((b) => b.coverUrl)
        .firstOrNull;
    final bookTitle = (playerState.audiobook?.bookTitle.isNotEmpty ?? false)
        ? playerState.audiobook!.bookTitle
        : '笔记专注模式';

    final notes = audiobookId > 0
        ? NoteStore.instance.notesFor(audiobookId)
        : NoteStore.instance.allNotes;

    // 按章节分组
    final grouped = <String, List<TimestampNote>>{};
    for (final note in notes) {
      final key = note.chapterTitle.isNotEmpty ? note.chapterTitle : '未分组章节';
      grouped.putIfAbsent(key, () => <TimestampNote>[]).add(note);
    }

    return Scaffold(
      key: const Key('desktop_notes_focus_page'),
      appBar: AppBar(
        title: Text('笔记专注模式 · $bookTitle'),
        actions: [
          if (audiobookId > 0)
            FilledButton.tonalIcon(
              key: const Key('focus_notes_export'),
              onPressed: _exportNotes,
              icon: const Icon(Icons.file_download_outlined, size: 18),
              label: const Text('导出 Markdown'),
            ),
          const SizedBox(width: EchoMetrics.space2),
        ],
      ),
      body: Row(
        children: [
          // 左栏：封面 + 播控 + 章节列表
          Container(
            width: 320,
            decoration: BoxDecoration(
              color: tokens.surfaceElevated,
              border: Border(right: BorderSide(color: tokens.surfaceSubtle)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(EchoMetrics.space2),
                  child: Row(
                    children: [
                      BookCover(url: cover, width: 64, height: 86),
                      const SizedBox(width: EchoMetrics.space2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              bookTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleSmall?.copyWith(
                                color: tokens.textPrimary,
                              ),
                            ),
                            const SizedBox(height: EchoMetrics.space1),
                            Text(
                              '当前位置 ${formatDurationMs(playerState.positionMs)}',
                              style: textTheme.labelSmall?.copyWith(
                                color: tokens.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // 简洁播控条
                if (playerState.hasBook)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: EchoMetrics.space2,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          tooltip: '上一章',
                          onPressed: playerState.hasPreviousChunk
                              ? playerController.previousChunk
                              : null,
                          icon: const Icon(Icons.skip_previous),
                        ),
                        IconButton(
                          tooltip: '快退 15s',
                          onPressed: () => playerController.skipBy(
                            const Duration(seconds: -15),
                          ),
                          icon: const Icon(Icons.replay_10),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: const EdgeInsets.all(12),
                          ),
                          onPressed: playerController.togglePlayPause,
                          child: Icon(
                            playerState.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                          ),
                        ),
                        IconButton(
                          tooltip: '快进 15s',
                          onPressed: () => playerController.skipBy(
                            const Duration(seconds: 15),
                          ),
                          icon: const Icon(Icons.forward_10),
                        ),
                        IconButton(
                          tooltip: '下一章',
                          onPressed: playerState.hasNextChunk
                              ? playerController.nextChunk
                              : null,
                          icon: const Icon(Icons.skip_next),
                        ),
                      ],
                    ),
                  ),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    itemCount: playerState.chunks.length,
                    itemBuilder: (_, idx) {
                      final chunk = playerState.chunks[idx];
                      final isCurrent = idx == playerState.currentChunkIndex;
                      return ListTile(
                        dense: true,
                        selected: isCurrent,
                        selectedTileColor: tokens.primary.withValues(
                          alpha: 0.14,
                        ),
                        leading: Icon(
                          isCurrent
                              ? Icons.graphic_eq
                              : Icons.menu_book_outlined,
                          size: 18,
                          color: isCurrent
                              ? tokens.primary
                              : tokens.textSecondary,
                        ),
                        title: Text(
                          chunk.title.isNotEmpty
                              ? chunk.title
                              : '第 ${idx + 1} 章',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => playerController.selectChunk(idx),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // 右栏：编辑区 + 按章节分组笔记流
          Expanded(
            child: Column(
              children: [
                if (audiobookId > 0)
                  Container(
                    padding: const EdgeInsets.all(EchoMetrics.space2),
                    decoration: BoxDecoration(
                      color: tokens.surfaceBase,
                      border: Border(
                        bottom: BorderSide(color: tokens.surfaceSubtle),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 格式工具栏
                        Row(
                          children: [
                            IconButton(
                              tooltip: '加粗',
                              icon: const Icon(Icons.format_bold, size: 18),
                              onPressed: () => _insertSnippet('**', '**'),
                            ),
                            IconButton(
                              tooltip: '引用',
                              icon: const Icon(Icons.format_quote, size: 18),
                              onPressed: () => _insertSnippet('> '),
                            ),
                            IconButton(
                              tooltip: '要点列表',
                              icon: const Icon(
                                Icons.format_list_bulleted,
                                size: 18,
                              ),
                              onPressed: () => _insertSnippet('- '),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: tokens.primary.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                formatDurationMs(playerState.positionMs),
                                style: textTheme.labelSmall?.copyWith(
                                  color: tokens.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: EchoMetrics.space1),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: TextField(
                                key: const Key('focus_note_input'),
                                controller: _inputController,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                  hintText: '写下此刻的想法或摘录（支持 Markdown）…',
                                ),
                              ),
                            ),
                            const SizedBox(width: EchoMetrics.space2),
                            FilledButton.icon(
                              key: const Key('focus_note_submit'),
                              onPressed: _submitNote,
                              icon: const Icon(Icons.add),
                              label: const Text('打点保存'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: grouped.isEmpty
                      ? Center(
                          child: Text(
                            '还没有时间戳笔记，在上方输入框随时记录',
                            style: textTheme.bodyMedium?.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.all(EchoMetrics.space3),
                          children: [
                            for (final entry in grouped.entries) ...[
                              Padding(
                                padding: const EdgeInsets.only(
                                  bottom: EchoMetrics.space1,
                                  top: EchoMetrics.space1,
                                ),
                                child: Text(
                                  '${entry.key}（${entry.value.length}）',
                                  style: textTheme.titleSmall?.copyWith(
                                    color: tokens.textSecondary,
                                  ),
                                ),
                              ),
                              for (final note in entry.value)
                                Card(
                                  margin: const EdgeInsets.only(
                                    bottom: EchoMetrics.space1,
                                  ),
                                  child: ListTile(
                                    leading: ActionChip(
                                      label: Text(note.positionLabel),
                                      avatar: Icon(
                                        Icons.play_arrow,
                                        size: 16,
                                        color: tokens.primary,
                                      ),
                                      onPressed: () =>
                                          playerController.seekTo(
                                            note.positionMs,
                                          ),
                                    ),
                                    title: Text(
                                      note.text,
                                      style: textTheme.bodyMedium?.copyWith(
                                        color: tokens.textPrimary,
                                      ),
                                    ),
                                    trailing: IconButton(
                                      tooltip: '删除笔记',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () {
                                        NoteStore.instance.remove(note.id);
                                        ref
                                            .read(
                                              progressSyncServiceProvider
                                                  .notifier,
                                            )
                                            .reportNoteDeleted(note.id);
                                        setState(() {});
                                      },
                                    ),
                                  ),
                                ),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
