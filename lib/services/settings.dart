import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/text_utils.dart';
import 'translate/ai_router.dart';

/// 默认术语表：射频/天线领域常用词，可在设置里自行修改。
const defaultGlossary = '''# 每行一条：英文 = 中文。翻译时会提示术语，大模型引擎会强制使用。
radiation pattern = 方向图
beamwidth = 波束宽度
half-power beamwidth = 半功率波束宽度
downtilt = 下倾角
electrical downtilt = 电下倾
gain = 增益
directivity = 方向性系数
front-to-back ratio = 前后比
cross-polarization = 交叉极化
isolation = 隔离度
return loss = 回波损耗
VSWR = 电压驻波比
phase shifter = 移相器
feed network = 馈电网络
dipole = 偶极子
ground plane = 地板
metasurface = 超表面
beamforming = 波束赋形
sidelobe = 旁瓣
grating lobe = 栅瓣
radome = 天线罩
null filling = 零点填充
beam squint = 波束偏斜
parasitic element = 寄生单元
mutual coupling = 互耦
upper sidelobe suppression = 上旁瓣抑制
adjacent-cell interference = 邻区干扰
''';

/// 引擎显示顺序。
const engineOrder = ['volc', 'baidu', 'llm', 'deepl', 'tencent'];

/// 自动划词默认生效的程序：浏览器、PDF 阅读器、Office、笔记软件。
/// 在这些程序里，对选中文字发送 Ctrl+C 是安全的。
const defaultAutoSelectApps = '''chrome.exe
msedge.exe
firefox.exe
brave.exe
vivaldi.exe
opera.exe
360se.exe
360chrome.exe
QQBrowser.exe
SogouExplorer.exe
Acrobat.exe
AcroRd32.exe
SumatraPDF.exe
FoxitPDFReader.exe
FoxitReader.exe
FoxitPhantomPDF.exe
PDFXEdit.exe
WINWORD.EXE
POWERPNT.EXE
OUTLOOK.EXE
ONENOTE.EXE
wps.exe
wpp.exe
Typora.exe
Obsidian.exe
Notion.exe
zotero.exe
notepad.exe
notepad++.exe
WeChat.exe
Weixin.exe
''';

/// 选中文字后的行为。
enum AutoSelectMode {
  /// 在鼠标旁显示小图标，点击后翻译。
  icon,

  /// 直接弹出翻译窗口。
  popup,
}

class HotkeyPreset {
  const HotkeyPreset(this.label, this.ctrl, this.alt, this.shift, this.key);
  final String label;
  final bool ctrl;
  final bool alt;
  final bool shift;

  /// 单个字母键（大写），如 'D'。
  final String key;
}

const hotkeyPresets = <HotkeyPreset>[
  HotkeyPreset('Alt + D', false, true, false, 'D'),
  HotkeyPreset('Ctrl + Alt + D', true, true, false, 'D'),
  HotkeyPreset('Ctrl + Shift + X', true, false, true, 'X'),
  HotkeyPreset('Alt + Q', false, true, false, 'Q'),
];

/// 截图识别热键。最后一项表示不注册。
const ocrHotkeyPresets = <HotkeyPreset>[
  HotkeyPreset('Alt + S', false, true, false, 'S'),
  HotkeyPreset('Ctrl + Alt + S', true, true, false, 'S'),
  HotkeyPreset('Alt + W', false, true, false, 'W'),
  HotkeyPreset('关闭', false, false, false, ''),
];

/// 应用设置，基于 SharedPreferences 持久化。
class Settings extends ChangeNotifier {
  Settings._();
  static final Settings instance = Settings._();

