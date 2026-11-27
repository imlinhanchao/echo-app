# Echo 声明式书源配置指南（`book-sources.v1`）

从 `book-sources.v1` 起，Echo 支持直接在客户端加载声明式书源配置来搜书与下载电子书，无需部署 `ebook-api` 中转服务。同时仍保留 `ebook_api` 驱动，方便重度自建用户继续复用现有服务端。

---

## 一、核心架构与 3 层隔离设计

Echo 书源系统将“规则、用户偏好、私密凭据”严格隔离在 3 个存储层中，确保订阅刷新安全且导出配置零泄密：

1. **规则注册表层（`book_sources/registry.json`）**
   - 存放内置公版书源、远程订阅拉取的 Bundle 规则、以及用户本地导入的纯规则定义（`BookSourceDefinition`）。
   - 远程订阅到期（默认 `config_ttl_hours: 24`）后台自动刷新或手动点击更新时，只覆盖该订阅下的规则定义。
2. **用户配置覆盖层（`book_sources/overlays.json`）**
   - 存放每个书源的个人开关状态（`enabled`）、首选镜像（`preferred_domain`）、自定义镜像域名（`custom_domain`）、反向代理前缀（`proxy_prefix`）以及当前选中的搜索书源（`active_source_id`）。
   - **订阅更新绝不会覆盖用户的网络配置或开关选择。**
3. **凭据保险箱层（`FlutterSecureStorage`：`echo_book_source_creds_v1`）**
   - 存放用户登录换取的 Cookie / Token / Basic Auth 凭据与最近一次校验的账号额度摘要。
   - **单源导出与配置分享时**，仅从白名单序列化 `BookSourceDefinition`（`toExportJson()`），从数据结构上物理隔绝凭据与个人域名覆盖配置。

---

## 二、三种书源驱动（`driver`）

| `driver` 值 | 适用场景 | 核心能力 |
| :--- | :--- | :--- |
| `rule` | 常规 JSON API、HTML 网页、XML 接口 | 纯声明式多节点镜像故障转移、动态表单登录（含 CSRF 与 `Set-Cookie`）、游标/页码分页、详情补全、异步轮询下载、反爬识别与错误映射 |
| `opds` | Calibre / Komga / 标准 OPDS 1.2 (Atom XML) & OPDS 2.0 (JSON) 书库 | 自动发现 OpenSearch `rel="search"` 搜索模板、支持 `{searchTerms}` / `{startPage}` / `{count}`、多格式优先级匹配（`prefer_formats`）、Basic / Bearer 认证；无服务端搜索时退化为根目录本地关键词过滤 |
| `ebook_api` | 自建 `ebook-api` 后端兼容桥接 | 复用已有 `ebook-api` 实例，支持自定义 `remote_provider`（如 `zlib`）与旧版配置首次启动自动迁移 |

> **安全边界**：`rule` 引擎为纯声明式引擎，**不内置 JavaScript 执行引擎（如 QuickJS）或隐藏 WebView**。遇到 Cloudflare Turnstile 交互式人机验证、AES/RSA 动态签名脚本加密的站点时，无法直接作为静态规则书源，建议使用站点官方 OPDS/API 或自建后端封装。

---

## 三、内置公版书源

App 默认内置 3 个可开箱即用的公版书源（定义于 `assets/bundled-book-sources.json`）：

1. **`gutendex`（古登堡公版书库）**：基于 `gutendex.com` JSON API，7 万+多语种公版名著，支持语言、格式（EPUB / TXT）与排序筛选，免登录直连下载。
2. **`standard_ebooks`（Standard Ebooks）**：基于 `standardebooks.org` 两步 HTML 提取（搜索列表 `ol.ebooks-list > li[typeof='schema:Book']` + 详情页提取 `a.epub[href$='.epub']`），免登录下载人工精排 EPUB。
3. **`wenshuoge`（文硕阁）**：基于 `www.wenshuoge.com` v2 OpenAPI + JSON-LD 详情提取。**搜书完全免登录**（支持 Keyset `cursor` 游标分页）；**下载 EPUB 需免费账号**（通过 `/api/v2/auth/csrf` + `password/login` 换取 `wenshuoge_session` Cookie，并支持异步 `poll` 状态轮询与每日额度校验 `/api/v2/downloads/quota`）。

---

## 四、Schema v1 结构总览

导入配置文件同时支持两种根结构：
- **单条书源对象（Single Source）**：直接书写一个源对象（可用于单源分享）。
- **书源集合（Bundle）**：适合作为远程订阅地址托管多个书源：

