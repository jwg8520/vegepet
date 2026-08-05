import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final targetPath = args[0];
  final opsDir = args[1];
  final dryRun = args.contains('--dry-run');

  var content = File(targetPath)
      .readAsStringSync(encoding: utf8)
      .replaceAll('\r\n', '\n');

  final opFiles = Directory(opsDir).listSync().whereType<File>().where(
    (f) => f.path.endsWith('.json'),
  ).toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  var applied = 0;
  var failed = 0;
  for (final f in opFiles) {
    final rec = jsonDecode(f.readAsStringSync(encoding: utf8)) as Map<String, dynamic>;
    final name = rec['name'] as String;
    final label = '${f.uri.pathSegments.last} (line ${rec['lineNo']})';
    if (name == 'Write') {
      stdout.writeln('SKIP Write op $label - handle manually');
      failed++;
      continue;
    }
    final oldString = rec['old_string'] as String?;
    final newString = rec['new_string'] as String? ?? '';
    final replaceAll = rec['replace_all'] == true;
    if (oldString == null || oldString.isEmpty) {
      stdout.writeln('SKIP $label - empty old_string');
      failed++;
      continue;
    }
    final count = _countOccurrences(content, oldString);
    if (count == 0) {
      stdout.writeln('FAIL $label - old_string not found (0 occurrences)');
      failed++;
      continue;
    }
    if (count > 1 && !replaceAll) {
      stdout.writeln(
        'WARN $label - old_string found $count times, replacing FIRST only',
      );
      final idx = content.indexOf(oldString);
      content = content.replaceRange(idx, idx + oldString.length, newString);
      applied++;
      continue;
    }
    if (replaceAll) {
      content = content.replaceAll(oldString, newString);
    } else {
      final idx = content.indexOf(oldString);
      content = content.replaceRange(idx, idx + oldString.length, newString);
    }
    stdout.writeln('OK   $label - applied ($count occurrence(s))');
    applied++;
  }

  stdout.writeln('---');
  stdout.writeln('Applied: $applied, Failed: $failed, Total: ${opFiles.length}');

  if (!dryRun) {
    File(targetPath).writeAsStringSync(
      content.replaceAll('\n', '\r\n'),
      encoding: utf8,
    );
    stdout.writeln('Wrote result to $targetPath');
  } else {
    stdout.writeln('Dry run - no changes written');
  }
}

int _countOccurrences(String haystack, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var start = 0;
  while (true) {
    final idx = haystack.indexOf(needle, start);
    if (idx < 0) break;
    count++;
    start = idx + needle.length;
  }
  return count;
}
