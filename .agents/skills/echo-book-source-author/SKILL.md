---
name: echo-book-source-author
description: 评估目标电子书网站是否可以转化为 Echo App 客户端声明式书源（book-sources.v1），并完成规则编写、静默校验、CLI 连通性测试与安全脱敏检查。当用户要求判断某网站能否转成书源、编写或调试 Echo 书源 JSON 配置、或排查书源搜索/登录/下载规则问题时使用本技能。
---

# Echo 书源可行性评估与编写指南（`book-sources.v1`）

本技能指导 Agent（或开发者）按标准工程流程完成：
1. **评估目标网站是否适合转为客户端静态书源**（不踩坑、不硬写无法绕过的反爬）；
2. **编写符合 `book-sources.v1` Schema 的纯声明式书源 JSON**；
3. **通过内置 Dart CLI 校验脚本做静态校验 + 只读连通性测试**；
4. **确保输出配置完全脱敏**（绝不包含账号密码、Cookie、私有反代或灰色站点测试凭据）。

---

## 一、核心约束（动手前必读）

Echo 的 `rule` 书源引擎是**纯声明式配置引擎**（JSON / HTML CSS / JSON-LD / XML + HTTP 多步编排 + 镜像故障转移），**刻意不内置 JS 引擎（QuickJS/V8）与隐藏 WebView**。因此：
- 请求参数、Headers、Cookies、Body、响应抽取、分页、下载跳转与异步轮询**必须可以用静态规则与 `{{...}}` 模板描述**；
- 书源系统支持 3 种驱动：
  - `rule`：声明式 JSON / HTML / XML 规则（绝大多数公开站、OpenAPI 站、静态列表 HTML 站适用）；
  - `opds`：原生 OPDS 1.2（Atom XML + OpenSearch）及 OPDS 2.0（JSON）书库；
  - `ebook_api`：兼容自建 `ebook-api` 后端（用于重度风控、需浏览器态或服务端下载缓存的站点）。
- 书架本地导入目前仅支持 **`.epub`** 与 **`.txt`**；若目标站点全站只有 `.pdf` / `.azw3` 且无格式转换服务，应明确告知用户该书源仅能搜索元数据或暂不建议导入有声书链路。

---

## 二、第一步：网站可行性嗅探与判定矩阵

在写任何 JSON 之前，先使用浏览器 DevTools（Network 面板）或 `curl`（带真实手机/桌面 Chrome `User-Agent`）检测目标站点的真实网络流量，重点观察以下 5 个请求阶段：
1. **健康探针 / 首页**：是否直接返回 HTTP 200 JSON / HTML？还是被 CF 拦截？
2. **搜书接口**：是开放 GET/POST JSON API，还是服务端渲染 HTML 搜索结果页？翻页是 `page=` 还是 Keyset `cursor=`？
3. **书籍详情**：搜索结果是否已含直链，还是需要打开详情页才能拿到简介/封面/下载链接？
4. **登录 / 凭据流**：搜索是否免登？下载是否需要登录？登录是否需要前置 CSRF Token 与 `Set-Cookie`？
5. **下载文件流**：点击下载是 200/302 直出 `.epub`/`.txt`，还是先返回异步任务（`queued -> ready` 轮询）？

### 判定决策表

| 站点特征 | 结论 | 推荐方案 |
| :--- | :--- | :--- |
| 标准 `/opds` Atom XML 或 OPDS 2.0 JSON（如 Calibre / Komga） | **直接可转** | 使用 `driver: "opds"`（仅需域名，5 行即可工作） |
| 开放或公开可请求 JSON API / OpenAPI v2，参数明文（含 `cursor` 分页 / CSRF Cookie 登录 / 异步任务轮询） | **直接可转** | 使用 `driver: "rule"`（`mode: "json"` + `auth` + `poll`） |
| 服务端直出 HTML（列表页 + 详情页 + 直接下载标签或 `<script type="application/ld+json">`） | **直接可转** | 使用 `driver: "rule"`（`mode: "html"` + 两步 `download.steps`），建议设 `min_request_interval_ms >= 800` |
| 需要正常 Browser `User-Agent` + `Origin`/`Referer` 才能过 CDN 校验，但无 JS 挑战 | **可转（需补头）** | 在 `headers` 中配置贴近 Chrome 的 `User-Agent`、`Accept`、`Origin`、`Referer` |
| 存在 **Cloudflare Turnstile / hCaptcha / 滑块验证码**、JS Cookie 质询（5 秒盾）、每次登录/下载强制图形验证码 | **不可直接转静态规则** | 诚实告知阻塞原因；如站方提供 Cookie 导入可仅作实验评估，或改用官方开放 API / `ebook_api` 自建桥 |
| 请求参数或下载链接依赖 **混淆 JS 签名**（如动态 AES、WASM token、Canvas 指纹）或内容受 DRM 加密 | **不可转客户端规则** | 明确判定为「不支持」，切勿强行拼脆弱正则 |
| 全站仅提供付费加密在线阅读、无合法 `.epub`/`.txt` 下载端点 | **不可转有声书书源** | 明确判定为「不支持」 |