```json
{
  "schema_version": 1,
  "config_version": "2026.11.27.1",
  "config_ttl_hours": 24,
  "name": "示例公开书源合集",
  "sources": [
    { ... }
  ]
}
```

### 单条书源顶层字段（`BookSourceDefinition`）

| 字段 | 必填 | 类型 | 说明 |
| :--- | :---: | :--- | :--- |
| `schema_version` | 是 | `int` | 当前固定为 `1` |
| `id` | 是 | `string` | 唯一标识，仅允许 `[a-zA-Z0-9_-]`，最长 64 字符 |
| `name` | 是 | `string` | App 内展示名称 |
| `description` | 否 | `string` | 书源说明与账号/使用提示 |
| `driver` | 是 | `string` | `rule` \| `opds` \| `ebook_api` |
| `enabled` | 否 | `bool` | 默认启用状态（用户手动切换开关后会写入 overlay，不受更新影响） |
| `domains` | 是 | `string[]` | 候选基地址列表（仅允许 `http://` / `https://`，也可单写 `base_url`） |
| `headers` | 否 | `object` | 每次请求默认附带的 HTTP 请求头（如 `User-Agent`、`Accept`、`Origin`） |
| `image_headers` | 否 | `object` | 加载书籍封面图时附带的请求头（如防盗链 `Referer`） |
| `min_request_interval_ms` | 否 | `int` | 同一书源请求节流最小间隔（毫秒） |
| `max_mirror_attempts` | 否 | `int` | 单次操作最多尝试多少个候选镜像域名，默认 `2` |
| `supported_formats` | 否 | `string[]` | 声明支持格式（如 `["epub", "txt"]`），仅用于元数据/展示 |
| `probe` | 否 | `object` | 节点测速/健康检查规则（`method`、`path`、`expect_status`、`timeout_ms`） |
| `auth` | 否 | `object` | 登录表单、Cookie/Header 注入及账号状态校验规则 |
| `errors` | 否 | `object` | 反爬检测、JSON 错误信封解析与状态码映射规则 |
| `search` | 规则源必填 | `object` | 搜索请求、筛选器映射、分页与字段提取规则 |
| `detail` | 否 | `object` | 书籍详情补全（用于补全简介、大图或解析延迟下载链接） |
| `download` | 规则源必填 | `object` | 多步跳转/异步轮询与最终流式下载规则 |
| `opds` | OPDS 可选 | `object` | `search_url`（覆盖 OpenSearch 自动发现）与 `prefer_formats` |
| `ebook_api` | bridge 可选 | `object` | `remote_provider`（默认 `zlib`） |

---

## 五、模板变量语法（`{{...}}`）

可在请求 `url`、`path`、`query`、`headers`、`cookies`、`body` 以及提取规则 `template` 中使用：

| 变量路径 | 含义 |
| :--- | :--- |
| `{{origin}}` | 当前选中的书源域名（不含末尾 `/`） |
| `{{query.q}}` | 用户输入的搜索关键词 |
| `{{query.page}}` | 当前页码（从 `1` 开始） |
| `{{query.limit}}` | 每页条数 |
| `{{query.offset}}` | 偏移量 `(page - 1) * limit` |
| `{{book.ref}}` | 书籍唯一引用标识 `ref` |
| `{{book.ref_parts.0}}` | 按 `download.ref_separator`（默认 `:`）切分后的第 N 段 |
| `{{book.var.<key>}}` | 在搜索/详情 `vars` 中预提取并缓存的变量（若冷缓存为空，下载前会自动回退请求 `detail` 补全） |
| `{{input.<field_key>}}` | 登录表单提交时用户输入的字段值 |
| `{{cred.<cred_key>}}` | SecureStorage 中已保存的凭据键值 |
| `{{step.<step_id>.<key>}}` | 前置步骤（`pre_steps` / `steps`）中 `extract` 或 `extract_cookies` 提取到的值 |
| `{{vars.<key>}}` | 同条记录提取阶段先求值的 `vars` 变量 |
| `{{fields.<key>}}` | 同条记录提取阶段已求值的标准字段（如 `fields.ref`） |
| `{{rand.uuid}}` | 随机生成的 UUID v4 |
| `{{rand.id_24}}` | 24 位随机字母数字串（常用于 `visitorId`） |

> 同一次请求构建上下文中，`{{rand.uuid}}` 与 `{{rand.id_24}}` 会缓存复用；不同步骤或多次请求间重新生成。

---

## 六、声明式提取器（`BookSourceExtractRule`）

### 1. 定位能力

