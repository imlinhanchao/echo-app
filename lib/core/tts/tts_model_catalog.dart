import 'package:flutter/foundation.dart';

/// 端侧 sherpa-onnx TTS 模型架构类型。
enum TtsModelKind { kokoro, matcha, vits }

/// 预设音色描述。
@immutable
class TtsSpeakerPreset {
  const TtsSpeakerPreset({required this.id, required this.name, this.tag = ''});

  final int id;
  final String name;
  final String tag;
}

/// 单个需要下载的模型文件/压缩包条目（支持主/备镜像自动切换）。
@immutable
class TtsDownloadAsset {
  const TtsDownloadAsset({
    required this.filename,
    required this.isArchive,
    required this.cnMirrorUrls,
    required this.officialUrls,
  });

  final String filename;
  final bool isArchive;
  final List<String> cnMirrorUrls;
  final List<String> officialUrls;

  List<String> orderedUrls({required bool preferCnMirror}) {
    return preferCnMirror
        ? <String>[...cnMirrorUrls, ...officialUrls]
        : <String>[...officialUrls, ...cnMirrorUrls];
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
    this.voicesFile = '',
    this.vocoderFile = '',
    this.tokensFile = 'tokens.txt',
    this.lexiconFiles = const <String>[],
    this.dataDirName = 'espeak-ng-data',
    this.dictDirName = '',
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
  final String voicesFile;
  final String vocoderFile;
  final String tokensFile;
  final List<String> lexiconFiles;
  final String dataDirName;
  final String dictDirName;
}

/// 内置精选的 3 档手机端离线中文/中英 TTS 模型清单。
abstract final class TtsModelCatalog {
  static const String _ghReleaseBase =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download';

  static List<String> _cnMirrorsForGh(String relativePath) => <String>[
    'https://ghfast.top/$_ghReleaseBase/$relativePath',
    'https://gh-proxy.com/$_ghReleaseBase/$relativePath',
  ];

  static const TtsModelSpec kokoroZhV11 = TtsModelSpec(
    id: 'kokoro-int8-multi-lang-v1_1',
    name: 'Kokoro v1.1 中英（INT8）',
    subtitle: '82M 量化版 · 音质最自然、多音色，中高端手机推荐',
    kind: TtsModelKind.kokoro,
    estimatedSizeMb: 120,
    recommendedTag: '音质优先',
    modelFileCandidates: <String>['model.int8.onnx', 'model.onnx'],
    voicesFile: 'voices.bin',
    tokensFile: 'tokens.txt',
    lexiconFiles: <String>['lexicon-us-en.txt', 'lexicon-zh.txt'],
    dataDirName: 'espeak-ng-data',
    dictDirName: 'dict',
    assets: <TtsDownloadAsset>[
      TtsDownloadAsset(
        filename: 'kokoro-int8-multi-lang-v1_1.tar.bz2',
        isArchive: true,
        cnMirrorUrls: <String>[
          'https://ghfast.top/$_ghReleaseBase/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2',
          'https://gh-proxy.com/$_ghReleaseBase/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2',
        ],
        officialUrls: <String>[
          '$_ghReleaseBase/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2',
        ],
      ),
    ],
    speakers: <TtsSpeakerPreset>[
      TtsSpeakerPreset(id: 45, name: 'zf_001（女声·清亮）', tag: '中文女'),
      TtsSpeakerPreset(id: 46, name: 'zf_002（女声·温柔）', tag: '中文女'),
      TtsSpeakerPreset(id: 47, name: 'zf_003（女声·知性）', tag: '中文女'),
      TtsSpeakerPreset(id: 50, name: 'zm_010（男声·沉稳）', tag: '中文男'),
      TtsSpeakerPreset(id: 51, name: 'zm_011（男声·播音）', tag: '中文男'),
      TtsSpeakerPreset(id: 0, name: 'af_alloy（英文女声）', tag: '英文'),
    ],
  );