---

## 三、第二步：编写 `book-sources.v1` 规则要点

详细字段请查阅 [Schema v1 完整参考](references/schema-v1.md)，典型范例可直接参照：
- JSON API + CSRF 登录 + 游标分页 + 异步轮询：[examples/json-api-auth.json](examples/json-api-auth.json)
- 两步 HTML 提取：[examples/html-two-step.json](examples/html-two-step.json)
- 原生 OPDS 书库：[examples/opds-catalog.json](examples/opds-catalog.json)

编写时的关键最佳实践：
1. **字段优先顺序**：先在 `response.vars` 提取中间变量（如 `download_url`），再在 `response.fields` 提取必填项 `ref`、`title` 与可选项。列表提取使用 `"all": true` 或 `"split_regex"`。
2. **含 `/` 或 `.` 的 JSON 键名**：不要用 `"formats.application/epub+zip"`（`.` 会错误切分部分路径或在 `image/jpeg` 场景语义不清），统一用 `"path_segments": ["formats", "application/epub+zip"]`。
3. **详情页 JSON-LD 提取**：如果 HTML 页把数据放在 `<script type="application/ld+json">`，使用 `selector: "script[type='application/ld+json']"` + `json_path: "description"`。
4. **反防盗链封面头**：若封面图片校验 `Referer` 或 `User-Agent`，在顶层设置 `image_headers`（App 内所有 `BookCover` 已透传 `SearchBook.imageHeaders`）。
5. **跨源下载不漏 Cookie**：如果最终文件地址在第三方 CDN（不同域名），务必在 `file_request` 设置 `"same_origin_credentials": false`；如果需站内 Session Cookie，则保持默认 `true`。
6. **区分匿名与登录校验**：当站方 `/auth/status` 匿名也返回 `200`（`user: null`）时，在 `auth.verify.steps` 里**把会返回 `401` 的受保护接口（例如 `/downloads/quota`）放在前面**，避免失效会话误判为正常。
7. **筛选能力精确声明**：只声明网站真正支持的 `search.filters`（`extensions` / `languages` / `year_from` / `year_to` / `order`），Echo 搜索界面会自动隐藏未声明的筛选条件。
8. **镜像池与反爬虫保护**：如果站方有多镜像域名，尽量列出多个可用镜像并在 `errors.bot_protection` 声明挑战状态码（如 `[403, 503]` + `"html_body": true`），引擎会自动切换并缓存健康节点 10 分钟。

---

## 四、第三步：校验、干跑测试与安全审计

### 1. 运行静默校验与连通性干跑（必需）

在 `echo-app` 根目录运行纯 Dart 校验脚本（无需模拟器或 Flutter UI）：

```bash
cd /home/hancel/project/audio_book/echo-app

# 1) 静态 Schema + 模板占位符 + 正则表达式校验
dart run .agents/skills/echo-book-source-author/scripts/validate_source.dart \
  path/to/your-source.json --strict

# 2) 指定书源 id 发起只读真实搜书 + 详情页干跑（不消耗下载配额）
dart run .agents/skills/echo-book-source-author/scripts/validate_source.dart \
  path/to/your-source.json --source your_source_id --search "红楼梦" --probe --strict
```

### 2. 下载验证注意事项
- 若书源免登录直下：可按需确认最终 EPUB 响应 `Content-Type` 或前 4 字节为 `PK\x03\x04`（ZIP/EPUB 魔数）。
- 若书源需要账号或限制每日配额：先向用户说明需要测试账号且**最多消耗 1 次下载额度**，征得允许后再执行最小化验证，禁止把任何账号/密码/Cookie 写入 `.json` 文件或示例文档。

### 3. 提交前安全自检清单
- [ ] JSON 中没有任何硬编码账号、密码、Token、Session Cookie 或用户私有反代地址；
- [ ] 所有域名均使用 `http://` 或 `https://`，无 `javascript:` / `data:`；
- [ ] 若包含爬虫抓取（`mode: "html"`），已设置合理限流 `min_request_interval_ms`（如 500–1000ms）；
- [ ] `validate_source.dart --strict` 退出码为 `0`。

---

## 五、第四步：告知用户如何导入 Echo App

向用户交付最终书源 JSON 后，指引其通过以下任一方式导入：
1. **单文件 / 剪贴板导入**：打开 Echo →「我的」→「书源管理」→ 右上角 `+` →「粘贴 / 导入 JSON」→ 选择文件或粘贴 JSON 文本。
2. **远程订阅导入**：将 Bundle JSON 托管到 HTTPS URL 后，在「书源管理 → + → 远程订阅 URL」填入地址并开启自动更新（支持每隔 `config_ttl_hours` 刷新，且不会覆盖用户的镜像选择、反代与账号凭据）。
3. **如实告知使用限制**：明确说明该书源是否需账号登录、每日限额、支持格式（EPUB/TXT）以及是否建议在国内网络下配置反代前缀。
