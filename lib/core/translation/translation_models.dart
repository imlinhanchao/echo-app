import 'package:flutter/foundation.dart';

/// 阅读器双语显示模式。
enum BilingualDisplayMode {
  original('original', '原文'),
  bilingual('bilingual', '双语对照'),
  translatedOnly('translated_only', '仅译文');

  const BilingualDisplayMode(this.id, this.label);
  final String id;
  final String label;

  static BilingualDisplayMode fromId(String? id) {
    for (final mode in BilingualDisplayMode.values) {
      if (mode.id == id) return mode;
    }
    return BilingualDisplayMode.original;
  }
}

/// 支持的目标翻译语种（名称与腾讯 HY-MT1.5 官方 Prompt 模板对齐）。
enum TranslationTargetLanguage {
  zhHans('zh-Hans', '简体中文', '中文', 'Chinese'),
  zhHant('zh-Hant', '繁体中文', '繁体中文', 'Traditional Chinese'),
  en('en', '英语', '英语', 'English'),
  ja('ja', '日语', '日语', 'Japanese'),
  ko('ko', '韩语', '韩语', 'Korean'),
  fr('fr', '法语', '法语', 'French'),
  de('de', '德语', '德语', 'German'),
  es('es', '西班牙语', '西班牙语', 'Spanish'),
  ru('ru', '俄语', '俄语', 'Russian');

  const TranslationTargetLanguage(
    this.code,
    this.label,
    this.zhPromptName,
    this.enPromptName,
  );

  final String code;
  final String label;
  final String zhPromptName;
  final String enPromptName;

  bool get isChinese => this == zhHans || this == zhHant;

  static TranslationTargetLanguage fromCode(String? code) {
    for (final lang in TranslationTargetLanguage.values) {
      if (lang.code == code) return lang;
    }
    return TranslationTargetLanguage.zhHans;
  }
}

/// 翻译模型下载镜像选项。
@immutable
class TranslationMirrorOption {
  const TranslationMirrorOption({
    required this.id,
    required this.label,
    required this.baseUrl,
    this.description = '',
  });

  final String id;
  final String label;
  final String baseUrl;
  final String description;
}

/// 端侧翻译模型目录条目。
@immutable
class TranslationModelSpec {
  const TranslationModelSpec({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.estimatedSizeBytes,
    required this.recommendedTag,
    required this.hfRepo,
    required this.filename,
    this.isImported = false,
  });

  final String id;
  final String name;
  final String subtitle;
  final int estimatedSizeBytes;
  final String recommendedTag;
  final String hfRepo;
  final String filename;
  final bool isImported;

  double get estimatedSizeMb => estimatedSizeBytes / (1024 * 1024);

  /// 生成指定镜像下的 GGUF 下载链接。
  String downloadUrlForMirror({
    required String mirrorId,
    String customPrefix = '',
  }) {
    if (isImported || hfRepo.isEmpty || filename.isEmpty) return '';
    return TranslationModelCatalog.buildUrlForMirror(
      hfRepo: hfRepo,
      filename: filename,
      mirrorId: mirrorId,
      customPrefix: customPrefix,
    );
  }
}

/// HY-MT1.5 离线翻译模型与镜像预设目录。
abstract final class TranslationModelCatalog {
  static const String mirrorHfMirror = 'hf_mirror';
  static const String mirrorHuggingFace = 'huggingface';
  static const String mirrorCustom = 'custom';

  static const String modelId125Bit = 'hy-mt1.5-1.8b-1.25bit';
  static const String modelIdQ4Km = 'hy-mt1.5-1.8b-q4km';
  static const String modelIdImported = 'imported-gguf';

  static const String defaultModelId = modelId125Bit;

  static const List<TranslationMirrorOption> mirrors = <TranslationMirrorOption>[
    TranslationMirrorOption(
      id: mirrorHfMirror,
      label: 'HF-Mirror（国内镜像）',
      baseUrl: 'https://hf-mirror.com',
      description: '国内网络推荐，HuggingFace 镜像节点直下',
    ),
    TranslationMirrorOption(
      id: mirrorHuggingFace,
      label: 'HuggingFace 官方直连',
      baseUrl: 'https://huggingface.co',
      description: '海外或具备代理环境优先使用',
    ),
    TranslationMirrorOption(
      id: mirrorCustom,
      label: '自定义下载前缀',
      baseUrl: '',
      description: '自建或第三方 HuggingFace 反代前缀',
    ),
  ];

