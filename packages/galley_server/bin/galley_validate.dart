import 'dart:convert';
import 'dart:io';

import 'package:galley_server/judge.dart';

/// The judge the server's hooks call: its one argument is the path of a file holding the
/// request as JSON, and the answer is one line of JSON on stdout (DESIGN D15).
///
/// A file, not the JSON as the argument: Linux caps one argument at 128 KiB
/// (MAX_ARG_STRLEN), and a round's manifest of thousands of files, or a finish that names
/// every mark, is larger. PocketBase's hooks have no way to write to a command's stdin, and
/// can write a file. The hook writes it, owner-only, under the server's data directory, and
/// removes it.
///
/// Always exits 0. PocketBase's `$os.exec` throws away a failed command's output (seen on
/// 0.40.6), so a refusal sent with a non-zero exit would reach the writer as "exit status 1",
/// without its reason. A failure of the judge itself is a refusal too, never a pass: a write
/// nobody judged must not land.
void main(List<String> args) {
  JsonMap answer;
  try {
    if (args.length != 1) {
      answer = {'refused': 'galley_validate takes one argument, the path of the request'};
    } else {
      final String text;
      try {
        text = File(args.single).readAsStringSync();
      } on FileSystemException catch (e) {
        throw StateError('could not read the request: ${e.message} (${e.path})');
      }
      answer = judge(jsonDecode(text));
    }
  } on FormatException catch (e) {
    answer = {'refused': 'the request is not JSON: ${e.message}'};
  } catch (e) {
    answer = {'refused': 'the validator failed: $e'};
  }
  stdout.writeln(jsonEncode(answer));
}