- **JSON 定位**
  - `path`: 点分路径，如 `"data.user.email"` 或 `"results.0.id"`。
  - `paths`: 按顺序回退尝试多个路径。
  - `path_segments`: **精确键名数组**，用于键名本身含 `.` 或 `/` 的 JSON 对象，例如 `["formats", "application/epub+zip"]`。
- **HTML 定位**
  - `selector` / `selectors`: CSS 选择器（列表按顺序取首个非空匹配）。
  - `attr` / `attrs`: 提取属性值（如 `href`、`src`、`about`）；留空则提取清洗后的文本。
  - `preserve_paragraphs`: 设为 `true` 时保留段落空行（`\n\n`），适合详情页内容简介。
  - `next_sibling`: 选取当前元素紧邻的下一个指定标签兄弟节点（`"*"` 匹配任意标签）。
  - `after_heading` / `heading_selector`: 在标题文本匹配 `after_heading` 的标题之后选取下一个有效内容元素。
  - `json_path`: 当 HTML 元素本身是 `<script type="application/ld+json">` 时，先解析脚本内 JSON，再按点分路径取值。
- **XML 定位**
  - `selector` 支持简化的元素路径与属性等值过滤，如 `link[rel='acquisition'][type='application/epub+zip']`。
- **组合与常量**
  - `cookie`: 从响应 `Set-Cookie` 提取指定 Cookie（或用 `extract_cookies`）。
  - `first_of`: 顺序尝试一组子规则，返回首个非空结果。
  - `when_present`: 条件探针，仅当探针规则非空时继续求值外层规则（如配合 `const_value: "epub"` 检测字段是否存在）。
  - `const_value`: 直接输出固定常量。
  - `template`: 使用 `{{...}}` 模板组合其他已提取字段或变量。

### 2. 后处理管道

同一规则上提取到原始值后，依次执行以下转换：

1. `strip_prefix` / `strip_suffix`：剥离指定前缀/后缀。
2. `regex` / `regex_group`：正则提取第 N 个捕获组（默认组 0）。
3. `replace_pattern` / `replace_with`：正则替换。
4. `prefix`：拼接前缀。
5. `transform`：`lower` \| `upper` \| `trim`。
6. `resolve_url`: `true` 时基于响应地址补全为绝对 `http(s)` URL，同时自动拦截 `javascript:` 与 `data:` 危险协议。
7. 列表字段（如 `authors`）：支持 `all: true`（收集所有匹配项）或 `split_regex`（按正则切分字符串）；单值字段可用 `join_with` 拼接数组（默认 `" / "`）。

### 3. 搜索与详情常用标准字段名

- 必填（搜索列表）：`ref`、`title`
- 可选：`authors`、`year`、`publisher`、`language`、`format`、`size`、`isbn`、`cover_url`、`description`、`source_url`
- 中间变量（写入 `BookSourceSearchBook.sourceVars`）：定义在 `response.vars` 或 `detail.vars` 下（如 `download_url`）。

---

## 七、筛选、分页、认证与下载进阶

### 1. 动态筛选（`search.filters`）

App 会根据当前活跃书源的 `search.filters` 自动显示或隐藏界面中的筛选控件（支持的才显示，不支持的隐藏）：

- `extensions`：映射前端 `EPUB` 快捷筛选（对应结果页「仅 EPUB」chip）。
- `languages`：映射语言筛选。
- `year_from` / `year_to`：映射出版年份区间，`omit_if_zero: true` 时值为 `0` 自动省略。
- `order`：映射排序参数，支持 `options: [{"value": "", "label": "相关度"}, ...]`。

每个列表型筛选规则均支持三种传递模式（`mode`）：
- `single`（默认）：只传第一个值。
- `repeat`：重复添加同名参数（例如 `?extensions[]=epub&extensions[]=txt`）。
- `join`：使用 `join_with`（默认 `,`）拼接成一个参数值。

### 2. 分页规则（`search.response.pagination`）

支持以下 4 种常见分页模式（可组合）：
1. **页码与总页数**：`current_page_path` + `total_pages_path`
2. **总数推算**：`total_count_path` + `page_size`
3. **下一页链接检测**：`next_page_path`（JSON）或 `next_page_selector`（HTML）
4. **Keyset 游标分页**：`cursor_param`（下一页 query 参数名）+ `next_cursor_path`（响应 JSON 中的游标字段路径；第 1 页不传，翻第 2 页起自动回填并按查询词 + 筛选签名缓存）。

### 3. 认证与凭据注入（`auth`）

