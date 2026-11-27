# Galley design decisions

Each decision gives what was chosen, why, and what was rejected. A decision that is replaced
stays here, marked *Retracted*, next to the decision that replaced it. The facts these
decisions rest on are cited in [BOUNDARY.md](BOUNDARY.md). What exists today is in the
[README](../README.md).

## Principles

The decisions below follow from these. Code comments cite them by name.

- **An unknown is never nothing.** A frame that failed is an error card, not a missing frame.
  An anchor that was not found is Lost, not Exact. A landing Galley could not read is a
  finding, never a match. Empty, null and "could not read" must never be storable as "nothing
  is wrong".
- **Nothing is erased.** Rounds stack. A mark's history is an append-only log, and a frame
  that left the app is retired with its history kept.
- **No real backends in a frame.** Frames run on the app's fakes only.
- **The app writes one host file.** Galley never imports an app, and asks nothing of it beyond
  `GalleyHost` (D2′).
- **Assert on the population, not only the absence,** and mutate the code to prove a test is
  load-bearing. "No errors" is also what a broken producer returns.

## D1 · Packages split by what they may depend on (2026-11-25)

```
packages/
  galley_core/     pure Dart. Models, frame keys, anchors, re-anchoring, the .galley format.
                   Depends on nothing but the Dart SDK.
  galley/          Flutter, test-time. GalleyHost + FrameSource contracts, built-in axes,
                   the packer. Depends on galley_core and flutter_test.
  galley_cli/      `galley pack | mark | pull | answer | verify | reopen | withdraw | serve` on a local galley
                   (D12); `push` with the server. Depends on galley_core, never on Flutter.
  galley_server/   planned (D15): the server's schema and hooks, the validator, and the
                   client the CLI and canvas share. Depends on galley_core, never on Flutter.
  galley_web/      the reviewer canvas (Flutter web, D14). Depends on galley_core.
```

- **Why:** carry-forward is the product, and it is pure logic over two trees. In
  `galley_core` it is tested in milliseconds with no Flutter binding, and the server, CLI and
  viewer all share one definition of a frame key and an anchor. If each layer had its own copy,
  they would drift. The first drift would show up as a mark landing on the wrong widget, which
  is the defect reviewers would trust the product least after.
- **Rejected:** one Flutter package. The CLI and server would then pull in Flutter to read a
  manifest.

## D2′ · The app's only code is one host file (2026-11-25, replaces D2)

Agreed with the first adopting app. The lens: protect the app's DX, keep Galley's lines out of
the app, and let Galley do the hard engineering.

```dart
abstract class GalleyHost {
  List<GalleyScenario> get scenarios;          // name + screens (List<Uri>)
  List<String> get variants => const [];
  GalleyAxes get axes => GalleyAxes();
  List<String> get sourceRoots => const ['lib'];
  Future<Widget> mount(GalleyFrame frame);     // scenario, uri, variant
  Future<void> arrive(WidgetTester t, GalleyFrame frame) async {}
}
```

- **Galley derives the frames** as scenarios × screens × axes, and its pairwise planner picks the
  combinations. The app keeps no screen catalog, because one grows with every screen added.
- **`arrive` is the exception, not the rule.** It is only for screens no URI reaches, such as
  a timer that holds in-memory state. It takes the frame because getting there is scripted from the
  scenario's state.
- **`mount` is called once per render**, so twice per frame (D4). It must build fresh fakes each
  time. If a fake is shared, the second render sees the first one's changes and the frame becomes
  a determinism error.
- **`mount` runs on the real clock**, in `tester.runAsync`, with 30 s of real time. A
  testWidgets body runs on a fake clock that only a pump moves, and nothing pumps while Galley
  awaits the mount. A mount that awaits real I/O therefore never finished, and the run stalled
  with no output (observed in the first adopting app, 0.1.1). Rejected: handing `mount` the
  tester, which would make every host learn the trap. `arrive` stays on the fake clock, because
  its taps and pumps need it.
- **What landed is read from the Router**, not asked of the host: the outermost `Router` with a
  parser, its delegate's `currentConfiguration` restored to a uri (BOUNDARY § Landing). An app
  with no Router gets a `landing-unknown` finding, never an assumed match.
- **Determinism belongs to Galley**, and so does saying where it broke:
  - *Not built yet:* the clock is pinned. testWidgets builds `FakeAsync()` with no initialTime (flutter_test
    `binding.dart:2591`), and FakeAsync seeds `package:clock` from the wall clock
    (`fake_async-1.3.3/lib/fake_async.dart:106`). So `clock.now()` differs from run to run.
    Galley zones in a fixed epoch that advances with fake time. `DateTime.now()` is out of its
    reach, which is the audit's job.
    - An app's own time seam wins, and Galley never moves it. An app whose test harness pins
      its own clock sees no change from the zone. A frame that needs another moment says so in
      its scenario.
  - Network images: flutter_test already answers every request with an empty 400
    (`_binding_io.dart:79`). Galley replaces that with a placeholder and records each URL on the
    frame.
  - Fonts come from the app's FontManifest. A family that is requested but not loaded is a
    finding.
  - A frame that never settles is captured with tickers off and marked frozen, never passed as
    clean.
  - When the two renders differ, the element trees are diffed. If the trees match but the pixels
    don't, the deepest widget inside the pixel diff's bounding box is named, with its source
    location.
  - *Not built yet:* `dart run galley:audit` reports `DateTime.now()`, `Random()` and wall-clock Timers in lib/.
    It is report-only unless `--strict`.
    - There are no inline suppressions (`// galley:allow`), because they would scatter Galley
      lines through the app.
    - A read inside a class that implements a one-method time seam is reported as the seam,
      not as a leak. That is the system `Clock`'s job.
    - Enforcement belongs to the app, in its own source rules.
