import 'package:galley_core/galley_core.dart';

/// Where every frame of a round sits on the canvas: rows are flows and columns are states
/// (ROADMAP step 5), in logical pixels, one frame pixel to one board pixel at 100%.
///
/// - A **flow** is the first segment of the `screen` axis: `bloom.staff.packing` is in `bloom`.
///   A screen's id is its path in the app, so that segment is the part of the app it is in.
/// - A **state** is a column: one screen in one scenario. Its frames are the same state on each
///   device, text scale or theme, side by side, so the variants of one state are compared
///   without looking across the board.
/// - Rows and columns are in the order the round lists its frames: the app's plan, which put
///   them in an order a person chose. Rejected: sorting by name, which puts `bloom.tins` before
///   `bloom` and spreads one flow's states in the alphabet's order instead of the app's.
///
/// Pure: the canvas draws it and a test reads it, with no renderer in between.
final class Board {
  Board._(this.rows, this.width, this.height, this.varying, this._names);

  /// The board for [frames], in the round's order.
  factory Board.of(List<RoundFrame> frames) {
    final varying = _varying(frames);
    // Grouped by id, named for a reviewer: two screens the host gave one name stay two columns.
    final rows = <String, Map<String, List<RoundFrame>>>{};
    final names = <FrameKey, String>{};
    for (final f in frames) {
      final key = f.record.key;
      rows.putIfAbsent(flowOf(key), () => {}).putIfAbsent(_stateOf(key), () => []).add(f);
      names[key] = _nameOf(key, f.record);
    }
    var top = 0.0, width = 0.0;
    final laid = <BoardRow>[];
    for (final MapEntry(key: flow, value: states) in rows.entries) {
      var left = 0.0, tallest = 0.0;
      final columns = <BoardColumn>[];
      for (final cell in states.values) {
        final tilesTop = top + rowLabel + columnLabel;
        var x = left;
        final tiles = <BoardTile>[];
        for (final f in cell) {
          final d = f.record.device;
          final screen = LogicalRect(
            x + bezel,
            tilesTop + tileLabel + bezel,
            d.logicalWidth,
            d.logicalHeight,
          );
          tiles.add(BoardTile(f, screen, _caption(f.record, varying)));
          x = screen.right + bezel + tileGap;
          final h = tileLabel + 2 * bezel + d.logicalHeight;
          if (h > tallest) tallest = h;
        }
        final right = x - tileGap;
        final first = cell.first.record;
        columns.add(
          BoardColumn(
            _stateName(first.key, first),
            LogicalRect(left, top + rowLabel, right - left, 0),
            tiles,
          ),
        );
        left = right + columnGap;
      }
      final height = rowLabel + columnLabel + tallest;
      laid.add(
        BoardRow(
          flow,
          _flowName(flow, [for (final c in states.values) ...c]),
          LogicalRect(0, top, left - columnGap, height),
          [
            for (final c in columns)
              BoardColumn(
                c.state,
                LogicalRect(c.rect.left, c.rect.top, c.rect.width, height - rowLabel),
                c.tiles,
              ),
          ],
        ),
      );
      if (left - columnGap > width) width = left - columnGap;
      top += height + rowGap;
    }
    return Board._(
      List.unmodifiable(laid),
      width,
      laid.isEmpty ? 0 : top - rowGap,
      List.unmodifiable(varying),
      Map.unmodifiable(names),
    );
  }

  /// Its rows, top to bottom.
  final List<BoardRow> rows;

  /// Its size, in logical pixels.
  final double width, height;

  /// The axes other than screen and scenario that take more than one value in the round, in
  /// axis order: what tells a column's frames apart, and so what a tile's caption shows. An
  /// axis with one value says nothing about any one frame, so it is left out.
  final List<String> varying;

  /// Every tile, row by row.
  Iterable<BoardTile> get tiles => [
    for (final r in rows)
      for (final c in r.columns) ...c.tiles,
  ];

  /// The tile showing [key], or null when the round has no such frame.
  BoardTile? tileOf(FrameKey key) {
    for (final t in tiles) {
      if (t.frame.record.key == key) return t;
    }
    return null;
  }

  /// Above a row, for its flow's name.
  static const rowLabel = 72.0;

  /// Above a column, for its state's name.
  static const columnLabel = 40.0;

  /// Above a tile, for what sets it apart in its column.
  static const tileLabel = 28.0;

  /// The device's outline around its screen.
  static const bezel = 10.0;

  /// Between two tiles of a column.
  static const tileGap = 24.0;

  /// Between two columns of a row: wider than [tileGap], so a state reads as one group.
  static const columnGap = 96.0;

