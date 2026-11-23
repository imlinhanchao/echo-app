import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:echo/core/books/epub_parser.dart';
import 'package:echo/core/books/local_library_store.dart';
import 'package:echo/core/books/txt_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _buildMinimalEpub({
  String title = '三体测试',
  String author = '刘慈欣',
  bool includeCover = true,
}) {
  final archive = Archive();

  void addString(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  addString('mimetype', 'application/epub+zip');
  addString(
    'META-INF/container.xml',
    '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''',
  );
  addString(
    'OEBPS/content.opf',
    '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
    <dc:creator>$author</dc:creator>
    <dc:publisher>重庆出版社</dc:publisher>
    <dc:date>2008-01-01</dc:date>
    <dc:description>地球往事三部曲测试简介</dc:description>
    ${includeCover ? '<meta name="cover" content="cover-img"/>' : ''}
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    ${includeCover ? '<item id="cover-img" href="cover.jpg" media-type="image/jpeg"/>' : ''}
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>''',
  );
  addString(
    'OEBPS/toc.ncx',
    '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="p1" playOrder="1">
      <navLabel><text>第一章 科学边界</text></navLabel>
      <content src="ch1.xhtml"/>
    </navPoint>
    <navPoint id="p2" playOrder="2">
      <navLabel><text>第二章 台球</text></navLabel>
      <content src="ch2.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''',
  );
  addString(
    'OEBPS/ch1.xhtml',
    '''<html><body><h1>科学边界</h1><p>汪淼觉得，来找他的这四个人是一个奇怪的组合。</p><p>两名警察和两名军人。</p></body></html>''',
  );
  addString(
    'OEBPS/ch2.xhtml',
    '''<html><body><h1>台球</h1><p>丁仪把黑球放回台面。</p></body></html>''',
  );
  if (includeCover) {
    final fakeJpg = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]);
    archive.addFile(ArchiveFile('OEBPS/cover.jpg', fakeJpg.length, fakeJpg));
  }

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  group('EpubParser', () {
    test('parses metadata, NCX titles, cover and clean chapter text', () {
      final bytes = _buildMinimalEpub();
      final parsed = const EpubParser().parse(bytes);

      expect(parsed.title, '三体测试');
      expect(parsed.authors, <String>['刘慈欣']);
      expect(parsed.publisher, '重庆出版社');
      expect(parsed.year, '2008');
      expect(parsed.coverBytes, isNotNull);
      expect(parsed.coverExt, 'jpg');
      expect(parsed.chapters, hasLength(2));
      expect(parsed.chapters[0].title, '第一章 科学边界');
      expect(parsed.chapters[0].text, contains('汪淼觉得'));
      expect(parsed.chapters[0].text, contains('两名警察和两名军人'));
      expect(parsed.chapters[1].title, '第二章 台球');
    });
  });

  group('TxtParser', () {
    test('splits Chinese chapters by heading regex', () {
      const sample = '''
这是一段简短的书名页。

第一章 初见
清晨的阳光洒在窗台上，一切都很安静。
他推开门走了出去。

第二章 远行
列车缓缓驶离站台。
''';
      final parsed = const TxtParser().parse(
        Uint8List.fromList(utf8.encode(sample)),
        fallbackTitle: '远行记',
      );
      expect(parsed.title, '远行记');
      expect(parsed.chapters, hasLength(2));
      expect(parsed.chapters[0].title, '第一章 初见');
      expect(parsed.chapters[0].text, contains('清晨的阳光'));
      expect(parsed.chapters[1].title, '第二章 远行');
    });

    test('falls back to fixed-size chunking when no chapter headings exist', () {
      final body = List<String>.generate(
        10,
        (i) => '段落$i：${'这是一段测试文本。' * 15}',
      ).join('\n\n');
      final parsed = const TxtParser(
        fallbackChunkChars: 300,
      ).parse(Uint8List.fromList(utf8.encode(body)), fallbackTitle: '散文集');
      expect(parsed.chapters.length, greaterThan(2));
      expect(parsed.chapters.first.title, '第 1 节');
    });
  });

  group('LocalLibraryStore', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('echo_local_lib_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('imports EPUB and TXT, persists index, reads chapters and deletes', () async {
      final store = LocalLibraryStore(rootDir: tempDir);
      final epubBook = await store.importBytes(
        _buildMinimalEpub(),
        filename: 'santi.epub',
      );
      expect(epubBook.id, 1);
      expect(epubBook.title, '三体测试');
      expect(epubBook.coverUrl, startsWith('file://'));

      final txtBook = await store.importBytes(
        Uint8List.fromList(utf8.encode('第一章 开始\n你好世界。\n\n第二章 结束\n再见。')),
        filename: 'demo.txt',
      );
      expect(txtBook.id, 2);
      expect(txtBook.format, 'txt');

      // 重新实例化仓库验证持久化恢复
      final reloaded = LocalLibraryStore(rootDir: tempDir);
      final books = await reloaded.listBooks();
      expect(books, hasLength(2));
      final chapters = await reloaded.listChapters(epubBook.id);
      expect(chapters, hasLength(2));
      expect(chapters.first.title, '第一章 科学边界');

      await reloaded.deleteBook(epubBook.id);
      expect(await reloaded.listBooks(), hasLength(1));
    });
  });
}
