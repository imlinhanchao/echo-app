# 回声

跨平台听看一体书客户端（Flutter）。搜书、下载、转有声书、听与看——一本"书"的完整生命周期。

> 版本 **v0.3.0** · 质量门禁 `flutter analyze` 0 issues、`flutter test` 51/51 通过

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/设计与实现现状.md](docs/设计与实现现状.md) | **主文档**：设计系统落地、界面清单与截图索引、交互规范、技术架构、已验证事实、已知问题、路线图 |
| [docs/API-契约.md](docs/API-契约.md) | 与 echo-service 的全部接口契约与字段映射 |
| [docs/设计规划（原始）.md](docs/设计规划（原始）.md) | 项目初期的产品与视觉规划（历史基线） |
| [开发计划.md](开发计划.md) | 分阶段计划、验收标准、开发进度流水 |
| [AGENTS.md](AGENTS.md) | 给 AI 编码 Agent 的仓库约定与踩坑清单 |
| [docs/screenshots/](docs/screenshots/) | 29 张模拟器实测截图（按版本分组） |
| [../assets/design-tokens.json](assets/design-tokens.json) | 设计 Token 唯一真相 |

## 项目速览

| 项 | 值 |
| --- | --- |
| 应用名 | 回声（Android `label` / iOS `CFBundleDisplayName` / macOS `PRODUCT_NAME`） |
| 包名 | `org.hancel.echo` |
| 后端 | [echo-service](../echo-service/README.md)（Go，`http://<host>:8090`，Bearer Token） |
| TTS 依赖 | tts-service（局域网 Mac，经 echo-service 代理调用，客户端不直连） |
| 设计系统 | [design-tokens.json](assets/design-tokens.json) → `EchoTokens(ThemeExtension)`，深色优先 |

## 已实现功能

1. **账号**：注册 / 登录 / Token 自动续期 / 登出
2. **书源**：zlib 账号配置（账密或 Cookie 导入）、验证、配额显示、失效重配
3. **获取**：搜索（关键词 + 高级筛选：语言/年份/排序）、结果详情、一键下载
4. **转换**：转有声书（模型/音色/语速/章节多选/音色试听）
5. **任务**：任务中心（轮询、取消、失败原因直显、完成刷新书架）
6. **播放器**：SRT 句级跟读（当前句居中）、章节切换、±15s 跨块、章节刻度进度条、倍速、睡眠定时、断点续听、媒体通知
7. **阅读器**：按可视尺寸精确分页、左右滑翻页、章节目录、阅读百分比、位置记忆、从当前位置听书
8. **详情页**：封面/简介/有声书列表/章节预览 + 智能主操作 + EPUB 导出
9. **离线**：按分块下载音频+SRT+章节清单，断网可播放
10. **笔记**：播放器时间戳笔记（打点/跳转/删除）
11. **统计**：我的页本周收听时长 / 连续天数 / 已听完本数
12. **主题**：深色优先 + 亮色对偶，我的页可切换并持久化

未实现项（平板/桌面布局、鸿蒙构建、跨设备同步、发现页推荐、华为锁屏适配等）见 [设计与实现现状 §8-9](docs/设计与实现现状.md)。

## 开发环境

Flutter 版本由 fvm 固定（`.fvmrc` = 3.38.9），SDK 缓存在工作区 `.tmp/fvm`：

```bash
cd echo-app
export FVM_CACHE_PATH="$(dirname "$PWD")/.tmp/fvm" \
       PUB_CACHE="$(dirname "$PWD")/.tmp/pub-cache"

fvm flutter pub get
fvm flutter analyze          # 期望 0 issues
fvm flutter test             # 期望 51/51
```

### 运行 / 打包

```bash
# Android 模拟器（访问宿主机服务用 10.0.2.2）
fvm flutter build apk --debug --dart-define=ECHO_BASE_URL=http://10.0.2.2:8090
adb install -r build/app/outputs/flutter-apk/app-debug.apk

# 真机（同一局域网）
fvm flutter build apk --release --dart-define=ECHO_BASE_URL=http://192.168.50.200:8090
```

服务地址也可用其他地址，只要手机能访问到 echo-service。

## 测试账号（本地联调）

见工作区根目录 `TEST_ACCOUNT.md`（不在本仓库内，含凭据，勿提交）：

- A 账号：已配置 zlib，书库有《呐喊》与多本有声书 —— 用于播放/阅读/离线验证
- B 账号：空书库、未配置 zlib —— 用于错误路径与隔离验证
