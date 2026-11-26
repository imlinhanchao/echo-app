import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 荐书规则默认常量与内置兜底 JSON。
abstract final class DiscoverConfigDefaults {
  /// 默认远程规则地址（可直接通过修改仓库或自定义 URL 动态更新解析规则）。
  static const String defaultRemoteUrl =
      'https://raw.githubusercontent.com/imlinhanchao/echo-app/main/assets/discover-rules.json';

  static const int supportedSchemaVersion = 1;
  static const int defaultConfigTtlHours = 24;
  static const int defaultCacheTtlHours = 12;
  static const int defaultMinRequestIntervalMs = 1500;
  static const int defaultPageSize = 20;
}

/// 内置默认规则兜底（与 `assets/discover-rules.json` 保持同步，
/// 防止未初始化资产束的纯单测环境无法读取 `rootBundle`）。
const String kBundledDiscoverRulesJson = r'''
{
  "schema_version": 1,
  "config_version": "2026.11.26.4",
  "config_ttl_hours": 24,
  "default_source_id": "tstrs",
  "sources": [
    {
      "id": "tstrs",
      "name": "SaltyLeo 的书架",
      "description": "高质量图书榜单与主题书单（点击书籍可在书源中一键检索）",
      "enabled": true,
      "mode": "html",
      "base_url": "https://tstrs.me",
      "cache_ttl_hours": 12,
      "min_request_interval_ms": 1500,
      "headers": {
        "User-Agent": "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
      },
      "image_headers": {
        "Referer": "https://tstrs.me/",
        "User-Agent": "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
      },
      "feeds": [
        {
          "id": "home",
          "title": "大家都在看",
          "kind": "books",
          "url": "/",
          "items_selector": "#home-trending a.book-hcard",
          "fields": {
            "title": { "selector": ".book-hcard-title" },
            "author": { "selector": ".book-hcard-author" },
            "publisher": { "selector": ".book-hcard-press" },
            "year": { "selector": ".book-hcard-year" },
            "cover": {
              "selector": "img.cover-thumb",
              "attrs": ["data-src", "data-fallback-src", "src"],
              "resolve_url": true
            },
            "url": { "attr": "href", "resolve_url": true }
          }
        },
        {
          "id": "chart_hot",
          "title": "热搜榜",
          "kind": "books",
          "url": "/charts?board=hot",
          "items_selector": "a.search-row.rank-item",
          "fields": {
            "title": { "selector": ".search-row-title" },
            "author": { "selector": ".search-row-author" },
            "meta": { "selector": ".search-row-press" },
            "summary": { "selector": ".search-row-summary" },
            "score": {
              "selector": ".cover-score-num",
              "regex": "[0-9]+(?:\\.[0-9]+)?"
            },
            "cover": {
              "selector": "img.cover-thumb",
              "attrs": ["data-src", "data-fallback-src", "src"],
              "resolve_url": true
            },
            "url": { "attr": "href", "resolve_url": true }
          }
        },
        {
          "id": "chart_classics",
          "title": "殿堂经典",
          "kind": "books",
          "url": "/charts?board=classics",
          "items_selector": "a.search-row.rank-item",
          "fields": {
            "title": { "selector": ".search-row-title" },
            "author": { "selector": ".search-row-author" },
            "meta": { "selector": ".search-row-press" },
            "summary": { "selector": ".search-row-summary" },
            "score": {
              "selector": ".cover-score-num",
              "regex": "[0-9]+(?:\\.[0-9]+)?"
            },
            "cover": {
              "selector": "img.cover-thumb",
              "attrs": ["data-src", "data-fallback-src", "src"],
              "resolve_url": true
            },
            "url": { "attr": "href", "resolve_url": true }
          }
        },
        {
          "id": "chart_top_rated",
          "title": "高分神作",
          "kind": "books",
          "url": "/charts?board=top-rated",
          "items_selector": "a.search-row.rank-item",
          "fields": {
            "title": { "selector": ".search-row-title" },
            "author": { "selector": ".search-row-author" },
            "meta": { "selector": ".search-row-press" },
            "summary": { "selector": ".search-row-summary" },
            "score": {
              "selector": ".cover-score-num",
              "regex": "[0-9]+(?:\\.[0-9]+)?"
            },
            "cover": {
              "selector": "img.cover-thumb",
              "attrs": ["data-src", "data-fallback-src", "src"],
              "resolve_url": true
            },
            "url": { "attr": "href", "resolve_url": true }
          }
        },
        {
          "id": "chart_hidden",
          "title": "宝藏冷门",
          "kind": "books",
          "url": "/charts?board=hidden",
          "items_selector": "a.search-row.rank-item",
          "fields": {
            "title": { "selector": ".search-row-title" },
            "author": { "selector": ".search-row-author" },
            "meta": { "selector": ".search-row-press" },
            "summary": { "selector": ".search-row-summary" },
            "score": {
              "selector": ".cover-score-num",
              "regex": "[0-9]+(?:\\.[0-9]+)?"
            },
            "cover": {
              "selector": "img.cover-thumb",
              "attrs": ["data-src", "data-fallback-src", "src"],
              "resolve_url": true
            },
            "url": { "attr": "href", "resolve_url": true }
          }
        },
        {
          "id": "booklists",
          "title": "精选书单",
          "kind": "booklists",
          "url": "/booklists?page={page}",
          "items_selector": "a.booklist-card-stack",
          "fields": {
            "title": { "selector": ".bls-title" },
            "meta": { "selector": ".bls-meta" },
            "summary": { "selector": ".bls-blurb" },
            "covers": {
              "selector": ".bls-sheet img",
              "attrs": ["data-src", "data-fallback-src", "src"],
              "resolve_url": true,
              "all": true
            },
            "url": { "attr": "href", "resolve_url": true }
          }
        }
      ],
      "booklist_detail": {
        "items_selector": ".bl-book",
        "fields": {
          "title": { "selector": ".bl-book-title" },
          "meta": { "selector": ".bl-book-meta" },
          "summary": { "selector": ".bl-book-summary" },
          "note": { "next_sibling": "p" },
          "score": {
            "selector": ".bl-book-score",
            "regex": "[0-9]+(?:\\.[0-9]+)?"
          },
          "cover": {
            "selector": "img.cover-thumb",
            "attrs": ["data-src", "data-fallback-src", "src"],
            "resolve_url": true
          },
          "url": {
            "selector": "a.bl-book-link",
            "attr": "href",
            "resolve_url": true
          }
        }
      },
      "book_detail": {
        "fields": {
          "summary": {
            "after_heading": "内容简介",
            "selector": ".text-body",
            "preserve_paragraphs": true
          },
          "score": {
            "selector": ".book-hero-score",
            "regex": "[0-9]+(?:\\.[0-9]+)?"
          },
          "pages": {
            "heading_selector": ".book-meta dt",
            "after_heading": "页数",
            "regex": "[0-9]+"
          },
          "word_count": {
            "heading_selector": ".book-meta dt",
            "after_heading": "字数"
          },
          "chapter_count": {
            "heading_selector": ".book-meta dt",
            "after_heading": "章节数",
            "regex": "[0-9]+"
          },
          "isbn": {
            "heading_selector": ".book-meta dt",
            "after_heading": "ISBN",
            "regex": "[0-9Xx-]{10,17}"
          },
          "cover": {
            "selector": "[data-cover]",
            "attrs": ["data-cover-thumb", "data-cover-src"],
            "resolve_url": true
          }
        },
        "extra_fields": [
          {
            "key": "editorial",
            "label": "编辑推荐",
            "style": "quote",
            "rule": {
              "selector": ".book-editorial",
              "preserve_paragraphs": true
            }
          },
          {
            "key": "audience_fit",
            "label": "适合阅读",
            "style": "positive_list",
            "rule": {
              "selector": ".book-audience.is-fit .book-point-list li",
              "all": true
            }
          },
          {
            "key": "audience_unfit",
            "label": "不太适合",
            "style": "negative_list",
            "rule": {
              "selector": ".book-audience.is-unfit .book-point-list li",
              "all": true
            }
          },
          {
            "key": "reading_advice",
            "label": "阅读建议",
            "style": "list",
            "rule": {
              "selector": ".book-advice-list li",
              "all": true
            }
          },
          {
            "key": "tags",
            "label": "标签",
            "style": "tags",
            "rule": {
              "selector": ".book-tags a",
              "all": true,
              "max_items": 8
            }
          }
        ]
      }
    },
    {
      "id": "douban",
      "name": "豆瓣读书",
      "description": "豆瓣热门图书榜、新书速递、Top 250 与畅销榜",
      "enabled": true,
      "mode": "html",
      "base_url": "https://book.douban.com",
      "cache_ttl_hours": 12,
      "min_request_interval_ms": 1500,
      "headers": {
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
      },
      "image_headers": {
        "Referer": "https://book.douban.com/",
        "User-Agent": "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
      },
      "feeds": [
        {
          "id": "chart",
          "title": "热门图书榜",
          "kind": "books",
          "url": "/chart",
          "items_selector": "li.media.clearfix",
          "fields": {
            "title": { "selector": "h2 a" },
            "meta": { "selector": "p.subject-abstract" },
            "score": {
              "selector": "p.subject-rating span.font-small",
              "regex": "[0-9]+(?:\\.[0-9]+)?"
            },
            "cover": {
              "selector": "img.subject-cover",
              "attr": "src",
              "replace_pattern": "/view/subject/s/",
              "replace_with": "/view/subject/l/",
              "resolve_url": true
            },
            "url": {
              "selector": "h2 a",
              "attr": "href",
              "resolve_url": true
            }
          },
          "extra_fields": [
            {
              "key": "tags",
              "label": "榜单标签",
              "style": "tags",
              "rule": {
                "selector": ".subject-tags .tag",
                "all": true,
                "max_items": 6
              }
            }
          ]
        },
        {
          "id": "latest",
          "title": "新书速递",
          "kind": "books",
          "url": "/latest",
          "items_selector": "li.media.clearfix",
          "fields": {
            "title": { "selector": "h2 a" },
            "meta": { "selector": "p.subject-abstract" },
            "score": {
              "selector": "p.subject-rating span.font-small",
              "regex": "[0-9]+(?:\\.[0-9]+)?"
            },
            "cover": {
              "selector": "img.subject-cover",
              "attr": "src",
              "replace_pattern": "/view/subject/s/",
              "replace_with": "/view/subject/l/",
              "resolve_url": true
            },
            "url": {
              "selector": "h2 a",
              "attr": "href",
              "resolve_url": true
            }
          },
          "extra_fields": [
            {
              "key": "tags",
              "label": "榜单标签",
              "style": "tags",
              "rule": {
                "selector": ".subject-tags .tag",
                "all": true,
                "max_items": 6
              }
            }
          ]
        },
        {
          "id": "top250",
          "title": "豆瓣 Top 250",
          "kind": "books",
          "url": "/top250?start={offset}",
          "page_size": 25,
          "items_selector": "tr.item",
          "fields": {
            "title": {
              "selector": ".pl2 a",
              "attr": "title"
            },
            "meta": { "selector": "p.pl" },
            "score": {
              "selector": ".rating_nums",
              "regex": "[0-9]+(?:\\.[0-9]+)?"
            },
            "note": { "selector": "p.quote span.inq" },
            "cover": {
              "selector": "a.nbg img",
              "attr": "src",
              "replace_pattern": "/view/subject/s/",
              "replace_with": "/view/subject/l/",
              "resolve_url": true
            },
            "url": {
              "selector": ".pl2 a",
              "attr": "href",
              "resolve_url": true
            }
          },
          "extra_fields": [
            {
              "key": "editorial_quote",
              "label": "编辑荐语",
              "style": "quote",
              "rule": {
                "selector": "p.quote span.inq"
              }
            }
          ]
        },
        {
          "id": "bestseller",
          "title": "畅销图书榜",
          "kind": "books",
          "mode": "json",
          "url": "https://m.douban.com/rexxar/api/v2/subject_collection/book_bestseller/items?start={offset}&count={limit}",
          "page_size": 20,
          "headers": {
            "User-Agent": "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
            "Referer": "https://m.douban.com/book/",
            "Accept": "application/json, text/plain, */*"
          },
          "items_path": "subject_collection_items",
          "fields": {
            "title": { "path": "title" },
            "author": { "path": "author" },
            "publisher": { "path": "press" },
            "year": { "path": "year" },
            "meta": { "path": "info" },
            "summary": {
              "paths": ["description", "cards.0.content"]
            },
            "score": { "path": "rating.value" },
            "cover": {
              "paths": ["cover.url", "cover_url", "pic.normal"],
              "resolve_url": true
            },
            "url": {
              "path": "url",
              "replace_pattern": "https?://www\\.douban\\.com/doubanapp/dispatch/book/",
              "replace_with": "https://book.douban.com/subject/",
              "resolve_url": true
            }
          },
          "extra_fields": [
            {
              "key": "tags",
              "label": "标签",
              "style": "tags",
              "rule": {
                "path": "tags",
                "all": true,
                "max_items": 6
              }
            }
          ]
        }
      ],
      "book_detail": {
        "mode": "html",
        "fields": {
          "summary": {
            "selectors": ["#link-report .all.hidden .intro", "#link-report .intro"],
            "preserve_paragraphs": true,
            "strip_suffix": "(展开全部)"
          },
          "pages": {
            "selector": "#info",
            "regex": "页数\\s*[:：]\\s*([0-9]+)",
            "regex_group": 1
          },
          "word_count": {
            "selector": "#info",
            "regex": "字数\\s*[:：]\\s*([^\\s/]+)",
            "regex_group": 1
          },
          "isbn": {
            "selector": "#info",
            "regex": "ISBN\\s*[:：]\\s*([0-9Xx-]{10,17})",
            "regex_group": 1
          },
          "cover": {
            "selector": "#mainpic img",
            "attr": "src",
            "replace_pattern": "/view/subject/s/",
            "replace_with": "/view/subject/l/",
            "resolve_url": true
          }
        },
        "extra_fields": [
          {
            "key": "hot_comments",
            "label": "热门短评",
            "style": "list",
            "rule": {
              "selector": ".comment-content .short",
              "all": true,
              "max_items": 3
            }
          },
          {
            "key": "author_intro",
            "label": "作者简介",
            "style": "text",
            "rule": {
              "after_heading": "作者简介",
              "selectors": [".all.hidden .intro", ".intro"],
              "preserve_paragraphs": true,
              "strip_suffix": "(展开全部)"
            }
          }
        ]
      }
    }
  ]
}
''';

