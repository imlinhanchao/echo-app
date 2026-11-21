# 回声 · 客户端 API 契约

客户端只对接 **echo-service**（Go 后端，默认 `http://<host>:8090`），不直连 TTS 服务。
所有接口前缀 `/api`，请求/响应均为 JSON。

- 服务地址：构建期通过 `--dart-define=ECHO_BASE_URL=...` 注入（默认 `http://127.0.0.1:8090`；局域网真机使用 `http://192.168.50.200:8090`；模拟器访问宿主机用 `http://10.0.2.2:8090`）。
- 鉴权：`Authorization: Bearer echo_pat_...`（媒体文件同样带此头）。
- 错误契约：`{"error":{"code":"...","message":"..."}}`，客户端统一转为 `ApiException` 并直显 `message`。

实现位置：[`lib/core/api/echo_api.dart`](../lib/core/api/echo_api.dart)、模型 [`lib/core/api/models.dart`](../lib/core/api/models.dart)。

---

## 1. 认证

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/auth/token` | 账密换 Bearer Token |
| POST | `/api/auth/token/refresh` | 轮换 Token（旧 Token 立即失效） |
| POST | `/api/auth/token/revoke` | 撤销当前 Token |
| GET | `/api/auth/me` | 当前用户与会话 |
| POST | `/api/auth/register` | 注册（客户端注册后自动登录） |

请求/响应要点：

```jsonc
// POST /api/auth/token
{ "email": "...", "password": "...", "name": "设备名" }
→ { "token": "echo_pat_...", "token_type": "Bearer", "expires_at": "...", "user": { "id": 1, "email": "..." } }

// GET /api/auth/me
→ { "user": {...}, "registration_open": true }
```

客户端行为：401 时自动 `refresh` 并重放原请求一次；refresh 也失败则清凭据并回到登录页。

---

## 2. 书源与账号（zlib）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/providers` | 书源列表 + 当前账号状态/配额 |
| PUT | `/api/providers/{id}/account` | 保存凭据并验证 |
| POST | `/api/providers/{id}/account/verify` | 重新验证并刷新配额 |
| DELETE | `/api/providers/{id}/account` | 删除凭据 |

```jsonc
// PUT .../account（两种模式）
{ "mode": "password", "domain": "z-library.sk", "email": "...", "password": "..." }
{ "mode": "cookies",  "domain": "z-library.sk", "remix_userid": "...", "remix_userkey": "..." }

// 响应
{ "account": { "configured": true, "status": "ok", "email": "...",
                "daily_used": 3, "daily_limit": 10, "daily_remaining": 7,
                "quota_known": true } }
```

`status` 为 `needs_login` / `error` 时，客户端在书源页与搜索结果错误横幅提示「去配置账号」。

---

## 3. 搜索

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/search?provider=zlib&q=&page=&limit=&ext=&lang=&year_from=&year_to=&order=` | 搜索 |
| GET | `/api/providers/{id}/books/{ref}` | 书源侧图书详情（`ref` 为 `id:hash`，需 URL 编码） |

- `ext` / `lang` 为逗号分隔多值（客户端语言选项：`chinese,english,japanese,german,french,spanish,russian`）；
- `order`：空=相关度，`popular`=最热，`date`=最新。

```jsonc
→ { "books": [ { "provider":"zlib", "ref":"123:abc", "title":"...", "authors":["..."],
                 "year":"2008", "publisher":"", "language":"", "format":"EPUB",
                 "size":"2.5 MB", "isbn":"", "cover_url":"https://...",
                 "description":"", "source_url":"" } ],
    "page": 1, "total_pages": 3, "provider": "zlib" }
```

---

## 4. 书库与章节

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/library` | 书库列表 → `{"books":[...]}` |
| GET | `/api/library/{id}` | 书籍详情 + 关联有声书 → `{"book":{...},"audiobooks":[...]}` |
| DELETE | `/api/library/{id}` | 删除书籍（并删关联有声书） |
| GET | `/api/library/{id}/chapters` | 章节预览；`?full=1` 含正文 |
| POST | `/api/library/download` | 发起下载任务 → `{"job":{...}}` |
| POST | `/api/library/{id}/audiobooks` | 发起转有声书任务 → `{"job":{...}}` |

```jsonc
// 章节（chapterView）
{ "chapters": [ { "index": 0, "title": "版权信息", "chars": 121, "preview": "...", "text": "（full=1 时）" } ] }

// 转有声书请求
{ "model": "edge-tts", "voice": "zh-CN-YunxiNeural", "speed": 1.0,
  "instruct": "", "fallback_model": "", "chapters": [0, 1] }

// 下载请求
{ "provider": "zlib", "ref": "123:abc" }
```

