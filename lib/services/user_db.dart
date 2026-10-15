import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

class HistoryItem {
  HistoryItem(this.id, this.text, this.result, this.time);
  final int id;
  final String text;
  final String result;
  final DateTime time;
}

class WordbookItem {
  WordbookItem({
    required this.word,
    required this.phonetic,
    required this.translation,
    required this.context,
    required this.added,
    required this.lookups,
  });
  final String word;
  final String phonetic;
  final String translation;
  final String context;
  final DateTime added;
  final int lookups;
}

/// 用户数据：查询历史、生词本。
class UserDb extends ChangeNotifier {
  UserDb._();
  static final UserDb instance = UserDb._();

  late Database _db;

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _db = sqlite3.open('${dir.path}${Platform.pathSeparator}user.db');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL,
        result TEXT NOT NULL DEFAULT '',
        time INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS wordbook (
        word TEXT PRIMARY KEY COLLATE NOCASE,
        phonetic TEXT NOT NULL DEFAULT '',
        translation TEXT NOT NULL DEFAULT '',
        context TEXT NOT NULL DEFAULT '',
        added INTEGER NOT NULL,
        lookups INTEGER NOT NULL DEFAULT 1
      );
      CREATE TABLE IF NOT EXISTS lookup_count (
        word TEXT PRIMARY KEY COLLATE NOCASE,
        n INTEGER NOT NULL
      );
    ''');
  }

  // ---------------- 历史 ----------------

  void addHistory(String text, String result) {
    final t = text.trim();
    if (t.isEmpty) return;
    // 同样的内容只保留最新一条。
    _db.execute('DELETE FROM history WHERE text = ?', [t]);
    _db.execute('INSERT INTO history (text, result, time) VALUES (?, ?, ?)',
        [t, result, DateTime.now().millisecondsSinceEpoch]);
    _db.execute('DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY id DESC LIMIT 1000)');
    notifyListeners();
  }

  List<HistoryItem> history({int limit = 300}) => _db
      .select('SELECT * FROM history ORDER BY id DESC LIMIT ?', [limit])
      .map((r) => HistoryItem(r['id'] as int, r['text'] as String, r['result'] as String,
          DateTime.fromMillisecondsSinceEpoch(r['time'] as int)))
      .toList();

  void deleteHistory(int id) {
    _db.execute('DELETE FROM history WHERE id = ?', [id]);
    notifyListeners();
  }

  void clearHistory() {
    _db.execute('DELETE FROM history');
    notifyListeners();
  }

  // ---------------- 查词次数 ----------------

  /// 记录一次查词，返回累计次数。
  int countLookup(String word) {
    _db.execute(
        'INSERT INTO lookup_count (word, n) VALUES (?, 1) ON CONFLICT(word) DO UPDATE SET n = n + 1', [word]);
    _db.execute('UPDATE wordbook SET lookups = lookups + 1 WHERE word = ?', [word]);
    final r = _db.select('SELECT n FROM lookup_count WHERE word = ?', [word]);
    return r.isEmpty ? 1 : r.first['n'] as int;
  }

  // ---------------- 生词本 ----------------

  bool inWordbook(String word) =>
      _db.select('SELECT 1 FROM wordbook WHERE word = ?', [word]).isNotEmpty;

  void addWord(String word, String phonetic, String translation, {String context = ''}) {
    final n = _db.select('SELECT n FROM lookup_count WHERE word = ?', [word]);
    _db.execute(
      'INSERT OR REPLACE INTO wordbook (word, phonetic, translation, context, added, lookups) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [word, phonetic, translation, context, DateTime.now().millisecondsSinceEpoch, n.isEmpty ? 1 : n.first['n']],
    );
    notifyListeners();
  }

  void removeWord(String word) {
    _db.execute('DELETE FROM wordbook WHERE word = ?', [word]);
    notifyListeners();
  }

  List<WordbookItem> wordbook({String orderBy = 'added'}) {
    final order = orderBy == 'lookups' ? 'lookups DESC, added DESC' : 'added DESC';
    return _db
        .select('SELECT * FROM wordbook ORDER BY $order')
        .map((r) => WordbookItem(
              word: r['word'] as String,
              phonetic: r['phonetic'] as String,
              translation: r['translation'] as String,
              context: r['context'] as String,
              added: DateTime.fromMillisecondsSinceEpoch(r['added'] as int),
              lookups: r['lookups'] as int,
            ))
        .toList();
  }

  /// 导出为 Anki 可直接导入的制表符分隔文本：正面=单词，背面=音标+释义+例句。
  Future<File> exportWordbook() async {
    final dir = Platform.isAndroid
        ? (await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory())
        : await getApplicationDocumentsDirectory();
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final file = File('${dir.path}${Platform.pathSeparator}灵译生词本_$stamp.txt');
    String clean(String s) => s.replaceAll('\t', ' ').replaceAll('\n', '<br>');
    final buf = StringBuffer()
      ..writeln('#separator:tab')
      ..writeln('#html:true');
    for (final w in wordbook()) {
      final back = [
        if (w.phonetic.isNotEmpty) '[${w.phonetic}]',
        w.translation,
        if (w.context.isNotEmpty) '<i>${w.context}</i>',
      ].join('<br>');
      buf.writeln('${clean(w.word)}\t${clean(back)}');
    }
    await file.writeAsString(buf.toString());
    return file;
  }
}
