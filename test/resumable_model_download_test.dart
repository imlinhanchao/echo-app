import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/tts/download_keepalive_service.dart';
import 'package:echo/core/tts/resumable_downloader.dart';
import 'package:echo/core/tts/tts_model_manager.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _buildFakePiperArchive() {
  final archive = Archive();
  final onnxBytes = Uint8List.fromList(List<int>.generate(96 * 1024, (i) => i % 251));
  final tokenBytes = utf8.encode('a 0\nb 1\n');
  archive.addFile(
    ArchiveFile(
      'vits-piper-zh_CN-huayan-medium/zh_CN-huayan-medium.onnx',
      onnxBytes.length,
      onnxBytes,
    ),
  );
  archive.addFile(
    ArchiveFile(
      'vits-piper-zh_CN-huayan-medium/tokens.txt',
      tokenBytes.length,
      tokenBytes,
    ),
  );
  final tarBytes = TarEncoder().encode(archive);
  return Uint8List.fromList(BZip2Encoder().encode(tarBytes));
}

void main() {
  group('ResumableFileDownloader', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('echo_resume_dl_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('resumes via HTTP Range after mid-stream disconnect and produces identical bytes', () async {
      final payload = Uint8List.fromList(
        List<int>.generate(256 * 1024, (i) => (i * 17 + 3) % 256),
      );
      final receivedRanges = <String?>[];
      var requestCount = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        requestCount++;
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        receivedRanges.add(rangeHeader);

        if (requestCount == 1) {
          // 首次响应发送前 64KB 后强行断开 TCP，模拟手机锁屏断流
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.add(
            utf8.encode(
              'HTTP/1.1 200 OK\r\n'
              'Content-Length: ${payload.length}\r\n'
              'Connection: close\r\n\r\n',
            ),
          );
          socket.add(payload.sublist(0, 64 * 1024));
          await socket.flush();
          socket.destroy();
          return;
        }

        var start = 0;
        if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
          start = int.parse(rangeHeader.substring(6).split('-').first);
        }
        final slice = payload.sublist(start);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${payload.length - 1}/${payload.length}',
        );
        request.response.headers.contentLength = slice.length;
        request.response.add(slice);
        await request.response.close();
      });

      final destFile = File('${tempDir.path}/model.bin');
      final downloader = const ResumableFileDownloader(
        maxRetriesPerUrl: 2,
        retryBaseDelay: Duration.zero,
      );
      final progressEvents = <(int, int)>[];

      await downloader.download(
        dio: Dio(),
        urls: <String>['http://127.0.0.1:${server.port}/model.bin'],
        destFile: destFile,
        onProgress: (r, t, _, _) => progressEvents.add((r, t)),
      );

      expect(requestCount, 2);
      expect(receivedRanges, <String?>[null, 'bytes=65536-']);
      expect(destFile.existsSync(), isTrue);
      expect(destFile.readAsBytesSync(), equals(payload));
      expect(ResumableFileDownloader.partFileFor(destFile).existsSync(), isFalse);
      expect(ResumableFileDownloader.metaFileFor(destFile).existsSync(), isFalse);
      expect(progressEvents.last, (payload.length, payload.length));
    });

    test('handles 416 when .part is already complete and 200 OK fallback when server ignores Range', () async {
      final payload = Uint8List.fromList(
        List<int>.generate(48 * 1024, (i) => i % 253),
      );
      var mode = '416';

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        if (mode == '416') {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */${payload.length}',
          );
          await request.response.close();
          return;
        }
        // 服务端忽略 Range，直接返回完整 200 OK
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      });

      final downloader = const ResumableFileDownloader(
        maxRetriesPerUrl: 0,
        retryBaseDelay: Duration.zero,
      );

      // 1. 416：.part 已完整，直接重命名为最终文件
      final file416 = File('${tempDir.path}/done_via_416.bin');
      await ResumableFileDownloader.partFileFor(file416).writeAsBytes(payload);
      await downloader.download(
        dio: Dio(),
        urls: <String>['http://127.0.0.1:${server.port}/a.bin'],
        destFile: file416,
      );
      expect(file416.existsSync(), isTrue);
      expect(file416.readAsBytesSync(), equals(payload));

      // 2. 200 OK 回退：存在旧 .part 残片时覆盖重下而不拼接脏数据
      mode = '200';
      final file200 = File('${tempDir.path}/fallback_200.bin');
      await ResumableFileDownloader.partFileFor(file200).writeAsBytes(
        List<int>.filled(1024, 99),
      );
      await downloader.download(
        dio: Dio(),
        urls: <String>['http://127.0.0.1:${server.port}/b.bin'],
        destFile: file200,
      );
      expect(file200.existsSync(), isTrue);
      expect(file200.readAsBytesSync(), equals(payload));
    });
  });

  group('TtsModelManager resume & lifecycle recovery', () {
    late Directory modelsDir;

    setUp(() async {
      modelsDir = await Directory.systemTemp.createTemp('echo_mgr_resume_');
    });

    tearDown(() async {
      if (await modelsDir.exists()) {
        await modelsDir.delete(recursive: true);
      }
    });

    test('preserves partial download as paused on disconnect, restores on reload, auto-resumes on foreground, and clears partial on request', () async {
      final archiveBytes = _buildFakePiperArchive();
      var dropAllRequests = true;
      final splitPoint = archiveBytes.length ~/ 2;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        if (dropAllRequests) {
          if (rangeHeader == null) {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.add(
              utf8.encode(
                'HTTP/1.1 200 OK\r\n'
                'Content-Length: ${archiveBytes.length}\r\n'
                'Connection: close\r\n\r\n',
              ),
            );
            socket.add(archiveBytes.sublist(0, splitPoint));
            await socket.flush();
            socket.destroy();
            return;
          }
          // 后续镜像在本次阶段也模拟继续断网，使首轮 downloadModel 保留断点进入 paused
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
          return;
        }

        var start = 0;
        if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
          start = int.parse(rangeHeader.substring(6).split('-').first);
        }
        final slice = archiveBytes.sublist(start);
        request.response.statusCode = start > 0
            ? HttpStatus.partialContent
            : HttpStatus.ok;
        if (start > 0) {
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${archiveBytes.length - 1}/${archiveBytes.length}',
          );
        }
        request.response.headers.contentLength = slice.length;
        request.response.add(slice);
        await request.response.close();
      });

      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            options.path =
                'http://127.0.0.1:${server.port}/vits-piper-zh_CN-huayan-medium.tar.bz2';
            handler.next(options);
          },
        ),
      );

      final storage = MemoryStandaloneConfigStorage(
        const StandaloneConfig(onboardingCompleted: true),
      );
      final configCtrl = StandaloneConfigController(
        storage,
        const StandaloneConfig(onboardingCompleted: true),
      );
      const modelId = 'vits-piper-zh_CN-huayan-medium';

      final manager = TtsModelManager(
        configCtrl,
        dio: dio,
        rootDirOverride: modelsDir,
        keepAliveService: const NoopDownloadKeepAliveService(),
        downloader: const ResumableFileDownloader(
          maxRetriesPerUrl: 0,
          retryBaseDelay: Duration.zero,
        ),
      );
      addTearDown(manager.dispose);
      await manager.refresh();

      // 1. 首次下载中途断流 -> 保留断点，状态变为 paused
      final err = await manager.downloadModel(modelId);
      expect(err, isNotNull);
      final pausedEntry = manager.currentState.entryOf(modelId)!;
      expect(pausedEntry.status, ModelInstallStatus.paused);
      expect(pausedEntry.downloadedBytes, splitPoint);
      expect(pausedEntry.totalBytes, archiveBytes.length);
      expect(pausedEntry.progress, greaterThan(0));

      // 2. 模拟冷重启后重新加载 TtsModelManager -> 自动识别磁盘断点为 paused
      final reloadedManager = TtsModelManager(
        configCtrl,
        dio: dio,
        rootDirOverride: modelsDir,
        keepAliveService: const NoopDownloadKeepAliveService(),
      );
      addTearDown(reloadedManager.dispose);
      await reloadedManager.refresh();
      final restoredEntry = reloadedManager.currentState.entryOf(modelId)!;
      expect(restoredEntry.status, ModelInstallStatus.paused);
      expect(restoredEntry.downloadedBytes, splitPoint);

      // 3. 网络恢复 + 切回前台 -> onAppResumed 自动从断点续传并完成解压安装
      dropAllRequests = false;
      await manager.onAppResumed();
      // 等待后台异步续传与 Isolate 解压完成
      for (var i = 0; i < 60; i++) {
        if (manager.currentState.entryOf(modelId)?.isInstalled == true) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final installed = manager.currentState.entryOf(modelId)!;
      expect(installed.isInstalled, isTrue);
      expect(installed.resolvedPaths, isNotNull);
      expect(configCtrl.state.activeTtsModelId, modelId);

      // 4. 校验 clearPartialDownload 清理断点目录
      final fakePart = File(
        '${modelsDir.path}/.tmp_$modelId/vits-piper-zh_CN-huayan-medium.tar.bz2.part',
      );
      await fakePart.parent.create(recursive: true);
      await fakePart.writeAsBytes(<int>[1, 2, 3, 4]);
      await reloadedManager.clearPartialDownload(modelId);
      expect(
        Directory('${modelsDir.path}/.tmp_$modelId').existsSync(),
        isFalse,
      );
      expect(
        reloadedManager.currentState.entryOf(modelId)?.status,
        ModelInstallStatus.notInstalled,
      );

      // 5. 校验 importLocalArchive 在 Isolate 中流式解压同样无闭包捕获异常
      final localArchiveFile = File('${modelsDir.path}/local_piper.tar.bz2');
      await localArchiveFile.writeAsBytes(archiveBytes);
      await manager.deleteModel(modelId);
      final importErr = await manager.importLocalArchive(
        modelId,
        localArchiveFile,
      );
      expect(importErr, isNull);
      expect(manager.currentState.entryOf(modelId)?.isInstalled, isTrue);
    });
  });
}