- **The error headline is about the frame:** scenario, uri, axes, expected, landed and culprit.
  The stack goes in the details.
- **Rejected:** the app keeping a per-screen catalog (D2 below), and `GalleyScenario.apply`
  alongside `mount`, because that would put state setup in two places.

## D2 · The app's only code is a host and a catalog (2026-11-25) — *Retracted by D2′*

The app implements two interfaces, and Galley depends on nothing else of the app's (dependency
inversion):

- `FrameSource`: yields `FrameSpec`s. Each spec is a screen id, the flow it belongs to, the
  app's own state axes (scenario, variant), and the built-in axes that apply.
- `GalleyHost.arrive(GalleyTester, FrameSpec)`: puts the app into that frame. It mounts on fakes,
  applies the scenario, and then reaches the screen by **route or by scripted steps**. Some
  screens hold in-memory state that no URL can carry.

Galley applies the built-in axes itself, through Flutter's test hooks (BOUNDARY § Flutter test
hooks): device size and pixel ratio, text scale, brightness, platform and locale. It resets them
after every frame, because `flutter test` does not.

- **Rejected:** `Scenario.screens` as the only source of frames. A route alone cannot reach
  every screen. A scenario still names its screens; the host's
  catalog turns each one into an arrival.
- **Rejected for v1:** `RouteSource` and `PreviewSource`. Many apps have no route table (a
  router that parses with a switch has nothing to enumerate). Previews are found by the analyzer, not at runtime
  (BOUNDARY § Flutter previews). Both are later bets.

## D3 · The packer runs inside the app's own `flutter test` (2026-11-25)

`galley pack` runs `flutter test <the app's galley entry> --dart-define=GALLEY_OUT=<dir>`.
That puts the packer in the app's own test process, with the app's fonts, fakes and
`test/support` code, and with creation tracking on by default (BOUNDARY § Creation locations).

- **Why:** the fakes and harness that make a screen render headless already live in the
  app's tests. Moving them out into a package is a cost every adopting app would pay again.
- **Rejected:** a separate entrypoint on `flutter-tester`. That needs args smuggled through the environment and has no `WidgetTester`.

## D4 · A frame is captured as pixels plus a tree, and must render the same twice (2026-11-25)

For each frame the packer captures:
- the PNG of the root layer;
- every element that owns a `RenderBox`: its runtime type, key, global rect, creation location
  (file:line:column, via `dart:developer`'s `CreationLocation.of`), and the semantics label of
  the node it contributes to;
- every `FlutterError` raised while the frame mounted and settled, including overflows,
  collected through a scoped `FlutterError.onError`. `takeException` returns only the first.

It then **renders the frame again from scratch and compares**: pixels first, then the
recorded trees field by field. A frame that differs, threw,
or never settled becomes an error card that names the cause. It is never dropped. An empty
round must never read as "nothing to review".

- **Why twice:** a single clock read or unsettled animation would otherwise make the frame
  "changed" in every later round, and Compare would become noise.

## D5 · The frame key is the axis values, not the pixels (2026-11-25)

A frame key is the canonical, sorted `axis=value` list: screen, scenario, variant, device,
platform, brightness, text scale, locale. It carries no hash, so the same frame in round 5 is
"the same frame" as in round 4 even when its pixels changed. Content hashes identify an
image, and a frame key identifies a place in the review.

## D6 · A mark is anchored by layered evidence, and re-anchoring reports its confidence (2026-11-25)

A mark stores:
- the frame key;
- the anchor widget's key, semantics label, creation location and index path, and its rect;
- the pin's offset inside that widget, relative to the widget's size;
- a crop of the snapshot.

Carry-forward looks up the anchor in the new frame's tree in a fixed order: key, then semantics
label, then creation location, then index path. Each step falls back to the next only when the
previous one is absent or ambiguous. The result is **Exact** (found, rect similar), **Moved**
(found, rect elsewhere) or **Lost** (not found: the mark keeps its old crop as a ghost). A
frame missing from the new round is **retired**, with its history kept. Nothing is ever deleted.

*As built (`galley_core/lib/src/reanchor.dart`, 2026-11-25):*
- **Matchers narrow; they do not race.** Each matcher filters the candidates the earlier ones
  left. One left decides it. Several left carry on. None left means this evidence no longer
  holds, so it is skipped. A shared label plus a call site picks out one of three buttons,
  where "first matcher with a unique hit" would fall through to the index path.
  - The order is key, semantics label, exact location, then file + type, then index path +
    type.
  - File + type was added because a single line inserted above a widget breaks an exact
    location.
- **Ambiguous is Lost, with its candidates.** If the evidence runs out with several nodes
  left, the result is Lost and lists them. It never picks the first.
- **Index path needs the type too.** Rejected: a path alone. Some node sits at almost any path,
  so a deleted widget would be reported as found.
- **Exact means IoU ≥ 0.9.** That is about 5 px of drift on a 100 px wide box. Rejected: 1.0,
  which calls every sub-pixel re-layout Moved and trains reviewers to ignore the flag.
- **A mark's status is a fold over an append-only event log** (answered, verified, reopened,
  withdrawn). An illegal sequence is refused when it is written and again when it is read.
