# AGENTS.md — 回声客户端

给 AI 编码 Agent 的仓库约定。人类可读的说明见 [README.md](README.md)，
功能与设计现状见 [docs/设计与实现现状.md](docs/设计与实现现状.md)，
接口契约见 [docs/API-契约.md](docs/API-契约.md)。

## 项目速览

**回声** 是 Flutter 跨平台听看一体书客户端（包名 `org.hancel.echo`），
后端是 `../echo-service`（Go，Bearer Token）。客户端**不直连 TTS 服务**，
所有获取/转换/播放能力都经 echo-service 的 HTTP 接口。

- 框架：Flutter（fvm 固定版本，见 `.fvmrc`）
- 状态管理：Riverpod（`Provider` + `StateNotifierProvider`）
- 音频：`just_audio` + `audio_service`（Android/iOS 后台与锁屏播控）
- 存储：`flutter_secure_storage`（Token/进度/笔记/统计/阅读位置）
- 网络：`dio`（统一 `ApiException`）

## 常用命令

Flutter SDK 缓存位于工作区 `.tmp/fvm`，每个新 shell 都要带环境变量：

```bash
cd echo-app
export FVM_CACHE_PATH="$(dirname "$PWD")/.tmp/fvm" \
       PUB_CACHE="$(dirname "$PWD")/.tmp/pub-cache"

fvm flutter pub get
fvm flutter analyze                    # 必须 0 issues
fvm flutter test                       # 必须全绿（当前 51）
fvm dart format lib test               # 提交前格式化
```

构建：

```bash
# 模拟器（宿主机服务用 10.0.2.2）
fvm flutter build apk --debug --dart-define=ECHO_BASE_URL=http://10.0.2.2:8090
# 局域网真机
fvm flutter build apk --release --dart-define=ECHO_BASE_URL=http://192.168.50.200:8090
```

模拟器操作（启动/安装/截图/UI dump）见技能 `android-emulator-testing`。
注意本机 AVD 实名是 `Medium_Phone_API_37.0`（不是 `Medium_Phone`）。

## 目录结构

```
lib/
├── core/          基础设施：api / auth / audio / offline / reader / notes / stats / export / media / settings
├── design/        design-tokens 载入、ThemeExtension、尺度常量、封面组件
├── features/      auth / library / player / reader / search / jobs / providers / profile / shell
└── main.dart      启动装配：audio_service → 离线目录 → 统计 → 笔记 → 主题
test/              widget/单元测试 + `stub_adapter.dart`（HTTP 桩）+ `tokens_fixtures.dart`
docs/              主文档、API 契约、设计规划（原始）、截图
```

## 硬性约定

### 1. 设计 Token，禁止裸值

- 颜色只能来自 `Theme.of(context).extension<EchoTokens>()!`；尺度只能来自 `EchoMetrics`；
- Token 的唯一真相是 `assets/design-tokens.json`，新增语义色要同步更新该文件 + `EchoTokens` 字段 + `copyWith`/`lerp`；
- 深色为基准态（dark-first）；新增界面必须同时考虑亮色。

### 2. 网络层

- 所有请求走 `EchoApi`，不要在其他地方 new `Dio`；错误统一 `ApiException`（`{"error":{code,message}}`）；
- 401 由拦截器自动 `refresh` 并重放一次，业务层不要自己处理 token 过期；
- 媒体地址是**相对路径**，必须经 `EchoApi.resolveUri()`；播放/下载要带 `authHeaders()`。

### 3. 播放链路

- `AudioEngine` 是抽象层：生产用 `AudioServiceEngine`/`JustAudioEngine`，测试用 `FakeAudioEngine`；
- 载入分块时**先查离线文件**（`OfflineFiles.audioFile`），命中即 `file://` 播放且不带鉴权头；
- 续听规则：恢复到末尾（距块尾 ≤2s）视为已听完，必须从头重播；
- 清单请求失败要回退本地缓存的 `manifest.json`（离线播放依赖它）。

