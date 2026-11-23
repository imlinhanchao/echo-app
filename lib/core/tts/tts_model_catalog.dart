import 'package:flutter/foundation.dart';

/// 端侧 TTS 模型 / 引擎类型（已下架 Kokoro 与 Piper）。
enum TtsModelKind { zipvoice, matcha, vits, systemTts }

/// 预设音色描述。
@immutable
class TtsSpeakerPreset {
  const TtsSpeakerPreset({required this.id, required this.name, this.tag = ''});

  final int id;
  final String name;
  final String tag;
}

/// 模型下载源选项（支持国内镜像、GitHub 官方直连与自定义加速前缀）。
@immutable
class TtsDownloadMirrorOption {
  const TtsDownloadMirrorOption({
    required this.id,
    required this.label,
    required this.prefix,
    this.description = '',
  });

  final String id;
  final String label;
  final String prefix;
  final String description;
}

/// 单个需要下载的模型文件/压缩包条目（严格按用户所选单一镜像解析下载链接）。
@immutable
class TtsDownloadAsset {
  const TtsDownloadAsset({
    required this.filename,
    required this.isArchive,
    required this.ghRelativePath,
  });

  final String filename;
  final bool isArchive;
  final String ghRelativePath;

  List<String> urlsForMirror({
    required String mirrorId,
    String customPrefix = '',
  }) {
    return <String>[
      TtsModelCatalog.buildUrlForMirror(
        ghRelativePath,
        mirrorId: mirrorId,
        customPrefix: customPrefix,
      ),
    ];
  }
}

/// 端侧 TTS 模型目录条目。
@immutable
class TtsModelSpec {
  const TtsModelSpec({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.kind,
    required this.estimatedSizeMb,
    required this.recommendedTag,
    required this.assets,
    required this.speakers,
    required this.modelFileCandidates,
    this.decoderFileCandidates = const <String>[],
    this.voicesFile = '',
    this.vocoderFile = '',
    this.tokensFile = 'tokens.txt',
    this.lexiconFiles = const <String>[],
    this.dataDirName = 'espeak-ng-data',
    this.dictDirName = '',
    this.ruleFstFiles = const <String>[],
    this.defaultReferenceAudio = '',
    this.defaultReferenceText = '',
  });

  final String id;
  final String name;
  final String subtitle;
  final TtsModelKind kind;
  final int estimatedSizeMb;
  final String recommendedTag;
  final List<TtsDownloadAsset> assets;
  final List<TtsSpeakerPreset> speakers;
  final List<String> modelFileCandidates;
  final List<String> decoderFileCandidates;
  final String voicesFile;
  final String vocoderFile;
  final String tokensFile;
  final List<String> lexiconFiles;
  final String dataDirName;
  final String dictDirName;
  final List<String> ruleFstFiles;
  final String defaultReferenceAudio;
  final String defaultReferenceText;

  bool get isSystemTts => kind == TtsModelKind.systemTts;
}

/// 手机端中文 TTS 精选清单与下载镜像配置（已移除效果不佳的 Kokoro / Piper）。
abstract final class TtsModelCatalog {
  static const String _ghReleaseBase =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download';

  /// 已下架旧模型 ID（用于在模型管理页检测本地残留并提示一键清理）。
  static const List<String> legacyModelIds = <String>[
    'kokoro-int8-multi-lang-v1_1',
    'vits-piper-zh_CN-huayan-medium',
  ];

  static const String mirrorGhFast = 'ghfast';
  static const String mirrorGhProxyCom = 'ghproxy_com';
  static const String mirrorGhProxyNet = 'ghproxy_net';
  static const String mirrorGithub = 'github';
  static const String mirrorCustom = 'custom';

  static const List<TtsDownloadMirrorOption> downloadMirrors =
      <TtsDownloadMirrorOption>[
        TtsDownloadMirrorOption(
          id: mirrorGhFast,
          label: 'ghfast.top（国内加速）',
          prefix: 'https://ghfast.top/',
          description: '推荐默认镜像，国内下载通常更快',
        ),
        TtsDownloadMirrorOption(
          id: mirrorGhProxyCom,
          label: 'gh-proxy.com（国内加速）',
          prefix: 'https://gh-proxy.com/',
          description: '国内备用加速节点',
        ),
        TtsDownloadMirrorOption(
          id: mirrorGhProxyNet,
          label: 'ghproxy.net（国内加速）',
          prefix: 'https://ghproxy.net/',
          description: '国内第三方加速节点',
        ),
        TtsDownloadMirrorOption(
          id: mirrorGithub,
          label: 'GitHub 官方直连',
          prefix: '',
          description: '海外网络或已开启代理时使用',
        ),
        TtsDownloadMirrorOption(
          id: mirrorCustom,
          label: '自定义加速前缀',
          prefix: '',
          description: '填写自建 GitHub 代理前缀（例如 https://proxy.example.com/）',
        ),
      ];

