<div align="center">
  <img src="assets/icon/logo.svg" alt="Echo Logo" width="112" height="112" />
  <h1>Echo · 回声</h1>
  <p>静默阅读，随时聆听 —— 端侧离线语音驱动的跨平台听看一体书客户端</p>

  <p>
    <img src="https://img.shields.io/badge/Flutter-3.38.9-0D0E10?style=flat-square&logo=flutter&logoColor=D4AE74&labelColor=16171B" alt="Flutter 3.38.9" />
    <img src="https://img.shields.io/badge/Dart-3.10.8-0D0E10?style=flat-square&logo=dart&logoColor=D4AE74&labelColor=16171B" alt="Dart 3.10.8" />
    <img src="https://img.shields.io/badge/Platforms-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20Linux-8F6836?style=flat-square&labelColor=16171B" alt="Supported Platforms" />
    <a href="https://github.com/imlinhanchao/echo-app/releases"><img src="https://img.shields.io/github/v/release/imlinhanchao/echo-app?style=flat-square&color=D4AE74&labelColor=16171B" alt="GitHub Release" /></a>
  </p>

  <p>
    <a href="#核心特性">核心特性</a> ·
    <a href="#端侧语音引擎">端侧语音引擎</a> ·
    <a href="#安装与下载">安装与下载</a> ·
    <a href="#架构与设计">架构与设计</a> ·
    <a href="#本地开发">本地开发</a> ·
    <a href="#发布流程">发布流程</a>
  </p>
</div>

---

## 核心特性

