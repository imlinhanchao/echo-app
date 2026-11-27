import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 翻译推理被主动取消时抛出的特定异常，供调度器安全回滚队列状态。
class TranslationCancelledException implements Exception {
  const TranslationCancelledException([this.message = '翻译已取消']);
  final String message;

  @override
  String toString() => message;
}

/// 端侧离线翻译推理引擎抽象（一期实现 Android arm64 llama.cpp FFI，预留桌面/iOS 扩展）。
abstract class TranslationEngine {
  bool get isLoaded;
  String? get loadedModelPath;

  Future<void> ensureLoaded(
    String modelPath, {
    int nThreads = 4,
    int nCtx = 1024,
  });

  Future<String> translate(String prompt, {int maxTokens = 512});

  void cancelCurrent();

  Future<void> unload();

  Future<void> dispose();
}

typedef _EchoMtBackendInitNative = Void Function();
typedef _EchoMtBackendInitDart = void Function();

typedef _EchoMtLoadModelNative = Pointer<Void> Function(
  Pointer<Utf8> modelPath,
  Int32 nThreads,
  Int32 nCtx,
);
typedef _EchoMtLoadModelDart = Pointer<Void> Function(
  Pointer<Utf8> modelPath,
  int nThreads,
  int nCtx,
);

typedef _EchoMtIsReadyNative = Int32 Function(Pointer<Void> handle);
typedef _EchoMtIsReadyDart = int Function(Pointer<Void> handle);

typedef _EchoMtTranslateNative = Int32 Function(
  Pointer<Void> handle,
  Pointer<Utf8> prompt,
  Int32 maxTokens,
  Pointer<Utf8> outBuf,
  Int32 outBufLen,
);
typedef _EchoMtTranslateDart = int Function(
  Pointer<Void> handle,
  Pointer<Utf8> prompt,
  int maxTokens,
  Pointer<Utf8> outBuf,
  int outBufLen,
);

typedef _EchoMtCancelNative = Void Function(Pointer<Void> handle);
typedef _EchoMtCancelDart = void Function(Pointer<Void> handle);

typedef _EchoMtUnloadModelNative = Void Function(Pointer<Void> handle);
typedef _EchoMtUnloadModelDart = void Function(Pointer<Void> handle);

typedef _EchoMtCpuCapsNative = Uint32 Function();
typedef _EchoMtCpuCapsDart = int Function();

typedef _EchoMtLastErrorNative = Pointer<Utf8> Function(Pointer<Void> handle);
typedef _EchoMtLastErrorDart = Pointer<Utf8> Function(Pointer<Void> handle);

int _probeAndroidCpuCapsFromProc() {
  try {
    final file = File('/proc/cpuinfo');
    if (!file.existsSync()) return 0;
    final lines = file.readAsLinesSync();
    for (final line in lines) {
      if (!line.startsWith('Features')) continue;
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final tokens = line
          .substring(colon + 1)
          .trim()
          .split(RegExp(r'\s+'))
          .toSet();
      var caps = 0;
      if (tokens.contains('asimdhp')) caps |= 1;
      if (tokens.contains('asimddp')) caps |= 2;
      if (tokens.contains('i8mm')) caps |= 4;
      if (caps != 0) return caps;
    }
  } catch (_) {}
  return 0;
}