  static TtsDownloadMirrorOption mirrorById(String id) {
    for (final opt in downloadMirrors) {
      if (opt.id == id) return opt;
    }
    return downloadMirrors.first;
  }

  /// 校验自定义镜像前缀合法性，返回 null 表示合法。
  static String? validateCustomMirrorPrefix(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return '请输入自定义加速前缀，例如 https://ghfast.top/';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return '镜像前缀必须以 http:// 或 https:// 开头并包含合法域名';
    }
    return null;
  }

  static String normalizeMirrorPrefix(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.endsWith('/') ? trimmed : '$trimmed/';
  }

  /// 严格按照指定镜像生成单一下载地址（不做跨镜像静默回退）。
  static String buildUrlForMirror(
    String ghRelativePath, {
    required String mirrorId,
    String customPrefix = '',
  }) {
    final officialUrl = '$_ghReleaseBase/$ghRelativePath';
    if (mirrorId == mirrorGithub) {
      return officialUrl;
    }
    if (mirrorId == mirrorCustom) {
      final err = validateCustomMirrorPrefix(customPrefix);
      if (err != null) {
        throw FormatException(err);
      }
      return '${normalizeMirrorPrefix(customPrefix)}$officialUrl';
    }
    final opt = mirrorById(mirrorId);
    final prefix = normalizeMirrorPrefix(opt.prefix);
    return prefix.isEmpty ? officialUrl : '$prefix$officialUrl';
  }

  /// 1. Android 系统 TTS（支持本机默认、MultiTTS、讯飞等已安装引擎，零下载）。
  static const TtsModelSpec androidSystemTts = TtsModelSpec(
    id: 'android-system-tts',
    name: 'Android 系统语音（本机引擎 / MultiTTS）',
    subtitle: '免下载直接调用手机已安装的语音引擎与音色，支持边听边看与离线转有声书',
    kind: TtsModelKind.systemTts,
    estimatedSizeMb: 0,
    recommendedTag: '免下载推荐',
    assets: <TtsDownloadAsset>[],
    speakers: <TtsSpeakerPreset>[
      TtsSpeakerPreset(id: 0, name: '跟随系统引擎音色', tag: '系统'),
    ],
    modelFileCandidates: <String>[],
    tokensFile: '',
    dataDirName: '',
  );

  /// 2. ZipVoice Distill INT8 中英零样本音色克隆（24kHz 高自然度）。
  static const TtsModelSpec zipvoiceZhEnInt8 = TtsModelSpec(
    id: 'sherpa-onnx-zipvoice-distill-int8-zh-en-emilia',
    name: 'ZipVoice INT8 中英（24kHz 克隆）',
    subtitle: '零样本音色克隆 · 默认自带参考音色开箱即用，也可导入自己的 3-10 秒 WAV',
    kind: TtsModelKind.zipvoice,
    estimatedSizeMb: 156,
    recommendedTag: '音质克隆',
    modelFileCandidates: <String>['encoder.int8.onnx', 'encoder.onnx'],
    decoderFileCandidates: <String>['decoder.int8.onnx', 'decoder.onnx'],
    vocoderFile: 'vocos_24khz.onnx',
    tokensFile: 'tokens.txt',
    lexiconFiles: <String>['lexicon.txt'],
    dataDirName: '',
    defaultReferenceAudio: 'test_wavs/leijun-1.wav',
    defaultReferenceText: '那还是三十六年前, 一九八七年. 我呢考上了武汉大学的计算机系.',
    assets: <TtsDownloadAsset>[
      TtsDownloadAsset(
        filename: 'sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2',
        isArchive: true,
        ghRelativePath:
            'tts-models/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2',
      ),
      TtsDownloadAsset(
        filename: 'vocos_24khz.onnx',
        isArchive: false,
        ghRelativePath: 'vocoder-models/vocos_24khz.onnx',
      ),
    ],
    speakers: <TtsSpeakerPreset>[
      TtsSpeakerPreset(id: 0, name: '当前参考音色', tag: '克隆'),
    ],
  );

  /// 3. MeloTTS 中英混读（VITS 架构，节奏自然、中英混读稳定）。
  static const TtsModelSpec meloTtsZhEn = TtsModelSpec(
    id: 'vits-melo-tts-zh_en',
    name: 'MeloTTS 中英混读',
    subtitle: '韵律自然 · 中英夹杂小说表现好，手机端合成流畅',
    kind: TtsModelKind.vits,
    estimatedSizeMb: 159,
    recommendedTag: '中英自然',
    modelFileCandidates: <String>['model.onnx', 'model.int8.onnx'],
    tokensFile: 'tokens.txt',
    lexiconFiles: <String>['lexicon.txt'],
    dataDirName: '',
    dictDirName: 'dict',
    ruleFstFiles: <String>[
      'phone.fst',
      'date.fst',
      'number.fst',
      'new_heteronym.fst',
    ],
    assets: <TtsDownloadAsset>[
      TtsDownloadAsset(
        filename: 'vits-melo-tts-zh_en.tar.bz2',
        isArchive: true,
        ghRelativePath: 'tts-models/vits-melo-tts-zh_en.tar.bz2',
      ),
    ],
    speakers: <TtsSpeakerPreset>[
      TtsSpeakerPreset(id: 0, name: 'Melo 标准女声', tag: '中英'),
    ],
  );

  /// 4. Matcha 中文标贝标准女声（22kHz，纯中文极快清晰）。
  static const TtsModelSpec matchaZhBaker = TtsModelSpec(
    id: 'matcha-icefall-zh-baker',
    name: 'Matcha 中文播音女声（22kHz）',
    subtitle: '22kHz 标贝标准女声 · 发音清晰饱满、RTF 极低，纯中文长篇听书优选',
    kind: TtsModelKind.matcha,
    estimatedSizeMb: 123,
    recommendedTag: '中文清晰',
    modelFileCandidates: <String>['model-steps-3.onnx', 'model.onnx'],
    vocoderFile: 'vocos-22khz-univ.onnx',
    tokensFile: 'tokens.txt',
    lexiconFiles: <String>['lexicon.txt'],
    dataDirName: '',
    dictDirName: 'dict',
    ruleFstFiles: <String>['phone.fst', 'date.fst', 'number.fst'],
    assets: <TtsDownloadAsset>[
      TtsDownloadAsset(
        filename: 'matcha-icefall-zh-baker.tar.bz2',
        isArchive: true,
        ghRelativePath: 'tts-models/matcha-icefall-zh-baker.tar.bz2',
      ),
      TtsDownloadAsset(
        filename: 'vocos-22khz-univ.onnx',
        isArchive: false,
        ghRelativePath: 'vocoder-models/vocos-22khz-univ.onnx',
      ),
    ],
    speakers: <TtsSpeakerPreset>[
      TtsSpeakerPreset(id: 0, name: '标贝中文女声', tag: '中文'),
    ],
  );

  /// 5. Matcha 中英混读（16kHz 轻量均衡）。
  static const TtsModelSpec matchaZhEn = TtsModelSpec(
    id: 'matcha-icefall-zh-en',
    name: 'Matcha 中英混读（16kHz）',
    subtitle: '非自回归流匹配 · 体积适中、中英混排均衡',
    kind: TtsModelKind.matcha,
    estimatedSizeMb: 127,
    recommendedTag: '轻量均衡',
    modelFileCandidates: <String>['model-steps-3.onnx', 'model.onnx'],
    vocoderFile: 'vocos-16khz-univ.onnx',
    tokensFile: 'tokens.txt',
    lexiconFiles: <String>['lexicon.txt'],
    dataDirName: 'espeak-ng-data',
    dictDirName: '',
    ruleFstFiles: <String>['phone-zh.fst', 'date-zh.fst', 'number-zh.fst'],
    assets: <TtsDownloadAsset>[
      TtsDownloadAsset(
        filename: 'matcha-icefall-zh-en.tar.bz2',
        isArchive: true,
        ghRelativePath: 'tts-models/matcha-icefall-zh-en.tar.bz2',
      ),
      TtsDownloadAsset(
        filename: 'vocos-16khz-univ.onnx',
        isArchive: false,
        ghRelativePath: 'vocoder-models/vocos-16khz-univ.onnx',
      ),
    ],
    speakers: <TtsSpeakerPreset>[
      TtsSpeakerPreset(id: 0, name: '默认中英女声', tag: '中英'),
    ],
  );

  static const List<TtsModelSpec> all = <TtsModelSpec>[
    androidSystemTts,
    zipvoiceZhEnInt8,
    meloTtsZhEn,
    matchaZhBaker,
    matchaZhEn,
  ];

  static TtsModelSpec? byId(String id) {
    for (final spec in all) {
      if (spec.id == id) return spec;
    }
    return null;
  }
}