- `required`: `true` 表示全源需要登录；`false` + `required_for: ["download"]` 表示**搜书免登、下载前登录**。
- `inject`：声明如何将凭据注入后续请求（`headers`、`cookies`、`query`、`basic_auth`，默认 `same_origin_only: true` 自动在跨域跳转时剥离敏感头与 Cookie）。
- `modes`：支持多种登录方式：
  - 若配置了 `login` 对象，表单提交时会依次执行 `pre_steps`（例如获取 CSRF Token + Cookie）、提交主登录请求，并用 `save_credentials` 与 `save_cookie_credentials` 提取结果存入 SecureStorage。
  - 若未配置 `login`（例如纯 Cookie 导入或 API Key / OPDS Basic 账号模式），表单提交会直接将用户输入保存为凭据。
- `verify`：支持单步 `path` 或多步 `steps`（例如先查配额接口 `401` 判失效，再查用户信息接口），提取字段规范键名：`email`、`daily_used`、`daily_limit`、`daily_remaining`、`quota_known`、`premium`。

### 4. 反爬识别与错误映射（`errors`）

- `bot_protection`：`statuses`（如 `[403, 503]`）配合 `html_body: true` / `has_location_header: true`，命中时立即将该域名标记为不健康，自动故障转移到镜像池的下一候选节点（健康节点缓存 10 分钟）。
- `envelope`：从业务信封提取上游报错与错误码（`success_path`、`success_values`、`error_path`、`error_code_path`）。
- `rules`：将 HTTP 状态码或上游 `error_code_regex` / `error_regex` 归一化映射为 Echo 标准错误码：`SESSION_EXPIRED`、`QUOTA_EXCEEDED`、`NOT_FOUND`、`PROVIDER_NOT_CONFIGURED`、`PROVIDER_BLOCKED`、`PROVIDER_UNAVAILABLE`。
  - 若某规则设置了 `require_unauthenticated: true`，则仅在当前请求未携带有效登录态时命中。

### 5. 多步下载与异步轮询（`download`）

- `steps`：按顺序执行的 HTTP 预处理步骤，支持：
  - `follow_while_url_regex` + `max_hops`：当提取出的跳转地址仍为站内中间页时自动多跳追踪（如先打开详情/跳转页再取直链）。
  - `poll`：提交下载任务后若上游返回异步状态（如 `queued`），按 `interval_ms`（默认 3000 毫秒）与 `max_attempts`（默认 40 次）定期轮询，直到 `until_path == until_value`（提取 `url`），或在命中 `fail_path == fail_value` 时抛出上游错误消息。
- `file_request`：最终流式下载请求：
  - 支持 `same_origin_credentials`（默认 `true`；下载外链 CDN/对象存储文件且不需站内 Cookie 时建议设为 `false`）。
  - 内置指数退避重试（默认 `retries: 3`）、流停滞超时（`stall_timeout_seconds`）、500MB 上限保护、RFC 5987 `Content-Disposition` 文件名解码与扩展名安全校验（目前书架支持导入 `.epub` 与 `.txt`）。

---

## 八、反向代理与镜像优先策略

当部分公版或自建站存在地区直连不稳定时，用户无需修改书源规则，直接在 **书源详情页 → 域名、镜像与反代** 中即可按需配置：

1. **镜像测速与切换**：点击「测试所有节点延迟」，一键切换更快镜像。
2. **自定义备用域名**：添加用户私有的可用镜像，优先级高于订阅内置域名列表。
3. **反向代理前缀（`proxy_prefix`）**：支持两种写法：
   - **拼接模式**：`https://proxy.example.com/` -> 自动补齐末尾 `/` 并直接拼接目标完整 URL（如 `https://proxy.example.com/https://origin.example.org/...`）。
   - **占位符模式**：`https://proxy.example.com/?url={url}` -> 将目标完整 URL 进行 `Uri.encodeComponent` URL 编码后替换 `{url}`。

---

## 九、完整参考模板（JSON API + 登录态 + 异步轮询）

