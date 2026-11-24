import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notes/reading_annotation_store.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';

enum _AnnotationFilter { all, notesOnly, highlightsOnly }

String _formatAnnotationTime(DateTime utcTime) {
  final local = utcTime.toLocal();
  final mm = local.month.toString().padLeft(2, '0');
  final dd = local.day.toString().padLeft(2, '0');
  final hh = local.hour.toString().padLeft(2, '0');
  final min = local.minute.toString().padLeft(2, '0');
  return '$mm-$dd $hh:$min';
}

/// 共享墨色调色圆点行：用于选词浮动工具栏与笔记编辑抽屉。
class _AnnotationColorRow extends StatelessWidget {
  const _AnnotationColorRow({
    required this.selectedColor,
    required this.keyPrefix,
    required this.onSelect,
    this.dotSize = 22,
    this.spacing = 10,
  });

  final ReadingHighlightColor selectedColor;
  final String keyPrefix;
  final ValueChanged<ReadingHighlightColor> onSelect;
  final double dotSize;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < ReadingHighlightColor.values.length; i++) ...[
          if (i > 0) SizedBox(width: spacing),
          _ColorDotButton(
            buttonKey: Key('$keyPrefix${ReadingHighlightColor.values[i].name}'),
            highlightColor: ReadingHighlightColor.values[i],
            selected: ReadingHighlightColor.values[i] == selectedColor,
            ringColor: tokens.textPrimary,
            size: dotSize,
            onTap: () => onSelect(ReadingHighlightColor.values[i]),
          ),
        ],
      ],
    );
  }
}

class _ColorDotButton extends StatelessWidget {
  const _ColorDotButton({
    required this.buttonKey,
    required this.highlightColor,
    required this.selected,
    required this.ringColor,
    required this.size,
    required this.onTap,
  });

