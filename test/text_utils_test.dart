import 'package:flutter_test/flutter_test.dart';
import 'package:lingyi/services/translate/tencent.dart';
import 'package:lingyi/util/text_utils.dart';

void main() {
  group('语言与查询判定', () {
    test('detectLang', () {
      expect(detectLang('hello world'), Lang.en);
      expect(detectLang('天线增益'), Lang.zh);
      expect(detectLang('S11 参数小于 -10 dB'), Lang.zh);
      expect(detectLang('The VSWR 很高'), Lang.en);
    });

    test('isDictionaryQuery', () {
      expect(isDictionaryQuery('antenna'), isTrue);
      expect(isDictionaryQuery('  "Antenna," '), isTrue);
      expect(isDictionaryQuery('front-to-back'), isTrue);
      expect(isDictionaryQuery('look up to'), isTrue);
      expect(isDictionaryQuery('The antenna gain is 18 dBi.'), isFalse);
      expect(isDictionaryQuery('天线'), isTrue);
      expect(isDictionaryQuery('这根天线的增益是多少'), isFalse);
    });

    test('normalizeQuery', () {
      expect(normalizeQuery('  “Antenna”. '), 'Antenna');
      expect(normalizeQuery('a\n  b'), 'a b');
    });
  });

  group('词形', () {
    test('stemCandidates', () {
      expect(stemCandidates('studies'), contains('study'));
      expect(stemCandidates('stopped'), contains('stop'));
      expect(stemCandidates('running'), contains('run'));
      expect(stemCandidates('making'), contains('make'));
      expect(stemCandidates('antennas'), contains('antenna'));
    });

    test('parseExchange / lemmaOf', () {
      final ex = parseExchange('0:go/1:p');
      expect(ex.single.key, '0');
      expect(lemmaOf('0:go/1:p'), 'go');
      expect(parseExchange('p:went/d:gone/i:going/3:goes').length, 4);
      expect(parseExchange(null), isEmpty);
    });

    test('splitPos', () {
      expect(splitPos('n. 天线, 触须').key, 'n.');
      expect(splitPos('[计] 阻抗').value, '阻抗');
      expect(splitPos('vt.&vi. 运行').key, isNotEmpty);
      expect(splitPos('天线下倾角').key, '');
    });

    test('parseTags', () {
      expect(parseTags('cet6 ky gre'), ['六级', '考研', 'GRE']);
    });
  });

  group('术语表', () {
    final g = parseGlossary('# 注释\nradiation pattern = 方向图\nVSWR=电压驻波比\ngain → 增益\n');
    test('parseGlossary', () {
      expect(g.length, 3);
      expect(g['VSWR'], '电压驻波比');
      expect(g['gain'], '增益');
    });
    test('glossaryHits 英译中', () {
      final hits = glossaryHits('The Radiation Pattern and VSWR were measured.', g);
      expect(hits.keys, containsAll(['radiation pattern', 'VSWR']));
      expect(hits.containsKey('gain'), isFalse);
    });
    test('glossaryHits 整词匹配', () {
      expect(glossaryHits('regain control', g).containsKey('gain'), isFalse);
    });
    test('glossaryHits 中译英', () {
      final hits = glossaryHits('该天线的方向图很好', g);
      expect(hits['方向图'], 'radiation pattern');
    });
  });

  test('腾讯云 TC3 签名与官方算法一致', () {
    // 期望值由 Python 按腾讯云文档的签名算法独立计算。
    final h = TencentEngine.signedHeaders(
      secretId: 'AKIDtest123',
      secretKey: 'secretKeyTest456',
      region: 'ap-guangzhou',
      payload: '{"SourceText":"hello","Source":"auto","Target":"zh","ProjectId":0}',
      now: DateTime.fromMillisecondsSinceEpoch(1760500000 * 1000, isUtc: true),
    );
    expect(
      h['Authorization'],
      'TC3-HMAC-SHA256 Credential=AKIDtest123/2025-10-15/tmt/tc3_request, '
      'SignedHeaders=content-type;host;x-tc-action, '
      'Signature=f8c354da79d5e091fcb998fc7b52b82f30af4e8f6c9d8ccfe737dd38477243a8',
    );
    expect(h['X-TC-Timestamp'], '1760500000');
  });
}