```json
{
  "schema_version": 1,
  "id": "demo_open_catalog",
  "name": "示例开放书阁",
  "description": "演示 JSON API 搜索、CSRF 登录、配额校验与异步下载轮询",
  "driver": "rule",
  "enabled": true,
  "domains": [
    "https://library.example.org"
  ],
  "headers": {
    "Accept": "application/json",
    "Origin": "https://library.example.org"
  },
  "min_request_interval_ms": 500,
  "supported_formats": ["epub"],
  "probe": {
    "path": "/api/health",
    "timeout_ms": 8000
  },
  "auth": {
    "required": false,
    "required_for": ["download"],
    "inject": {
      "cookies": {
        "session_id": "{{cred.session_id}}"
      }
    },
    "modes": [
      {
        "id": "password",
        "label": "账号密码",
        "fields": [
          { "key": "email", "label": "邮箱", "type": "email" },
          { "key": "password", "label": "密码", "type": "password" }
        ],
        "login": {
          "pre_steps": [
            {
              "id": "csrf",
              "method": "GET",
              "path": "/api/csrf",
              "extract": { "token": { "path": "data.token" } },
              "extract_cookies": { "csrf_cookie": "csrf_token" }
            }
          ],
          "method": "POST",
          "path": "/api/login",
          "content_type": "json",
          "headers": { "X-CSRF-Token": "{{step.csrf.token}}" },
          "cookies": { "csrf_token": "{{step.csrf.csrf_cookie}}" },
          "body": { "email": "{{input.email}}", "password": "{{input.password}}" },
          "save_credentials": {
            "email": { "path": "data.user.email" }
          },
          "save_cookie_credentials": {
            "session_id": "session_id"
          }
        }
      }
    ],
    "verify": {
      "steps": [
        {
          "id": "quota",
          "method": "GET",
          "path": "/api/quota",
          "extract": {
            "daily_used": { "path": "data.used" },
            "daily_limit": { "path": "data.limit" },
            "daily_remaining": { "path": "data.remaining" }
          }
        },
        {
          "id": "profile",
          "method": "GET",
          "path": "/api/me",
          "extract": { "email": { "path": "data.email" } }
        }
      ],
      "fields": {
        "email": { "template": "{{step.profile.email}}" },
        "daily_used": { "template": "{{step.quota.daily_used}}" },
        "daily_limit": { "template": "{{step.quota.daily_limit}}" },
        "daily_remaining": { "template": "{{step.quota.daily_remaining}}" }
      }
    }
  },
  "errors": {
    "envelope": {
      "error_path": "error.message",
      "error_code_path": "error.code"
    },
    "rules": [
      { "code": "QUOTA_EXCEEDED", "statuses": [429], "error_code_regex": "quota|daily_limit" },
      { "code": "SESSION_EXPIRED", "statuses": [401], "error_code_regex": "login_required|unauthorized" }
    ]
  },
  "search": {
    "request": {
      "method": "GET",
      "path": "/api/books",
      "query": { "q": "{{query.q}}", "limit": "{{query.limit}}" },
      "page_size": 20
    },
    "response": {
      "mode": "json",
      "items_path": "data.items",
      "pagination": {
        "total_count_path": "meta.total",
        "page_size": 20,
        "cursor_param": "cursor",
        "next_cursor_path": "meta.nextCursor"
      },
      "fields": {
        "ref": { "path": "id" },
        "title": { "path": "title" },
        "authors": { "path": "authors", "all": true },
        "format": { "const_value": "epub" },
        "cover_url": { "path": "cover", "resolve_url": true }
      }
    }
  },
  "download": {
    "steps": [
      {
        "id": "request_file",
        "method": "POST",
        "path": "/api/downloads",
        "content_type": "json",
        "body": { "bookId": "{{book.ref}}", "requestId": "{{rand.uuid}}" },
        "extract": {
          "state": { "path": "data.state" },
          "task_id": { "path": "data.taskId" },
          "url": { "path": "data.url", "resolve_url": true }
        },
        "poll": {
          "method": "GET",
          "path": "/api/downloads/{{step.request_file.task_id}}",
          "interval_ms": 2000,
          "max_attempts": 30,
          "until_path": "data.state",
          "until_value": "ready",
          "fail_path": "data.state",
          "fail_value": "failed",
          "fail_message_path": "data.message",
          "extract": { "url": { "path": "data.url", "resolve_url": true } }
        }
      }
    ],
    "file_request": {
      "url": "{{step.request_file.url}}",
      "same_origin_credentials": true
    }
  }
}
```

---

## 十、开发与校验 CLI 工具

仓库内自带书源校验脚本与 Agent Authoring Skill（`echo-book-source-author`）：

```bash
cd echo-app
# 校验静态 JSON 结构与规则合法性
dart run .agents/skills/echo-book-source-author/scripts/validate_source.dart path/to/source.json

# 指定某条书源并做真实搜书 + 详情连通性干跑（仅发起只读搜索）
dart run .agents/skills/echo-book-source-author/scripts/validate_source.dart \
  assets/bundled-book-sources.json --source standard_ebooks --search "pride" --strict
```
