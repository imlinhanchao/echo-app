# `book-sources.v1` Schema 快速参考

## 1. 顶层结构

支持 **Single Source**（直接以单源对象为根）或 **Bundle**（用于订阅与合集）：

```jsonc
{
  "schema_version": 1,          // 必填，固定 1
  "config_version": "2026.11.27.1", // 可选，Bundle 版本标识
  "config_ttl_hours": 24,       // 可选，订阅后台刷新周期（默认 24）
  "name": "合集名称",
  "sources": [ /* BookSourceDefinition[] */ ]
}
```

## 2. `BookSourceDefinition` 字段

```jsonc
{
  "schema_version": 1,
  "id": "my_source",            // [a-zA-Z0-9_-]{1,64}
  "name": "书源名称",
  "description": "简介",
  "driver": "rule",             // "rule" | "opds" | "ebook_api"
  "enabled": true,
  "domains": ["https://example.org"], // 也兼容单字符串 "base_url"
  "headers": {},
  "image_headers": {},
  "min_request_interval_ms": 0,
  "max_mirror_attempts": 2,
  "supported_formats": ["epub", "txt"],
  "probe": { "method": "GET", "path": "/", "expect_status": [200], "timeout_ms": 8000 },
  "auth": { /* 见第 3 节 */ },
  "errors": { /* 见第 4 节 */ },
  "search": { /* 见第 5 节 */ },
  "detail": { /* 见第 6 节 */ },
  "download": { /* 见第 7 节 */ },
  "opds": { "search_url": "", "prefer_formats": ["epub", "txt"] },
  "ebook_api": { "remote_provider": "zlib" }
}
```

## 3. `auth` 认证配置

```jsonc
"auth": {
  "required": false,             // 全源需登录设为 true
  "required_for": ["download"],  // 可单独限制 "search" 或 "download"
  "inject": {
    "same_origin_only": true,    // 跨域跳走时自动剥离 Cookie / Auth 头
    "headers": { "X-Api-Key": "{{cred.api_key}}" },
    "cookies": { "sid": "{{cred.session_id}}" },
    "query": {},
    "basic_auth": { "username": "{{cred.username}}", "password": "{{cred.password}}" }
  },
  "modes": [
    {
      "id": "password",
      "label": "账号密码",
      "fields": [
        { "key": "email", "label": "邮箱", "type": "email", "required": true, "hint": "" }
        // type 支持: text | email | password | multiline
      ],
      "login": {                 // 省略 login 时，用户输入直接保存为凭据键值对
        "pre_steps": [ /* BookSourceStepConfig[] */ ],
        "method": "POST",
        "path": "/api/login",    // 或绝对 "url"
        "content_type": "json",  // "none" | "form" | "json"
        "headers": {},
        "cookies": {},
        "body": { "email": "{{input.email}}", "password": "{{input.password}}" },
        "response_mode": "json", // "json" | "html" | "xml"
        "save_credentials": { "email": { "path": "data.email" } },
        "save_cookie_credentials": { "session_id": "sid" }
      }
    }
  ],
  "verify": {
    "steps": [ /* 可选多步，如先查 quota 判 401，再查 me */ ],
    "method": "GET",
    "path": "/api/me",           // 无 steps 时单步请求
    "response_mode": "json",
    "fields": {
      "email": { "path": "data.email" },
      "daily_used": { "path": "data.used" },
      "daily_limit": { "path": "data.limit" },
      "daily_remaining": { "path": "data.remaining" },
      "quota_known": { "const_value": "true" },
      "premium": { "path": "data.vip" }
    }
  }
}
```

## 4. `errors` 错误识别与分类

```jsonc
"errors": {
  "bot_protection": {
    "statuses": [403, 503],
    "html_body": true,
    "has_location_header": false
  },
  "envelope": {
    "success_path": "success",
    "success_values": [1, true],
    "error_path": "error.message",
    "error_code_path": "error.code"
  },
  "rules": [
    {
      "code": "QUOTA_EXCEEDED",   // Echo 标准码
      "statuses": [429],
      "error_code_regex": "quota|limit",
      "error_regex": "",
      "require_unauthenticated": false
    }
  ]
}
```

标准错误码：`SESSION_EXPIRED`、`QUOTA_EXCEEDED`、`NOT_FOUND`、`PROVIDER_NOT_CONFIGURED`、`PROVIDER_BLOCKED`、`PROVIDER_UNAVAILABLE`。