  static TranslationMirrorOption mirrorById(String id) {
    for (final m in mirrors) {
      if (m.id == id) return m;
    }
    return mirrors.first;
  }

  static String buildUrlForMirror({
    required String hfRepo,
    required String filename,
    required String mirrorId,
    String customPrefix = '',
  }) {
    final relativePath = '$hfRepo/resolve/main/$filename';
    final officialUrl = 'https://huggingface.co/$relativePath';

    if (mirrorId == mirrorCustom) {
      final raw = customPrefix.trim();
      if (raw.isNotEmpty) {
        if (raw.contains('{url}')) {
          return raw.replaceAll('{url}', officialUrl);
        }
        final trimmed = raw.endsWith('/')
            ? raw.substring(0, raw.length - 1)
            : raw;
        if (trimmed.contains('huggingface.co')) {
          return '$trimmed/$officialUrl';
        }
        return '$trimmed/$relativePath';
      }
      return 'https://hf-mirror.com/$relativePath';
    }

    final opt = mirrorById(mirrorId);
    final base = opt.baseUrl.isEmpty ? 'https://hf-mirror.com' : opt.baseUrl;
    return '$base/$relativePath';
  }

  /// 1. 腾讯 AngelSlim HY-MT1.5-1.8B 1.25-bit STQ 极速量化版（~440MB）。
  static const TranslationModelSpec hyMt125Bit = TranslationModelSpec(
    id: modelId125Bit,
    name: 'HY-MT1.5-1.8B · 1.25-bit',
    subtitle: 'Tencent Sherry STQ1_0 极速压缩 · 约 440MB，内存占用极低，手机首选',
    estimatedSizeBytes: 461860704,
    recommendedTag: '推荐 · 440MB',
    hfRepo: 'AngelSlim/Hy-MT1.5-1.8B-1.25bit-GGUF',
    filename: 'Hy-MT1.5-1.8B-1.25bit.gguf',
  );

  /// 2. 腾讯官方 HY-MT1.5-1.8B Q4_K_M 标准均衡版（~1.06GB）。
  static const TranslationModelSpec hyMtQ4Km = TranslationModelSpec(
    id: modelIdQ4Km,
    name: 'HY-MT1.5-1.8B · Q4_K_M',
    subtitle: '标准 4-bit K-Quant · 约 1.06GB，旗舰机型追求更高翻译精度的备选',
    estimatedSizeBytes: 1133080512,
    recommendedTag: '高精度 · 1.06GB',
    hfRepo: 'tencent/HY-MT1.5-1.8B-GGUF',
    filename: 'HY-MT1.5-1.8B-Q4_K_M.gguf',
  );

  static const TranslationModelSpec importedPlaceholder = TranslationModelSpec(
    id: modelIdImported,
    name: '本地导入 GGUF 模型',
    subtitle: '从设备存储选取自定义量化 GGUF 模型文件',
    estimatedSizeBytes: 0,
    recommendedTag: '本地导入',
    hfRepo: '',
    filename: '',
    isImported: true,
  );

  static const List<TranslationModelSpec> downloadablePresets =
      <TranslationModelSpec>[hyMt125Bit, hyMtQ4Km];

  static TranslationModelSpec? byId(String id) {
    for (final s in downloadablePresets) {
      if (s.id == id) return s;
    }
    if (id == modelIdImported) return importedPlaceholder;
    return null;
  }
}

/// 严格按 HY-MT1.5 官方模板构造翻译 Prompt（ZH<=>XX 与 XX<=>XX 区分模板）。
String buildHyMtPrompt({
  required String sourceText,
  required TranslationTargetLanguage targetLanguage,
}) {
  final trimmed = sourceText.trim();
  if (trimmed.isEmpty) return '';

  // 目标语言为中文，或源文包含显著中文字符时走中文指令模板
  final hasCjkSource = RegExp(r'[\u4e00-\u9fff]').hasMatch(trimmed);
  if (targetLanguage.isChinese || hasCjkSource) {
    return '将以下文本翻译为${targetLanguage.zhPromptName}，注意只需要输出翻译后的结果，不要额外解释：\n\n$trimmed';
  }
  return 'Translate the following segment into ${targetLanguage.enPromptName}, without additional explanation.\n\n$trimmed';
}
