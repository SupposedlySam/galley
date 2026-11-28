/// <reference path="../pb_data/types.d.ts" />

// Galley's hooks (docs/DESIGN.md D15). The collections' rules have already said the writer may
// write here at all; each hook below gathers what the write depends on, asks galley_validate
// whether it may say what it says, and stores it, all in one transaction.
//
// Why a transaction of our own: PocketBase's create and update endpoints do not run in one
// (apis/record_crud.go, v0.40.6), so the rows a hook reads could change before its write
// lands. A transaction runs on PocketBase's one writing connection (core/base.go,
// SetMaxOpenConns(1)), so two of them never interleave: the mark a finish counts is every mark
// there is, and an event's `seq` is the count of events there are. Setting `e.app` to the
// transaction before `e.next()` makes the INSERT or UPDATE itself run in it; PocketBase's own
// delete does the same (core/record_model.go, onRecordDeleteExecute).
//
// Each handler requires galley.js inside itself: PocketBase runs a handler in a VM that sees
// nothing declared beside it.

// A mark: raised on the newest finished round, on a frame it has, with an anchor, a pin and a
// note the core reads.
onRecordCreateExecute((e) => {
  const g = require(`${__hooks}/galley.js`);
  e.app.runInTransaction((tx) => {
    const round = tx.findRecordById("rounds", e.record.getString("round"));
    const galley = round.getString("galley");
    g.judge(tx, {
      write: "mark",
      mark: {
        frame: e.record.getString("frame"),
        anchor: g.json(e.record, "anchor"),
        pin: g.json(e.record, "pin"),
        note: e.record.getString("note"),
      },
      round: {
        number: round.getInt("number"),
        finished: round.getBool("finished"),
        frames: g.json(round, "frames"),
      },
      newest: g.newest(tx, galley, true),
    });
    e.app = tx;
    e.next();
  });
}, "marks");

// An event: one the mark's history allows, an answer only from the owner, numbered next.
onRecordCreateExecute((e) => {
  const g = require(`${__hooks}/galley.js`);
  e.app.runInTransaction((tx) => {
    const mark = tx.findRecordById("marks", e.record.getString("mark"));
    const galley = tx.findRecordById("rounds", mark.getString("round")).getString("galley");
    const byUser = g.members(tx, galley);
    const writer = byUser[e.record.getString("author")];
    if (!writer) throw new ForbiddenError("only a member of the galley writes to its marks");
    const history = g.history(tx, mark.id, byUser);
    g.judge(tx, {
      write: "event",
      mark: g.markRow(mark, byUser),
      history,
      event: {
        kind: e.record.getString("kind"),
        answer: e.record.getString("answer"),
        commit: e.record.getString("commit"),
        note: e.record.getString("note"),
      },
      role: writer.role,
      by: writer.alias,
    });
    // PocketBase runs one writing transaction at a time, so of two events sent at once the
    // second is judged and numbered against a history that holds the first. Without
    // `e.app = tx` the save would wait on the transaction this hook holds, and never end
    // (measured: the suite hung). The unique (mark, seq) index is a second guard, for a writer
    // that is not this hook. The writer is not retried: its refusal is the answer.
    e.record.set("seq", history.length + 1);
    e.app = tx;
    e.next();
  });
}, "events");

// A round: the next number in the galley, with frame keys and a manifest the core reads.
onRecordCreateExecute((e) => {
  const g = require(`${__hooks}/galley.js`);
  e.app.runInTransaction((tx) => {
    g.judge(tx, {
      write: "round",
      round: {
        number: e.record.getInt("number"),
        frames: g.json(e.record, "frames"),
        manifest: g.json(e.record, "manifest"),
      },
      newest: g.newest(tx, e.record.getString("galley"), false),
    });
    e.app = tx;
    e.next();
  });
}, "rounds");

// Finishing a round: every file its manifest lists is there, and the placements name every
// mark raised on an earlier round. The rule allows no other update.
onRecordUpdateExecute((e) => {
  const g = require(`${__hooks}/galley.js`);
  e.app.runInTransaction((tx) => {
    const was = e.record.original();
    const galley = was.getString("galley"), number = was.getInt("number");
    const byUser = g.members(tx, galley);
    const marks = tx.findRecordsByFilter(
      "marks",
      "round.galley = {:g} && round.number < {:n}",
      "created",
      0,
      0,
      { g: galley, n: number },
    );
    g.judge(tx, {
      write: "finish",
      round: { number, finished: was.getBool("finished"), manifest: g.json(was, "manifest") },
      files: tx
        .findRecordsByFilter("files", "round = {:r}", "", 0, 0, { r: was.id })
        .map((f) => f.getString("path")),
      placements: g.json(e.record, "placements"),
      marks: marks.map((m) => g.markRow(m, byUser)),
    });
    e.app = tx;
    e.next();
  });
}, "rounds");

// A round's file: listed by its manifest, at its size, once, before the round is finished.
onRecordCreateExecute((e) => {
  const g = require(`${__hooks}/galley.js`);
  e.app.runInTransaction((tx) => {
    const round = tx.findRecordById("rounds", e.record.getString("round"));
    const upload = e.record.getUnsavedFiles("file")[0];
    g.judge(tx, {
      write: "file",
      round: { finished: round.getBool("finished"), manifest: g.json(round, "manifest") },
      path: e.record.getString("path"),
      size: upload ? upload.size : -1,
      existing: tx
        .findRecordsByFilter("files", "round = {:r}", "", 0, 0, { r: round.id })
        .map((f) => f.getString("path")),
    });
    e.app = tx;
    e.next();
  });
}, "files");

