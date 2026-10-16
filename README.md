# 灵译 LingYi

对标有道的个人翻译工具：**查词 + 翻译**（同声传译在路线图中），一套 Flutter 代码同时支持 **Windows** 和 **Android**。

## 功能（v0.3.1）

| 功能 | Windows | Android |
|---|---|---|
| 离线查词（ECDICT：音标、柯林斯星级、考试标签、分词性释义、词形变化、英文释义） | ✅ | ✅ |
| 变形自动还原（went → go，antennas → antenna） | ✅ | ✅ |
| 输入联想、中文反查英文 | ✅ | ✅ |
| 多引擎并排翻译：火山、百度、DeepL、腾讯、AI 翻译 | ✅ | ✅ |
| AI 多线路自动切换：魔搭 Qwen3.5-397B → Qwen3.5-27B → AMD MiMo-V2.6-Flash → Gemma-4-31B → 智谱 GLM-4-Flash，结果下方显示实际使用的模型 | ✅ | ✅ |
| 术语表（默认内置射频/天线术语；AI 翻译强制使用） | ✅ | ✅ |
| AI 讲解单词 / 解析句子 | ✅ | ✅ |
| 朗读（系统 TTS） | ✅ | ✅ |
| 生词本（导出 Anki 格式）、历史记录 | ✅ | ✅ |
| 划词自动翻译：选中文字后鼠标旁出现「译」图标（或直接弹出），终端自动排除 | ✅ | — |
| 全局热键划词：选中文字按 `Alt + D`，鼠标旁弹出翻译 | ✅ | — |
| 复制即翻译（可选）、托盘常驻 | ✅ | — |
| 在任意 App 选中文字 → 菜单「灵译查词」 | — | ✅ |
| **截图翻译**：`Alt + S` 框选屏幕，识别文字和公式后在鼠标旁弹出翻译（公式保持原样） | ✅ | — |
| **截图识别**：智能模式（视觉大模型，文字 + 公式混排）/ 本地文字 / 本地公式；公式输出 LaTeX，可复制为 Word 公式 | ✅ | — |
| **PDF 翻译**：保留原排版、公式和图表，输出左右对照 / 交替页 / 仅译文 PDF，套用术语表 | ✅ | — |
| **术语表**：内置约 480 条电磁场与微波、射频、天线、基站天线、超表面、仿真测量术语；只提示原文中出现的术语，支持复数和连字符变体 | ✅ | ✅ |
| 分享文字到灵译 | — | ✅ |

## 下载与编译

推送到 GitHub 后，Actions 会自动编译：

- **Actions → 编译 → 最新一次运行 → Artifacts**：`lingyi-windows`（解压后运行 `lingyi.exe`）、`lingyi-android`（APK）
- 打 `v*` 标签（如 `v0.1.0`）会自动创建 Release 并附上两个安装包

本地编译（需要 Flutter 3.47+）：

```bash
flutter create --platforms=windows,android --org com.chafer --project-name lingyi .
flutter pub get
flutter run -d windows          # 或连接手机后 flutter run
```

仓库里只保存定制过的平台文件（安卓清单、MainActivity、图标），其余由 `flutter create` 生成，已存在的文件不会被覆盖。

## 截图识别与 PDF 翻译（v0.3，Windows）

这两项由随包附带的本地后端 `backend\lingyi_backend.exe` 完成，灵译在需要时自动启动它，退出时一并关闭：

- **智能识别（默认）**：魔搭 Qwen3.5-27B → Qwen3.5-397B → AMD DeepSeek-V4-Flash-Vision → Qwen3.8-27B → 智谱 GLM-4V-Flash → GLM-4.1V-Thinking-Flash 视觉识别，文字和公式一起输出（Markdown + LaTeX），都不可用时改用本地文字识别。截图会上传到魔搭/AMD/智谱。选择依据见 `tools/ocr_eval`（论文排版测试图：Qwen3.5 公式 5/5 全对，GLM-4V 4/5，本地 OCR 0/5）
- 文字识别（本地离线）：RapidOCR（PP-OCRv4，中英文）；会把断行合并成段落，并修复英文单词间丢失的空格
- 公式识别（本地离线）：RapidLaTeXOCR，只适合单个公式的截图，输出 LaTeX 和 MathML
- PDF 翻译所需的版面模型、字体（中英文精简版）、字符映射表、tiktoken 词表已内置在安装包里，无需联网下载
- PDF 翻译：BabelDOC 引擎，使用 设置 → AI 翻译 的线路（同样自动切换）和术语表
- PDF 速度（实测 15 页论文，`backend/tools/pdf_bench.py`）：默认每秒 4 个请求、不自动提取术语约 2 分钟；旧默认（每秒 1 个 + 自动提取术语）约 10 分半
- 后端只监听 127.0.0.1，并校验每次启动随机生成的令牌