List<String> _parseStringList(Object? raw) {
  if (raw is! List) return const <String>[];
  return raw
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
}

/// 单个字段提取规则（同时兼容 HTML CSS 选择器与 JSON 点路径模式）。
@immutable
class DiscoverFieldRule {
  const DiscoverFieldRule({
    this.selector = '',
    this.selectors = const <String>[],
    this.attr = '',
    this.attrs = const <String>[],
    this.all = false,
    this.nextSibling = '',
    this.afterHeading = '',
    this.headingSelector = '',
    this.preserveParagraphs = false,
    this.maxItems = 0,
    this.path = '',
    this.paths = const <String>[],
    this.joinWith = ' / ',
    this.regex = '',
    this.regexGroup = 0,
    this.replacePattern = '',
    this.replaceWith = '',
    this.prefix = '',
    this.stripPrefix = '',
    this.stripSuffix = '',
    this.resolveUrl = false,
  });

  factory DiscoverFieldRule.fromJson(Object? raw) {
    if (raw is String) {
      return DiscoverFieldRule(selector: raw.trim(), path: raw.trim());
    }
    if (raw is! Map) return const DiscoverFieldRule();
    final json = raw.cast<String, dynamic>();
    return DiscoverFieldRule(
      selector: (json['selector'] as String? ?? '').trim(),
      selectors: _parseStringList(json['selectors']),
      attr: (json['attr'] as String? ?? '').trim(),
      attrs: _parseStringList(json['attrs']),
      all: json['all'] as bool? ?? false,
      nextSibling: (json['next_sibling'] as String? ?? '').trim(),
      afterHeading: (json['after_heading'] as String? ?? '').trim(),
      headingSelector: (json['heading_selector'] as String? ?? '').trim(),
      preserveParagraphs: json['preserve_paragraphs'] as bool? ?? false,
      maxItems: (json['max_items'] as num?)?.toInt() ?? 0,
      path: (json['path'] as String? ?? '').trim(),
      paths: _parseStringList(json['paths']),
      joinWith: json['join_with'] as String? ?? ' / ',
      regex: json['regex'] as String? ?? '',
      regexGroup: (json['regex_group'] as num?)?.toInt() ?? 0,
      replacePattern: json['replace_pattern'] as String? ?? '',
      replaceWith: json['replace_with'] as String? ?? '',
      prefix: json['prefix'] as String? ?? '',
      stripPrefix: json['strip_prefix'] as String? ?? '',
      stripSuffix: json['strip_suffix'] as String? ?? '',
      resolveUrl: json['resolve_url'] as bool? ?? false,
    );
  }

