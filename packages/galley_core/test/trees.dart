import 'package:galley_core/galley_core.dart';

/// Builds a [FrameTree] from rows of `(path, type, rect, key?, label?, location?)`, root first.
///
/// Tests write trees as data so the shape under test is visible at the call site.
FrameTree tree(List<WidgetNode> nodes, {double width = 400, double height = 800}) =>
    FrameTree(bounds: LogicalRect(0, 0, width, height), nodes: nodes);

/// A node, with a terse signature for test tables.
WidgetNode node(
  List<int> path,
  String type, {
  LogicalRect rect = const LogicalRect(0, 0, 10, 10),
  String? key,
  String? label,
  SourceLocation? at,
}) => WidgetNode(
  indexPath: path,
  type: type,
  rect: rect,
  key: key,
  semanticsLabel: label,
  location: at,
);

/// A location in a fake app file.
SourceLocation loc(int line, [int column = 5, String file = 'package:app/screen.dart']) =>
    SourceLocation(file, line, column);

/// The root of every test tree.
final root = node([], 'App', rect: const LogicalRect(0, 0, 400, 800));