- **A mark is taken back by a withdrawal, never by deleting it** (0.3.7). Only whoever raised
  it may withdraw it, with a note saying why (a duplicate, a test), from any status but
  verified. A withdrawn mark is final, keeps its history, and is carried into every round like
  any other. Rejected: letting anyone withdraw, which would let an answerer close a mark
  without the reviewer's say; an owner who disagrees answers `wont-fix`. Observed: with no way
  to take a mark back, the first adopting app deleted a test mark's file by hand, and the
  galley stopped holding together (D12).

*Carry-forward as built (`galley_core/lib/src/round.dart`, 2026-11-26):*
- **Every mark gets one placement per round**, verified marks included:
  - **Raised:** new in this round.
  - **Reanchored:** looked up, and the result is Exact, Moved or Lost.
  - **Unplaced:** cannot be judged.
  - **Retired:** the frame is not in the round.
- **An error frame, or one with no tree, is Unplaced, never Lost.** Lost is a claim about the
  app. A frame that landed on the login screen would make every mark on it Lost for a reason
  that is not theirs. A frozen frame is placed, because its picture and tree are real.
- **The next round looks for the widget as it was last found**, not as raised. The mark keeps
  its anchor as raised. Moved then means "moved since the last round", and clears once the
  widget stays put.
  - **Rejected:** always looking from the raised anchor. A widget that moved once would be
    Moved in every later round, and its call site would go stale with every edit above it.
  - A mark that is not found keeps the anchor it was last found at, so a frame that comes back
    finds it again.
- **Pure.** The caller reads the records and trees (`RoundFrame`), so the CLI, the server and
  the tests carry marks the same way. `RoundManifest` is the `index.json` the packer writes and
  everything else reads.
- *Mutation, 2026-11-26:* 12 of 12 mutants are killed. One survived the first suite: keeping
  the raised anchor for a mark that was not placed. A test was added for it.

## D7 · Server: measured against these constraints, then decided (2026-11-25, decided 2026-11-26)

Reviewers are outside the app's team, so the server needs:
- sign-in that needs no password, such as an emailed code;
- read rules applied to every read, live streams included, scoped to the galleys a reviewer
  was invited to;
- invites and accepting them;
- image storage behind the same rules;
- presence, later, for multiplayer.

Each candidate backend is measured against this list with a spike before the server is
written, and the gaps it leaves get a decision here.

### Decided: PocketBase (2026-11-26)

Two candidates were run on loopback against the list, with a real round (155 frames: 27.5 MB of
PNGs, 16 MB of trees): PocketBase v0.40.6, and a Dart backend-as-a-service. No email reached a
real person; codes were caught by a hook or an SMTP sink.

| Constraint | PocketBase | The Dart candidate |
|---|---|---|
| Emailed-code sign-in | Built in. Password login and open sign-up off. An unknown email gets the same 200, so emails can't be enumerated. | Built in. 3 wrong guesses spend the code. |
| A non-member reads nothing, streams included | Pass. Rules are evaluated per event, so a removed member gets nothing more on a stream that is still open. | Pass, but membership rides in the token's claims: a removed member keeps reading until the token refreshes. |
| Invites | Not built in: an invites collection, a create rule and 3 hooks. Self-invite, escalation, reuse and accepting for someone else were refused. | Not built in: a table and a cron job, about 15 s from accept to access. |
| Images behind membership | Pass. A file is fetched with a short-lived file token (180 s), checked again at fetch. | Pass for one round only: an image's rule sees no galley, so access needs a claims list of image ids, 3.4 KB for 155 frames, which outgrows a header within a few rounds. |
| Upload of the round | 0.3 s, 0.1 s with 4 workers. | 6 s, 2 s with 4 workers, after raising a 100-per-minute create limit that refused 55 of 155 rows. An oversize image is a bare 500. |
| Presence | None built in. | None found. |

**PocketBase, because its rules hold where the round is largest.** Images are most of a round,
and the Dart candidate cannot scope an image to a galley without a list that grows with every
round. Its revocation also waits for a token refresh, where PocketBase's stops the next event.

What this leaves:
- **The code lockout.** 5 wrong guesses lock the account for minutes (429, even for a new
  code), so anyone who knows a reviewer's email can lock them out. Accepted for a handful of
  invited reviewers; an app-level throttle per requester closes it if it is ever abused.
- **Carry-forward runs in `galley push`, not on the server.** PocketBase's hooks are JS or Go,
  so galley_core cannot run inside it. The CLI places every mark (D6) and writes the
  placements; the server's rules only say who may write them (the galley's owner).
- **Invites are code we own**: the collection, its rule and the 3 hooks, tested to the same
  bar as the rest.
- **Pre-1.0**, so its upgrades are pinned and read before they are taken.
- **A stack unlike the owner's other services.** The Dart candidate is what they already run,
  and PocketBase is one more thing to know, operate and keep current. Weighed after the
  decision (2026-11-27), when the owner asked, and it does not change it: the image-scoping gap
  is a limit of the Dart candidate's rule language (a read rule has no subquery), not a missing
  feature to wait for. It would be reopened by a release whose read rules can check a
  membership row, which would also lift the revocation gap.

**What hosting needs:** one small machine with a persistent volume (one Go binary and SQLite),
HTTPS, and outgoing email for the codes. Built-in backups write a zip on a schedule, optionally
to S3. Who pays for it, and where it runs, is the owner's decision (ROADMAP step 8).

Rejected: deciding on features alone. Both candidates' gaps only showed when they were run,
the image-scoping limit only with a real round's file count.

## D8 · Released by git tag until pub.dev (2026-11-25)