  final String selector;
  final List<String> selectors;
  final String attr;
  final List<String> attrs;
  final bool all;
  final String nextSibling;
  final String afterHeading;
  final String headingSelector;
  final bool preserveParagraphs;
  final int maxItems;
  final String path;
  final List<String> paths;
  final String joinWith;
  final String regex;
  final int regexGroup;
  final String replacePattern;
  final String replaceWith;
  final String prefix;
  final String stripPrefix;
  final String stripSuffix;
  final bool resolveUrl;

  /// 合并 `selector` 与 `selectors` 为有序 CSS 选择器候选列表。
  List<String> get selectorCandidates {
    final out = <String>[];
    if (selector.isNotEmpty) out.add(selector);
    for (final s in selectors) {
      if (s.isNotEmpty && !out.contains(s)) {
        out.add(s);
      }
    }
    return out;
  }

  /// 合并 `attr` 与 `attrs` 为有序属性候选列表。
  List<String> get attrCandidates {
    final out = <String>[];
    if (attr.isNotEmpty) out.add(attr);
    for (final a in attrs) {
      if (a.isNotEmpty && !out.contains(a)) {
        out.add(a);
      }
    }
    return out;
  }

  /// 合并 `path` 与 `paths` 为有序 JSON 路径候选列表。
  List<String> get pathCandidates {
    final out = <String>[];
    if (path.isNotEmpty) out.add(path);
    for (final p in paths) {
      if (p.isNotEmpty && !out.contains(p)) {
        out.add(p);
      }
    }
    return out;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (selector.isNotEmpty) 'selector': selector,
    if (selectors.isNotEmpty) 'selectors': selectors,
    if (attr.isNotEmpty) 'attr': attr,
    if (attrs.isNotEmpty) 'attrs': attrs,
    if (all) 'all': all,
    if (nextSibling.isNotEmpty) 'next_sibling': nextSibling,
    if (afterHeading.isNotEmpty) 'after_heading': afterHeading,
    if (headingSelector.isNotEmpty) 'heading_selector': headingSelector,
    if (preserveParagraphs) 'preserve_paragraphs': preserveParagraphs,
    if (maxItems > 0) 'max_items': maxItems,
    if (path.isNotEmpty) 'path': path,
    if (paths.isNotEmpty) 'paths': paths,
    if (joinWith != ' / ') 'join_with': joinWith,
    if (regex.isNotEmpty) 'regex': regex,
    if (regexGroup != 0) 'regex_group': regexGroup,
    if (replacePattern.isNotEmpty) 'replace_pattern': replacePattern,
    if (replaceWith.isNotEmpty) 'replace_with': replaceWith,
    if (prefix.isNotEmpty) 'prefix': prefix,
    if (stripPrefix.isNotEmpty) 'strip_prefix': stripPrefix,
    if (stripSuffix.isNotEmpty) 'strip_suffix': stripSuffix,
    if (resolveUrl) 'resolve_url': resolveUrl,
  };
}

