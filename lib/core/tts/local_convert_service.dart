import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/models.dart';
import '../books/local_library_store.dart';
import '../offline/offline_store.dart';
import 'audio_encoder_service.dart';
import 'sentence_splitter.dart';
import 'sherpa_tts_engine.dart';
import 'tts_model_manager.dart';
import 'wav_encoder.dart';

/// 本地转有声书进度回调。
typedef ConvertProgressCallback =
    void Function(int progressPercent, String statusText);

/// 本地离线转有声书服务：
/// 按章逐句调用端侧 TTS 合成 PCM，累计精准 SRT 时间轴，再由原生 M4A 编码器（或 WAV 降级）
/// 落盘至 [OfflineFiles] 与 [LocalLibraryStore]，产出的分块可直接被 [ChunkedPlayerController] 零 CPU 播放。
class LocalConvertService {
  LocalConvertService({
    required LocalLibraryStore libraryStore,
    required OnDeviceTtsEngine ttsEngine,
    required AudioEncoderService encoderService,
    SentenceSplitter? splitter,
    Directory? workDirOverride,
  }) : _libraryStore = libraryStore,
       _ttsEngine = ttsEngine,
       _encoderService = encoderService,
       _splitter = splitter ?? const SentenceSplitter(),
       _workDirOverride = workDirOverride;

  final LocalLibraryStore _libraryStore;
  final OnDeviceTtsEngine _ttsEngine;
  final AudioEncoderService _encoderService;
  final SentenceSplitter _splitter;
  final Directory? _workDirOverride;

