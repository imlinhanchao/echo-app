import 'dart:io';

import 'package:echo/core/notes/reading_annotation_store.dart';
import 'package:echo/core/reader/reading_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReadingAnnotationStore & interval segment builder', () {
    test('ReadingAnnotation JSON round-trip and color fallback', () {
      final now = DateTime.utc(2026, 11, 24, 15, 0, 0);
      final ann = ReadingAnnotation(
        id: 'ann_1',
        bookId: 7,
        chapterIndex: 2,
        startOffset: 10,
        endOffset: 24,
        quote: '乱哄哄的教室里',
        note: '人物出场环境描写',
        color: ReadingHighlightColor.amber,
        chapterTitle: '第二章',
        target: ReadingAnnotationTarget.translation,
        transStartInFirst: 3,
        transEndInLast: 11,
        alignedOrigStart: 12,
        alignedOrigEnd: 21,
        createdAt: now,
        updatedAt: now,
      );

      final decoded = ReadingAnnotation.fromJson(ann.toJson());
      expect(decoded.id, 'ann_1');
      expect(decoded.bookId, 7);
      expect(decoded.chapterIndex, 2);
      expect(decoded.startOffset, 10);
      expect(decoded.endOffset, 24);
      expect(decoded.quote, '乱哄哄的教室里');
      expect(decoded.note, '人物出场环境描写');
      expect(decoded.hasNote, isTrue);
      expect(decoded.color, ReadingHighlightColor.amber);
      expect(decoded.chapterTitle, '第二章');
      expect(decoded.target, ReadingAnnotationTarget.translation);
      expect(decoded.transStartInFirst, 3);
      expect(decoded.transEndInLast, 11);
      expect(decoded.hasAlignedOrigRange, isTrue);
      expect(decoded.alignedOrigStart, 12);
      expect(decoded.alignedOrigEnd, 21);

      // 旧版本序列化数据不含 target / trans_* / aligned_orig_* 字段时兼容回退为 auto + null
      final legacyJson = Map<String, dynamic>.from(ann.toJson())
        ..remove('target')
        ..remove('trans_start_in_first')
        ..remove('trans_end_in_last')
        ..remove('aligned_orig_start')
        ..remove('aligned_orig_end');
      final legacyDecoded = ReadingAnnotation.fromJson(legacyJson);
      expect(legacyDecoded.target, ReadingAnnotationTarget.auto);
      expect(legacyDecoded.transStartInFirst, isNull);
      expect(legacyDecoded.transEndInLast, isNull);
      expect(legacyDecoded.hasAlignedOrigRange, isFalse);
      expect(legacyDecoded.alignedOrigStart, isNull);
      expect(legacyDecoded.alignedOrigEnd, isNull);

      expect(ReadingHighlightColor.fromKey('unknown'), ReadingHighlightColor.gold);
      expect(ReadingHighlightColor.fromKey(null), ReadingHighlightColor.gold);
      expect(ReadingHighlightColor.fromKey('rose'), ReadingHighlightColor.rose);
      expect(
        ReadingAnnotationTarget.fromKey('original'),
        ReadingAnnotationTarget.original,
      );
      expect(
        ReadingAnnotationTarget.fromKey('invalid'),
        ReadingAnnotationTarget.auto,
      );
    });

    test('PersistentReadingAnnotationStore persists CRUD across instances', () async {
      final dir = await Directory.systemTemp.createTemp('echo_ann_persist_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final store1 = PersistentReadingAnnotationStore(rootDirOverride: dir);
      final t1 = DateTime.utc(2026, 11, 24, 10, 0);
      final t2 = DateTime.utc(2026, 11, 24, 10, 1);
      await store1.upsert(
        ReadingAnnotation(
          id: 'a2',
          bookId: 12,
          chapterIndex: 1,
          startOffset: 30,
          endOffset: 42,
          quote: '第二章摘录',
          color: ReadingHighlightColor.sage,
          createdAt: t2,
          updatedAt: t2,
        ),
      );
      await store1.upsert(
        ReadingAnnotation(
          id: 'a1',
          bookId: 12,
          chapterIndex: 0,
          startOffset: 5,
          endOffset: 15,
          quote: '第一章摘录',
          note: '关键伏笔',
          color: ReadingHighlightColor.rose,
          createdAt: t1,
          updatedAt: t1,
        ),
      );

      final store2 = PersistentReadingAnnotationStore(rootDirOverride: dir);
      final loaded = await store2.listForBook(12);
      expect(loaded.length, 2);
      expect(loaded[0].id, 'a1');
      expect(loaded[1].id, 'a2');
      expect(loaded[0].note, '关键伏笔');
      expect(loaded[1].color, ReadingHighlightColor.sage);

      await store2.delete(12, 'a1');
      final afterDelete = await store2.listForBook(12);
      expect(afterDelete.map((e) => e.id).toList(), <String>['a2']);

      await store2.deleteAllForBook(12);
      expect(await store2.listForBook(12), isEmpty);
    });

    test('BookAnnotationsController normalizes, sorts, updates and removes', () async {
      final store = MemoryReadingAnnotationStore();
      final ctrl = BookAnnotationsController(store, 99);
      addTearDown(ctrl.dispose);

      await ctrl.add(
        chapterIndex: 2,
        startOffset: 40,
        endOffset: 50,
        quote: '二章句子',
        chapterTitle: '第 3 章',
      );
      final created = await ctrl.add(
        chapterIndex: 0,
        startOffset: 25,
        endOffset: 10,
        quote: '首章划线',
        color: ReadingHighlightColor.slate,
        chapterTitle: '第 1 章',
      );

      expect(ctrl.state.length, 2);
      expect(ctrl.state.first.id, created.id);
      expect(ctrl.state.first.startOffset, 10);
      expect(ctrl.state.first.endOffset, 25);
      expect(ctrl.state.first.hasNote, isFalse);

      final upgraded = await ctrl.update(
        ctrl.state.first.copyWith(
          note: '  补记一条想法  ',
          color: ReadingHighlightColor.amber,
        ),
      );
      expect(upgraded.hasNote, isTrue);
      expect(upgraded.note, '补记一条想法');
      expect(ctrl.state.first.color, ReadingHighlightColor.amber);

      await ctrl.remove(upgraded.id);
      expect(ctrl.state.length, 1);
      expect(ctrl.state.first.chapterIndex, 2);
    });

    test('BookAnnotationsController.setAlignedOriginalRange persists range without mutating updatedAt or deleted notes', () async {
      final store = MemoryReadingAnnotationStore();
      final ctrl = BookAnnotationsController(store, 101);
      addTearDown(ctrl.dispose);

      final created = await ctrl.add(
        chapterIndex: 0,
        startOffset: 0,
        endOffset: 80,
        quote: '在农场里',
        note: '重要细节',
        color: ReadingHighlightColor.sage,
        target: ReadingAnnotationTarget.translation,
        transStartInFirst: 20,
        transEndInLast: 24,
      );
      final originalUpdatedAt = created.updatedAt;

      // 非法区间（end <= start）直接忽略
      await ctrl.setAlignedOriginalRange(
        annotationId: created.id,
        alignedOrigStart: 40,
        alignedOrigEnd: 40,
      );
      expect(ctrl.state.single.hasAlignedOrigRange, isFalse);

      await ctrl.setAlignedOriginalRange(
        annotationId: created.id,
        alignedOrigStart: 45,
        alignedOrigEnd: 56,
      );
      final updated = ctrl.state.single;
      expect(updated.hasAlignedOrigRange, isTrue);
      expect(updated.alignedOrigStart, 45);
      expect(updated.alignedOrigEnd, 56);
      expect(updated.note, '重要细节');
      expect(updated.color, ReadingHighlightColor.sage);
      expect(updated.updatedAt, originalUpdatedAt);

      // 若批注已被删除，后到的对齐结果不可复活该批注
      await ctrl.remove(created.id);
      expect(ctrl.state, isEmpty);
      await ctrl.setAlignedOriginalRange(
        annotationId: created.id,
        alignedOrigStart: 10,
        alignedOrigEnd: 20,
      );
      expect(ctrl.state, isEmpty);
      expect(await store.listForBook(101), isEmpty);
    });

    test('buildStyledPageSegments handles clamping, overlaps, notes priority, and active cue', () {
      const page = ReaderPage(
        chapterIndex: 1,
        chapterTitle: '第二章',
        startChar: 100,
        endChar: 120,
        text: '0123456789abcdefghij',
        pageInChapter: 2,
        pageCountInChapter: 3,
      );

      // No highlights
      final plain = buildStyledPageSegments(
        page: page,
        annotations: const <ReadingAnnotation>[],
      );
      expect(plain.length, 1);
      expect(plain.first.text, page.text);
      expect(plain.first.annotation, isNull);
      expect(plain.first.isActiveCue, isFalse);

      final now = DateTime.utc(2026, 11, 24, 12, 0);
      final pureHighlight = ReadingAnnotation(
        id: 'hl',
        bookId: 1,
        chapterIndex: 1,
        startOffset: 95, // starts on previous page
        endOffset: 110,
        quote: 'overlap hl',
        color: ReadingHighlightColor.gold,
        createdAt: now,
        updatedAt: now.add(const Duration(seconds: 5)),
      );
      final noteHighlight = ReadingAnnotation(
        id: 'nt',
        bookId: 1,
        chapterIndex: 1,
        startOffset: 105,
        endOffset: 115,
        quote: 'note hl',
        note: 'Note has priority',
        color: ReadingHighlightColor.rose,
        createdAt: now,
        updatedAt: now,
      );
      final otherChapterAnn = ReadingAnnotation(
        id: 'other',
        bookId: 1,
        chapterIndex: 0,
        startOffset: 100,
        endOffset: 110,
        quote: 'ignored',
        createdAt: now,
        updatedAt: now,
      );

      final segments = buildStyledPageSegments(
        page: page,
        annotations: <ReadingAnnotation>[
          pureHighlight,
          noteHighlight,
          otherChapterAnn,
        ],
        activeCueSpan: (start: 8, end: 18),
      );

      // Verify exact concatenation matches page.text character-for-character.
      expect(segments.map((s) => s.text).join(), page.text);

      // Boundaries: 0, 5, 8, 10, 15, 18, 20
      expect(segments.length, 6);

      // [0, 5): pureHighlight only
      expect(segments[0].start, 0);
      expect(segments[0].end, 5);
      expect(segments[0].annotation?.id, 'hl');
      expect(segments[0].isActiveCue, isFalse);

      // [5, 8): noteHighlight overrides pureHighlight even though pureHighlight has newer updatedAt
      expect(segments[1].start, 5);
      expect(segments[1].end, 8);
      expect(segments[1].annotation?.id, 'nt');
      expect(segments[1].isActiveCue, isFalse);

      // [8, 10): noteHighlight + activeCue
      expect(segments[2].start, 8);
      expect(segments[2].end, 10);
      expect(segments[2].annotation?.id, 'nt');
      expect(segments[2].isActiveCue, isTrue);

      // [10, 15): noteHighlight + activeCue
      expect(segments[3].start, 10);
      expect(segments[3].end, 15);
      expect(segments[3].annotation?.id, 'nt');
      expect(segments[3].isActiveCue, isTrue);

      // [15, 18): activeCue only
      expect(segments[4].start, 15);
      expect(segments[4].end, 18);
      expect(segments[4].annotation, isNull);
      expect(segments[4].isActiveCue, isTrue);

      // [18, 20): plain tail
      expect(segments[5].start, 18);
      expect(segments[5].end, 20);
      expect(segments[5].annotation, isNull);
      expect(segments[5].isActiveCue, isFalse);
    });

    test('expandInitialSelection expands ASCII words, CJK clauses, caps long spans, and skips whitespace', () {
      expect(expandInitialSelection('   ', 0), isNull);

      const enText = 'Hello wonderful world.';
      final enSpan = expandInitialSelection(enText, 9); // inside 'wonderful'
      expect(enSpan, isNotNull);
      expect(enText.substring(enSpan!.start, enSpan.end), 'wonderful');

      const zhText = '第一句内容。  第二分句写得刚好合适，第三句开始。';
      // Click on space before '第'
      final wsSpan = expandInitialSelection(zhText, 6);
      expect(wsSpan, isNotNull);
      expect(zhText.substring(wsSpan!.start, wsSpan.end), '第二分句写得刚好合适');

      const longClause =
          '这是一段非常长而且中间没有任何标点符号隔开的连续中文测试长句内容需要自动截取窗口';
      final capped = expandInitialSelection(longClause, 15);
      expect(capped, isNotNull);
      expect(capped!.end - capped.start, lessThanOrEqualTo(14));
      expect(capped.start, lessThanOrEqualTo(15));
      expect(capped.end, greaterThan(15));
    });
  });
}