/// 荐书源动态扩展展示字段配置（由远程/内置规则声明并按 `style` 动态渲染）。
@immutable
class DiscoverExtraFieldConfig {
  const DiscoverExtraFieldConfig({
    required this.key,
    required this.label,
    this.style = 'text',
    required this.rule,
  });

  factory DiscoverExtraFieldConfig.fromJson(Map<String, dynamic> json) {
    final rawStyle = (json['style'] as String? ?? '').trim();
    return DiscoverExtraFieldConfig(
      key: (json['key'] as String? ?? '').trim(),
      label: (json['label'] as String? ?? '').trim(),
      style: rawStyle.isEmpty ? 'text' : rawStyle,
      rule: DiscoverFieldRule.fromJson(
        json.containsKey('rule') ? json['rule'] : json,
      ),
    );
  }

  final String key;
  final String label;
  final String style;
  final DiscoverFieldRule rule;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'label': label,
    'style': style,
    'rule': rule.toJson(),
  };
}

List<DiscoverExtraFieldConfig> _parseExtraFieldsList(Object? raw) {
  if (raw is! List) return const <DiscoverExtraFieldConfig>[];
  final out = <DiscoverExtraFieldConfig>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final parsed = DiscoverExtraFieldConfig.fromJson(
      item.cast<String, dynamic>(),
    );
    if (parsed.key.isEmpty || parsed.label.isEmpty) continue;
    out.add(parsed);
  }
  return List<DiscoverExtraFieldConfig>.unmodifiable(out);
}