从源码运行时（没有打包的 exe），在 设置 → 截图识别与 PDF 翻译 → 高级 中填写：

```
启动命令：python -m lingyi_backend
工作目录：<仓库>\backend      （需 Python 3.12，先执行 pip install -r requirements.txt 和 pip install --no-deps -r requirements-nodeps.txt）
```

后端单独测试：`cd backend && python -m pytest tests -q && python tools/smoke_test.py`

## 首次配置

1. **翻译引擎**（设置 → 翻译引擎）。默认只启用 AI 翻译，其他引擎可手动开启、结果并排显示
   - **AI 翻译**（划词翻译、AI 讲解、PDF 翻译共用）：默认线路 魔搭 `Qwen3.5-397B-A17B` → 魔搭 `Qwen3.5-27B` → AMD `MiMo-V2.6-Flash` → AMD `Gemma-4-31B-IT` → 智谱 `glm-4-flash-250414`。AMD 密钥在 developer.amd.com.cn → Radeon Cloud → Token Factory 获取（免绑卡，每天约 $10 免费额度）。
     前一个限流（429）、额度用完、超时或服务端出错时自动换下一个，出错的接口暂停使用一段时间（30 秒起，最长 10 分钟）后再回到首选。
     线路顺序可在设置里调整，也可以加入 Qwen3.5-122B 或自定义接口。选择依据见 `tools/api_eval.py` 的实测（16 句射频句子，397B 术语命中 41/42）。
     - 魔搭令牌：modelscope.cn 绑定阿里云账号、实名、**验证邮箱**后，在“访问令牌”页创建（`ms-` 开头）。每天约 2000 次免费调用，单模型额度动态调整。
     - 智谱密钥：open.bigmodel.cn → API Keys。GLM-4-Flash 官方免费。
   - 腾讯云：已于 2026-10-01 停发免费额度，2027-10-01 起停止服务，仅供已有付费资源包时使用。
   - 火山翻译：先用后付费，文本翻译 49 元/百万字符（开通页未显示免费额度）。
   - 百度翻译：个人认证并切换到高级版后每月 100 万字符免费（未实测）。
   - DeepL：免费版每月 50 万字符，密钥以 `:fx` 结尾。
   - 自定义 AI 接口：在 AI 线路里添加「自定义接口」，DeepSeek / 通义千问 / Kimi / 硅基流动 / 本地 Ollama 一键预设。
2. **标准词库**（可选）：设置 → 离线词库 → 下载标准词库（默认地址已填好）。若 fork 到自己的仓库，先在 Actions 里运行一次「生成标准词库」，再把
   `https://github.com/<用户名>/<仓库>/releases/download/dict-v1/standard.db.gz`
   填到设置 → 离线词库 → 下载地址。约 135 万词，覆盖 metasurface、beamforming、downtilt 等专业词。

## 目录结构

```
lib/
  main.dart                 启动：设置、用户库、词库、桌面集成
  util/text_utils.dart      语言判断、查词判定、词形/词性/术语解析（纯函数，有单元测试）
  services/
    dict_service.dart       ECDICT 本地词典（sqlite3）
    user_db.dart            历史、生词本、查词次数
    settings.dart           设置（含默认术语表、热键预设）
    tts.dart                朗读
    translate/              火山、百度、腾讯（签名算法有单元测试）、DeepL；ai_router.dart AI 多线路自动切换
  platform/
    desktop.dart            Windows：托盘、全局热键、模拟 Ctrl+C 划词、迷你弹窗、剪贴板监听
    win_input.dart          user32 FFI（keybd_event、GetCursorPos 等）
    android_intent.dart     安卓：PROCESS_TEXT / SEND
    screen_capture.dart     调用系统截图（ms-screenclip），等待截图进入剪贴板
  services/backend.dart     启动/连接本地后端，OCR 与 PDF 任务接口
  ui/                       查词翻译、截图识别、PDF 翻译、单词卡片、生词本、历史、设置
backend/                    本地后端（Python 3.12 + FastAPI）
  lingyi_backend/           ocr.py 文字/公式识别 · pdf_jobs.py BabelDOC 任务 · ai_fallback.py AI 接口自动切换 · server.py 接口
  tests/  tools/            单元测试、冒烟测试、PDF 端到端测试（CI 自动运行）
  lingyi_backend.spec       PyInstaller 打包配置
tools/build_dict.py         从 ECDICT 生成 core.db / standard.db
```

## 路线图

- **v0.3.x**：划词改用 UI Automation 读取选区（不经过剪贴板）、Word 文档翻译、悬浮球（安卓）
- **v0.4**：同声传译——系统音频/麦克风 → sherpa-onnx 流式识别 + SenseVoice 整句定稿 → 翻译 → 双语字幕条
- **v0.5**：MDX 词典挂载、生词本复习

## 数据来源

词库来自 [ECDICT](https://github.com/skywind3000/ECDICT)（MIT 许可）。
