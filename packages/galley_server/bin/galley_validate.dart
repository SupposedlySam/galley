import 'dart:convert';
import 'dart:io';

import 'package:galley_server/judge.dart';

/// The judge the server's hooks call: the request is the one argument, as JSON, and the
/// answer is one line of JSON on stdout (DESIGN D15).
///
/// Always exits 0. PocketBase's `$os.exec` throws away a failed command's output (seen on
/// 0.40.6), so a refusal sent with a non-zero exit would reach the writer as "exit status 1",
/// without its reason. A failure of the judge itself is a refusal too, never a pass: a write
/// nobody judged must not land.
void main(List<String> args) {
  JsonMap answer;
  try {
    answer = args.length == 1
        ? judge(jsonDecode(args.single))
        : {'refused': 'galley_validate takes one argument, the request as JSON'};
  } on FormatException catch (e) {
    answer = {'refused': 'the request is not JSON: ${e.message}'};
  } catch (e) {
    answer = {'refused': 'the validator failed: $e'};
  }
  stdout.writeln(jsonEncode(answer));
}
