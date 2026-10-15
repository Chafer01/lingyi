import 'package:flutter_test/flutter_test.dart';
import 'package:lingyi/services/backend.dart';

void main() {
  group('本地后端', () {
    test('splitCommandLine', () {
      expect(splitCommandLine('python -m lingyi_backend'), ['python', '-m', 'lingyi_backend']);
      expect(splitCommandLine('"C:\\Program Files\\Python312\\python.exe"  -m  lingyi_backend'),
          ['C:\\Program Files\\Python312\\python.exe', '-m', 'lingyi_backend']);
      expect(splitCommandLine('  '), isEmpty);
    });

    test('PdfJob 解析', () {
      final j = PdfJob({
        'id': 'abc',
        'status': 'running',
        'stage': '翻译段落',
        'progress': 42.5,
        'file': 'paper.pdf',
        'elapsed': 12,
        'outputs': {'dual': 'C:\\a.zh.dual.pdf'},
      });
      expect(j.finished, isFalse);
      expect(j.progress, 42.5);
      expect(j.outputs['dual'], 'C:\\a.zh.dual.pdf');
      expect(PdfJob({'id': 'x', 'status': 'error'}).finished, isTrue);
    });

    test('OcrResult 解析', () {
      final r = OcrResult({'mode': 'formula', 'text': r'G=\frac{a}{b}', 'latex': r'G=\frac{a}{b}', 'mathml': '<math/>'});
      expect(r.latex, r'G=\frac{a}{b}');
      expect(r.image, isNull);
    });
  });
}