The packages follow semantic versioning, and each release is a tag `v<version>` on the
GitHub repo. Before pub.dev, an app pins a tag:

```yaml
dev_dependencies:
  galley:
    git: {url: https://github.com/SupposedlySam/galley, path: packages/galley, ref: v0.3.6}
```

- **Why not a path dependency:** CI and fresh clones have no sibling checkout, so `pub get`
  fails for the whole app. A dev tool must not be able to break an app's release build.
- **One version for both packages** while they move together.
- **`galley` depends on `galley_core` by path** while apps pin a git tag: a git dependency
  resolves a relative path inside its own repo. A version constraint would send pub to pub.dev
  for a `galley_core` that is not there. The commit that publishes to pub.dev replaces the path
  with `^<version>` and removes `galley`'s `publish_to: none`, because pub.dev refuses path
  dependencies. Until then `publish_to: none` also stops an accidental publish.
- **Before 1.0, a minor bump means a breaking change, and only that.** Every other release is a
  patch, new features included (Dart's convention for 0.x). A change is breaking if an app's
  host stops compiling, or if a round that passed now fails. A new finding kind, or a finding
  moving to another kind, is not breaking: a finding never fails a round.
- *Corrected:* 0.2.0 (the `broken-word` finding) and 0.3.0 (`broken-word-unseen`) were minor
  bumps for changes that broke nothing, and by the rule above they should have been patches.
  The tags stay, because an app pins them; numbering continues from 0.3.0.

## D9 · A round is the essential set plus pairwise cover, with the subject as a factor (2026-11-25)

A **subject** is a frame before the axes are applied: its scenario, screen and variant. The
`FramePlanner` (`galley_core/lib/src/plan.dart`) plans a round in two steps:
- It takes every subject on every axis's reference value (the first value declared).
- It adds frames until every pair of values from two factors appears. The subject is one
  factor, and each axis is another.

- **Why the subject is a factor:** so that every screen is seen on every device and at every
  text scale. The default 2 devices × 2 text scales then costs 2n to 2n + 2 frames for n
  subjects, and 2n is the lower bound.
- **Rejected:** pairs among the axes only. That shows the small phone at 2.0× on one screen and
  counts the job done.
- **Rejected:** the full product. That is about 35,000 frames for a mid-sized app.
- **Deterministic greedy construction (AETG family).** Ties go to the lowest index, so they go
  to the reference value. The same input gives the same frames in the same order, so a round's
  frame list does not churn.
- *Mutation, 2026-11-25:* 11 of 13 mutants are killed.
  - Dropping either half of the seed pair survives, because greedy picks the seed's values
    anyway: they are its gain.
  - The seed is kept as the termination guarantee: every row covers at least one uncovered
    pair.

## D10 · What a render does for the app, and what it reports (2026-11-25)

`FrameRenderer` (`galley/lib/src/render.dart`) mounts, settles, arrives, settles, then reads
the landing, records the tree and captures pixels. Whatever it had to work around becomes a
**finding** on the frame, so the card says what is not real:

| Finding | When |
|---|---|
| `landing-unknown` | no `Router` with a parser, or it reports no configuration |
| `frozen` | still animating after 10 s of fake time; captured with tickers stopped |
| `missing-font` | text asks for a family that was not loaded |
| `default-font` | text names no family; a device would use its own font |
| `network-image` | a `NetworkImage` was drawn as a gray placeholder; the URLs are listed |
| `unpainted` | some pixels are not opaque; a device shows its window background there |
| `broken-word` | a line break falls between two letters: a word did not fit its line |
| `broken-word-unseen` | the same, in text laid out outside the picture (below the fold, under a clip) |

- **Errors are not findings.** A throw from mount, build or arrive, any `FlutterError`, a
  landing on another uri, or two renders that differ makes the frame an error. Each frame is
  its own test, and an error fails it with a headline: scenario, expected, landed, device,
  errors.
- **A mount that outruns its budget is an error**, not a stalled run: "mount did not finish
  within 30 s of real time".
- **Each render gets a new `KeyedSubtree(UniqueKey())`.** Without it the second render reuses
  the first one's State (its router, its controllers), shows the first one's end state, and the
  determinism check compares a frame with itself. Observed in Galley's own `arrive` test.
- **A word broken across lines is a finding, not an error.** The frame drew everything, and
  whether "PLAC" over "ED" is acceptable is the reviewer's call. It is read from the laid-out
  text's carets, so it judges what was laid out. A break after a soft hyphen is the author's and
  is not reported.
- **A broken word the picture does not show is its own kind**, `broken-word-unseen`. A lazy
  list lays out rows past its viewport, so the first adopting app's card said "cockt|ail" over
  a frame with no such word. Rejected: dropping it, because a break below the fold still ships,
  and "no broken words" would then mean "none on the first screen". Rejected: one kind with a
  label in the message, because a card could not tell them apart without parsing the message. Asked for by the first adopting app, whose 2.0× small-phone frames broke
  several labels and carried no finding.
- **Unpainted pixels are reported, not filled.** Rejected: compositing over black or white. A
  real device's window background depends on its theme, and a guessed color would hide that
  the app paints nothing there.
- **The record** (`galley_core/lib/src/record.dart`) is one JSON file per frame. Its status is
  `rendered`, `frozen` or `error`, and the constructor refuses an error with no errors or errors
  on a non-error. A landing is a uri or an unknown with a reason, never both and never neither.

## D11 · A round records where it came from (2026-11-26)

`round.json` holds the app's commit, whether its tree had changes not in that commit, the
Flutter version and the time (`galley_core/lib/src/provenance.dart`). An answer says "fixed in
this commit", and a round that names its commit is how a reviewer knows the fix is in the frame.

- **Each fact is Known or Unrecorded with a reason.** Rejected: an empty string or `null` for a
  commit that could not be read. That looks the same as a writer that forgot, and a dirty
  `false` would look like a clean tree.
- **Read before anything is written.** A round written inside the checkout to a directory git
  does not ignore would otherwise make its own tree look dirty.
- **Untracked files make the tree dirty; ignored ones do not.** A new file the app imports
  changes what renders. A build directory does not.
- **The Flutter version is read from `$FLUTTER_ROOT/bin/cache/flutter.version.json`**, which
  `flutter test` sets for the test process. Rejected: running `flutter --version`. It takes
  seconds, it can run a different Flutter from the one running the test, and it can update
  itself.
- **A round outside git still packs.** Its frames are worth reviewing, and the reviewer is told
  the commit is unknown.
- *Mutation, 2026-11-26:* 9 of 9 mutants of the reader and the packer's write are killed,
  against real git in temp checkouts. Not tested: git exiting 0 with something that is not a
  SHA, which real git cannot be made to do. The guard is there so that a round would say so
  rather than fail.

## D12 · A galley is a directory, and `galley_cli` keeps it (2026-11-26)

Until the server (D7), a galley is a directory, `.galley/` in the app's root by default
(`galley_cli/lib/src/galley_directory.dart`):

```
.galley/
  marks/<id>.json              one mark each, its history only ever appended to
  rounds/<n>/                  a round as the packer wrote it
  rounds/<n>/placements.json   where every mark is in that round
```

`galley pack` renders round n+1 by running the app's galley test with `GALLEY_OUT` set
(D3), reads it back through `StoredRound` in galley_core, and carries every mark into it from
the round that last placed it. `mark`, `pull`, `answer`, `verify`, `reopen` and `withdraw` work
on it.

- **One file per mark.** Two people answering two marks never write the same file. Rejected:
  one `marks.json`, where every answer rewrites every mark.
- **A mark is only ever appended to.** `saveMark` refuses a write that changes the note, the
  anchor or a past event. Rejected: trusting each command to append; a command that rebuilt a
  mark from its arguments would drop its history without a word.
- **Placements are per round.** The next round is carried from the round that last placed
  each mark, so a round that rendered and was never carried (a pack killed in between) is
  skipped, not read as "every mark is gone". `placements(n)` is null for such a round, never
  an empty list.
- **A round that did not finish is refused and kept.** No `index.json` means the galley test
  died. `pack` exits 1, says where the partial round is, and the next round is numbered past
  it rather than writing over it.
- **A round with error frames is a round.** `pack` exits 0 when the round was written, and
  says that the test exited non-zero: each error frame failed its test (D10), and its marks
  are Unplaced, not Lost.
- **Ids are random** (`m` + 12 hex digits). Rejected: a counter. Two people marking the same
  galley offline would both make `m3`.
- **`answer fixed` stores the full SHA, and checks it is a commit** in the app's repository.
  A short SHA unique today can be ambiguous next year, and a fix in a commit that does not
  exist cannot be verified.
- **`.galley/` must be ignored or committed.** Provenance is read before the round is written
  (D11), but the earlier rounds are already there: an untracked `.galley/` makes every round
  after the first look dirty. Ignoring it is the expected case; the server will hold the
  galley.
- **A galley that does not hold together is refused, naming the file** (0.3.7): a mark or
  placements file that does not read, a placement naming a mark with no file, a round record
  listed and missing. It is `Refused.damaged`, never a `FormatException`, which callers read
  as bad input: in 0.3.6 a mark file deleted by hand made every `POST /api/marks` a 400 that
  blamed the request. `galley serve` reads every mark and placement before it listens, so it
  says so at start. Records and trees are checked when read, not at start: they are large and
  the packer's own.
- **The reader is in galley_core** (`StoredRound` over a `RoundFiles` interface), so the
  server and the viewer read a round the same way the CLI does. A missing tree leaves its
  frame treeless (its marks Unplaced); a malformed one is refused, because a packer bug must
  not read as an app with no widgets.
- *Mutation, 2026-11-26:* 12 of 12 mutants of `StoredRound` and `Placements`, and 35 of 35 of
  the CLI and the galley directory, are killed. One test packs the galley package's toy round
  twice with the real `flutter test`. Not tested: a write killed between the temp file and
  its rename.

## D13 · `galley serve` is the canvas's backend on one machine (2026-11-26)

`galley serve` serves a local galley over HTTP on loopback
(`galley_cli/lib/src/galley_server.dart`). The canvas reads rounds and marks from it, and
raises marks and records events through it. Every write goes through `LocalGalley`, the same
service the commands use, so a mark raised in the browser is checked and stored exactly like
one raised with `galley mark`. Rejected: a second implementation of raise and record for the
server. The two would drift on what they refuse.

```
GET  /api/galley                rounds, latest_round
GET  /api/marks                 every mark as a work item; image is a URL under /api/rounds
GET  /api/rounds/<n>/<path>     a file of a finished round
POST /api/marks                 frame (key | axes), node and/or  -> 201 mark, status, node, round
                                at, note, by
POST /api/marks/<id>/events     a MarkEvent's JSON, without at   -> 200 mark, status
GET  /<path>                    the built canvas, from --web
```

- **It is for one machine.** It binds loopback only, `127.0.0.1` and `::1` at one port, so a
  client that tries `::1` first and does not fall back still finds it. The outside reviewers are served by the
  server of D7, not by this one.
- **The Host must be loopback at its own port.** A page on another site can rebind its name
  to 127.0.0.1 and reach the socket (DNS rebinding), but it still sends its own name as the
  Host, and that is refused with 403.
- **A POST must be `application/json`.** A page on another origin cannot send that without a
  CORS preflight, and the server answers no preflight, so another site cannot write marks.
  Rejected: a token in the URL. It protects against the same two attacks, and it ends up in
  shell history and screenshots.
- **Who acts is whoever the request names (`by`)**, as it is for the commands. Anyone who can
  reach this socket can already write the galley's files.
- **An event's time is the server's.** A client's `at` is replaced. A history ordered by
  clocks the reviewers set is not an order. A fix's commit is resolved to its full SHA in the
  app's repository, as `answer fixed` does.
- **One rule keeps file reads inside a round or the canvas:** the resolved path, with `..`
  and symlinks resolved, must be under the resolved root. A round that did not finish (no
  `index.json`) serves nothing. Rejected: also refusing `..` and encoded separators one segment
  at a time. Mutation found no request that check refused and the root rule let through.
- **A refusal says what kind it is** (`Refused.invalid`, `missing`, `conflict`,
  `environment`, `damaged`). The server answers 422, 404 and 409 for the first three, and 500 for
  the last two. A malformed request is
  400, a wrong content type 415, a body over 1 MB 413, and a wrong method 405. 409 is kept for
  a mark whose status does not allow the event, so a client can tell "fix the input" from "the
  mark moved on". *Corrected in 0.3.6:* 0.3.5 answered every refusal 409, a blank note
  included. The first app to call it reported that. An oversized body is read to the end
  and dropped before the answer is sent. Answering early resets the connection, and the
  client sees a broken pipe instead of a 413.
- **A widget is given by its node, a point, or both** (0.3.7). A point alone pins the deepest
  widget there. Node and point together pin that widget at the point, which must be inside
  it (422 otherwise): the canvas lets a reviewer click a label and choose the card around
  it. Rejected: the point alone, which could only ever name the deepest widget.
- **A frame is taken as its key or as its axes.** A mark's JSON carries the key string, and a
  record's axes read as an object, so whichever a client read goes back as it is.
- **The port defaults to 7340**, so the canvas's address can be bookmarked. Rejected: a free
  port each run, which would print a new address every time.
- *Mutation, 2026-11-26:* 20 mutants of the server were run, and every one left in the code
  is killed. The two that survived were the per-segment checks, and they were removed (see
  above). In 0.3.6, 12 more for the refusal kinds, the IPv6 bind and the key form, all killed.
  In 0.3.7, 5 for a node with a point, 6 for a damaged galley and 7 for withdrawal in the
  core, all killed; one survived at first (a point below the widget) until a test reached it.
  Not tested: the fallback to IPv4 alone on a machine with no IPv6 loopback. How the built
  canvas reaches an app is D14.

## D14 · The canvas ships built, as a release asset `galley serve` fetches and checks (2026-11-26)

`galley_web` is a Flutter web app, and an app adopts Galley by git tag (D8), so `galley
serve` must find a built canvas that nobody on the app's side built. Measured on this
machine: `flutter build web --release --no-web-resources-cdn` is 40 MB (CanvasKit 36 MB,
`main.dart.js` 1.7 MB), 14 MB as tar.gz. Decided with 0.3.7, and built in 0.3.8, whose
archive is 14,373,021 bytes in 54 entries. How a release builds and pins it is
[RELEASING.md](RELEASING.md).

- **The build is a GitHub release asset, `galley_web-<version>.tar.gz`, on the tag it was
  built from.** `galley_cli` pins it in its source: the tag and the archive's SHA-256. A
  release that does not change the canvas keeps the old pin.
- **`galley serve` fetches it on first use**, into a cache outside the app
  (`$GALLEY_CACHE`, else the platform's user cache directory, under `galley/`). The archive
  must match the pinned SHA-256 before anything is unpacked, and it is unpacked beside its
  final place and renamed into it, so a cache directory is whole or absent. After that,
  `serve` starts with no network.
- **A canvas that cannot be fetched is said, not hidden.** `serve` still serves the API,
  and says at start that there is no canvas, why, and that `--web <dir>` serves one. A
  mismatched SHA-256 is refused and nothing is kept.
- **`--web <dir>` overrides it**, for working on the canvas itself.
- **The build loads nothing from outside.** `--no-web-resources-cdn` puts CanvasKit in the
  archive, so a galley can be reviewed offline (D13), and a reviewer's browser tells no
  third party what it opened.
- Rejected: **committing the build.** 40 MB a release, kept forever in this repo's history
  and in the git mirror pub keeps of it for every adopter.
- Rejected: **building it on demand from the pub cache.** It writes into the pub cache, or
  copies the package and runs `pub get` in the copy, builds with whatever Flutter the app
  pins (which this canvas was never tested on), and takes minutes. It also cannot work once
  `galley_cli` is on pub.dev, which ships no Flutter sources for a pure-Dart package.
- Rejected: **CanvasKit from Google's CDN.** It cuts the archive to about 2 MB, and makes the
  canvas need the network and tell a third party when it is opened.
- What it costs: a release that changes the canvas has one more step, building and attaching
  the archive, and `galley_cli` gains the dependencies to check and unpack it.

## D15 · The server is PocketBase with Galley's schema, and the core judges every write (2026-11-27)

ROADMAP step 6 puts a galley on the server D7 chose, for reviewers who are not on the owner's
machine. The local galley (D12) is unchanged; a galley is local or on a server, never both.
This was reviewed before any of it was built, and the review's findings are folded in below.
Each one names the failure it prevents.

### What is stored, and who may write it

| Collection | Holds | Written by | Never |
|---|---|---|---|
| `users` | email | nobody: an invite makes the user | sign-up, a password |
| `galleys` | name, owner | any signed-in user, as owner | deleted |
| `members` | galley, user, role (owner or reviewer), alias, revoked | the galley's owner, in the batch that makes the galley; the invitee, accepting, who chooses the alias; the owner, revoking | deleted; two for one user in one galley; an alias changed by a member |
| `invites` | galley, email (lower-cased), accepted | the galley's owner; the hook that burns it on accepting | reused, accepted for someone else, made by a reviewer; for an owner (an invite makes a reviewer, so it carries no role) |
| `rounds` | galley, number, frame keys, manifest (path, SHA-256, size), placements, finished | the owner, while pushing | read by a reviewer before `finished`; changed after it; two with one number |
| `files` | round, path, the file | the owner, before the round is finished, at a path its manifest lists | updated or deleted; two at one path |
| `marks` | round, frame key, anchor, pin, note, author | any member, as themselves | updated or deleted; raised on a round a newer one replaced, or on a frame it does not have |
| `events` | mark, seq, kind, note, commit, answer kind, author | any member, as themselves; an answer only the owner | updated or deleted; one the mark's history does not allow; two with one seq |

Every rule also requires that the writer's membership is not revoked, and takes the galley
from the row written to (the mark's, the round's), never from a field of the request. A mark
and an event have no galley column: theirs is their round's, reached through the relation, so
it cannot disagree with it.

- **Nothing is erased, and the schema says so.** No relation cascades on delete, no
  collection has a delete rule, and a migration test checks both, for every collection.
  Rejected: a delete rule of nobody on top of cascading relations, which the spike had. One
  deleted user row would then take every mark and event they wrote with it. What this does not
  stop: whoever runs the server can edit its database. Galley does not defend against its
  operator.
- **A member is revoked, not removed.** The owner sets `revoked`, and from the next request
  the member can neither read nor write. What they wrote stays, under their alias. D7 chose
  PocketBase partly because revoking a member stops their next write. Building the server
  without revocation would have dropped that.
- **`by` is the member's alias in that galley.** It is chosen on accepting the invite: 1 to 40
  letters, digits, spaces, `.`, `-` or `'`, with no control characters. It must be unique in
  the galley, ignoring case and repeated spaces. Records store the author's user id, and the
  client reads `by` through the membership. A mark's `by` and a withdrawal's `by` are then the
  same string exactly when they are the same person, which is what `Withdrawn` compares (D12).
  A superuser who corrects a typo corrects it everywhere at once. Rejected:
  - one name per user, set once and unique on the server: a stranger could take "Sam" first,
    and a typo was permanent;
  - the user id: a person cannot read it in `pull --json`;
  - the email: every member would see every other member's address;
  - `by` stored on each record: a correction would split one person into two.

  Not caught: two aliases that look alike in different scripts. `galley members` shows the
  owner each alias next to its email.
- **Events are typed columns, not a JSON blob.** `kind` is one of the event names, and
  `note`, `commit` and the answer kind are fields. The client builds the core's `MarkEvent`
  from them, and the time is the server's `created` (D13). Rejected: the event's JSON as
  written. It carried a `by` and an `at` the client chose, and any shape that
  `MarkEvent.fromJson` cannot read would make the mark unreadable for everyone.
- **The core judges every write.** A hook gathers the write, the mark, its events in `seq`
  order and the writer's role. It writes them as JSON to a file and passes its path to `galley_validate`, a Dart program
  over galley_core compiled with `dart compile exe`, inside the write's transaction. The
  validator answers `{"ok": true}` or `{"refused": "<why>"}`, which the hook returns as a 400.
  It folds the history as `Mark` does and checks the new event with `MarkEvent.apply`. It also
  checks the answer (a note, a commit of 7 to 40 hex digits), a reopen or withdrawal's note,
  the anchor through `Anchor.fromJson`, and the pin's range. Seen on 0.40.6 (spike kept in
  `.game_loop/notes/spike-exec/`, not tracked): `$os.exec` inside `runInTransaction` answers
  in about 14 ms warm and 365 ms on the first call. A non-zero exit throws away the output, so
  the validator always exits 0. Rejected:
  - the fold written again in the hook's JavaScript, with a test that compares the two. The
    copy would not have been one function but every rule above, and the comparison could only
    cover the cases someone thought to list;
  - galley_core compiled to JavaScript for the hook's runtime: untried, and dart2js expects a
    browser's globals.

  The cost is a Dart toolchain wherever the validator is built. `galley host` compiles it
  with the Dart running `galley`, once per version, into the cache. A server elsewhere gets
  it cross-compiled (`--target-os linux`, checked from macOS).
- **Two writes to one mark at once cannot both land.** The hook gives each event `seq` =
  the count of earlier events + 1, and (mark, seq) is unique. Both run inside the transaction
  that judges the event, and PocketBase runs one writing transaction at a time, so the second
  of two events sent together is judged against a history that holds the first. Five verifies
  sent at once land once, and the other four are refused in the core's words (galley_cli's
  `host_test.dart`). The index is a second guard, for a writer that is not the hook. The client
  does not retry: the refusal it gets is the answer, against the history that landed.
  Rejected: ordering by `created`, which has millisecond resolution, so two events could tie.
  *Corrected 2026-11-27:* this said the index refused the second and the client tried again;
  measured, the transactions never interleave, so the index is not reached.
