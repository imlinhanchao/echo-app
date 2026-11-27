import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:echo/core/book_sources/book_source_driver.dart';
import 'package:echo/core/book_sources/book_source_models.dart';
import 'package:echo/core/book_sources/mirror_pool_manager.dart';
import 'package:echo/core/book_sources/opds_book_source_driver.dart';
import 'package:echo/core/book_sources/rule_book_source_driver.dart';
import 'package:echo/core/book_sources/rule_extractor.dart';

const Set<String> _validTemplateRoots = <String>{
  'origin',
  'query',
  'input',
  'cred',
  'book',
  'step',
  'vars',
  'fields',
  'rand',
};

Future<int> main(List<String> args) async {
  String? filePath;
  String? sourceId;
  String? searchQuery;
  var runProbe = false;
  var strict = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-h' || arg == '--help') {
      _printUsage();
      return 0;
    } else if (arg == '--source') {
      if (i + 1 >= args.length) {
        stderr.writeln('ERROR: --source 需要提供书源 id');
        return 1;
      }
      sourceId = args[++i].trim();
    } else if (arg == '--search') {
      if (i + 1 >= args.length) {
        stderr.writeln('ERROR: --search 需要提供搜索关键词');
        return 1;
      }
      searchQuery = args[++i];
    } else if (arg == '--probe') {
      runProbe = true;
    } else if (arg == '--strict') {
      strict = true;
    } else if (arg.startsWith('-')) {
      stderr.writeln('ERROR: 未知参数 $arg');
      _printUsage();
      return 1;
    } else {
      if (filePath != null) {
        stderr.writeln('ERROR: 只支持指定一个 JSON 文件路径');
        return 1;
      }
      filePath = arg;
    }
  }

  if (filePath == null || filePath.trim().isEmpty) {
    _printUsage();
    return 1;
  }

  final file = File(filePath);
  if (!file.existsSync()) {
    stderr.writeln('ERROR: 文件不存在: $filePath');
    return 1;
  }

  final String rawJson;
  try {
    rawJson = await file.readAsString();
  } catch (e) {
    stderr.writeln('ERROR: 无法读取文件 $filePath: $e');
    return 1;
  }

  final dynamic decoded;
  try {
    decoded = jsonDecode(rawJson);
  } catch (e) {
    stderr.writeln('ERROR: JSON 语法无效: $e');
    return 1;
  }

  if (decoded is! Map) {
    stderr.writeln('ERROR: JSON 根节点必须是对象');
    return 1;
  }

  final BookSourceBundle bundle;
  try {
    bundle = parseBookSourceInput(rawJson);
  } catch (e) {
    stderr.writeln('ERROR: 解析书源配置失败: $e');
    return 1;
  }

  final schemaErr = validateBookSourceBundle(
    bundle,
    rawJson: decoded.cast<String, dynamic>(),
  );
  if (schemaErr != null) {
    stderr.writeln('ERROR: Schema 校验失败: $schemaErr');
    return 1;
  }

  final targets = sourceId != null && sourceId.isNotEmpty
      ? bundle.sources.where((s) => s.id == sourceId).toList(growable: false)
      : bundle.sources;
  if (targets.isEmpty) {
    stderr.writeln('ERROR: 在 $filePath 中未找到 id="$sourceId" 的书源');
    return 1;
  }

  final warnings = <String>[];
  final errors = <String>[];

  for (final src in targets) {
    _auditSource(src, errors: errors, warnings: warnings);
  }

  stdout.writeln(
    'Parsed ${targets.length} source(s) from $filePath '
    '(schema_version=${bundle.schemaVersion}'
    '${bundle.configVersion.isNotEmpty ? ", config_version=${bundle.configVersion}" : ""}).',
  );
  for (final src in targets) {
    stdout.writeln(
      '  - ${src.id} [${src.driver.wireName}] "${src.name}" '
      '(${src.domains.length} domain(s), defaultEnabled=${src.defaultEnabled})',
    );
  }

  for (final w in warnings) {
    stderr.writeln('WARNING: $w');
  }
  for (final e in errors) {
    stderr.writeln('ERROR: $e');
  }

  if (errors.isNotEmpty) {
    return 1;
  }
  if (strict && warnings.isNotEmpty) {
    stderr.writeln('ERROR: --strict 模式下存在 ${warnings.length} 条警告');
    return 2;
  }

  if (runProbe || (searchQuery != null && searchQuery.trim().isNotEmpty)) {
    final targetDef = targets.firstWhere(
      (s) => s.defaultEnabled,
      orElse: () => targets.first,
    );
    final resolved = ResolvedBookSource(
      definition: targetDef,
      origin: BookSourceOrigin.local,
    );
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 15),
      ),
    );
    try {
      final mirrorPool = MirrorPoolManager(dio: dio);
      if (runProbe) {
        stdout.writeln('Probing domains for "${resolved.id}"...');
        final probes = await mirrorPool.probeAll(resolved);
        for (final p in probes) {
          stdout.writeln(
            '  * ${p.domain}: ${p.ok ? "OK" : "FAIL"} '
            '(status=${p.statusCode ?? "-"}, ${p.latencyMs}ms'
            '${p.error.isNotEmpty ? ", error=${p.error}" : ""})',
          );
        }
        if (strict && probes.every((p) => !p.ok)) {
          stderr.writeln('ERROR: --strict 模式下所有节点探针均失败');
          return 2;
        }
      }

      if (searchQuery != null && searchQuery.trim().isNotEmpty) {
        final ok = await _runLiveSearchAndDetail(
          resolved,
          mirrorPool: mirrorPool,
          query: searchQuery.trim(),
          strict: strict,
        );
        if (!ok) {
          return 2;
        }
      }
    } finally {
      dio.close(force: true);
    }
  }

  stdout.writeln('OK: 书源配置校验通过。');
  return 0;
}