  late SharedPreferences _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    await _migrateAi();
    await _migrateGlossary();
  }

  /// 已经改过术语表的用户：把新版默认术语里缺少的条目补到末尾（只补一次）。
  Future<void> _migrateGlossary() async {
    if (_p.getBool('glossaryV2') ?? false) return;
    final saved = _p.getString('glossary');
    if (saved != null) {
      final have = parseGlossary(saved).keys.map((k) => k.toLowerCase()).toSet();
      final add = defaultGlossary
          .split('\n')
          .where((l) => l.contains('=') && !l.trimLeft().startsWith('#'))
          .where((l) => !have.contains(l.split('=').first.trim().toLowerCase()))
          .toList();
      if (add.isNotEmpty) {
        await _p.setString('glossary', '${saved.trimRight()}\n${add.join('\n')}\n');
      }
    }
    await _p.setBool('glossaryV2', true);
  }

  /// v0.3.1 之前只有一个“大模型接口”。把原来填的智谱/魔搭密钥迁移到新的分平台密钥，
  /// 其他接口（DeepSeek、Ollama 等）保留为“自定义接口”并接在默认线路后面。
  Future<void> _migrateAi() async {
    if (_p.getBool('aiMigrated') ?? false) return;
    final base = _p.getString('llmBaseUrl');
    final key = _p.getString('llmKey') ?? '';
    if (key.isNotEmpty && (base == null || base.contains('bigmodel.cn'))) {
      if (zhipuKey.isEmpty) await _p.setString('zhipuKey', key);
      await _p.remove('llmBaseUrl');
      await _p.remove('llmKey');
      await _p.remove('llmModel');
    } else if (key.isNotEmpty && base != null && base.contains('modelscope.cn')) {
      if (modelscopeKey.isEmpty) await _p.setString('modelscopeKey', key);
      await _p.remove('llmBaseUrl');
      await _p.remove('llmKey');
      await _p.remove('llmModel');
    } else if (base != null && base.isNotEmpty && !base.contains('bigmodel.cn')) {
      await _p.setStringList('aiChain', [...defaultAiChain, 'custom']);
    }
    await _p.setBool('aiMigrated', true);
  }

  String _s(String k, [String d = '']) => _p.getString(k) ?? d;
  Future<void> _set(String k, Object v) async {
    if (v is String) await _p.setString(k, v);
    if (v is bool) await _p.setBool(k, v);
    if (v is int) await _p.setInt(k, v);
    if (v is List<String>) await _p.setStringList(k, v);
    notifyListeners();
  }

  // ---- 腾讯云机器翻译 ----
  String get tencentId => _s('tencentId');
  set tencentId(String v) => _set('tencentId', v.trim());
  String get tencentKey => _s('tencentKey');
  set tencentKey(String v) => _set('tencentKey', v.trim());
  String get tencentRegion => _s('tencentRegion', 'ap-guangzhou');
  set tencentRegion(String v) => _set('tencentRegion', v.trim());

  // ---- 火山引擎 ----
  String get volcAk => _s('volcAk');
  set volcAk(String v) => _set('volcAk', v.trim());
  String get volcSk => _s('volcSk');
  set volcSk(String v) => _set('volcSk', v.trim());

  // ---- 百度翻译 ----
  String get baiduAppId => _s('baiduAppId');
  set baiduAppId(String v) => _set('baiduAppId', v.trim());
  String get baiduKey => _s('baiduKey');
  set baiduKey(String v) => _set('baiduKey', v.trim());

  // ---- DeepL ----
  String get deeplKey => _s('deeplKey');
  set deeplKey(String v) => _set('deeplKey', v.trim());

  // ---- AI 翻译（OpenAI 兼容接口，按线路顺序自动切换）----
  /// 魔搭 ModelScope 访问令牌（ms- 开头）。
  String get modelscopeKey => _s('modelscopeKey');
  set modelscopeKey(String v) => _set('modelscopeKey', v.trim());

  /// 智谱开放平台 API Key。
  String get zhipuKey => _s('zhipuKey');
  set zhipuKey(String v) => _set('zhipuKey', v.trim());

  /// 启用的 AI 线路 id，按尝试顺序。见 [aiRoutes]。
  List<String> get aiChain => (_p.getStringList('aiChain') ?? defaultAiChain)
      .where((id) => aiRouteById(id) != null)
      .toList();
  set aiChain(List<String> v) => _set('aiChain', v);

  // 自定义接口（DeepSeek、通义千问、Kimi、Ollama 等）
  String get llmBaseUrl => _s('llmBaseUrl');
  set llmBaseUrl(String v) => _set('llmBaseUrl', v.trim());
  String get llmKey => _s('llmKey');
  set llmKey(String v) => _set('llmKey', v.trim());
  String get llmModel => _s('llmModel');
  set llmModel(String v) => _set('llmModel', v.trim());

  /// 启用的翻译引擎 id，按显示顺序。
  List<String> get enabledEngines =>
      _p.getStringList('enabledEngines') ?? const ['volc', 'baidu', 'llm'];
  set enabledEngines(List<String> v) => _set('enabledEngines', v);

  bool isEngineEnabled(String id) => enabledEngines.contains(id);
  void setEngineEnabled(String id, bool on) {
    final list = List<String>.from(enabledEngines)..remove(id);
    if (on) {
      const order = engineOrder;
      list.add(id);
      list.sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
    }
    enabledEngines = list;
  }

  // ---- 术语表 ----
  String get glossary => _s('glossary', defaultGlossary);
  set glossary(String v) => _set('glossary', v);

  // ---- 词库 ----
  /// 标准词库下载地址（gzip 压缩的 SQLite）。CI 会把它发布到仓库的 Release。
  static const defaultDictUrl =
      'https://github.com/Chafer01/lingyi/releases/download/dict-v1/standard.db.gz';
  String get standardDictUrl => _s('standardDictUrl', defaultDictUrl);
  set standardDictUrl(String v) => _set('standardDictUrl', v.trim());

  // ---- 桌面 ----
  int get hotkeyIndex => (_p.getInt('hotkeyIndex') ?? 0).clamp(0, hotkeyPresets.length - 1);
  set hotkeyIndex(int v) => _set('hotkeyIndex', v);
  HotkeyPreset get hotkey => hotkeyPresets[hotkeyIndex];

  bool get clipboardWatch => _p.getBool('clipboardWatch') ?? false;
  set clipboardWatch(bool v) => _set('clipboardWatch', v);

  /// 选中文字后自动取词。
  bool get autoSelect => _p.getBool('autoSelect') ?? true;
  set autoSelect(bool v) => _set('autoSelect', v);

  AutoSelectMode get autoSelectMode =>
      AutoSelectMode.values[(_p.getInt('autoSelectMode') ?? 0).clamp(0, AutoSelectMode.values.length - 1)];
  set autoSelectMode(AutoSelectMode v) => _set('autoSelectMode', v.index);

  /// 生效范围：false = 只在列表中的程序，true = 所有程序（终端除外）。
  bool get autoSelectAllApps => _p.getBool('autoSelectAllApps') ?? false;
  set autoSelectAllApps(bool v) => _set('autoSelectAllApps', v);

  /// 程序列表（每行一个 exe 名）。范围为“所有程序”时，作为排除列表使用。
  String get autoSelectApps => _s('autoSelectApps', defaultAutoSelectApps);
  set autoSelectApps(String v) => _set('autoSelectApps', v);

  String get autoSelectExclude => _s('autoSelectExclude', 'Code.exe\n');
  set autoSelectExclude(String v) => _set('autoSelectExclude', v);

  bool get closeToTray => _p.getBool('closeToTray') ?? true;
  set closeToTray(bool v) => _set('closeToTray', v);

  // ---- 截图识别与 PDF 翻译（Windows，本地 Python 后端）----
  int get ocrHotkeyIndex => (_p.getInt('ocrHotkeyIndex') ?? 0).clamp(0, ocrHotkeyPresets.length - 1);
  set ocrHotkeyIndex(int v) => _set('ocrHotkeyIndex', v);
  HotkeyPreset get ocrHotkey => ocrHotkeyPresets[ocrHotkeyIndex];

  /// 后端启动命令。留空时使用随包附带的 backend\lingyi_backend.exe；
  /// 从源码运行时可填 `python -m lingyi_backend`，并把工作目录设为仓库的 backend 文件夹。
  String get backendCmd => _s('backendCmd');
  set backendCmd(String v) => _set('backendCmd', v);
  String get backendDir => _s('backendDir');
  set backendDir(String v) => _set('backendDir', v);

  /// PDF 翻译：每秒请求数（免费大模型一般只允许 1 个并发）。
  int get pdfQps => (_p.getInt('pdfQps') ?? 1).clamp(1, 32);
  set pdfQps(int v) => _set('pdfQps', v);

  /// PDF 输出：dual 左右对照 / alternating 原文译文交替页 / mono 仅译文 / both 双语 + 仅译文。
  String get pdfOutput => _s('pdfOutput', 'dual');
  set pdfOutput(String v) => _set('pdfOutput', v);

  /// 翻译前先让 AI 自动提取全文术语，保证前后译法一致（会多消耗一些额度）。
  bool get pdfExtractTerms => _p.getBool('pdfExtractTerms') ?? true;
  set pdfExtractTerms(bool v) => _set('pdfExtractTerms', v);

  // ---- 外观 ----
  ThemeMode get themeMode => ThemeMode.values[(_p.getInt('themeMode') ?? 0).clamp(0, 2)];
  set themeMode(ThemeMode v) => _set('themeMode', v.index);
}