- **A mark that still does not fold is shown damaged, alone.** If the database was edited, or
  the validator has a bug, that mark is listed with the reason, and the others are read.
  Locally, D12 refuses the whole galley, because the owner is its only writer and should fix
  it. On a server, one bad record must not hide every other member's marks (an unknown is
  never nothing, but it is not everything either). *Not built yet (0.3.9):* `Galley.marks`
  has no form for a damaged mark, so the client refuses the read as `Refused.damaged`, naming
  the mark and why. It never drops the mark. The form comes with the canvas on the server,
  which is what shows it.
- **A round is finished last, and whole.** `galley push`:
  1. creates the round with its frame keys and manifest;
  2. uploads its files in parallel;
  3. carries every mark;
  4. sets `finished` and the placements in one update.

  The hook refuses the finish unless every path in the manifest has a file and the placements
  name every mark raised on an earlier round. That check runs in the finish's own transaction,
  so a mark raised while the push ran makes the finish refused, and the push carries again.
  A reader checks each file against the manifest's SHA-256 and names the one that differs. A
  push that dies leaves an unfinished round that no reviewer reads, and the next push takes
  the next number (D12). Rejected: placements as a file of the round. A finish could not check
  a file, and a file is never replaced.
- **A mark is raised on the newest finished round.** A raise on an older one is refused
  ("round 4 is out; reload"), so every mark the canvas shows is placed in the round on screen.