Map<String, DiscoverFieldRule> _parseFieldsMap(Object? raw) {
  if (raw is! Map) return const <String, DiscoverFieldRule>{};
  final out = <String, DiscoverFieldRule>{};
  for (final entry in raw.entries) {
    final key = entry.key.toString().trim();
    if (key.isEmpty) continue;
    out[key] = DiscoverFieldRule.fromJson(entry.value);
  }
  return Map<String, DiscoverFieldRule>.unmodifiable(out);
}

Map<String, String> _parseStringMap(Object? raw) {
  if (raw is! Map) return const <String, String>{};
  final out = <String, String>{};
  for (final entry in raw.entries) {
    final k = entry.key.toString().trim();
    final v = entry.value?.toString() ?? '';
    if (k.isNotEmpty && v.isNotEmpty) {
      out[k] = v;
    }
  }
  return Map<String, String>.unmodifiable(out);
}

/// 单个荐书频道/榜单配置。
@immutable
class DiscoverFeedConfig {
  const DiscoverFeedConfig({
    required this.id,
    required this.title,
    this.kind = 'books',
    this.mode = '',
    required this.url,
    this.pageSize = DiscoverConfigDefaults.defaultPageSize,
    this.jsonp = false,
    this.headers = const <String, String>{},
    this.itemsSelector = '',
    this.itemsPath = '',
    this.fields = const <String, DiscoverFieldRule>{},
    this.extraFields = const <DiscoverExtraFieldConfig>[],
  });

  factory DiscoverFeedConfig.fromJson(Map<String, dynamic> json) {
    final rawKind = (json['kind'] as String? ?? 'books').trim().toLowerCase();
    final rawPageSize = (json['page_size'] as num?)?.toInt();
    return DiscoverFeedConfig(
      id: (json['id'] as String? ?? '').trim(),
      title: (json['title'] as String? ?? '').trim(),
      kind: rawKind == 'booklists' ? 'booklists' : 'books',
      mode: (json['mode'] as String? ?? '').trim().toLowerCase(),
      url: (json['url'] as String? ?? '').trim(),
      pageSize: rawPageSize != null && rawPageSize > 0
          ? rawPageSize
          : DiscoverConfigDefaults.defaultPageSize,
      jsonp: json['jsonp'] as bool? ?? false,
      headers: _parseStringMap(json['headers']),
      itemsSelector: (json['items_selector'] as String? ?? '').trim(),
      itemsPath: (json['items_path'] as String? ?? '').trim(),
      fields: _parseFieldsMap(json['fields']),
      extraFields: _parseExtraFieldsList(json['extra_fields']),
    );
  }

  final String id;
  final String title;
  final String kind; // 'books' | 'booklists'
  final String mode; // 可空：为空时继承所属 source.mode
  final String url;
  final int pageSize;
  final bool jsonp;
  final Map<String, String> headers;
  final String itemsSelector;
  final String itemsPath;
  final Map<String, DiscoverFieldRule> fields;
  final List<DiscoverExtraFieldConfig> extraFields;

