# Echo · 回声

跨平台听看一体书客户端（Flutter）。搜书、下载、转有声书、听与看——一本"书"的完整生命周期。

> 开发计划与功能覆盖矩阵见 [开发计划.md](开发计划.md)；产品与视觉设计见 [Echo-设计规划.md](../Echo-设计规划.md)。

## 项目速览

| 项 | 值 |
| --- | --- |
| 包名 | `org.hancel.echo` |
| 后端 | [echo-service](../echo-service/README.md)（Go，`127.0.0.1:8090`，Bearer Token） |
| TTS 依赖 | tts-service（局域网 Mac `192.168.50.10:8123`，经 echo-service 代理调用） |
| 设计系统 | [design-tokens.json](../design-tokens.json)（深色优先，三层 Token） |
| 设计图 | [generated/](../generated/)（16 张界面方向稿） |

## 开发环境（fvm）

fvm 缓存固定在工作区 `.tmp/fvm`（Flutter 3.38.9，`.fvmrc` 已钉住），命令前带上环境变量：

```bash
cd echo-app
export FVM_CACHE_PATH="$(dirname "$PWD")/.tmp/fvm" \
       PUB_CACHE="$(dirname "$PWD")/.tmp/pub-cache"
fvm flutter pub get      # 安装依赖
fvm flutter analyze       # 静态检查（当前 0 issues）
fvm flutter test          # 测试（当前 43/43 通过）
fvm flutter run -d chrome  # 运行（本机缺 Linux 桌面工具链，可先用 Chrome）

# Android 模拟器真机运行（宿主机 echo-service 经 10.0.2.2 访问）
fvm flutter build apk --debug --dart-define=ECHO_BASE_URL=http://10.0.2.2:8090
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n org.hancel.echo/org.hancel.echo.MainActivity
```

## 功能全景

1. 注册 / 登录 / 设备 Token 管理
2. zlib 书源账号配置（镜像 / 账密 / Cookie 导入、配额）
3. 搜索 → 详情 → 下载入库
4. 转有声书（模型 / 音色 / 语速 / 章节范围、试听）
5. 任务中心（下载 + 转换，章级进度、取消、失败原因）
6. 播放器 v3（SRT 跟读高亮、章节刻度、翻章、倍速、睡眠定时）
7. 阅读器（衬线排版、边听边看共享进度）
8. 离线按块缓存（音频 + SRT）

## 阶段状态

- [x] Phase 0 · 底座（fvm / 脚手架 / Token 主题）✅ 2026-11-20
- [x] Phase 1 · 认证 + 消费 ✅ 2026-11-20（登录注册、书库/有声书双 Tab、分块播放、SRT 跟读、断点续听）
- [ ] Phase 2 · 获取闭环（✅ 功能与测试完成：账号配置/搜索/任务中心/转换表单 + 模拟器登录-主壳-搜索-登出真机验证；⏳ audio_service 锁屏播控、播放链路真机验证、阅读器）（账号配置、搜索、转换、播放器 v3、阅读器）
- [ ] Phase 3 · 多端 + 笔记
- [ ] Phase 4 · 增强（同步、导入、车机）

详见 [开发计划.md](开发计划.md) §5 验收标准。