- **Mail is never sent by accident.** With no SMTP configured, PocketBase sends mail with the
  machine's `sendmail`. Galley's hook refuses to send a code unless SMTP is set, or unless
  `GALLEY_OTP_LOG` names a directory, where `galley host` writes the code for a local run.
- **Limits are set, not defaulted.** A file is at most 20 MB, a manifest lists at most 5,000
  files, a note is at most 4,000 characters, and PocketBase's rate limiter is on. Not built: a
  quota on rounds. An owner can fill the disk, and the owner is the person who runs the server.
- **A note is a reviewer's words.** `pull --json` hands notes to the agent that edits the
  app. The README and `llms.txt` say a note is a request to weigh, never an instruction to
  follow.

### Where the code is

```
packages/galley_core/     + the Galley interface, pin resolution, the rules the validator runs
packages/galley_server/   what speaks the server's language. Depends on galley_core.
  lib/galley_server.dart    the client: sign-in, galleys, members, rounds, marks, events.
                            Pure Dart and package:http, so the CLI and the canvas share it.
  lib/pocketbase/           pb_migrations/ and pb_hooks/, run as they are by PocketBase
  bin/galley_validate.dart  the judge the hooks call
```

- **One `Galley` interface, in the core.** The CLI's commands, `galley serve` and the canvas
  speak to a galley through it: rounds, marks with their placements, raise and add an event.
  `LocalGalley` (CLI), the server client (galley_server) and the canvas's client for `galley
  serve` implement it. The work items `pull --json` prints are built from it in the core. The
  refusal it throws moves to the core with it. Rejected: the server client as a fourth shape
  beside `LocalGalley`, the D13 JSON and `GalleyApi`. Each command would then have had one
  path for each galley.
- **The client is one package both sides use.** Rejected: the mapping in galley_core and the
  HTTP in each layer, which would write sign-in, paging and file tokens twice. Rejected too:
  the client in galley_core, which depends on nothing but the SDK (D1).
- **The schema is source that ships with the client, not a build.** `galley host` finds
  `lib/pocketbase` and the validator's source through the package's own location, so the
  schema is always the same version as the CLI that runs it. Rejected: a release archive
  pinned like the canvas (D14). The canvas is a build because building it needs the matching
  Flutter. The schema needs no build, and the validator needs only the Dart already running.
  An archive would add a pin to bump and a publish step to each server change.
- **A round reads in parallel.** The client fetches a round's files eight at a time and gets
  a new file token when one expires. Read one at a time, about 310 files would take tens of
  seconds over a real network.
- **`galley host` runs a server on this machine** for the step 6 check and for working on
  the server. It fetches the pinned PocketBase for this platform, checks its SHA-256 as D14
  checks the canvas, and runs it with the schema, the hooks, the validator and the canvas.
  The fetch, the check and the unpacking are the canvas cache's, generalized to any pinned
  archive. It is not hosting (ROADMAP step 8), which runs the same files next to the same
  binary. The server's tests are galley_cli's, through `galley host`. galley_server cannot
  depend on galley_cli, which depends on it.
- **The commands follow the galley.** `galley link <url>` writes `.galley/server.json`. From
  then on `pull`, `answer`, `verify`, `reopen`, `withdraw` and `mark` act on the server as
  the signed-in user, and `push` replaces `pack`. In that mode `pack` and `--by` are refused,
  not ignored. `galley login` signs in by emailed code. The token is kept in the user cache
  directory, keyed by the server, never in `.galley/`, which may be committed (D12). The
  owner's agent uses the owner's token, so its answers carry the owner's alias, as `--by`
  does locally. The local marks and rounds stay where they are, unused, and `galley unlink`
  goes back to them. Not built: importing local marks. Their `by` names nobody on the
  server, and mapping each one to a member is a decision for the owner.
- **The owner may verify their own answer.** The core allows it, and the server does not
  narrow it, because the first adopting app's owner is also one of its reviewers. Narrowing it
  is a rule for the validator, if a galley ever needs it.
