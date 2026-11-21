import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api/echo_api.dart';
import '../api/models.dart';

/// EPUB 导出：把服务端书库里的书籍文件下载到本地，并调起系统分享
/// （用户可保存到文件、发送到微信/邮箱，或用其他阅读器打开）。
abstract final class BookExporter {
  static Future<String?> export(EchoApi api, LibraryBook book) async {
    final bytes = await api.downloadBookBytes(book.id);
    if (bytes.isEmpty) return null;

    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/echo_exports');
    if (!dir.existsSync()) await dir.create(recursive: true);

    final safeTitle = book.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final ext = book.format.isNotEmpty ? book.format.toLowerCase() : 'epub';
    final file = File('${dir.path}/$safeTitle.$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// 调起系统分享面板。
  static Future<void> share(String path, {String? title}) async {
    try {
      await Share.shareXFiles(
        <XFile>[XFile(path)],
        subject: title,
        text: title,
      );
    } catch (_) {
      // 分享失败时文件已保存在本地
    }
  }
}