// A membership: an alias no other member has; for an invitee, their invite burned with it.
onRecordCreateExecute((e) => {
  const g = require(`${__hooks}/galley.js`);
  e.app.runInTransaction((tx) => {
    const galley = e.record.getString("galley");
    g.judge(tx, {
      write: "member",
      alias: e.record.getString("alias"),
      aliases: Object.values(g.members(tx, galley)).map((m) => m.alias),
    });
    if (e.record.getString("role") === "reviewer") {
      const email = tx.findRecordById("users", e.record.getString("user")).email();
      const open = tx.findRecordsByFilter(
        "invites",
        "galley = {:g} && email = {:e} && accepted = false",
        "",
        1,
        0,
        { g: galley, e: email },
      );
      // The rule saw an open invite; another accept may have taken it since.
      if (!open.length) throw new BadRequestError("there is no open invite to this galley for you");
      open[0].set("accepted", true);
      tx.save(open[0]);
    }
    e.app = tx;
    e.next();
  });
}, "members");

// A member's first visit: to a finished round of their galley, and only one, kept after.
onRecordCreateExecute((e) => {
  const g = require(`${__hooks}/galley.js`);
  e.app.runInTransaction((tx) => {
    const member = tx.findRecordById("members", e.record.getString("member"));
    const kept = tx.findRecordsByFilter("visits", "member = {:m}", "", 1, 0, { m: member.id });
    // Two tabs opened at once: the second reads the first's visit and updates it instead. The
    // unique index on `member` is the second guard.
    if (kept.length) throw new BadRequestError("this member's visit is kept already; read it again");
    g.judge(tx, {
      write: "visit",
      visit: g.visitOf(e.record),
      kept: null,
      finished: g.finished(tx, member.getString("galley")),
    });
    e.app = tx;
    e.next();
  });
}, "visits");

// A later visit: the round opened after the one kept, judged against the row as it is in this
// transaction, not as the request found it.
onRecordUpdateExecute((e) => {
  const g = require(`${__hooks}/galley.js`);
  e.app.runInTransaction((tx) => {
    const kept = tx.findRecordById("visits", e.record.id);
    const member = tx.findRecordById("members", kept.getString("member"));
    g.judge(tx, {
      write: "visit",
      visit: g.visitOf(e.record),
      kept: g.visitOf(kept),
      finished: g.finished(tx, member.getString("galley")),
    });
    e.app = tx;
    e.next();
  });
}, "visits");

// An invite: its email lower-cased, as every user's is, and a user for it, since nobody signs
// up. The code that signs them in goes to that email.
onRecordCreateExecute((e) => {
  e.app.runInTransaction((tx) => {
    const email = e.record.getString("email").toLowerCase();
    e.record.set("email", email);
    require(`${__hooks}/galley.js`).userFor(tx, email);
    e.app = tx;
    e.next();
  });
}, "invites");

// The operator's settings, from the environment, on every start (galley.js, `operator`).
// Applied once PocketBase has bootstrapped, when its settings are loaded (core/base.go,
// v0.40.6: Bootstrap runs the system migrations, then ReloadSettings). Galley's own migration
// runs after, and changes none of these. Rejected: onServe, which the JavaScript VM does not
// offer (plugins/jsvm/binds.go, excludeHooks); and a migration, which runs once, so a
// deployment's changed secret would never reach the server.
onBootstrap((e) => {
  e.next();
  require(`${__hooks}/galley.js`).operator(e.app);
});

// An owner the operator listed (GALLEY_OWNERS) asks for a code and has no user yet: one is
// made now, so the code is sent. Made when asked for, not at start: on a first start the users
// collection is made by Galley's migration, after bootstrap. Anyone else with no user is
// answered as PocketBase answers them, with an id and no code (apis/record_auth_otp_request.go).
onRecordRequestOTPRequest((e) => {
  if (!e.record) {
    const g = require(`${__hooks}/galley.js`);
    const email = `${e.requestInfo().body.email || ""}`.toLowerCase();
    if (g.owners().includes(email)) e.record = g.userFor(e.app, email);
  }
  e.next();
}, "users");

// A sign-in code is mailed only when SMTP is set. With none, PocketBase would hand the mail
// to this machine's `sendmail`; instead the code is written to GALLEY_OTP_LOG, which
// `galley host` sets for a run on this machine, and with neither it is not sent at all.
onMailerRecordOTPSend((e) => {
  if (e.app.settings().smtp.enabled) return e.next();
  const dir = $os.getenv("GALLEY_OTP_LOG");
  if (!dir) {
    e.app
      .logger()
      .error("galley: no sign-in code was sent: set SMTP, or GALLEY_OTP_LOG for a local run");
    throw new BadRequestError("this server sends no mail yet");
  }
  $os.writeFile(`${dir}/${e.record.email()}`, `${e.meta.password}\n`, 0o600);
}, "users");
