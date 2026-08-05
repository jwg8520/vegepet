import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final path = args[0];
  final startLine = int.parse(args[1]); // 1-indexed, inclusive
  final endLine = int.parse(args[2]); // 1-indexed, inclusive
  final outDir = args[3];

  final lines = File(path).readAsLinesSync(encoding: utf8);
  Directory(outDir).createSync(recursive: true);

  int callIndex = 0;
  for (var i = startLine - 1; i < endLine && i < lines.length; i++) {
    final lineNo = i + 1;
    final line = lines[i];
    if (line.trim().isEmpty) continue;
    Map<String, dynamic> obj;
    try {
      obj = jsonDecode(line) as Map<String, dynamic>;
    } catch (e) {
      stderr.writeln('Failed to parse line $lineNo: $e');
      continue;
    }
    if (obj['role'] != 'assistant') continue;
    final message = obj['message'] as Map<String, dynamic>?;
    if (message == null) continue;
    final content = message['content'] as List<dynamic>?;
    if (content == null) continue;
    for (final item in content) {
      if (item is! Map<String, dynamic>) continue;
      if (item['type'] != 'tool_use') continue;
      final name = item['name'];
      if (name != 'StrReplace' && name != 'Write') continue;
      final input = item['input'] as Map<String, dynamic>?;
      if (input == null) continue;
      final p = (input['path'] ?? '').toString();
      if (!p.replaceAll('\\', '/').endsWith('lib/main.dart')) continue;
      callIndex++;
      final rec = {
        'lineNo': lineNo,
        'callIndex': callIndex,
        'name': name,
        'path': p,
        'old_string': input['old_string'],
        'new_string': input['new_string'],
        'replace_all': input['replace_all'],
        'contents': input['contents'],
      };
      final outFile = File(
        '$outDir/${callIndex.toString().padLeft(4, '0')}_line$lineNo.json',
      );
      outFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(rec),
        encoding: utf8,
      );
    }
  }
  stdout.writeln('Extracted $callIndex tool calls to $outDir');
}
