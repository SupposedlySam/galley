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
    // Two events written at once both count the same history; the unique (mark, seq) index
    // refuses the second, and its writer refetches and tries again.
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

// An invite: its email lower-cased, as every user's is, and a user for it, since nobody signs
// up. The code that signs them in goes to that email.
onRecordCreateExecute((e) => {
  e.app.runInTransaction((tx) => {
    const email = e.record.getString("email").toLowerCase();
    e.record.set("email", email);
    try {
      tx.findAuthRecordByEmail("users", email);
    } catch (_) {
      const user = new Record(tx.findCollectionByNameOrId("users"));
      user.setEmail(email);
      user.setRandomPassword();
      tx.save(user);
    }
    e.app = tx;
    e.next();
  });
}, "invites");

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
