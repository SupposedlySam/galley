import 'dart:io';

import 'package:galley_cli/galley_cli.dart';

Future<void> main(List<String> args) async => exit(await runGalley(args));
