import 'package:galley_core/galley_core.dart';
import 'package:material_ui/material_ui.dart';

import 'board.dart';

/// What the canvas shows, and what a reviewer does on it, apart from how it is drawn.
///
/// The latest round is shown: it is the one marks are raised on (`galley serve` raises on it),
/// and the one the last answers were checked against. A mark last placed in an earlier round,
/// or on no widget of this one, is listed with why, never left off (DESIGN: an unknown is never
/// nothing).
final class CanvasModel extends ChangeNotifier {
  /// A canvas over [api], acting as [reviewer] (who marks are raised by).
  CanvasModel(this.api, {String reviewer = '', DateTime Function()? now})
    : _reviewer = reviewer.trim(),
      signedIn = null,
      _now = now ?? DateTime.now;

  /// A canvas over a galley on a server, acting as the member [signedIn] is: the reviewer is
  /// their alias, and is not changed here.
  CanvasModel.signedIn(this.api, SignedIn this.signedIn, {DateTime Function()? now})
    : _reviewer = signedIn.alias,
      _now = now ?? DateTime.now;

  /// Where rounds and marks come from.
  final Galley api;

  /// Who is signed in, on a galley on a server; null on `galley serve`'s, where the reviewer
  /// says who they are.
  ///
  /// The server keeps who wrote a mark or event by their account, and reads it back as their
  /// alias (DESIGN D15); a `by` that is not the alias is refused (ServerGalley.raise). Rejected:
  /// a name field here, whose every other value would be refused.
  final SignedIn? signedIn;

  final DateTime Function() _now;

  /// What there is to show: nothing yet, a refusal, or a round.
  CanvasState get state => _state;
  CanvasState _state = const Loading();

  /// Who is reviewing: the `by` of every mark raised and every event recorded here. Empty until
  /// the reviewer says.
  String get reviewer => _reviewer;
  String _reviewer;
  set reviewer(String name) {
    if (signedIn != null) {
      throw StateError('the reviewer is the member signed in, ${signedIn!.alias}');
    }
    _reviewer = name.trim();
    notifyListeners();
  }

  /// The mark whose thread is open, or null.
  String? get selected => _selected;
  String? _selected;

  /// Opens [id]'s thread, or closes it with null.
  void select(String? id) {
    _selected = id;
    notifyListeners();
  }

  /// The selected mark, or null.
  PlacedMark? get selectedMark => switch ((_state, _selected)) {
    (final Shown s, final id?) => s.marks.where((m) => m.mark.id == id).firstOrNull,
    _ => null,
  };

  /// Reads the latest round and every mark.
  Future<void> load() async {
    _state = const Loading();
    notifyListeners();
    try {
      final rounds = await api.rounds();
      if (rounds.isEmpty) {
        _state = Unavailable(
          'This galley has no rounds yet. Its owner makes one with '
          '${signedIn == null ? '`galley pack`' : '`galley push`'} in the app.',
        );
      } else {
        final n = rounds.last;
        final round = await api.round(n);
        _state = Shown(n, round, Board.of(round.frames), await api.marks());
      }
    } on Refused catch (e) {
      _state = Unavailable(e.message);
    } on FormatException catch (e) {
      _state = Unavailable('The galley sent something the canvas cannot read: ${e.message}');
    }
    notifyListeners();
  }

  /// Raises a mark on [node] of [frame], pinned at [at], and opens its thread. Returns why not,
  /// or null when it was raised.
  Future<String?> raise({
    required FrameKey frame,
    required WidgetNode node,
    required ({double x, double y}) at,
    required String note,
  }) => _act(() async {
    final raised = await api.raise(
      frame: frame,
      target: AtNode(node.indexPath, at: at),
      note: note,
      by: _reviewer,
    );
    _selected = raised.mark.id;
  });