  /// Between two rows.
  static const rowGap = 160.0;

  /// The flow [key] is in: the first segment of its `screen`, or `(no screen)` when it has none.
  static String flowOf(FrameKey key) => switch (key.values['screen']) {
    final screen? => screen.split('.').first,
    null => '(no screen)',
  };

  /// [key] as a reviewer reads it, off the board: its state, as a column is headed, then the
  /// value of every other axis, by the axis's name. A frame the board lacks (one gone since a
  /// visit) has no record to name its screen, so it is named by its id. Rejected: the key's own
  /// order, which sorts the axes by name and so put the device before the screen.
  String nameOf(FrameKey key) => _names[key] ?? _nameOf(key, null);

  final Map<FrameKey, String> _names;

  static String _nameOf(FrameKey key, FrameRecord? record) => [
    _stateName(key, record),
    for (final MapEntry(:key, :value) in key.values.entries)
      if (!_stateAxes.contains(key)) value,
  ].join(' · ');

  /// The column [key]'s frame is in, by id: what groups it.
  static String _stateOf(FrameKey key) =>
      [?key.values['screen'], ?key.values['scenario']].join(' · ');

  /// The column's heading: the screen as the reviewer knows it, then the scenario.
  static String _stateName(FrameKey key, FrameRecord? record) => [
    if (key.values['screen'] case final id?) record == null ? id : screenName(record),
    ?key.values['scenario'],
  ].join(' · ');

  /// What a reviewer calls [record]'s screen: the name the app gave it, or `home` for the app's
  /// root, or its id. Not `root`, the id of `/`: that is the router's word, not the reviewer's.
  /// Only the uri `/` is `home`; a route `/root` keeps its id.
  static String screenName(FrameRecord record) =>
      record.screenName ??
      (record.uri.pathSegments.every((s) => s.isEmpty) && !record.uri.hasQuery
          ? 'home'
          : record.key.values['screen'] ?? '(no screen)');

  /// A row's heading: the name of the screen whose id is the flow's (`/bloom` for `bloom`),
  /// when the row has it, or the flow's id.
  static String _flowName(String flow, List<RoundFrame> frames) {
    for (final f in frames) {
      if (f.record.key.values['screen'] == flow) return screenName(f.record);
    }
    return flow;
  }

  static List<String> _varying(List<RoundFrame> frames) {
    final values = <String, Set<String>>{};
    for (final f in frames) {
      for (final MapEntry(:key, :value) in f.record.key.values.entries) {
        if (!_stateAxes.contains(key)) (values[key] ??= {}).add(value);
      }
    }
    return [
      for (final MapEntry(:key, :value) in values.entries)
        if (value.length > 1) key,
    ]..sort();
  }

  /// The device by its name, then the other axes that vary. The device always leads, even
  /// when one device is in the round: it names the outline drawn around the frame. Its axis
  /// value is left out. Observed: showing both drew `Pixel 7 · pixel-7` on every tile.
  static String _caption(FrameRecord record, List<String> varying) => [
    record.device.name,
    for (final axis in varying)
      if (axis != _deviceAxis) ?record.key.values[axis],
  ].join(' · ');

  static const _deviceAxis = 'device';

  static const _stateAxes = {'screen', 'scenario'};
}

/// One flow: its states left to right.
final class BoardRow {
  /// A row.
  const BoardRow(this.flow, this.name, this.rect, this.columns);

  /// The flow's id: the first segment of its screens' ids.
  final String flow;

  /// What its heading says ([Board.screenName] of its root screen, or [flow]).
  final String name;

  /// Where it is, label included.
  final LogicalRect rect;

  /// Its states.
  final List<BoardColumn> columns;
}

/// One state of a flow: its frames side by side.
final class BoardColumn {
  /// A column.
  const BoardColumn(this.state, this.rect, this.tiles);

  /// The screen as the reviewer knows it, and the scenario, such as `bloom.staff · batchSetup`
  /// or, with the screen named, `Packing · batchSetup`.
  final String state;

  /// Where it is, label included.
  final LogicalRect rect;

  /// Its frames.
  final List<BoardTile> tiles;
}

/// One frame on the board.
final class BoardTile {
  /// A tile.
  const BoardTile(this.frame, this.screen, this.caption);

  /// The frame.
  final RoundFrame frame;

  /// Where the frame's screen is drawn, at its logical size. Its bezel and caption are around
  /// it, above and outside.
  final LogicalRect screen;

  /// Its device's name, then what else sets it apart in its column, such as
  /// `Pixel 7 · 2.0`.
  final String caption;
}
