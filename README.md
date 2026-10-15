# 灵译 LingYi

对标有道的个人翻译工具：**查词 + 翻译**（同声传译在路线图中），一套 Flutter 代码同时支持 **Windows** 和 **Android**。

## 功能（v0.1）

| 功能 | Windows | Android |
|---|---|---|
| 离线查词（ECDICT：音标、柯林斯星级、考试标签、分词性释义、词形变化、英文释义） | ✅ | ✅ |
| 变形自动还原（went → go，antennas → antenna） | ✅ | ✅ |
| 输入联想、中文反查英文 | ✅ | ✅ |
| 多引擎并排翻译：腾讯云、DeepL、AI（任意 OpenAI 兼容接口） | ✅ | ✅ |
| 术语表（默认内置射频/天线术语；AI 翻译强制使用） | ✅ | ✅ |
| AI 讲解单词 / 解析句子 | ✅ | ✅ |
| 朗读（系统 TTS） | ✅ | ✅ |
| 生词本（导出 Anki 格式）、历史记录 | ✅ | ✅ |
| 全局热键划词：选中文字按 `Alt + D`，鼠标旁弹出翻译 | ✅ | — |
| 复制即翻译（可选）、托盘常驻 | ✅ | — |
| 在任意 App 选中文字 → 菜单「灵译查词」 | — | ✅ |
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

## 首次配置

1. **翻译引擎**（设置 → 翻译引擎，至少配一个）
   - 腾讯云机器翻译：每月 500 万字符免费。控制台 → 访问管理 → API 密钥。建议关闭“后付费”。
   - DeepL：免费版每月 50 万字符，密钥以 `:fx` 结尾。
   - AI：DeepSeek / 通义千问 / Kimi / 本地 Ollama 一键预设，填密钥即可。
2. **标准词库**（可选）：在 Actions 里手动运行一次「生成标准词库」，然后把
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
    translate/              腾讯（TC3 签名）、DeepL、OpenAI 兼容大模型
  platform/
    desktop.dart            Windows：托盘、全局热键、模拟 Ctrl+C 划词、迷你弹窗、剪贴板监听
    win_input.dart          user32 FFI（keybd_event、GetCursorPos 等）
    android_intent.dart     安卓：PROCESS_TEXT / SEND
  ui/                       查词翻译、单词卡片、生词本、历史、设置
tools/build_dict.py         从 ECDICT 生成 core.db / standard.db
```

## 路线图

- **v0.2**：截图 OCR 翻译（Windows.Media.Ocr / 安卓 ML Kit）、PDF/Word 文档翻译、悬浮球（安卓）
- **v0.3**：同声传译——系统音频/麦克风 → sherpa-onnx 流式识别 + SenseVoice 整句定稿 → 翻译 → 双语字幕条
- **v0.4**：MDX 词典挂载、生词本复习

## 数据来源

词库来自 [ECDICT](https://github.com/skywind3000/ECDICT)（MIT 许可）。