  Future<Directory> _ensureWorkDir() async {
    if (_workDirOverride != null) {
      await _workDirOverride.create(recursive: true);
      return _workDirOverride;
    }
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'echo_convert_work'));
    await dir.create(recursive: true);
    return dir;
  }

  /// 将指定书籍的选定章节在本地转为分块有声书（M4A + SRT）。
  Future<AudiobookInfo> convertBook({
    required LibraryBook book,
    required ResolvedTtsModelPaths modelPaths,
    required int speakerId,
    required String voiceLabel,
    double speed = 1.0,
    List<int>? chapterIndices,
    bool Function()? isCancelled,
    ConvertProgressCallback? onProgress,
  }) async {
    final allChapters = await _libraryStore.listChapters(book.id);
    if (allChapters.isEmpty) {
      throw StateError('书籍没有可转换的章节');
    }

    final targets = (chapterIndices == null || chapterIndices.isEmpty)
        ? allChapters
        : allChapters.where((c) => chapterIndices.contains(c.index)).toList();
    if (targets.isEmpty) {
      throw StateError('未选择任何有效章节');
    }

    final audiobookId = await _libraryStore.allocateAudiobookId();
    final totalChars = targets.fold<int>(0, (acc, c) => acc + c.chars);

    var info = AudiobookInfo(
      id: audiobookId,
      bookId: book.id,
      bookTitle: book.title,
      model: modelPaths.spec.id,
      voice: voiceLabel,
      speed: speed,
      status: 'running',
      progress: 0,
      format: 'm4a',
      chars: totalChars,
      chaptersUrl: 'local://audiobooks/$audiobookId/chapters',
    );
    await _libraryStore.upsertAudiobook(info);

    final workDir = await _ensureWorkDir();
    final offlineDir = await OfflineFiles.dirFor(audiobookId);
    final chunks = <ChapterChunk>[];
    var totalDurationS = 0.0;
    var totalSizeBytes = 0;
    var totalSegments = 0;
    var detectedFormat = 'm4a';

    try {
      await _ttsEngine.loadModel(modelPaths);

      for (var cIdx = 0; cIdx < targets.length; cIdx++) {
        if (isCancelled?.call() == true) {
          info = _copyAudiobook(info, status: 'cancelled', error: '用户已取消');
          await _libraryStore.upsertAudiobook(info);
          return info;
        }

        final chapter = targets[cIdx];
        final sentences = _splitter.split(chapter.text);
        if (sentences.isEmpty) continue;

        final pcmFile = File(
          p.join(workDir.path, 'ab_${audiobookId}_ch_${chapter.index}.pcm'),
        );
        if (await pcmFile.exists()) await pcmFile.delete();
        final pcmSink = pcmFile.openWrite();
        final srtBuffer = StringBuffer();

        var sampleRate = 24000;
        var chapterElapsedMs = 0;
        var cueSeq = 1;

        try {
          for (var sIdx = 0; sIdx < sentences.length; sIdx++) {
            if (isCancelled?.call() == true) break;
            final sentence = sentences[sIdx];
            final synth = await _ttsEngine.synthesize(
              sentence.text,
              speakerId: speakerId,
              speed: speed,
            );
            if (synth.samples.isEmpty) continue;
            sampleRate = synth.sampleRate;

            final pcmBytes = float32ToPcm16(synth.samples);
            pcmSink.add(pcmBytes);

            final durMs = synth.durationMs;
            final startMs = chapterElapsedMs;
            final endMs = chapterElapsedMs + durMs;
            chapterElapsedMs = endMs;

            srtBuffer
              ..writeln(cueSeq++)
              ..writeln('${_formatSrtTime(startMs)} --> ${_formatSrtTime(endMs)}')
              ..writeln(sentence.text)
              ..writeln();

            // 细粒度进度汇报
            final frac =
                (cIdx + (sIdx + 1) / sentences.length) / targets.length;
            final pct = (frac * 98).round().clamp(1, 98);
            onProgress?.call(
              pct,
              '正在合成 ${chapter.title}（${sIdx + 1}/${sentences.length}）',
            );
          }
        } finally {
          await pcmSink.flush();
          await pcmSink.close();
        }

        if (isCancelled?.call() == true) {
          if (await pcmFile.exists()) await pcmFile.delete();
          info = _copyAudiobook(info, status: 'cancelled', error: '用户已取消');
          await _libraryStore.upsertAudiobook(info);
          return info;
        }

        if (chapterElapsedMs <= 0) {
          if (await pcmFile.exists()) await pcmFile.delete();
          continue;
        }

        final chunkN = chunks.length;
        final encoded = await _encoderService.encodePcm16File(
          pcmFile: pcmFile,
          targetPathWithoutExt: p.join(workDir.path, 'ab_${audiobookId}_$chunkN'),
          sampleRate: sampleRate,
        );
        if (await pcmFile.exists()) await pcmFile.delete();
        detectedFormat = encoded.format;

        // 写入 OfflineFiles 约定路径：`<audiobookId>/<chunkN>.audio` & `<chunkN>.srt`
        final finalAudioFile = File(p.join(offlineDir.path, '$chunkN.audio'));
        await File(encoded.outputPath).copy(finalAudioFile.path);
        try {
          await File(encoded.outputPath).delete();
        } catch (_) {}

        final finalSrtFile = File(p.join(offlineDir.path, '$chunkN.srt'));
        await finalSrtFile.writeAsString(srtBuffer.toString(), flush: true);

        final durS = chapterElapsedMs / 1000.0;
        final startS = totalDurationS;
        final endS = startS + durS;
        totalDurationS = endS;
        totalSizeBytes += encoded.sizeBytes;
        totalSegments += (cueSeq - 1);

        chunks.add(
          ChapterChunk(
            n: chunkN,
            chapterIndex: chapter.index,
            title: chapter.title,
            startS: startS,
            endS: endS,
            durationS: durS,
            sizeBytes: encoded.sizeBytes,
            audioFile: finalAudioFile.path,
            srtFile: finalSrtFile.path,
            audioUrl: finalAudioFile.uri.toString(),
            srtUrl: finalSrtFile.uri.toString(),
          ),
        );

        // 每完成一章即更新清单，支持边转边播
        final manifest = ChaptersManifestInfo(
          audiobookId: audiobookId,
          format: detectedFormat,
          durationS: totalDurationS,
          chunks: List<ChapterChunk>.unmodifiable(chunks),
        );
        await _libraryStore.saveChaptersManifest(audiobookId, manifest);
        await OfflineFiles.saveManifest(
          audiobookId,
          jsonEncode(_manifestJson(manifest)),
        );

        final progressPct = (((cIdx + 1) / targets.length) * 100).round();
        info = _copyAudiobook(
          info,
          progress: progressPct.clamp(0, 99),
          format: detectedFormat,
          durationS: totalDurationS,
          sizeBytes: totalSizeBytes,
          segments: totalSegments,
        );
        await _libraryStore.upsertAudiobook(info);
      }

      info = _copyAudiobook(
        info,
        status: 'done',
        progress: 100,
        format: detectedFormat,
        durationS: totalDurationS,
        sizeBytes: totalSizeBytes,
        segments: totalSegments,
      );
      await _libraryStore.upsertAudiobook(info);
      onProgress?.call(100, '转换完成');
      return info;
    } catch (e) {
      info = _copyAudiobook(info, status: 'failed', error: e.toString());
      await _libraryStore.upsertAudiobook(info);
      rethrow;
    }
  }

  AudiobookInfo _copyAudiobook(
    AudiobookInfo src, {
    String? status,
    int? progress,
    String? error,
    String? format,
    double? durationS,
    int? sizeBytes,
    int? segments,
  }) {
    return AudiobookInfo(
      id: src.id,
      bookId: src.bookId,
      bookTitle: src.bookTitle,
      model: src.model,
      voice: src.voice,
      speed: src.speed,
      status: status ?? src.status,
      progress: progress ?? src.progress,
      error: error ?? src.error,
      format: format ?? src.format,
      durationS: durationS ?? src.durationS,
      sizeBytes: sizeBytes ?? src.sizeBytes,
      segments: segments ?? src.segments,
      chars: src.chars,
      audioUrl: src.audioUrl,
      srtUrl: src.srtUrl,
      chaptersUrl: src.chaptersUrl,
    );
  }

  Map<String, dynamic> _manifestJson(ChaptersManifestInfo m) =>
      <String, dynamic>{
        'audiobook_id': m.audiobookId,
        'format': m.format,
        'duration_s': m.durationS,
        'chunk_seconds': m.chunkSeconds,
        'chunks': m.chunks
            .map(
              (c) => <String, dynamic>{
                'n': c.n,
                'chapter_index': c.chapterIndex,
                'title': c.title,
                'start_s': c.startS,
                'end_s': c.endS,
                'duration_s': c.durationS,
                'size_bytes': c.sizeBytes,
                'audio_file': c.audioFile,
                'srt_file': c.srtFile,
                'audio_url': c.audioUrl,
                'srt_url': c.srtUrl,
              },
            )
            .toList(),
      };

  String _formatSrtTime(int totalMs) {
    final ms = totalMs % 1000;
    final totalSec = totalMs ~/ 1000;
    final sec = totalSec % 60;
    final totalMin = totalSec ~/ 60;
    final min = totalMin % 60;
    final hour = totalMin ~/ 60;
    return '${hour.toString().padLeft(2, '0')}:'
        '${min.toString().padLeft(2, '0')}:'
        '${sec.toString().padLeft(2, '0')},'
        '${ms.toString().padLeft(3, '0')}';
  }
}

final Provider<LocalConvertService> localConvertServiceProvider =
    Provider<LocalConvertService>((ref) {
      return LocalConvertService(
        libraryStore: ref.watch(localLibraryStoreProvider),
        ttsEngine: ref.watch(onDeviceTtsEngineProvider),
        encoderService: ref.watch(audioEncoderServiceProvider),
      );
    });
