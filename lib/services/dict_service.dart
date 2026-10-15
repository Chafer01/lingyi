import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../util/text_utils.dart';

/// 一条词典词条（字段对应 ECDICT）。
class WordEntry {
  WordEntry({
    required this.word,
    this.phonetic = '',
    this.definition = '',
    this.translation = '',
    this.pos = '',
    this.collins = 0,
    this.oxford = false,
    this.tag = '',
    this.bnc = 0,
    this.frq = 0,
    this.exchange = '',
  });

  factory WordEntry.fromRow(Row r) => WordEntry(
        word: r['word'] as String,
        phonetic: (r['phonetic'] as String?) ?? '',
        definition: (r['definition'] as String?) ?? '',
        translation: (r['translation'] as String?) ?? '',
        pos: (r['pos'] as String?) ?? '',
        collins: (r['collins'] as int?) ?? 0,
        oxford: ((r['oxford'] as int?) ?? 0) > 0,
        tag: (r['tag'] as String?) ?? '',
        bnc: (r['bnc'] as int?) ?? 0,
        frq: (r['frq'] as int?) ?? 0,
        exchange: (r['exchange'] as String?) ?? '',
      );

  final String word;
  final String phonetic;
  final String definition;
  final String translation;
  final String pos;
  final int collins;
  final bool oxford;
  final String tag;
  final int bnc;
  final int frq;
  final String exchange;

  /// 中文释义第一行，用于列表展示。
  String get brief {
    final first = translation.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    return first.trim();
  }
}

/// 一次查词的结果。
class LookupResult {
  LookupResult({required this.query, this.entry, this.lemma, this.guessedFrom, this.suggestions = const []});

  final String query;

  /// 命中的词条。
  final WordEntry? entry;

  /// 若命中的是变形（如 went），这里是原形词条（go）。
  final WordEntry? lemma;

  /// 若通过去词尾猜测命中，记录原始输入。
  final String? guessedFrom;

  /// 未命中时的相近词（前缀匹配）。
  final List<WordEntry> suggestions;

  bool get found => entry != null;
}

/// 词库状态。
enum DictEdition { none, core, standard, custom }

/// 本地 ECDICT 词典服务。
///
/// 内置 core.db（约 6 万常用词，打包在 App 里）；可选下载 standard.db（约 135 万词）。
/// 也兼容 ECDICT 官方的 stardict.db（表名 stardict）。
class DictService extends ChangeNotifier {
  DictService._();
  static final DictService instance = DictService._();

  static const _coreVersion = '1';

  Database? _db;
  String _table = 'dict';
  DictEdition edition = DictEdition.none;
  int wordCount = 0;
  late Directory _dir;

  /// 标准词库下载进度（0~1），null 表示没有在下载。
  final ValueNotifier<double?> downloadProgress = ValueNotifier(null);

  String get editionLabel => switch (edition) {
        DictEdition.none => '未加载',
        DictEdition.core => '内置常用词库',
        DictEdition.standard => '标准词库',
        DictEdition.custom => '自定义词库',
      };

  File get _coreFile => File('${_dir.path}${Platform.pathSeparator}core.db');
  File get _standardFile => File('${_dir.path}${Platform.pathSeparator}standard.db');
  File get _customFile => File('${_dir.path}${Platform.pathSeparator}custom.db');

