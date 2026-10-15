import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
''';

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

/// 应用设置，基于 SharedPreferences 持久化。
class Settings extends ChangeNotifier {
  Settings._();
  static final Settings instance = Settings._();

  late SharedPreferences _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
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

  // ---- DeepL ----
  String get deeplKey => _s('deeplKey');
  set deeplKey(String v) => _set('deeplKey', v.trim());

  // ---- 大模型（OpenAI 兼容接口：DeepSeek、通义千问、Kimi、Ollama 等）----
  String get llmBaseUrl => _s('llmBaseUrl', 'https://api.deepseek.com/v1');
  set llmBaseUrl(String v) => _set('llmBaseUrl', v.trim());
  String get llmKey => _s('llmKey');
  set llmKey(String v) => _set('llmKey', v.trim());
  String get llmModel => _s('llmModel', 'deepseek-chat');
  set llmModel(String v) => _set('llmModel', v.trim());

  /// 启用的翻译引擎 id，按显示顺序。
  List<String> get enabledEngines =>
      _p.getStringList('enabledEngines') ?? const ['tencent', 'deepl', 'llm'];
  set enabledEngines(List<String> v) => _set('enabledEngines', v);

  bool isEngineEnabled(String id) => enabledEngines.contains(id);
  void setEngineEnabled(String id, bool on) {
    final list = List<String>.from(enabledEngines)..remove(id);
    if (on) {
      const order = ['tencent', 'deepl', 'llm'];
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

  bool get closeToTray => _p.getBool('closeToTray') ?? true;
  set closeToTray(bool v) => _set('closeToTray', v);

  // ---- 外观 ----
  ThemeMode get themeMode => ThemeMode.values[(_p.getInt('themeMode') ?? 0).clamp(0, 2)];
  set themeMode(ThemeMode v) => _set('themeMode', v.index);
}
