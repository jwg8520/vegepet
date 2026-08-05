import 'dart:io';

void main(List<String> args) {
  final path = args[0];
  final content = File(path).readAsStringSync().replaceAll('\r\n', '\n');
  final buffer = StringBuffer();
  var i = 0;
  var removedCount = 0;
  const needle = '_showSnack(';

  while (true) {
    final idx = content.indexOf(needle, i);
    if (idx < 0) {
      buffer.write(content.substring(i));
      break;
    }

    // Guard: make sure this is a real call, not part of a longer identifier.
    final before = idx > 0 ? content[idx - 1] : ' ';
    final isIdentChar =
        RegExp(r'[A-Za-z0-9_]').hasMatch(before);
    if (isIdentChar) {
      buffer.write(content.substring(i, idx + needle.length));
      i = idx + needle.length;
      continue;
    }

    // Find matching close paren, quote-aware.
    var depth = 1;
    var pos = idx + needle.length; // just after the opening '('
    String? quoteChar;
    var escaped = false;
    while (pos < content.length && depth > 0) {
      final ch = content[pos];
      if (quoteChar != null) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == quoteChar) {
          quoteChar = null;
        }
      } else {
        if (ch == "'" || ch == '"') {
          quoteChar = ch;
        } else if (ch == '(') {
          depth++;
        } else if (ch == ')') {
          depth--;
        }
      }
      pos++;
    }
    // pos is now right after the matching ')'.
    var matchEnd = pos;
    // Consume trailing whitespace + semicolon if present.
    var semiPos = matchEnd;
    while (semiPos < content.length &&
        (content[semiPos] == ' ' || content[semiPos] == '\t')) {
      semiPos++;
    }
    if (semiPos < content.length && content[semiPos] == ';') {
      matchEnd = semiPos + 1;
    }

    // Determine line boundaries.
    var lineStart = idx;
    while (lineStart > 0 && content[lineStart - 1] != '\n') {
      lineStart--;
    }
    var lineEnd = matchEnd;
    while (lineEnd < content.length && content[lineEnd] != '\n') {
      lineEnd++;
    }
    if (lineEnd < content.length) lineEnd++; // include the newline itself.

    final prefix = content.substring(lineStart, idx);
    final suffixEnd = lineEnd > 0 && content[lineEnd - 1] == '\n'
        ? lineEnd - 1
        : lineEnd;
    final suffix = content.substring(matchEnd, suffixEnd);

    removedCount++;
    if (prefix.trim().isEmpty && suffix.trim().isEmpty) {
      // Whole line(s) dedicated to this call -> drop entirely.
      buffer.write(content.substring(i, lineStart));
      i = lineEnd;
    } else {
      // Inline -> remove just the call+semicolon.
      buffer.write(content.substring(i, idx));
      i = matchEnd;
    }
  }

  stdout.writeln('Removed $removedCount _showSnack call(s).');
  File(path).writeAsStringSync(buffer.toString().replaceAll('\n', '\r\n'));
}