  bool get isBooklists => kind == 'booklists';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'kind': kind,
    if (mode.isNotEmpty) 'mode': mode,
    'url': url,
    if (pageSize != DiscoverConfigDefaults.defaultPageSize)
      'page_size': pageSize,
    if (jsonp) 'jsonp': jsonp,
    if (headers.isNotEmpty) 'headers': headers,
    if (itemsSelector.isNotEmpty) 'items_selector': itemsSelector,
    if (itemsPath.isNotEmpty) 'items_path': itemsPath,
    'fields': <String, dynamic>{
      for (final e in fields.entries) e.key: e.value.toJson(),
    },
    if (extraFields.isNotEmpty)
      'extra_fields': extraFields
          .map((e) => e.toJson())
          .toList(growable: false),
  };
}

/// 书单详情页解析规则。
@immutable
class DiscoverDetailConfig {
  const DiscoverDetailConfig({
    this.itemsSelector = '',
    this.itemsPath = '',
    this.summarySelector = '',
    this.summaryPath = '',
    this.fields = const <String, DiscoverFieldRule>{},
    this.extraFields = const <DiscoverExtraFieldConfig>[],
  });

  factory DiscoverDetailConfig.fromJson(Map<String, dynamic> json) {
    return DiscoverDetailConfig(
      itemsSelector: (json['items_selector'] as String? ?? '').trim(),
      itemsPath: (json['items_path'] as String? ?? '').trim(),
      summarySelector: (json['summary_selector'] as String? ?? '').trim(),
      summaryPath: (json['summary_path'] as String? ?? '').trim(),
      fields: _parseFieldsMap(json['fields']),
      extraFields: _parseExtraFieldsList(json['extra_fields']),
    );
  }

  final String itemsSelector;
  final String itemsPath;
  final String summarySelector;
  final String summaryPath;
  final Map<String, DiscoverFieldRule> fields;
  final List<DiscoverExtraFieldConfig> extraFields;

  bool get isConfigured =>
      itemsSelector.isNotEmpty || itemsPath.isNotEmpty || fields.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (itemsSelector.isNotEmpty) 'items_selector': itemsSelector,
    if (itemsPath.isNotEmpty) 'items_path': itemsPath,
    if (summarySelector.isNotEmpty) 'summary_selector': summarySelector,
    if (summaryPath.isNotEmpty) 'summary_path': summaryPath,
    'fields': <String, dynamic>{
      for (final e in fields.entries) e.key: e.value.toJson(),
    },
    if (extraFields.isNotEmpty)
      'extra_fields': extraFields
          .map((e) => e.toJson())
          .toList(growable: false),
  };
}

/// 单本图书详情页懒加载解析规则（补充简介、封面与动态扩展字段）。
@immutable
class DiscoverBookDetailConfig {
  const DiscoverBookDetailConfig({
    this.mode = '',
    this.headers = const <String, String>{},
    this.fields = const <String, DiscoverFieldRule>{},
    this.extraFields = const <DiscoverExtraFieldConfig>[],
  });

  factory DiscoverBookDetailConfig.fromJson(Map<String, dynamic> json) {
    return DiscoverBookDetailConfig(
      mode: (json['mode'] as String? ?? '').trim().toLowerCase(),
      headers: _parseStringMap(json['headers']),
      fields: _parseFieldsMap(json['fields']),
      extraFields: _parseExtraFieldsList(json['extra_fields']),
    );
  }

  final String mode;
  final Map<String, String> headers;
  final Map<String, DiscoverFieldRule> fields;
  final List<DiscoverExtraFieldConfig> extraFields;

  bool get isConfigured => fields.isNotEmpty || extraFields.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (mode.isNotEmpty) 'mode': mode,
    if (headers.isNotEmpty) 'headers': headers,
    if (fields.isNotEmpty)
      'fields': <String, dynamic>{
        for (final e in fields.entries) e.key: e.value.toJson(),
      },
    if (extraFields.isNotEmpty)
      'extra_fields': extraFields
          .map((e) => e.toJson())
          .toList(growable: false),
  };
}

/// 单个荐书源配置（对应一个站点或 JSON 数据源）。
@immutable
class DiscoverSourceConfig {
  const DiscoverSourceConfig({
    required this.id,
    required this.name,
    this.description = '',
    this.enabled = true,
    this.mode = 'html',
    required this.baseUrl,
    this.cacheTtlHours = DiscoverConfigDefaults.defaultCacheTtlHours,
    this.minRequestIntervalMs =
        DiscoverConfigDefaults.defaultMinRequestIntervalMs,
    this.headers = const <String, String>{},
    this.imageHeaders = const <String, String>{},
    this.feeds = const <DiscoverFeedConfig>[],
    this.booklistDetail,
    this.bookDetail,
  });