  static const TtsModelSpec matchaZhEn = TtsModelSpec(
    id: 'matcha-icefall-zh-en',
    name: 'Matcha 中英混读',
    subtitle: '非自回归流匹配 · 速度与音质均衡，中英混排稳定',
    kind: TtsModelKind.matcha,
    estimatedSizeMb: 85,
    recommendedTag: '均衡推荐',
    modelFileCandidates: <String>['model-steps-3.onnx', 'model.onnx'],
    vocoderFile: 'vocos-16khz-univ.onnx',
    tokensFile: 'tokens.txt',
    lexiconFiles: <String>['lexicon.txt'],
    dataDirName: 'espeak-ng-data',
    dictDirName: 'dict',
    assets: <TtsDownloadAsset>[
      TtsDownloadAsset(
        filename: 'matcha-icefall-zh-en.tar.bz2',
        isArchive: true,
        cnMirrorUrls: <String>[
          'https://ghfast.top/$_ghReleaseBase/tts-models/matcha-icefall-zh-en.tar.bz2',
          'https://gh-proxy.com/$_ghReleaseBase/tts-models/matcha-icefall-zh-en.tar.bz2',
        ],
        officialUrls: <String>[
          '$_ghReleaseBase/tts-models/matcha-icefall-zh-en.tar.bz2',
        ],
      ),
      TtsDownloadAsset(
        filename: 'vocos-16khz-univ.onnx',
        isArchive: false,
        cnMirrorUrls: <String>[
          'https://ghfast.top/$_ghReleaseBase/vocoder-models/vocos-16khz-univ.onnx',
          'https://gh-proxy.com/$_ghReleaseBase/vocoder-models/vocos-16khz-univ.onnx',
        ],
        officialUrls: <String>[
          '$_ghReleaseBase/vocoder-models/vocos-16khz-univ.onnx',
        ],
      ),
    ],
    speakers: <TtsSpeakerPreset>[
      TtsSpeakerPreset(id: 0, name: '默认中英女声', tag: '中英'),
    ],
  );

  static const TtsModelSpec piperZhHuayan = TtsModelSpec(
    id: 'vits-piper-zh_CN-huayan-medium',
    name: 'Piper 中文 · 华研（轻量极速）',
    subtitle: '极低 CPU 占用 · 老机型与长时间后台转码首选',
    kind: TtsModelKind.vits,
    estimatedSizeMb: 65,
    recommendedTag: '低端机极速',
    modelFileCandidates: <String>['zh_CN-huayan-medium.onnx', 'model.onnx'],
    tokensFile: 'tokens.txt',
    dataDirName: 'espeak-ng-data',
    assets: <TtsDownloadAsset>[
      TtsDownloadAsset(
        filename: 'vits-piper-zh_CN-huayan-medium.tar.bz2',
        isArchive: true,
        cnMirrorUrls: <String>[
          'https://ghfast.top/$_ghReleaseBase/tts-models/vits-piper-zh_CN-huayan-medium.tar.bz2',
          'https://gh-proxy.com/$_ghReleaseBase/tts-models/vits-piper-zh_CN-huayan-medium.tar.bz2',
        ],
        officialUrls: <String>[
          '$_ghReleaseBase/tts-models/vits-piper-zh_CN-huayan-medium.tar.bz2',
        ],
      ),
    ],
    speakers: <TtsSpeakerPreset>[
      TtsSpeakerPreset(id: 0, name: '华研女声', tag: '中文'),
    ],
  );

  static const List<TtsModelSpec> all = <TtsModelSpec>[
    kokoroZhV11,
    matchaZhEn,
    piperZhHuayan,
  ];

  static TtsModelSpec? byId(String id) {
    for (final spec in all) {
      if (spec.id == id) return spec;
    }
    return null;
  }

  /// 辅助工具：基于相对路径生成国内镜像列表（便于扩展新模型）。
  static List<String> cnMirrorsFor(String relativePath) =>
      _cnMirrorsForGh(relativePath);
}