## 5. `search` 搜索规则

```jsonc
"search": {
  "request": {
    "method": "GET",             // "GET" | "POST"
    "path": "/api/search",       // 或 "url"
    "content_type": "none",      // "none" | "form" | "json"
    "headers": {},
    "query": { "q": "{{query.q}}", "page": "{{query.page}}" },
    "body": {},
    "page_size": 20
  },
  "filters": {
    "extensions": { "param": "ext", "mode": "repeat", "transform": "lower", "map": {} },
    "languages":  { "param": "lang", "mode": "join", "join_with": ",", "map": {} },
    "year_from":  { "param": "year_from", "omit_if_zero": true },
    "year_to":    { "param": "year_to", "omit_if_zero": true },
    "order":      { "param": "sort", "options": [{ "value": "", "label": "相关" }] }
  },
  "response": {
    "mode": "json",              // "json" | "html" | "xml"
    "items_path": "results",     // JSON 列表路径
    "items_selector": "",        // HTML/XML 条目选择器
    "pagination": {
      "current_page_path": "",
      "total_pages_path": "",
      "total_count_path": "",
      "page_size": 20,
      "next_page_path": "",
      "next_page_selector": "",
      "cursor_param": "",
      "next_cursor_path": ""
    },
    "vars": { /* 中间变量提取规则 */ },
    "fields": {
      "ref": {}, "title": {}, "authors": {},
      "year": {}, "publisher": {}, "language": {},
      "format": {}, "size": {}, "isbn": {},
      "cover_url": {}, "description": {}, "source_url": {}
    }
  }
}
```

## 6. `detail` 详情规则

```jsonc
"detail": {
  "method": "GET",
  "path": "/book/{{book.ref}}",
  "headers": {},
  "response_mode": "html",       // "json" | "html" | "xml"
  "root_path": "",               // JSON 时可选根节点路径
  "vars": {},
  "fields": {}
}
```

## 7. `download` 下载与步骤流水线

```jsonc
"download": {
  "ref_separator": ":",          // 生成 {{book.ref_parts.N}}
  "steps": [
    {
      "id": "step1",
      "method": "GET",
      "path": "...",
      "url": "",
      "content_type": "none",
      "headers": {},
      "cookies": {},
      "query": {},
      "body": {},
      "response_mode": "json",
      "extract": { "url": { "path": "url", "resolve_url": true } },
      "extract_cookies": { "ck": "cookie_name" },
      "follow_while_url_regex": "^/redirect",
      "max_hops": 3,
      "poll": {
        "method": "GET",
        "path": "/status?id={{step.step1.id}}",
        "url": "",
        "headers": {},
        "cookies": {},
        "interval_ms": 3000,
        "max_attempts": 40,
        "until_path": "state",
        "until_value": "ready",
        "fail_path": "state",
        "fail_value": "failed",
        "fail_message_path": "error",
        "extract": { "url": { "path": "url", "resolve_url": true } }
      }
    }
  ],
  "file_request": {
    "url": "{{step.step1.url}}", // 或 "path"
    "method": "GET",
    "headers": {},
    "same_origin_credentials": true,
    "retries": 3,
    "stall_timeout_seconds": 120,
    "max_bytes": 524288000
  }
}
```

## 8. `BookSourceExtractRule` 支持属性

| 类别 | 属性名 |
| :--- | :--- |
| **JSON** | `path`, `paths`, `path_segments` |
| **HTML/XML** | `selector`, `selectors`, `attr`, `attrs`, `all`, `preserve_paragraphs`, `next_sibling`, `after_heading`, `heading_selector`, `json_path`, `max_items` |
| **Cookie / 组合** | `cookie`, `template`, `const_value`, `first_of`, `when_present` |
| **后处理** | `strip_prefix`, `strip_suffix`, `regex`, `regex_group`, `replace_pattern`, `replace_with`, `prefix`, `transform` (`lower`/`upper`/`trim`), `resolve_url`, `split_regex`, `join_with` |

## 9. 模板命名空间

`{{origin}}`、`{{query.q|page|limit|offset}}`、`{{book.ref|ref_parts.N|var.KEY}}`、`{{input.KEY}}`、`{{cred.KEY}}`、`{{step.ID.KEY}}`、`{{vars.KEY}}`、`{{fields.KEY}}`、`{{rand.uuid}}`、`{{rand.id_24}}`。