DynamicLibrary _openEchoMtLibrary() {
  if (Platform.isAndroid) {
    try {
      // 优先直接读取 /proc/cpuinfo，命中高阶指令集时免去先映射基础版 .so
      var caps = _probeAndroidCpuCapsFromProc();
      if ((caps & 0x7) == 0x7) {
        try {
          return DynamicLibrary.open('libecho_mt_i8mm.so');
        } catch (_) {}
      } else if ((caps & 0x3) == 0x3) {
        try {
          return DynamicLibrary.open('libecho_mt_dotprod.so');
        } catch (_) {}
      }

      final baseLib = DynamicLibrary.open('libecho_mt.so');
      if (caps == 0) {
        try {
          final probe = baseLib
              .lookupFunction<_EchoMtCpuCapsNative, _EchoMtCpuCapsDart>(
                'echo_mt_cpu_caps',
              );
          caps = probe();
        } catch (_) {}
        if ((caps & 0x7) == 0x7) {
          try {
            return DynamicLibrary.open('libecho_mt_i8mm.so');
          } catch (_) {}
        }
        if ((caps & 0x3) == 0x3) {
          try {
            return DynamicLibrary.open('libecho_mt_dotprod.so');
          } catch (_) {}
        }
      }
      return baseLib;
    } catch (e) {
      throw UnsupportedError('无法加载离线翻译原生库 libecho_mt.so（当前架构或平台可能暂未支持）：$e');
    }
  }
  if (Platform.isLinux) {
    try {
      return DynamicLibrary.open('libecho_mt.so');
    } catch (e) {
      throw UnsupportedError('无法加载离线翻译原生库 libecho_mt.so（当前架构或平台可能暂未支持）：$e');
    }
  }
  if (Platform.isMacOS || Platform.isIOS) {
    try {
      return Platform.isIOS
          ? DynamicLibrary.process()
          : DynamicLibrary.open('libecho_mt.dylib');
    } catch (e) {
      throw UnsupportedError('当前 Apple 平台暂未内置离线翻译库：$e');
    }
  }
  if (Platform.isWindows) {
    try {
      return DynamicLibrary.open('echo_mt.dll');
    } catch (e) {
      throw UnsupportedError('当前 Windows 平台暂未内置 echo_mt.dll：$e');
    }
  }
  throw UnsupportedError('当前平台不支持本地翻译 FFI 推理');
}

/// 基于后台常驻 Isolate 与 Dart FFI 的 `llama.cpp` 翻译推理引擎。
///
/// - 耗时推理全程在独立后台 Isolate 串行执行，不阻塞 UI 渲染线程；
/// - 主线程 `cancelCurrent()` 通过保存的原生句柄地址直接原子设置取消标志；
/// - 闲置超过 [idleTimeout] 自动卸载释放约 500MB 模型内存。
class LlamaFfiTranslationEngine implements TranslationEngine {
  LlamaFfiTranslationEngine({
    this.idleTimeout = const Duration(minutes: 5),
  });

  final Duration idleTimeout;

  Isolate? _worker;
  SendPort? _workerSendPort;
  ReceivePort? _mainReceivePort;
  StreamSubscription<dynamic>? _mainSub;

  int _nextReqId = 1;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  Future<void>? _spawning;

  int _handleAddress = 0;
  bool _unloading = false;
  String? _loadedModelPath;
  Timer? _idleTimer;

  _EchoMtCancelDart? _mainCancelFn;

  @override
  bool get isLoaded => _handleAddress != 0 && _loadedModelPath != null;