Future<bool> _runLiveSearchAndDetail(
  ResolvedBookSource resolved, {
  required MirrorPoolManager mirrorPool,
  required String query,
  required bool strict,
}) async {
  stdout.writeln(
    'Running dry-run search for "${resolved.id}" [${resolved.driver.wireName}] with query="$query"...',
  );
  if (resolved.driver == BookSourceDriverType.ebookApi) {
    stderr.writeln('WARNING: ebook_api 书源需连接自建后端实例，跳过干跑。');
    return !strict;
  }
  if (resolved.requiresAuthForSearch) {
    stderr.writeln(
      'WARNING: 书源 "${resolved.id}" 搜索阶段需要登录凭据，离线干跑不会注入账号，已跳过。',
    );
    return !strict;
  }

  final BookSourceDriver driver = resolved.driver == BookSourceDriverType.opds
      ? OpdsBookSourceDriver(mirrorPool: mirrorPool)
      : RuleBookSourceDriver(
          mirrorPool: mirrorPool,
          extractor: RuleExtractor(),
        );

  try {
    final page = await driver.search(
      resolved,
      BookSourceSearchRequest(query: query, page: 1, limit: 5),
    );
    stdout.writeln(
      'Search OK: page=${page.page}/${page.totalPages}, returned ${page.books.length} item(s).',
    );
    for (final b in page.books.take(3)) {
      stdout.writeln(
        '  * [${b.format.isEmpty ? "?" : b.format}] ${b.title} '
        '(${b.authors.isEmpty ? "未知作者" : b.authors.join(", ")}) ref=${b.ref}',
      );
    }
    if (page.books.isEmpty) {
      stderr.writeln('WARNING: 搜索结果为空，请检查关键词或选择器/JSON 路径');
      return !strict;
    }

    if (resolved.definition.detail?.isConfigured == true) {
      final first = page.books.first;
      final detail = await driver.getBookDetail(
        resolved,
        first.ref,
        baseBook: first,
      );
      stdout.writeln(
        'Detail OK: title="${detail.title}", '
        'cover=${detail.coverUrl.isNotEmpty ? "yes" : "no"}, '
        'descriptionLen=${detail.description.length}',
      );
    }
    return true;
  } on BookSourceException catch (e) {
    stderr.writeln('ERROR: 干跑请求失败 [${e.code}]: ${e.message}');
    return false;
  } catch (e) {
    stderr.writeln('ERROR: 干跑异常: $e');
    return false;
  }
}

