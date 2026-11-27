// What every hook in main.pb.js shares (docs/DESIGN.md D15). PocketBase runs each handler in a
// VM of its own, so a handler sees nothing declared beside it; each one requires this file.

/// Asks galley_validate whether [request] may be written, and throws the refusal as a 400 when
/// it may not. galley_validate always exits 0 (a failed command's output is lost) and writes
/// one line: `{"ok": true}` or `{"refused": "<why>"}`.
///
/// The request goes in a file whose path is the one argument: Linux caps one argument at
/// 128 KiB, which a round's manifest passes, and a hook cannot write to a command's stdin.
/// The file is the server's own: under its data directory, readable by its owner only, named
/// at random so two writes judged at once never share one, and removed once judged.
///
/// No validator, or one that answers anything else, refuses the write: a write nobody judged
/// does not land.
function judge(app, request) {
  const exe = $os.getenv("GALLEY_VALIDATE");
  if (!exe) {
    throw new InternalServerError(
      "this server has no validator (GALLEY_VALIDATE is not set), so it takes no writes",
    );
  }
  const dir = `${app.dataDir()}/galley_judge`;
  const file = `${dir}/${$security.randomString(24)}.json`;
  let line;
  try {
    $os.mkdirAll(dir, 0o700);
    $os.writeFile(file, JSON.stringify(request), 0o600);
    line = toString($os.exec(exe, file).output()).trim();
  } catch (e) {
    throw new InternalServerError(`the validator did not run: ${e}`);
  } finally {
    try {
      $os.remove(file);
    } catch (_) {
      // Never written: the error above says why.
    }
  }
  let answer;
  try {
    answer = JSON.parse(line);
  } catch (_) {
    throw new InternalServerError(`the validator answered something else: ${line.slice(0, 200)}`);
  }
  if (answer && answer.ok === true) return;
  if (answer && typeof answer.refused === "string") throw new BadRequestError(answer.refused);
  throw new InternalServerError(`the validator answered something else: ${line.slice(0, 200)}`);
}

/// A JSON column, parsed. Null when unset.
function json(record, field) {
  const raw = record.getString(field);
  return raw === "" ? null : JSON.parse(raw);
}

/// The galley's memberships by user id: the alias that is each one's `by`, and their role.
function members(app, galley) {
  const byUser = {};
  for (const m of app.findRecordsByFilter("members", "galley = {:g}", "", 0, 0, { g: galley })) {
    byUser[m.getString("user")] = { alias: m.getString("alias"), role: m.getString("role") };
  }
  return byUser;
}

/// The row galley_server's `markOfRow` reads: the mark's columns, its author's alias as `by`,
/// and the server's `created` as `at`.
function markRow(mark, byUser) {
  return {
    id: mark.id,
    frame: mark.getString("frame"),
    anchor: json(mark, "anchor"),
    pin: json(mark, "pin"),
    note: mark.getString("note"),
    by: alias(byUser, mark),
    at: mark.getString("created"),
  };
}

/// A mark's events as the rows `markOfRow` reads, in `seq` order.
function history(app, mark, byUser) {
  return app
    .findRecordsByFilter("events", "mark = {:m}", "seq", 0, 0, { m: mark })
    .map((e) => ({
      kind: e.getString("kind"),
      answer: e.getString("answer"),
      commit: e.getString("commit"),
      note: e.getString("note"),
      by: alias(byUser, e),
      at: e.getString("created"),
    }));
}

function alias(byUser, record) {
  const m = byUser[record.getString("author")];
  // A record whose author is no member: the database was edited. The validator refuses the
  // row it is in, naming it, rather than reading it as nobody.
  return m ? m.alias : null;
}

/// The highest round number in [galley], counting only finished rounds when [finished]; null
/// when there is none.
function newest(app, galley, finished) {
  const filter = finished ? "galley = {:g} && finished = true" : "galley = {:g}";
  const rounds = app.findRecordsByFilter("rounds", filter, "-number", 1, 0, { g: galley });
  return rounds.length ? rounds[0].getInt("number") : null;
}

/// The numbers of [galley]'s finished rounds, lowest first.
function finished(app, galley) {
  return app
    .findRecordsByFilter("rounds", "galley = {:g} && finished = true", "number", 0, 0, { g: galley })
    .map((r) => r.getInt("number"));
}

/// A visits row as galley_core's Visit reads it: an unset `before` is stored as 0, and is none.
function visitOf(record) {
  const latest = record.getInt("latest"), before = record.getInt("before");
  return before === 0 ? { latest } : { latest, before };
}

module.exports = { judge, json, members, markRow, history, newest, finished, visitOf };