  @override
  String? get loadedModelPath => _loadedModelPath;

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    if (!isLoaded) return;
    _idleTimer = Timer(idleTimeout, () {
      unload();
    });
  }

  Future<void> _ensureWorker() async {
    if (_workerSendPort != null) return;
    if (_spawning != null) {
      await _spawning;
      return;
    }
    final completer = Completer<void>();
    _spawning = completer.future;

    try {
      final readyCompleter = Completer<SendPort>();
      final receivePort = ReceivePort();
      _mainReceivePort = receivePort;

      _mainSub = receivePort.listen((dynamic message) {
        if (message is SendPort) {
          if (!readyCompleter.isCompleted) {
            readyCompleter.complete(message);
          }
          return;
        }
        if (message is Map<String, dynamic>) {
          final reqId = message['id'] as int?;
          if (reqId == null) return;
          final c = _pending.remove(reqId);
          if (c == null || c.isCompleted) return;
          final error = message['error'] as String?;
          if (error != null) {
            final cancelled = message['cancelled'] as bool? ?? false;
            c.completeError(
              cancelled
                  ? TranslationCancelledException(error)
                  : StateError(error),
            );
          } else {
            c.complete(message['result']);
          }
        }
      });

      _worker = await Isolate.spawn(
        _workerMain,
        receivePort.sendPort,
        debugName: 'EchoMtWorker',
      );
      _workerSendPort = await readyCompleter.future;
      completer.complete();
    } catch (e, st) {
      await _cleanupWorker();
      completer.completeError(e, st);
      rethrow;
    } finally {
      _spawning = null;
    }
  }

  Future<Object?> _sendRequest(
    String op, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    await _ensureWorker();
    final port = _workerSendPort;
    if (port == null) {
      throw StateError('翻译推理工作线程未就绪');
    }
    final reqId = _nextReqId++;
    final completer = Completer<Object?>();
    _pending[reqId] = completer;
    port.send(<String, dynamic>{'id': reqId, 'op': op, ...args});
    return completer.future;
  }

  @override
  Future<void> ensureLoaded(
    String modelPath, {
    int nThreads = 4,
    int nCtx = 1024,
  }) async {
    final normalized = modelPath.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('模型路径不能为空');
    }
    if (!File(normalized).existsSync()) {
      throw StateError('翻译模型文件不存在：$normalized');
    }

    _idleTimer?.cancel();
    _unloading = false;
    final addr =
        await _sendRequest('load', <String, dynamic>{
              'modelPath': normalized,
              'nThreads': nThreads,
              'nCtx': nCtx,
            })
            as int?;
    _handleAddress = addr ?? 0;
    _loadedModelPath = _handleAddress != 0 ? normalized : null;
    _resetIdleTimer();
  }

  @override
  Future<String> translate(String prompt, {int maxTokens = 512}) async {
    if (!isLoaded) {
      throw StateError('翻译模型尚未加载');
    }
    _idleTimer?.cancel();
    try {
      final res =
          await _sendRequest('translate', <String, dynamic>{
                'prompt': prompt,
                'maxTokens': maxTokens,
              })
              as String?;
      return res ?? '';
    } finally {
      _resetIdleTimer();
    }
  }

  @override
  void cancelCurrent() {
    final addr = _handleAddress;
    if (addr == 0 || _unloading) return;
    try {
      _mainCancelFn ??= _openEchoMtLibrary()
          .lookupFunction<_EchoMtCancelNative, _EchoMtCancelDart>(
            'echo_mt_cancel',
          );
      _mainCancelFn!(Pointer<Void>.fromAddress(addr));
    } catch (_) {
      // 忽略缺库或边缘时序错误
    }
  }

  @override
  Future<void> unload() async {
    _idleTimer?.cancel();
    if (_handleAddress == 0 && _workerSendPort == null) {
      _loadedModelPath = null;
      return;
    }
    _unloading = true;
    // 在清空 handle 地址前发出原生取消，立即打断正在进行的解码循环
    final addr = _handleAddress;
    _handleAddress = 0;
    _loadedModelPath = null;
    if (addr != 0) {
      try {
        _mainCancelFn ??= _openEchoMtLibrary()
            .lookupFunction<_EchoMtCancelNative, _EchoMtCancelDart>(
              'echo_mt_cancel',
            );
        _mainCancelFn!(Pointer<Void>.fromAddress(addr));
      } catch (_) {}
    }
    try {
      if (_workerSendPort != null) {
        await _sendRequest('unload');
      }
    } catch (_) {
    } finally {
      _unloading = false;
    }
  }

  @override
  Future<void> dispose() async {
    await unload();
    await _cleanupWorker();
  }

  Future<void> _cleanupWorker() async {
    _idleTimer?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(const TranslationCancelledException('引擎已释放'));
      }
    }
    _pending.clear();
    _workerSendPort = null;
    await _mainSub?.cancel();
    _mainSub = null;
    _mainReceivePort?.close();
    _mainReceivePort = null;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
  }

  /// 后台 Isolate 入口，严格串行持有与释放 FFI 句柄。
  static void _workerMain(SendPort mainPort) {
    final inbox = ReceivePort();
    mainPort.send(inbox.sendPort);

    DynamicLibrary? lib;
    _EchoMtBackendInitDart? backendInit;
    _EchoMtLoadModelDart? loadModel;
    _EchoMtIsReadyDart? isReady;
    _EchoMtTranslateDart? translateFn;
    _EchoMtUnloadModelDart? unloadModel;
    _EchoMtLastErrorDart? lastError;

    Pointer<Void> handle = nullptr;
    String currentPath = '';

    void bindLib() {
      if (lib != null) return;
      final loaded = _openEchoMtLibrary();
      backendInit = loaded
          .lookupFunction<_EchoMtBackendInitNative, _EchoMtBackendInitDart>(
            'echo_mt_backend_init',
          );
      loadModel = loaded
          .lookupFunction<_EchoMtLoadModelNative, _EchoMtLoadModelDart>(
            'echo_mt_load_model',
          );
      isReady = loaded.lookupFunction<_EchoMtIsReadyNative, _EchoMtIsReadyDart>(
        'echo_mt_is_ready',
      );
      translateFn = loaded
          .lookupFunction<_EchoMtTranslateNative, _EchoMtTranslateDart>(
            'echo_mt_translate',
          );
      unloadModel = loaded
          .lookupFunction<_EchoMtUnloadModelNative, _EchoMtUnloadModelDart>(
            'echo_mt_unload_model',
          );
      lastError = loaded
          .lookupFunction<_EchoMtLastErrorNative, _EchoMtLastErrorDart>(
            'echo_mt_last_error',
          );
      lib = loaded;
      backendInit!();
    }

    void freeCurrentHandle() {
      if (handle != nullptr && unloadModel != null) {
        unloadModel!(handle);
      }
      handle = nullptr;
      currentPath = '';
    }

    inbox.listen((dynamic rawMsg) {
      if (rawMsg is! Map<String, dynamic>) return;
      final reqId = rawMsg['id'] as int;
      final op = rawMsg['op'] as String;

      try {
        if (op == 'load') {
          bindLib();
          final path = rawMsg['modelPath'] as String;
          final nThreads = (rawMsg['nThreads'] as int?) ?? 4;
          final nCtx = (rawMsg['nCtx'] as int?) ?? 1024;

          if (handle != nullptr &&
              currentPath == path &&
              isReady!(handle) == 1) {
            mainPort.send(<String, dynamic>{
              'id': reqId,
              'result': handle.address,
            });
            return;
          }

          freeCurrentHandle();
          final pathPtr = path.toNativeUtf8();
          try {
            handle = loadModel!(pathPtr, nThreads, nCtx);
          } finally {
            calloc.free(pathPtr);
          }

          if (handle == nullptr) {
            throw StateError('无法分配模型推理句柄（内存不足）');
          }
          if (isReady!(handle) != 1) {
            final errPtr = lastError!(handle);
            final errText = errPtr == nullptr
                ? '模型文件损坏或格式不兼容'
                : errPtr.toDartString();
            freeCurrentHandle();
            throw StateError('加载离线翻译模型失败：$errText');
          }
          currentPath = path;
          mainPort.send(<String, dynamic>{
            'id': reqId,
            'result': handle.address,
          });
        } else if (op == 'translate') {
          if (handle == nullptr || isReady!(handle) != 1) {
            throw StateError('翻译模型未加载就绪');
          }
          final prompt = rawMsg['prompt'] as String;
          final maxTokens = (rawMsg['maxTokens'] as int?) ?? 512;
          const outCap = 32768;

          final promptPtr = prompt.toNativeUtf8();
          final outPtr = calloc<Uint8>(outCap).cast<Utf8>();
          try {
            final rc = translateFn!(handle, promptPtr, maxTokens, outPtr, outCap);
            if (rc == -2) {
              mainPort.send(<String, dynamic>{
                'id': reqId,
                'error': '翻译任务已取消',
                'cancelled': true,
              });
              return;
            }
            if (rc < 0) {
              final errPtr = lastError!(handle);
              final errText = errPtr == nullptr
                  ? '推理异常（code=$rc）'
                  : errPtr.toDartString();
              throw StateError(errText);
            }
            final output = rc == 0 ? '' : outPtr.toDartString(length: rc);
            mainPort.send(<String, dynamic>{'id': reqId, 'result': output});
          } finally {
            calloc.free(promptPtr);
            calloc.free(outPtr);
          }
        } else if (op == 'unload') {
          freeCurrentHandle();
          mainPort.send(<String, dynamic>{'id': reqId, 'result': true});
        } else {
          throw UnsupportedError('未知操作：$op');
        }
      } catch (e) {
        mainPort.send(<String, dynamic>{'id': reqId, 'error': e.toString()});
      }
    });
  }
}

final Provider<TranslationEngine> translationEngineProvider =
    Provider<TranslationEngine>((ref) {
      final engine = LlamaFfiTranslationEngine();
      ref.onDispose(() {
        unawaited(engine.dispose());
      });
      return engine;
    });