void _auditSource(
  BookSourceDefinition src, {
  required List<String> errors,
  required List<String> warnings,
}) {
  final definedVars = <String>{
    ...?src.search?.response.vars.keys,
    ...?src.detail?.vars.keys,
  };
  final authCredKeys = src.auth?.credentialKeys.toSet() ?? const <String>{};

  void checkRegex(String pattern, String where) {
    if (pattern.isEmpty) return;
    try {
      RegExp(pattern);
    } catch (e) {
      errors.add('[${src.id}] $where 正则无效 "$pattern": $e');
    }
  }

  void checkTemplatesInText(
    String text,
    String where, {
    Set<String> availableStepIds = const <String>{},
  }) {
    for (final m in RegExp(r'\{\{([a-zA-Z0-9_.-]+)\}\}').allMatches(text)) {
      final expr = m.group(1) ?? '';
      final parts = expr.split('.');
      final root = parts.first;
      if (!_validTemplateRoots.contains(root)) {
        warnings.add('[${src.id}] $where 含未识别模板变量 {{$expr}}');
        continue;
      }
      if (root == 'book' && parts.length >= 3 && parts[1] == 'var') {
        final varName = parts.sublist(2).join('.');
        if (!definedVars.contains(varName)) {
          warnings.add(
            '[${src.id}] $where 引用了未在 vars 中声明的 {{$expr}}',
          );
        }
      } else if (root == 'step' && parts.length >= 2) {
        final stepId = parts[1];
        if (stepId != 'last' && !availableStepIds.contains(stepId)) {
          warnings.add(
            '[${src.id}] $where 引用了未定义或顺序靠后的步骤 "{{$expr}}"',
          );
        }
      } else if (root == 'cred' &&
          parts.length >= 2 &&
          authCredKeys.isNotEmpty &&
          !authCredKeys.contains(parts[1])) {
        warnings.add(
          '[${src.id}] $where 引用了 {{$expr}}，但 auth.modes 中未声明凭据键 ${parts[1]}',
        );
      }
    }
  }

  void checkTemplateDynamic(
    Object? raw,
    String where, {
    Set<String> availableStepIds = const <String>{},
  }) {
    if (raw is String) {
      checkTemplatesInText(raw, where, availableStepIds: availableStepIds);
    } else if (raw is List) {
      for (final item in raw) {
        checkTemplateDynamic(item, where, availableStepIds: availableStepIds);
      }
    } else if (raw is Map) {
      for (final entry in raw.entries) {
        checkTemplateDynamic(
          entry.value,
          '$where.${entry.key}',
          availableStepIds: availableStepIds,
        );
      }
    }
  }

  void checkExtractRule(
    BookSourceExtractRule rule,
    String where, {
    Set<String> availableStepIds = const <String>{},
  }) {
    checkRegex(rule.regex, '$where.regex');
    checkRegex(rule.replacePattern, '$where.replace_pattern');
    checkRegex(rule.splitRegex, '$where.split_regex');
    if (rule.template.isNotEmpty) {
      checkTemplatesInText(
        rule.template,
        '$where.template',
        availableStepIds: availableStepIds,
      );
    }
    for (var i = 0; i < rule.firstOf.length; i++) {
      checkExtractRule(
        rule.firstOf[i],
        '$where.first_of[$i]',
        availableStepIds: availableStepIds,
      );
    }
    if (rule.whenPresent != null) {
      checkExtractRule(
        rule.whenPresent!,
        '$where.when_present',
        availableStepIds: availableStepIds,
      );
    }
  }

  void checkExtractMap(
    Map<String, BookSourceExtractRule> map,
    String where, {
    Set<String> availableStepIds = const <String>{},
  }) {
    for (final entry in map.entries) {
      checkExtractRule(
        entry.value,
        '$where.${entry.key}',
        availableStepIds: availableStepIds,
      );
    }
  }

  void checkStaticSecretHeaders(Map<String, String> headers, String where) {
    for (final entry in headers.entries) {
      final kLower = entry.key.toLowerCase();
      final val = entry.value.trim();
      if ((kLower == 'cookie' || kLower == 'authorization') &&
          val.isNotEmpty &&
          !val.contains('{{')) {
        warnings.add(
          '[${src.id}] $where.${entry.key} 含硬编码敏感头，发布前请改为 {{cred.*}} 模板',
        );
      }
    }
  }

  checkStaticSecretHeaders(src.headers, 'headers');
  checkStaticSecretHeaders(src.imageHeaders, 'image_headers');

  // Auth audit
  final auth = src.auth;
  if (auth != null) {
    checkTemplateDynamic(auth.inject.headers, 'auth.inject.headers');
    checkTemplateDynamic(auth.inject.cookies, 'auth.inject.cookies');
    checkTemplateDynamic(auth.inject.query, 'auth.inject.query');
    for (final mode in auth.modes) {
      final login = mode.login;
      if (login != null) {
        final seenPreIds = <String>{};
        for (var i = 0; i < login.preSteps.length; i++) {
          final st = login.preSteps[i];
          final w = 'auth.modes(${mode.id}).login.pre_steps[$i]';
          checkTemplateDynamic(st.path, '$w.path', availableStepIds: seenPreIds);
          checkTemplateDynamic(st.url, '$w.url', availableStepIds: seenPreIds);
          checkTemplateDynamic(
            st.headers,
            '$w.headers',
            availableStepIds: seenPreIds,
          );
          checkTemplateDynamic(
            st.cookies,
            '$w.cookies',
            availableStepIds: seenPreIds,
          );
          checkTemplateDynamic(st.body, '$w.body', availableStepIds: seenPreIds);
          checkRegex(st.followWhileUrlRegex, '$w.follow_while_url_regex');
          checkExtractMap(
            st.extract,
            '$w.extract',
            availableStepIds: seenPreIds,
          );
          if (st.id.isNotEmpty) seenPreIds.add(st.id);
        }
        checkTemplateDynamic(
          login.path,
          'auth.modes(${mode.id}).login.path',
          availableStepIds: seenPreIds,
        );
        checkTemplateDynamic(
          login.headers,
          'auth.modes(${mode.id}).login.headers',
          availableStepIds: seenPreIds,
        );
        checkTemplateDynamic(
          login.cookies,
          'auth.modes(${mode.id}).login.cookies',
          availableStepIds: seenPreIds,
        );
        checkTemplateDynamic(
          login.body,
          'auth.modes(${mode.id}).login.body',
          availableStepIds: seenPreIds,
        );
        checkExtractMap(
          login.saveCredentials,
          'auth.modes(${mode.id}).login.save_credentials',
          availableStepIds: seenPreIds,
        );
      }
    }

    final verify = auth.verify;
    if (verify != null) {
      final seenVerifyIds = <String>{};
      for (var i = 0; i < verify.steps.length; i++) {
        final st = verify.steps[i];
        final w = 'auth.verify.steps[$i]';
        checkTemplateDynamic(
          st.path,
          '$w.path',
          availableStepIds: seenVerifyIds,
        );
        checkTemplateDynamic(
          st.url,
          '$w.url',
          availableStepIds: seenVerifyIds,
        );
        checkTemplateDynamic(
          st.headers,
          '$w.headers',
          availableStepIds: seenVerifyIds,
        );
        checkExtractMap(
          st.extract,
          '$w.extract',
          availableStepIds: seenVerifyIds,
        );
        if (st.id.isNotEmpty) seenVerifyIds.add(st.id);
      }
      checkExtractMap(
        verify.fields,
        'auth.verify.fields',
        availableStepIds: seenVerifyIds,
      );
    }
  }

  // Errors audit
  final errs = src.errors;
  if (errs != null) {
    for (var i = 0; i < errs.rules.length; i++) {
      checkRegex(errs.rules[i].errorCodeRegex, 'errors.rules[$i].error_code_regex');
      checkRegex(errs.rules[i].errorRegex, 'errors.rules[$i].error_regex');
    }
  }

  // Search audit
  final search = src.search;
  if (search != null) {
    checkTemplateDynamic(search.request.path, 'search.request.path');
    checkTemplateDynamic(search.request.url, 'search.request.url');
    checkTemplateDynamic(search.request.query, 'search.request.query');
    checkTemplateDynamic(search.request.body, 'search.request.body');
    checkExtractMap(search.response.vars, 'search.response.vars');
    checkExtractMap(search.response.fields, 'search.response.fields');
    if (search.response.mode == 'html' && src.minRequestIntervalMs == 0) {
      warnings.add(
        '[${src.id}] HTML 抓取建议设置 min_request_interval_ms >= 500 以避免触发风控',
      );
    }
  }

  // Detail audit
  final detail = src.detail;
  if (detail != null) {
    checkTemplateDynamic(detail.path, 'detail.path');
    checkTemplateDynamic(detail.url, 'detail.url');
    checkExtractMap(detail.vars, 'detail.vars');
    checkExtractMap(detail.fields, 'detail.fields');
  }

  // Download pipeline audit
  final download = src.download;
  if (download != null) {
    final seenStepIds = <String>{};
    for (var i = 0; i < download.steps.length; i++) {
      final st = download.steps[i];
      final w = 'download.steps[$i]';
      checkTemplateDynamic(st.path, '$w.path', availableStepIds: seenStepIds);
      checkTemplateDynamic(st.url, '$w.url', availableStepIds: seenStepIds);
      checkTemplateDynamic(
        st.headers,
        '$w.headers',
        availableStepIds: seenStepIds,
      );
      checkTemplateDynamic(
        st.cookies,
        '$w.cookies',
        availableStepIds: seenStepIds,
      );
      checkTemplateDynamic(st.query, '$w.query', availableStepIds: seenStepIds);
      checkTemplateDynamic(st.body, '$w.body', availableStepIds: seenStepIds);
      checkRegex(st.followWhileUrlRegex, '$w.follow_while_url_regex');
      checkExtractMap(
        st.extract,
        '$w.extract',
        availableStepIds: seenStepIds,
      );
      if (st.id.isNotEmpty) seenStepIds.add(st.id);
      final poll = st.poll;
      if (poll != null) {
        checkTemplateDynamic(
          poll.path,
          '$w.poll.path',
          availableStepIds: seenStepIds,
        );
        checkTemplateDynamic(
          poll.url,
          '$w.poll.url',
          availableStepIds: seenStepIds,
        );
        checkExtractMap(
          poll.extract,
          '$w.poll.extract',
          availableStepIds: seenStepIds,
        );
      }
    }
    checkTemplateDynamic(
      download.fileRequest.url,
      'download.file_request.url',
      availableStepIds: seenStepIds,
    );
    checkTemplateDynamic(
      download.fileRequest.path,
      'download.file_request.path',
      availableStepIds: seenStepIds,
    );
    checkTemplateDynamic(
      download.fileRequest.headers,
      'download.file_request.headers',
      availableStepIds: seenStepIds,
    );
  }
}

void _printUsage() {
  stdout.writeln('''
Echo 书源规则校验与连通性测试工具 (pure Dart CLI)

用法:
  dart run .agents/skills/echo-book-source-author/scripts/validate_source.dart <config.json> [选项]

选项:
  --source <id>      指定要校验/测试的书源 id（默认校验全部，干跑默认首个启用源）
  --search <query>   发起只读搜书（及可选详情）干跑测试（不消耗下载配额）
  --probe            测试所有候选域名延迟与可用状态
  --strict           将任何警告（包括空搜索结果或模板警告）视为错误（返回退出码 2）
  -h, --help         显示本帮助信息
''');
}