  final Key buttonKey;
  final ReadingHighlightColor highlightColor;
  final bool selected;
  final Color ringColor;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: highlightColor.label,
      child: InkWell(
        key: buttonKey,
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: size + 6,
          height: size + 6,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? ringColor : Colors.transparent,
              width: 1.4,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: highlightColor.color,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarActionButton extends StatelessWidget {
  const _ToolbarActionButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.onTap,
    required this.color,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      key: buttonKey,
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 3),
            Text(
              label,
              style: textTheme.labelSmall?.copyWith(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 在 Overlay 坐标系下计算无遮挡的选词浮动操作栏左上角坐标。
///
/// 优先放在正文内容区内的选区上方（留出 [gapAbove] 间距）或选区下方
/// （留出底部水滴手柄高度 [gapBelow]），其次才借用顶栏或底栏外侧安全区域，
/// 避免工具栏覆盖被选中的文本与拖动手柄。
@visibleForTesting
Offset computeSelectionToolbarOffset({
  required Size overlaySize,
  required Size childSize,
  required Rect selectionRect,
  required double safeTop,
  required double safeBottom,
  required double contentTop,
  required double contentBottom,
  double horizontalMargin = 12.0,
  double gapAbove = 12.0,
  double gapBelow = 38.0,
}) {
  final maxX = math.max(
    horizontalMargin,
    overlaySize.width - horizontalMargin - childSize.width,
  );
  final x = (selectionRect.center.dx - childSize.width / 2).clamp(
    horizontalMargin,
    maxX,
  );

  final aboveY = selectionRect.top - gapAbove - childSize.height;
  final belowY = selectionRect.bottom + gapBelow;
  final contentMaxBottom = overlaySize.height - contentBottom;
  final safeMaxBottom = overlaySize.height - safeBottom;

  final double y;
  if (aboveY >= contentTop && aboveY + childSize.height <= safeMaxBottom) {
    y = aboveY;
  } else if (belowY >= safeTop &&
      belowY + childSize.height <= contentMaxBottom) {
    y = belowY;
  } else if (aboveY >= safeTop &&
      aboveY + childSize.height <= safeMaxBottom) {
    y = aboveY;
  } else if (belowY >= safeTop &&
      belowY + childSize.height <= safeMaxBottom) {
    y = belowY;
  } else {
    final maxY = math.max(
      safeTop,
      safeMaxBottom - childSize.height,
    );
    y = safeTop.clamp(safeTop, maxY);
  }
  return Offset(x.toDouble(), y.toDouble());
}

class _SelectionToolbarLayoutDelegate extends SingleChildLayoutDelegate {
  const _SelectionToolbarLayoutDelegate({
    required this.selectionRect,
    required this.safeTop,
    required this.safeBottom,
    required this.contentTop,
    required this.contentBottom,
  });

  final Rect selectionRect;
  final double safeTop;
  final double safeBottom;
  final double contentTop;
  final double contentBottom;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(
      Size(
        math.max(0.0, constraints.maxWidth - 24.0),
        math.max(0.0, constraints.maxHeight - safeTop - safeBottom),
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return computeSelectionToolbarOffset(
      overlaySize: size,
      childSize: childSize,
      selectionRect: selectionRect,
      safeTop: safeTop,
      safeBottom: safeBottom,
      contentTop: contentTop,
      contentBottom: contentBottom,
    );
  }

  @override
  bool shouldRelayout(_SelectionToolbarLayoutDelegate oldDelegate) {
    return oldDelegate.selectionRect != selectionRect ||
        oldDelegate.safeTop != safeTop ||
        oldDelegate.safeBottom != safeBottom ||
        oldDelegate.contentTop != contentTop ||
        oldDelegate.contentBottom != contentBottom;
  }
}

/// 极简书房选词浮动操作栏：提供 5 色快速划线、写笔记、复制与从此朗读。
class EchoSelectionToolbar extends StatelessWidget {
  const EchoSelectionToolbar({
    super.key,
    required this.selectionRect,
    required this.safeTop,
    required this.safeBottom,
    required this.topClearance,
    required this.bottomClearance,
    required this.selectedColor,
    required this.onSelectColor,
    required this.onHighlight,
    required this.onNote,
    required this.onCopy,
    this.onListenFromHere,
  });

  final Rect selectionRect;
  final double safeTop;
  final double safeBottom;
  final double topClearance;
  final double bottomClearance;
  final ReadingHighlightColor selectedColor;
  final ValueChanged<ReadingHighlightColor> onSelectColor;
  final VoidCallback onHighlight;
  final VoidCallback onNote;
  final VoidCallback onCopy;
  final VoidCallback? onListenFromHere;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hairline = echoHairlineColor(context, darkAlpha: 0.12);
    final bgColor = isDark
        ? Color.lerp(tokens.surfaceElevated, tokens.surfaceBase, 0.2)!
        : tokens.surfaceElevated;

    return CustomSingleChildLayout(
      delegate: _SelectionToolbarLayoutDelegate(
        selectionRect: selectionRect,
        safeTop: safeTop,
        safeBottom: safeBottom,
        contentTop: topClearance,
        contentBottom: bottomClearance,
      ),
      child: Material(
        color: Colors.transparent,
        child: Container(
          key: const Key('reader_selection_toolbar'),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: hairline, width: 0.8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.14),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AnnotationColorRow(
                selectedColor: selectedColor,
                keyPrefix: 'selection_color_',
                dotSize: 18,
                spacing: 8,
                onSelect: onSelectColor,
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: onListenFromHere != null ? 248 : 190,
                child: Divider(height: 1, thickness: 0.6, color: hairline),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ToolbarActionButton(
                    buttonKey: const Key('selection_action_highlight'),
                    icon: Icons.border_color_outlined,
                    label: '划线',
                    color: tokens.primary,
                    onTap: onHighlight,
                  ),
                  _ToolbarActionButton(
                    buttonKey: const Key('selection_action_note'),
                    icon: Icons.edit_note_outlined,
                    label: '写笔记',
                    color: tokens.textPrimary,
                    onTap: onNote,
                  ),
                  _ToolbarActionButton(
                    buttonKey: const Key('selection_action_copy'),
                    icon: Icons.content_copy_rounded,
                    label: '复制',
                    color: tokens.textPrimary,
                    onTap: onCopy,
                  ),
                  if (onListenFromHere != null)
                    _ToolbarActionButton(
                      buttonKey: const Key('selection_action_listen'),
                      icon: Icons.headphones_outlined,
                      label: '从此朗读',
                      color: tokens.textPrimary,
                      onTap: onListenFromHere!,
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

/// 弹出「写读书笔记 / 编辑划线」底部抽屉。
Future<void> showAnnotationEditorSheet({
  required BuildContext context,
  required String quote,
  ReadingAnnotation? existing,
  ReadingHighlightColor initialColor = ReadingHighlightColor.gold,
  String chapterTitle = '',
  required Future<void> Function(ReadingHighlightColor color, String note) onSave,
  Future<void> Function()? onDelete,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AnnotationEditorSheet(
      quote: existing?.quote ?? quote,
      existing: existing,
      initialColor: existing?.color ?? initialColor,
      chapterTitle: existing?.chapterTitle ?? chapterTitle,
      onSave: onSave,
      onDelete: onDelete,
    ),
  );
}

class _AnnotationEditorSheet extends StatefulWidget {
  const _AnnotationEditorSheet({
    required this.quote,
    this.existing,
    required this.initialColor,
    required this.chapterTitle,
    required this.onSave,
    this.onDelete,
  });

  final String quote;
  final ReadingAnnotation? existing;
  final ReadingHighlightColor initialColor;
  final String chapterTitle;
  final Future<void> Function(ReadingHighlightColor color, String note) onSave;
  final Future<void> Function()? onDelete;

  @override
  State<_AnnotationEditorSheet> createState() => _AnnotationEditorSheetState();
}

class _AnnotationEditorSheetState extends State<_AnnotationEditorSheet> {
  late final TextEditingController _noteCtrl;
  late ReadingHighlightColor _color;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _noteCtrl = TextEditingController(text: widget.existing?.note ?? '');
    _color = widget.initialColor;
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_color, _noteCtrl.text);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove() async {
    final onDelete = widget.onDelete;
    if (_saving || onDelete == null) return;
    setState(() => _saving = true);
    try {
      await onDelete();
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        EchoMetrics.pagePadding,
        0,
        EchoMetrics.pagePadding,
        bottomInset + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const EchoSheetDragHandle(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.existing == null ? '写读书笔记' : '编辑笔记与划线',
                    style: textTheme.titleLarge,
                  ),
                ),
                if (widget.chapterTitle.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: EchoPillBadge(label: widget.chapterTitle),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: _color.color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
                border: Border(
                  left: BorderSide(color: _color.color, width: 3),
                ),
              ),
              child: Text(
                widget.quote,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  color: tokens.textPrimary,
                  height: 1.55,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Text(
                  '墨色',
                  style: textTheme.labelMedium?.copyWith(
                    color: tokens.textSecondary,
                  ),
                ),
                const SizedBox(width: 12),
                _AnnotationColorRow(
                  selectedColor: _color,
                  keyPrefix: 'annotation_editor_color_',
                  onSelect: (c) => setState(() => _color = c),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('annotation_note_input'),
              controller: _noteCtrl,
              minLines: 3,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: '记下此刻的想法（留空则仅保留划线）',
                filled: true,
                fillColor: tokens.surfaceSubtle.withValues(alpha: 0.55),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: echoHairlineColor(context),
                    width: 0.8,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: echoHairlineColor(context),
                    width: 0.8,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (widget.existing != null && widget.onDelete != null)
                  TextButton.icon(
                    key: const Key('annotation_delete_button'),
                    style: TextButton.styleFrom(
                      foregroundColor: tokens.error,
                    ),
                    onPressed: _saving ? null : _remove,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('删除划线'),
                  ),
                IconButton(
                  tooltip: '复制摘录',
                  onPressed: () {
                    unawaited(Clipboard.setData(ClipboardData(text: widget.quote)));
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(content: Text('已复制摘录')),
                    );
                  },
                  icon: Icon(
                    Icons.content_copy_rounded,
                    size: 18,
                    color: tokens.textSecondary,
                  ),
                ),
                const Spacer(),
                FilledButton(
                  key: const Key('annotation_save_button'),
                  onPressed: _saving ? null : _submit,
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹出单本书全部「划线与笔记」列表抽屉（支持筛选、编辑、删除与定位跳转）。
Future<void> showBookAnnotationsSheet({
  required BuildContext context,
  required int bookId,
  required ValueChanged<ReadingAnnotation> onJumpTo,
  Future<void> Function(ReadingAnnotation annotation)? onEdit,
  Future<void> Function(ReadingAnnotation annotation)? onDelete,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      key: const Key('reader_notes_sheet'),
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (sheetCtx, scrollController) => _BookAnnotationsSheetBody(
        bookId: bookId,
        scrollController: scrollController,
        onJumpTo: (ann) {
          Navigator.of(sheetCtx).pop();
          onJumpTo(ann);
        },
        onEdit: onEdit,
        onDelete: onDelete,
      ),
    ),
  );
}

class _BookAnnotationsSheetBody extends ConsumerStatefulWidget {
  const _BookAnnotationsSheetBody({
    required this.bookId,
    required this.scrollController,
    required this.onJumpTo,
    this.onEdit,
    this.onDelete,
  });

  final int bookId;
  final ScrollController scrollController;
  final ValueChanged<ReadingAnnotation> onJumpTo;
  final Future<void> Function(ReadingAnnotation annotation)? onEdit;
  final Future<void> Function(ReadingAnnotation annotation)? onDelete;

  @override
  ConsumerState<_BookAnnotationsSheetBody> createState() =>
      _BookAnnotationsSheetBodyState();
}

class _BookAnnotationsSheetBodyState
    extends ConsumerState<_BookAnnotationsSheetBody> {
  _AnnotationFilter _filter = _AnnotationFilter.all;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final allAnnotations = ref.watch(bookAnnotationsProvider(widget.bookId));
    final filtered = switch (_filter) {
      _AnnotationFilter.all => allAnnotations,
      _AnnotationFilter.notesOnly =>
        allAnnotations.where((a) => a.hasNote).toList(growable: false),
      _AnnotationFilter.highlightsOnly =>
        allAnnotations.where((a) => !a.hasNote).toList(growable: false),
    };

    return Column(
      children: [
        const EchoSheetDragHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: EchoSectionHeader(
            title: '划线与笔记',
            subtitle: '${allAnnotations.length} 条',
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Row(
            children: [
              _FilterChipPill(
                chipKey: const Key('notes_filter_all'),
                label: '全部 (${allAnnotations.length})',
                selected: _filter == _AnnotationFilter.all,
                onTap: () => setState(() => _filter = _AnnotationFilter.all),
              ),
              const SizedBox(width: 8),
              _FilterChipPill(
                chipKey: const Key('notes_filter_notes'),
                label: '笔记 (${allAnnotations.where((a) => a.hasNote).length})',
                selected: _filter == _AnnotationFilter.notesOnly,
                onTap: () =>
                    setState(() => _filter = _AnnotationFilter.notesOnly),
              ),
              const SizedBox(width: 8),
              _FilterChipPill(
                chipKey: const Key('notes_filter_highlights'),
                label:
                    '划线 (${allAnnotations.where((a) => !a.hasNote).length})',
                selected: _filter == _AnnotationFilter.highlightsOnly,
                onTap: () =>
                    setState(() => _filter = _AnnotationFilter.highlightsOnly),
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.border_color_outlined,
                          size: 32,
                          color: tokens.textDisabled,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '长按正文选择文字，即可划线或写下读书笔记',
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, index) {
                    final ann = filtered[index];
                    return Container(
                      key: Key('annotation_item_${ann.id}'),
                      decoration: echoElevatedCardDecoration(
                        context,
                        radius: 14,
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => widget.onJumpTo(ann),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 3,
                                height: ann.hasNote ? 64 : 44,
                                margin: const EdgeInsets.only(top: 2),
                                decoration: BoxDecoration(
                                  color: ann.color.color,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            ann.chapterTitle.isNotEmpty
                                                ? ann.chapterTitle
                                                : '第 ${ann.chapterIndex + 1} 章',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: textTheme.labelSmall
                                                ?.copyWith(
                                                  color: tokens.textSecondary,
                                                ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          _formatAnnotationTime(ann.updatedAt),
                                          style: textTheme.labelSmall?.copyWith(
                                            color: tokens.textDisabled,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      ann.quote,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodyMedium?.copyWith(
                                        color: tokens.textPrimary,
                                        height: 1.5,
                                      ),
                                    ),
                                    if (ann.hasNote) ...[
                                      const SizedBox(height: 8),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 7,
                                        ),
                                        decoration: BoxDecoration(
                                          color: tokens.surfaceSubtle
                                              .withValues(alpha: 0.6),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Text(
                                          ann.note,
                                          style: textTheme.bodySmall?.copyWith(
                                            color: tokens.textSecondary,
                                            height: 1.45,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    key: Key('annotation_edit_${ann.id}'),
                                    tooltip: '编辑笔记',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () async {
                                      if (widget.onEdit != null) {
                                        await widget.onEdit!(ann);
                                      } else {
                                        await showAnnotationEditorSheet(
                                          context: context,
                                          quote: ann.quote,
                                          existing: ann,
                                          onSave: (color, note) async {
                                            await ref
                                                .read(
                                                  bookAnnotationsProvider(
                                                    widget.bookId,
                                                  ).notifier,
                                                )
                                                .update(
                                                  ann.copyWith(
                                                    color: color,
                                                    note: note,
                                                  ),
                                                );
                                          },
                                          onDelete: () => ref
                                              .read(
                                                bookAnnotationsProvider(
                                                  widget.bookId,
                                                ).notifier,
                                              )
                                              .remove(ann.id),
                                        );
                                      }
                                    },
                                    icon: Icon(
                                      Icons.edit_outlined,
                                      size: 17,
                                      color: tokens.textSecondary,
                                    ),
                                  ),
                                  IconButton(
                                    key: Key('annotation_delete_${ann.id}'),
                                    tooltip: '删除',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () async {
                                      if (widget.onDelete != null) {
                                        await widget.onDelete!(ann);
                                      } else {
                                        await ref
                                            .read(
                                              bookAnnotationsProvider(
                                                widget.bookId,
                                              ).notifier,
                                            )
                                            .remove(ann.id);
                                      }
                                    },
                                    icon: Icon(
                                      Icons.delete_outline,
                                      size: 17,
                                      color: tokens.textDisabled,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _FilterChipPill extends StatelessWidget {
  const _FilterChipPill({
    required this.chipKey,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Key chipKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      key: chipKey,
      borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? tokens.primary.withValues(alpha: 0.16)
              : tokens.surfaceSubtle.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
          border: Border.all(
            color: selected
                ? tokens.primary.withValues(alpha: 0.45)
                : echoHairlineColor(context),
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: textTheme.labelSmall?.copyWith(
            color: selected ? tokens.primary : tokens.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