  /// Records the event [event] builds on [mark]. Returns why not, or null when it was
  /// recorded. The galley gives the time ([Galley.record]).
  ///
  /// A mark taken from [queue] opens the next one in it, or the list when it was the last: a
  /// reviewer works through what waits on them without going back between each.
  Future<String?> record(Mark mark, MarkEvent Function(DateTime at) event) {
    final queued = queue.any((m) => m.mark.id == mark.id);
    return _act(
      () => api.record(mark.id, event),
      then: () {
        if (queued) _selected = queue.firstOrNull?.mark.id;
      },
    );
  }

  /// What waits on the reviewer: the marks they raised that were answered, oldest answer
  /// first, so the one waiting longest is checked first. Empty until the reviewer says who
  /// they are (a hand-written mark naming nobody is nobody's), or while no round is shown.
  ///
  /// Only their own marks: anyone may verify an answer (MarkEvent.apply), but the person who
  /// raised a mark is the one who knows what they meant. Rejected: every answered mark, which
  /// in a galley of three reviewers would put two thirds of the queue in front of someone who
  /// cannot say whether it is what was asked for.
  List<PlacedMark> get queue {
    final shown = _state;
    if (shown is! Shown || _reviewer.isEmpty) return const [];
    return [
      for (final m in shown.marks)
        if (m.mark.status == MarkStatus.answered && m.mark.by == _reviewer) m,
    ]..sort((a, b) => _answeredAt(a.mark).compareTo(_answeredAt(b.mark)));
  }

  static DateTime _answeredAt(Mark m) => m.history.whereType<Answered>().last.at;

  /// The frame [m] was raised on, as it was then: what the reviewer marked, to check the answer
  /// against. Each round is read once, however many marks were raised on it.
  Future<Before> before(PlacedMark m) async {
    final n = m.raisedIn;
    if (n == null) return const BeforeUnknown('the round it was raised on is not recorded');
    try {
      final round = switch (_state) {
        Shown(n: final shown, :final round) when shown == n => round,
        _ => await (_rounds[n] ??= api.round(n)),
      };
      final frame = round.round.frame(m.mark.frame);
      if (frame == null) return BeforeUnknown('round $n has no frame ${m.mark.frame}');
      return BeforeIn(n, frame.record);
    } on Refused catch (e) {
      _rounds.remove(n)?.ignore(); // Read again next time: a refusal may pass.
      return BeforeUnknown('round $n was not read: ${e.message}');
    } on FormatException catch (e) {
      _rounds.remove(n)?.ignore(); // Read again next time: it may have been cut short.
      return BeforeUnknown('round $n does not read: ${e.message}');
    }
  }

  final _rounds = <int, Future<StoredRound>>{};

  /// Verified by the reviewer: what [record] takes for "looks right".
  MarkEvent Function(DateTime at) verified() =>
      (at) => Verified(by: _reviewer, at: at);

  /// Reopened by the reviewer, saying [note].
  MarkEvent Function(DateTime at) reopened(String note) =>
      (at) => Reopened(note, by: _reviewer, at: at);

  /// Withdrawn by the reviewer, saying [note].
  MarkEvent Function(DateTime at) withdrawn(String note) =>
      (at) => Withdrawn(note, by: _reviewer, at: at);

  /// Whether the reviewer may [review] [mark] now, by the core's own rule ([MarkEvent.apply]),
  /// which the backend checks again: so a button the canvas offers is one the backend takes.
  ///
  /// It is asked before the reviewer has written a note, and a reopen or withdrawal refuses an
  /// empty one, so the event is built with a stand-in note. [MarkEvent.apply] reads only the
  /// status, who raised the mark and who acts. Rejected: a second copy of those rules here,
  /// which would drift from the backend's the first time either changed.
  bool offers(Mark mark, Review review) {
    if (_reviewer.isEmpty) return false;
    const note = 'offered';
    final event = switch (review) {
      Review.verify => verified(),
      Review.reopen => reopened(note),
      Review.withdraw => withdrawn(note),
    }(_now().toUtc());
    return event.apply(mark.status, raisedBy: mark.by) != null;
  }