### 4. 测试约定

- HTTP 用 `test/stub_adapter.dart` 的 `StubAdapter`（记录请求、按路径返回预设响应）；
- `path_provider` 在测试环境不可用 → 所有离线/导出路径必须 try/catch 降级；
- **不要在会走 widget 测试的代码里用 `Timer` 做防抖**（会报 "A Timer is still pending"）；
  用时间戳节流代替（见 `stats_store.dart` / `note_store.dart`）；
- 测试里的 provider 覆盖：`tokenStoreProvider` / `echoApiProvider` / `audioEngineProvider` / `progressStoreProvider` / `readingStoreProvider`。

### 5. 滚动与生命周期

- 懒加载 `ListView` 里对屏幕外元素 `ensureVisible` 无效，需「先按索引粗跳 → 构建后再精确定位」（见 `player_sheet.dart::_centerCue`）；
- 任何 post-frame 滚动回调都必须先判 `mounted` + `_scrollController.hasClients` + `ctx.mounted`，
  否则关闭页面会触发 `ScrollPosition.attached` 断言**红屏崩溃**（本项目真实踩过）。

### 6. Android 细节

- echo-service 是明文 HTTP：`AndroidManifest` 必须保留 `android:usesCleartextTraffic="true"`，
  否则 ExoPlayer（Java 网络栈）取不到音频，而 dio（Dart 栈）却能工作，表现为"列表能加载但播放失败"；
- `audio_service` 有断言：`androidNotificationOngoing` 为 true 时 `androidStopForegroundOnPause` 必须为 true；
- **通知渠道一经创建，重要性不可修改**；音频播放渠道由 audio_service 自行创建（id `org.hancel.echo.playback`）；
  曾尝试在 `MainActivity` 预建 DEFAULT 渠道 + 自定义小图标，在华为真机上导致媒体通知整个消失，已回退——改动此处需真机验证；
- 版本号在 `pubspec.yaml`（当前 0.3.0）；发版前同步更新 `profile_page.dart` 里的"关于"文案。

## 已知坑位清单

| 现象 | 原因 | 处置 |
| --- | --- | --- |
| 列表能加载、音频报 `Source error` | 明文 HTTP 被系统拦截（仅 Java 网络栈） | 保留 `usesCleartextTraffic` |
| 点播放"没反应"、停在块尾 | 续听恢复到末尾 → 立即 completed | 末尾 ≤2s 判定已听完并从头播 |
| 关闭播放器后红屏 `_dependents.isEmpty` | post-frame 滚动操作已卸载列表引发的连锁异常 | 三重守卫（见上） |
| 阅读器文字被底栏遮挡 | 按字符数估算分页，实际渲染更高 | `TextPainter` 精确分页（`reading_store.dart::paginateChapterBySize`） |
| 华为锁屏无媒体卡片 | 系统侧策略/通知渠道被降级 | 未解决，需真机 logcat；不要盲改通知配置 |
| 测试报 Timer 残留 | 防抖用了 `Timer` | 改时间戳节流 |

## 提交与发版

1. `fvm dart format lib test`；
2. `fvm flutter analyze` 0 issues、`fvm flutter test` 全绿；
3. 模拟器实测受影响界面（启动模拟器、安装、截图、必要时抓 logcat）；
4. 更新 [开发计划.md](开发计划.md) 进度表与 [docs/设计与实现现状.md](docs/设计与实现现状.md) 对应章节；
5. 提交信息用中文，格式 `feat|fix|docs|revert: vX.Y.Z —— 摘要`，正文分条列出变更与验证结果。

## 安全与边界

- 不提交任何凭据：仓库内不含 zlib 账号、Token、`.env`；
- 测试账号信息在工作区根目录 `TEST_ACCOUNT.md`（仓库之外），不要复制进本仓库；
- 用户数据（进度/笔记/统计）只存本机安全存储；
- 受伤的接口字段以 `echo-service` 的 README/AGENTS.md 与 `internal/api/views.go` 为准。