- **极简书房视觉体系**：采用暖墨黑（`#0D0E10` / `#D4AE74`）深色基准与羊皮纸白（`#F8F5F0` / `#8F6836`）浅色对偶主题（设计 Token 见 [`assets/design-tokens.json`](assets/design-tokens.json)），为缺失封面自动生成 2:3 复古布面装帧兜底封面，并适配手机、平板与桌面三断点布局。
- **单机离线优先，可选在线书源**：内置纯 Dart **EPUB（EPUB 2 NCX / EPUB 3 Nav）与 TXT** 解析器，自动完成封面提取与章节切分，无需后端服务即可导入本地电子书开箱使用；也可在设置中接入 [Ebook API](https://github.com/imlinhanchao/ebook-api) 扩展多书源搜索与下载。
- **边听边看与离线转有声书**：集成 `sherpa-onnx` 与系统语音引擎，实现端侧实时朗读与句级高亮联动；支持 `0.5x–2.5x`（`0.05x` 步进）不重合成、不中断句子的即时倍速调节，并支持按章在后台离线合成与分块导出本地有声书。
- **沉浸阅读与划线笔记**：基于视口尺寸进行高精度分页与缓存，内置阅读防锁屏常亮控制；支持长按选词、五级智能避让无遮挡浮动工具栏、五色墨色单/双下划线、笔记编辑、按类型筛选与跨章定位跳转。
- **系统级媒体播控**：Android 端提供锁屏与通知栏媒体播放控制（`audio_service` + `audio_session`），支持蓝牙/线控耳机锁屏暂停与恢复，并在主动停播时自动清理前台通知。

---

## 端侧语音引擎

应用内置 5 类端侧语音合成方案，可在「TTS 模型管理」页按需启用与管理：

| 模型 / 引擎 | 预估体积 | 技术架构 | 适用场景与特点 |
| --- | --- | --- | --- |
| **Android 系统语音（本机引擎 / MultiTTS）** | `0 MB` | 系统 TTS 接口 | 免下载直连手机已装语音引擎与音色，支持边听边看与离线转换 |
| **ZipVoice INT8 中英（24kHz 克隆）** | `~156 MB` | ZipVoice + Vocos 24kHz | 零样本音色克隆，默认自带参考音色，支持导入 3–10 秒自定义参考 WAV |
| **MeloTTS 中英混读** | `~159 MB` | VITS | 中英混读韵律自然，适合中英夹杂文本流畅朗读 |
| **Matcha 中文播音女声（22kHz）** | `~123 MB` | Matcha + Vocos 22kHz | 标贝标准女声，发音清晰饱满、RTF 极低，长篇中文听书优选 |
| **Matcha 中英混读（16kHz）** | `~127 MB` | Matcha + Vocos 16kHz | 非自回归流匹配架构，体积轻量、中英混排均衡 |

> **下载加速与保活**：模型下载支持「国内加速镜像 / GitHub 官方直连 / 自定义镜像前缀」切换，并具备断点续传与 Android 下载前台保活能力。

---

## 安装与下载

前往 [GitHub Releases](https://github.com/imlinhanchao/echo-app/releases) 下载对应平台的构建产物（暂不包含 iOS）：

| 平台 | 分发包命名 | 说明 |
| --- | --- | --- |
| **Android（ARM64，推荐）** | `echo_<tag>_android_arm64-v8a.apk` | 适用于现代 Android 手机与平板（Android 7.0+ / API 24+） |
| **Android（通用包）** | `echo_<tag>_android_universal.apk` | 全架构兼容包（arm64 / armeabi-v7a / x86 / x86_64） |
| **Windows（x64）** | `echo_<tag>_windows_x64.zip` | 解压后运行目录内的 `echo.exe` |
| **macOS（Universal）** | `echo_<tag>_macos_universal.dmg` | 原生支持 Apple Silicon 与 Intel，双击挂载后拖入 `Applications` |
| **Linux（x64）** | `echo_<tag>_linux_x64.tar.gz` | 解压后进入目录运行 `./echo`（需桌面环境具备 GTK 3 与 `libsecret` 运行库） |
| **完整性校验** | `checksums.txt` | 所有发布产物的 SHA-256 校验清单 |

---

## 架构与设计

### 核心技术栈

| 模块 | 选型 | 用途 |
| --- | --- | --- |
| **跨平台框架** | Flutter `3.38.9` / Dart `3.10.8` | 移动端（Android）与桌面端（Windows / macOS / Linux）统一 UI 与业务逻辑 |
| **状态管理** | `flutter_riverpod` | 响应式控制器编排、全局配置注入与单元测试替身隔离 |
| **端侧 TTS** | `sherpa_onnx` + 原生系统通道 | 端侧离线模型推理与 Android 系统 TTS / MultiTTS 统一封装 |
| **音频与媒体会话** | `just_audio` + `audio_service` + `audio_session` | 分块无缝续播、即时变速不变调、音频焦点管理与锁屏媒体控条 |
| **电子书与离线存储** | `archive` + `xml` + `html` + `flutter_secure_storage` | 纯 Dart EPUB/TXT 解析、分块有声书清单与安全凭据存储 |
| **网络与可选书源** | `dio` | 对接 Ebook API、模型断点下载与镜像前缀调度 |

### 目录结构

```text
echo-app/
├── .github/workflows/
│   └── release.yml          # 多平台手动发布工作流（Android / Windows / macOS / Linux）
├── assets/
│   ├── design-tokens.json   # 极简书房视觉 Token 唯一真源（含 2:3 封面、字体与色板）
│   └── icon/                # 应用图标与 Android 自适应图标分层源文件
├── lib/
│   ├── core/                # 核心能力层：api / audio / books / notes / offline / reader / settings / sync / tts
│   ├── design/              # 主题系统：EchoTokens、EchoMetrics、复古兜底封面与质感表面组件
│   ├── features/            # 业务特性层：library / reader / player / tts / onboarding / search / jobs / profile
│   └── main.dart            # 应用入口与媒体服务装配
├── android/                 # Android 工程、媒体服务原生桥接与 ProGuard/R8 资源保留配置
├── windows/                 # Windows 桌面工程与构建配置
├── macos/                   # macOS 桌面工程与沙箱权限声明
├── linux/                   # Linux 桌面工程与构建配置
└── test/                    # 单元测试与 Widget 回归测试套件
```

---

## 本地开发

### 环境要求

- **Flutter SDK**：`3.38.9`（版本由 [`.fvmrc`](.fvmrc) 锁定，Dart `3.10.8`）
- **Android 构建**：JDK 17 与 Android SDK（`minSdk 24`）
- **Linux 桌面构建**（Ubuntu/Debian）：`clang`、`cmake`、`ninja-build`、`pkg-config`、`libgtk-3-dev`、`liblzma-dev`、`libsecret-1-dev`

### 依赖检查与测试

```bash
flutter pub get
flutter analyze
flutter test
```

> 如处于受限网络环境，可在命令前按需附加镜像变量：`PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`。

### 本地构建发布包

```bash
# Android Release APK（可选注入默认服务端地址：--dart-define=ECHO_BASE_URL=<url>）
flutter build apk --release

# Windows x64 Release
flutter build windows --release

# macOS Universal Release
flutter build macos --release

# Linux x64 Release
flutter build linux --release
```

> **Android 正式签名**：将本地签名证书及 `android/key.properties`（已被 `.gitignore` 忽略，禁止提交）放到对应路径后，Gradle 会自动使用正式签名；缺失凭据时会自动回退到 debug 签名以便本地开发构建。

---

## 发布流程

本仓库通过 [`.github/workflows/release.yml`](.github/workflows/release.yml) 提供手动触发的多平台 Release 发布工作流（**Actions → Release → Run workflow**）：

1. 输入语义化版本号（如 `v0.4.0`），并可选指定构建号、Pre-release 或 Draft 标记。
2. `prepare` 任务先运行 `flutter analyze` 与 `flutter test` 作为质量门禁。
3. 门禁通过后并发构建 **Android**、**Windows**、**macOS**、**Linux** 四个平台产物；其中 Android 端会在打包后自动校验 R8 通知图标保留与正式签名证书，防止回退为 debug 签名。
4. `publish` 任务汇总全部产物并生成 `checksums.txt`，自动创建对应 Tag 的 GitHub Release。

### 仓库 Secrets 配置清单

启用正式 Android CI 签名需在 **Settings → Secrets and variables → Actions → Repository secrets** 中配置以下 4 项：

| Secret 名称 | 用途说明 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | PKCS12 正式签名 `.keystore` / `.jks` 文件的 Base64 单行编码内容 |
| `ANDROID_KEYSTORE_PASSWORD` | 签名库密码（`storePassword`） |
| `ANDROID_KEY_PASSWORD` | 签名别名密钥密码（`keyPassword`） |
| `ANDROID_KEY_ALIAS` | 签名证书条目别名（`keyAlias`） |
