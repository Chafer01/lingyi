/// 文本相关的纯函数工具：语言判断、查词判定、词形解析等。
library;

final _cjk = RegExp(r'[㐀-鿿豈-﫿]');
final _latin = RegExp(r'[A-Za-z]');
final _edgePunct = RegExp(r'''^[\s"'“”‘’()\[\]{}<>«»,.;:!?，。；：！？、…—\-]+|[\s"'“”‘’()\[\]{}<>«»,.;:!?，。；：！？、…—\-]+$''');
final _wordLike = RegExp(r"^[A-Za-z][A-Za-z'\-.]*( [A-Za-z][A-Za-z'\-.]*){0,2}$");

/// 文本主要语言。
enum Lang { zh, en }

/// 统计中文字符与拉丁字母的比例，判断主要语言。
Lang detectLang(String text) {
  final cjk = _cjk.allMatches(text).length;
  final latin = _latin.allMatches(text).length;
  // 一个汉字的信息量大约相当于 2~3 个字母。
  return cjk * 2.5 >= latin && cjk > 0 ? Lang.zh : Lang.en;
}

/// 去掉首尾标点和空白，合并内部空白。
String normalizeQuery(String raw) {
  var s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceAll(_edgePunct, '');
  return s;
}

/// 是否应当走词典（单词或不超过 3 个词的短语），否则走翻译。
bool isDictionaryQuery(String raw) {
  final s = normalizeQuery(raw);
  if (s.isEmpty || s.length > 48) return false;
  if (_wordLike.hasMatch(s)) return true;
  // 不超过 6 个字的纯中文，也尝试反查词典。
  return s.length <= 6 && RegExp(r'^[㐀-鿿]+$').hasMatch(s);
}

/// 根据常见屈折变化，猜测可能的原形（词典查不到时使用）。
List<String> stemCandidates(String word) {
  final w = word.toLowerCase();
  final out = <String>[];
  void add(String s) {
    if (s.length >= 2 && s != w && !out.contains(s)) out.add(s);
  }

  if (w.endsWith('ies')) add('${w.substring(0, w.length - 3)}y');
  if (w.endsWith('ied')) add('${w.substring(0, w.length - 3)}y');
  if (w.endsWith('es')) add(w.substring(0, w.length - 2));
  if (w.endsWith('s') && !w.endsWith('ss')) add(w.substring(0, w.length - 1));
  if (w.endsWith('ed')) {
    final base = w.substring(0, w.length - 2);
    add(base);
    add('${base}e');
    if (base.length > 2 && base[base.length - 1] == base[base.length - 2]) {
      add(base.substring(0, base.length - 1)); // stopped -> stop
    }
  }
  if (w.endsWith('ing')) {
    final base = w.substring(0, w.length - 3);
    add(base);
    add('${base}e');
    if (base.length > 2 && base[base.length - 1] == base[base.length - 2]) {
      add(base.substring(0, base.length - 1)); // running -> run
    }
  }
  if (w.endsWith('er')) add(w.substring(0, w.length - 2));
  if (w.endsWith('est')) add(w.substring(0, w.length - 3));
  if (w.endsWith('ly')) add(w.substring(0, w.length - 2));
  if (w.contains('-')) add(w.replaceAll('-', ''));
  return out;
}

/// ECDICT exchange 字段中各类词形的中文名称。
const exchangeNames = <String, String>{
  'p': '过去式',
  'd': '过去分词',
  'i': '现在分词',
  '3': '第三人称单数',
  'r': '比较级',
  't': '最高级',
  's': '复数',
  '0': '原形',
};

/// 解析 exchange 字段，例如 "p:went/d:gone/i:going/3:goes"。
/// 返回有序的 (类型, 词形) 列表，不含 "1:"（原形变换类型标记）。
List<MapEntry<String, String>> parseExchange(String? exchange) {
  if (exchange == null || exchange.isEmpty) return const [];
  final out = <MapEntry<String, String>>[];
  for (final part in exchange.split('/')) {
    final i = part.indexOf(':');
    if (i <= 0) continue;
    final k = part.substring(0, i);
    final v = part.substring(i + 1);
    if (k == '1' || v.isEmpty) continue;
    out.add(MapEntry(k, v));
  }
  return out;
}

/// 原形（exchange 中的 "0:" 项），没有则返回 null。
String? lemmaOf(String? exchange) {
  for (final e in parseExchange(exchange)) {
    if (e.key == '0') return e.value;
  }
  return null;
}

/// ECDICT tag 字段的中文名称。
const tagNames = <String, String>{
  'zk': '中考',
  'gk': '高考',
  'cet4': '四级',
  'cet6': '六级',
  'ky': '考研',
  'toefl': '托福',
  'ielts': '雅思',
  'gre': 'GRE',
};

List<String> parseTags(String? tag) {
  if (tag == null || tag.trim().isEmpty) return const [];
  return tag
      .trim()
      .split(RegExp(r'\s+'))
      .map((t) => tagNames[t] ?? t.toUpperCase())
      .toList();
}

/// 一条中文释义行，拆分为 (词性, 释义)。例如 "n. 天线, 触须" -> ("n.", "天线, 触须")；
/// "[计] 阻抗" -> ("[计]", "阻抗")。
MapEntry<String, String> splitPos(String line) {
  final m = RegExp(r'^((?:[a-z]+\.&?)+|\[[^\]]+\])\s*(.*)$').firstMatch(line.trim());
  if (m == null) return MapEntry('', line.trim());
  return MapEntry(m.group(1)!, m.group(2)!.trim());
}

/// 术语表：每行 "英文 = 中文"（也接受 "=" 两侧的空格、"→"、制表符）。
Map<String, String> parseGlossary(String text) {
  final out = <String, String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split(RegExp(r'\s*(?:=|→|\t)\s*'));
    if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      out[parts[0]] = parts[1];
    }
  }
  return out;
}

/// 找出原文中出现的术语（英文不区分大小写、按整词匹配；中文直接包含）。
Map<String, String> glossaryHits(String text, Map<String, String> glossary) {
  final hits = <String, String>{};
  final lower = text.toLowerCase();
  bool containsTerm(String term) {
    if (!_latin.hasMatch(term)) return text.contains(term);
    final re = RegExp(r'(^|[^A-Za-z])' + RegExp.escape(term.toLowerCase()) + r'($|[^A-Za-z])');
    return re.hasMatch(lower);
  }

  glossary.forEach((src, dst) {
    if (containsTerm(src)) {
      hits[src] = dst;
    } else if (containsTerm(dst)) {
      // 中译英时，原文里出现的是中文一侧。
      hits[dst] = src;
    }
  });
  return hits;
}