  factory DiscoverSourceConfig.fromJson(Map<String, dynamic> json) {
    final rawFeeds = json['feeds'] as List<dynamic>? ?? const <dynamic>[];
    final detailRaw = json['booklist_detail'];
    final bookDetailRaw = json['book_detail'];
    return DiscoverSourceConfig(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      description: (json['description'] as String? ?? '').trim(),
      enabled: json['enabled'] as bool? ?? true,
      mode: (json['mode'] as String? ?? 'html').trim().toLowerCase(),
      baseUrl: (json['base_url'] as String? ?? '').trim(),
      cacheTtlHours:
          (json['cache_ttl_hours'] as num?)?.toInt() ??
          DiscoverConfigDefaults.defaultCacheTtlHours,
      minRequestIntervalMs:
          (json['min_request_interval_ms'] as num?)?.toInt() ??
          DiscoverConfigDefaults.defaultMinRequestIntervalMs,
      headers: _parseStringMap(json['headers']),
      imageHeaders: _parseStringMap(json['image_headers']),
      feeds: rawFeeds
          .whereType<Map>()
          .map((e) => DiscoverFeedConfig.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false),
      booklistDetail: detailRaw is Map
          ? DiscoverDetailConfig.fromJson(detailRaw.cast<String, dynamic>())
          : null,
      bookDetail: bookDetailRaw is Map
          ? DiscoverBookDetailConfig.fromJson(
              bookDetailRaw.cast<String, dynamic>(),
            )
          : null,
    );
  }

  final String id;
  final String name;
  final String description;
  final bool enabled;
  final String mode; // 'html' | 'json'
  final String baseUrl;
  final int cacheTtlHours;
  final int minRequestIntervalMs;
  final Map<String, String> headers;
  final Map<String, String> imageHeaders;
  final List<DiscoverFeedConfig> feeds;
  final DiscoverDetailConfig? booklistDetail;
  final DiscoverBookDetailConfig? bookDetail;

  /// 图片加载请求头：保留 `imageHeaders`，并在缺失 UA 时自动补齐 `headers` 中的 `User-Agent`。
  Map<String, String> get effectiveImageHeaders {
    final out = <String, String>{...imageHeaders};
    final hasUa = out.keys.any((k) => k.toLowerCase() == 'user-agent');
    if (!hasUa) {
      for (final entry in headers.entries) {
        if (entry.key.toLowerCase() == 'user-agent' &&
            entry.value.trim().isNotEmpty) {
          out['User-Agent'] = entry.value;
          break;
        }
      }
    }
    return Map<String, String>.unmodifiable(out);
  }

  DiscoverFeedConfig? feedById(String feedId) {
    for (final feed in feeds) {
      if (feed.id == feedId) return feed;
    }
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    if (description.isNotEmpty) 'description': description,
    'enabled': enabled,
    'mode': mode,
    'base_url': baseUrl,
    'cache_ttl_hours': cacheTtlHours,
    'min_request_interval_ms': minRequestIntervalMs,
    if (headers.isNotEmpty) 'headers': headers,
    if (imageHeaders.isNotEmpty) 'image_headers': imageHeaders,
    'feeds': feeds.map((f) => f.toJson()).toList(growable: false),
    if (booklistDetail != null) 'booklist_detail': booklistDetail!.toJson(),
    if (bookDetail != null) 'book_detail': bookDetail!.toJson(),
  };
}

/// 顶层荐书远程规则文档。
@immutable
class DiscoverRulesConfig {
  const DiscoverRulesConfig({
    this.schemaVersion = DiscoverConfigDefaults.supportedSchemaVersion,
    this.configVersion = '',
    this.configTtlHours = DiscoverConfigDefaults.defaultConfigTtlHours,
    this.defaultSourceId = '',
    this.sources = const <DiscoverSourceConfig>[],
  });

  factory DiscoverRulesConfig.fromJson(Map<String, dynamic> json) {
    final rawSources = json['sources'] as List<dynamic>? ?? const <dynamic>[];
    return DiscoverRulesConfig(
      schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 0,
      configVersion: (json['config_version'] as String? ?? '').trim(),
      configTtlHours:
          (json['config_ttl_hours'] as num?)?.toInt() ??
          DiscoverConfigDefaults.defaultConfigTtlHours,
      defaultSourceId: (json['default_source_id'] as String? ?? '').trim(),
      sources: rawSources
          .whereType<Map>()
          .map((e) => DiscoverSourceConfig.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }

  factory DiscoverRulesConfig.fromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('荐书规则 JSON 根节点必须为对象');
    }
    return DiscoverRulesConfig.fromJson(decoded);
  }

  factory DiscoverRulesConfig.bundledFallback() =>
      DiscoverRulesConfig.fromJsonString(kBundledDiscoverRulesJson);

  final int schemaVersion;
  final String configVersion;
  final int configTtlHours;
  final String defaultSourceId;
  final List<DiscoverSourceConfig> sources;