  Future<String?> _act(Future<void> Function() action, {void Function()? then}) async {
    if (_reviewer.isEmpty) {
      return 'Say who you are first: a mark and its thread name who said what.';
    }
    try {
      await action();
    } on Refused catch (e) {
      return e.message;
    } on ArgumentError catch (e) {
      return '${e.message}';
    }
    await _refreshMarks(then);
    return null;
  }

  Future<void> _refreshMarks(void Function()? then) async {
    if (_state case final Shown s) {
      try {
        _state = s.withMarks(await api.marks());
        then?.call();
      } on Refused catch (e) {
        _state = Unavailable(e.message);
      }
      notifyListeners();
    }
  }
}

/// What a reviewer can do to a mark from its thread. Answering is the app's, from `galley
/// answer`, so it is not here.
enum Review {
  /// The answer looks right.
  verify,

  /// The answer does not fix it.
  reopen,

  /// Taking back one's own mark.
  withdraw,
}

/// What the canvas has to show.
sealed class CanvasState {
  const CanvasState();
}

/// Still reading.
final class Loading extends CanvasState {
  /// Reading.
  const Loading();
}

/// Nothing can be shown, and [message] says why: the galley refused, or sent what does not read.
final class Unavailable extends CanvasState {
  /// Unavailable, because of [message].
  const Unavailable(this.message);

  /// Why.
  final String message;
}

/// Round [n] on [board], with every mark.
final class Shown extends CanvasState {
  /// A round shown.
  Shown(this.n, this.round, this.board, GalleyMarks marks)
    : marks = marks.placed,
      damaged = marks.damaged;

  /// Which round.
  final int n;

  /// The round as read.
  final StoredRound round;

  /// Where its frames are.
  final Board board;

  /// Every mark, wherever it was last placed.
  final List<PlacedMark> marks;

  /// The marks the galley holds and could not read: listed with why, never left out, so a
  /// reviewer does not take a mark that does not read for a mark that was never raised.
  final List<DamagedMark> damaged;

  /// The marks drawn on [frame]: placed in this round, on a widget there.
  List<PlacedMark> pinnedOn(FrameKey frame) => [
    for (final m in marks)
      if (m.round == n && m.mark.frame == frame && m.carried.pin != null) m,
  ];

  /// Why [m] is not drawn on this round, or null when it is.
  String? notDrawn(PlacedMark m) => switch (m) {
    PlacedMark(round: null) => 'not placed in any round yet',
    PlacedMark(:final round?) when round != n => 'last placed in round $round, not this one',
    PlacedMark(carried: Carried(placement: Unplaced(:final reason))) => 'unplaced: $reason',
    PlacedMark(carried: Carried(placement: Reanchored(result: Lost()))) =>
      'lost: its widget was not found in this round',
    PlacedMark(carried: Carried(placement: Retired())) => 'retired: this round has no such frame',
    _ => null,
  };

  /// The same round with [marks] as they are now.
  Shown withMarks(GalleyMarks marks) => Shown(n, round, board, marks);
}

/// The frame a mark was raised on, as it was then, or why it cannot be shown.
sealed class Before {
  const Before();
}

/// Raised on [record]'s frame in round [n].
final class BeforeIn extends Before {
  /// In round [n], as [record] kept it.
  const BeforeIn(this.n, this.record);

  /// The round.
  final int n;

  /// The frame there.
  final FrameRecord record;
}

/// Not shown, because of [why]: said, so an empty box is never read as "nothing was there".
final class BeforeUnknown extends Before {
  /// Unknown, because of [why].
  const BeforeUnknown(this.why);

  /// Why.
  final String why;
}

/// The member a canvas on a server acts as, and how they sign out.
final class SignedIn {
  /// [alias], signed in as [email]; [signOut] ends the session on this browser.
  const SignedIn({required this.email, required this.alias, required this.signOut});

  /// What they signed in with.
  final String email;

  /// What the galley signs their marks and events with.
  final String alias;

  /// Forgets the session on this browser and goes back to signing in.
  final void Function() signOut;
}