`libraryBookView` 字段：`id, provider, provider_book_id, title, authors[], year, publisher, language, format, size_bytes, isbn, cover_url, description, source_url, status, created_at`。

---

## 5. 有声书与分章

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/audiobooks` | 有声书列表 → `{"audiobooks":[...]}` |
| GET | `/api/audiobooks/{id}` | 单本详情 → `{"audiobook":{...}}` |
| DELETE | `/api/audiobooks/{id}` | 删除 |
| GET | `/api/audiobooks/{id}/chapters` | **分章清单**（播放/离线核心） |

`audiobookView` 字段：`id, book_id, book_title, model, voice, speed, status, progress, error, format, duration_s, size_bytes, segments, chars, created_at, finished_at, audio_url, srt_url, chapters_url`。

`chapters` 响应：

```jsonc
{ "audiobook_id": 13, "format": "mp3", "duration_s": 1252.58, "chunk_seconds": 1800,
  "chunks": [ { "n": 1, "chapter_index": 0, "title": "狂人日记",
                "start_s": 0, "end_s": 1252.59, "duration_s": 1252.59,
                "size_bytes": 20042156,
                "audio_url": "/api/files/audiobooks/13?variant=chapter&n=1",
                "srt_url":   "/api/files/audiobooks/13?variant=chapter_srt&n=1" } ],
  "audio_url": "/api/files/audiobooks/13?variant=audio",
  "srt_url":   "/api/files/audiobooks/13?variant=srt" }
```

> 客户端把 `audio_url`/`srt_url` 视作**相对路径**，由 `EchoApi.resolveUri` 拼成绝对地址；离线下载会把清单原样缓存到本地。

---

## 6. 文件下载

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/files/books/{id}` | 下载 EPUB（导出功能使用） |
| GET | `/api/files/audiobooks/{id}?variant=audio` | 整本音频（分章后通常不保留） |
| GET | `/api/files/audiobooks/{id}?variant=srt` | 整本字幕 |
| GET | `/api/files/audiobooks/{id}?variant=chapter&n=N` | 分块音频 |
| GET | `/api/files/audiobooks/{id}?variant=chapter_srt&n=N` | 分块字幕（SRT） |

均需 `Authorization` 头。

---

## 7. 任务

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/jobs?limit=&offset=` | 任务列表 → `{"jobs":[...],"total":N}` |
| GET | `/api/jobs/{id}` | 单个任务 |
| POST | `/api/jobs/{id}/cancel` | 取消（协作式，段边界停止） |

```jsonc
{ "id": 17, "kind": "download|audiobook", "status": "queued|running|cancelling|done|failed|cancelled",
  "progress": 42, "error": "", "ref_id": 13, "created_at": "...", "started_at": "...",
  "finished_at": "...", "result": {...} }
```

客户端：任务页可见时每 3s 轮询；有任务新完成时刷新书架；失败原因直显服务端 `error`。

---

## 8. TTS 能力（经 echo-service 代理）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/tts/models` | 模型列表 + 健康状态 + `max_job_chars` |
| GET | `/api/tts/voices?model=` | 指定模型音色 |
| GET | `/api/tts/sample?model=&voice=` | 音色试听（WAV，需 Bearer） |

```jsonc
// models
{ "health": { "status": "ok", "models": [...], "busy": false },
  "models": [ { "id": "edge-tts", "repo": "", "default": true, "provider": "local|edge", "voices": ["..."] } ],
  "max_job_chars": 500000 }
```

TTS 不可达时，转换表单预检失败并禁用提交（服务端返回 502 `TTS_UNAVAILABLE`）。

---

## 9. 客户端模型映射速查

| 服务端 | 客户端类（`models.dart`） |
| --- | --- |
| auth token / me | `AuthToken` / `MeInfo` / `EchoUser` |
| libraryBookView | `LibraryBook`，详情封装 `BookDetail` |
| audiobookView | `AudiobookInfo`（`isReady` / `isRunning` / `isShowOnShelf`） |
| chapters 信封 + chunk | `ChaptersManifestInfo` / `ChapterChunk` |
| jobView | `JobInfo`（`JobKind` / `JobStatus` 枚举） |
| providerView / accountView | `ProviderInfo` / `ProviderAccountInfo` |
| search Book | `SearchBook`，信封 `SearchPageInfo` |
| chapterView | `ChapterPreview`（`full=1` 时含 `text`） |
| tts Model / Voice | `TtsModelInfo` / `TtsVoiceInfo` / `TtsModelsResponse` |
| 错误 | `ApiException`（`code` / `message` / `statusCode`） |