  List<DiscoverSourceConfig> get enabledSources =>
      sources.where((s) => s.enabled).toList(growable: false);

  DiscoverSourceConfig? sourceById(String id) {
    for (final source in enabledSources) {
      if (source.id == id) return source;
    }
    return null;
  }

  DiscoverSourceConfig? resolveDefaultSource() {
    if (defaultSourceId.isNotEmpty) {
      final matched = sourceById(defaultSourceId);
      if (matched != null) return matched;
    }
    final enabled = enabledSources;
    return enabled.isEmpty ? null : enabled.first;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema_version': schemaVersion,
    'config_version': configVersion,
    'config_ttl_hours': configTtlHours,
    'default_source_id': defaultSourceId,
    'sources': sources.map((s) => s.toJson()).toList(growable: false),
  };

  String toJsonString() => jsonEncode(toJson());
}

/// 校验远程或本地规则配置合法性，返回 null 表示通过。
String? validateDiscoverRulesConfig(DiscoverRulesConfig config) {
  if (config.schemaVersion != DiscoverConfigDefaults.supportedSchemaVersion) {
    return '不支持的规则 schema_version: ${config.schemaVersion}';
  }
  final enabled = config.enabledSources;
  if (enabled.isEmpty) {
    return '规则配置中至少需要包含 1 个已启用的荐书源';
  }
  final seenSourceIds = <String>{};
  for (final source in enabled) {
    if (source.id.isEmpty) {
      return '存在缺少 id 的荐书源';
    }
    if (!seenSourceIds.add(source.id)) {
      return '存在重复的荐书源 id: ${source.id}';
    }
    if (source.name.isEmpty) {
      return '荐书源 ${source.id} 缺少 name';
    }
    if (source.mode != 'html' && source.mode != 'json') {
      return '荐书源 ${source.id} 的 mode 仅支持 html 或 json';
    }
    final baseUri = Uri.tryParse(source.baseUrl);
    if (baseUri == null ||
        (baseUri.scheme != 'http' && baseUri.scheme != 'https') ||
        baseUri.host.isEmpty) {
      return '荐书源 ${source.id} 的 base_url 非法（仅支持 http/https）';
    }
    final bookDetail = source.bookDetail;
    if (bookDetail != null &&
        bookDetail.mode.isNotEmpty &&
        bookDetail.mode != 'html' &&
        bookDetail.mode != 'json') {
      return '荐书源 ${source.id} 的 book_detail.mode 仅支持 html 或 json';
    }
    if (source.feeds.isEmpty) {
      return '荐书源 ${source.id} 至少需要配置 1 个频道';
    }
    final seenFeedIds = <String>{};
    for (final feed in source.feeds) {
      if (feed.id.isEmpty || feed.title.isEmpty || feed.url.isEmpty) {
        return '荐书源 ${source.id} 存在不完整的频道配置（缺少 id/title/url）';
      }
      if (!seenFeedIds.add(feed.id)) {
        return '荐书源 ${source.id} 存在重复频道 id: ${feed.id}';
      }
      if (feed.mode.isNotEmpty && feed.mode != 'html' && feed.mode != 'json') {
        return '荐书源 ${source.id}/${feed.id} 的 mode 仅支持 html 或 json';
      }
      final effectiveMode = feed.mode.isNotEmpty ? feed.mode : source.mode;
      if (effectiveMode == 'html' && feed.itemsSelector.isEmpty) {
        return 'HTML 荐书源 ${source.id}/${feed.id} 缺少 items_selector';
      }
      final expandedSampleUrl = feed.url
          .replaceAll('{page}', '1')
          .replaceAll('{offset}', '0')
          .replaceAll('{limit}', '${feed.pageSize}');
      final resolvedUrl = resolveSafeHttpUrl(expandedSampleUrl, source.baseUrl);
      if (resolvedUrl.isEmpty) {
        return '荐书源 ${source.id}/${feed.id} 的 url 非法';
      }
    }
  }
  return null;
}

/// 校验远程配置 URL；允许留空（表示仅使用内置默认规则）。
String? validateDiscoverConfigUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return '远程配置地址必须以 http:// 或 https:// 开头并包含合法域名';
  }
  return null;
}

/// 基于 [baseUrl] 解析相对路径并确保协议安全（仅放行 http/https）。
String resolveSafeHttpUrl(String rawUrl, String baseUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.toLowerCase().startsWith('data:')) return '';
  final baseUri = Uri.tryParse(baseUrl.trim());
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null) return '';

  Uri resolved;
  if (parsed.hasScheme) {
    resolved = parsed;
  } else if (baseUri != null && baseUri.hasScheme && baseUri.host.isNotEmpty) {
    try {
      resolved = baseUri.resolveUri(parsed);
    } catch (_) {
      return '';
    }
  } else {
    return '';
  }

  if ((resolved.scheme != 'http' && resolved.scheme != 'https') ||
      resolved.host.isEmpty) {
    return '';
  }
  return resolved.toString();
}