  bool get hasStandard => _standardFile.existsSync();

  Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    _dir = Directory('${support.path}${Platform.pathSeparator}dict');
    await _dir.create(recursive: true);
    await _ensureCore();
    _openBest();
  }

  /// 首次启动时把内置的 core.db.gz 解压到应用目录（SQLite 需要真实文件）。
  Future<void> _ensureCore() async {
    final marker = File('${_coreFile.path}.v');
    if (_coreFile.existsSync() && marker.existsSync() && marker.readAsStringSync() == _coreVersion) {
      return;
    }
    final data = await rootBundle.load('assets/dict/core.db.gz');
    final gz = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final raw = await Isolate.run(() => gzip.decode(gz));
    await _coreFile.writeAsBytes(raw, flush: true);
    await marker.writeAsString(_coreVersion);
  }

  void _openBest() {
    _db?.close();
    _db = null;
    for (final (file, ed) in [
      (_customFile, DictEdition.custom),
      (_standardFile, DictEdition.standard),
      (_coreFile, DictEdition.core),
    ]) {
      if (!file.existsSync()) continue;
      try {
        final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
        final tables = db
            .select("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('dict','stardict')")
            .map((r) => r['name'] as String)
            .toList();
        if (tables.isEmpty) {
          db.close();
          continue;
        }
        _table = tables.contains('dict') ? 'dict' : 'stardict';
        _db = db;
        edition = ed;
        wordCount = db.select('SELECT count(*) AS n FROM $_table').first['n'] as int;
        break;
      } catch (e) {
        debugPrint('打开词库失败 ${file.path}: $e');
      }
    }
    notifyListeners();
  }

  WordEntry? _get(String word) {
    final db = _db;
    if (db == null || word.isEmpty) return null;
    final rows = db.select('SELECT * FROM $_table WHERE word = ? LIMIT 1', [word]);
    return rows.isEmpty ? null : WordEntry.fromRow(rows.first);
  }

  /// 查词：精确 → 去标点/小写 → 去词尾猜测 → 前缀联想。
  LookupResult lookup(String raw) {
    final q = normalizeQuery(raw);
    WordEntry? entry = _get(q);
    String? guessedFrom;
    if (entry == null) {
      for (final c in stemCandidates(q)) {
        entry = _get(c);
        if (entry != null) {
          guessedFrom = q;
          break;
        }
      }
    }
    if (entry == null) {
      return LookupResult(query: q, suggestions: suggest(q, limit: 8));
    }
    WordEntry? lemma;
    final l = lemmaOf(entry.exchange);
    if (l != null && l.toLowerCase() != entry.word.toLowerCase()) lemma = _get(l);
    return LookupResult(query: q, entry: entry, lemma: lemma, guessedFrom: guessedFrom);
  }

  /// 前缀联想，按词频排序。
  List<WordEntry> suggest(String prefix, {int limit = 10}) {
    final db = _db;
    final p = normalizeQuery(prefix);
    if (db == null || p.isEmpty || detectLang(p) == Lang.zh) return const [];
    // 利用主键索引做范围查询，再按词频排序。
    final rows = db.select(
      'SELECT * FROM $_table WHERE word >= ? AND word < ? LIMIT 300',
      [p, '$p\u{10FFFF}'],
    );
    final list = rows.map(WordEntry.fromRow).toList();
    int rank(WordEntry e) {
      final f = [e.frq, e.bnc].where((x) => x > 0);
      return f.isEmpty ? 1 << 30 : f.reduce((a, b) => a < b ? a : b);
    }

    list.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.word.length.compareTo(b.word.length);
    });
    return list.take(limit).toList();
  }

  /// 中文反查英文：在释义中搜索，按词频排序。
  List<WordEntry> reverseLookup(String zh, {int limit = 20}) {
    final db = _db;
    final q = normalizeQuery(zh);
    if (db == null || q.isEmpty) return const [];
    final rows = db.select(
      'SELECT * FROM $_table WHERE translation LIKE ? AND (frq > 0 OR bnc > 0 OR collins > 0) '
      'ORDER BY CASE WHEN frq > 0 THEN frq ELSE 999999 END LIMIT ?',
      ['%$q%', limit],
    );
    return rows.map(WordEntry.fromRow).toList();
  }

  /// 下载标准词库（gzip 压缩的 SQLite），边下载边解压。
  Future<void> downloadStandard(String url) async {
    if (downloadProgress.value != null) return;
    downloadProgress.value = 0;
    final tmp = File('${_standardFile.path}.part');
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(url)));
      if (resp.statusCode != 200) {
        throw HttpException('下载失败：HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength ?? 0;
      var received = 0;
      final counted = resp.stream.map((chunk) {
        received += chunk.length;
        if (total > 0) downloadProgress.value = received / total;
        return chunk;
      });
      final sink = tmp.openWrite();
      final source = url.endsWith('.gz') ? counted.transform(gzip.decoder) : counted;
      await sink.addStream(source);
      await sink.close();
      _db?.close();
      _db = null;
      if (_standardFile.existsSync()) await _standardFile.delete();
      await tmp.rename(_standardFile.path);
      _openBest();
    } finally {
      client.close();
      if (tmp.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      downloadProgress.value = null;
    }
  }

  /// 导入本地词库文件（例如 ECDICT 官方的 stardict.db）。
  Future<void> importCustom(String path) async {
    final src = File(path);
    if (!src.existsSync()) throw FileSystemException('文件不存在', path);
    // 先校验是不是可用的词库。
    final test = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      final ok = test
          .select("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('dict','stardict')")
          .isNotEmpty;
      if (!ok) throw const FormatException('不是 ECDICT 格式的词库（缺少 dict 或 stardict 表）');
    } finally {
      test.close();
    }
    _db?.close();
    _db = null;
    await src.copy(_customFile.path);
    _openBest();
  }

  /// 删除已下载/导入的词库，回到内置词库。
  Future<void> removeExtra() async {
    _db?.close();
    _db = null;
    for (final f in [_customFile, _standardFile]) {
      if (f.existsSync()) await f.delete();
    }
    _openBest();
  }
}
