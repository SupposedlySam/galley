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

/// The user whose email is [email], lower-cased, made if there is none: nobody signs up, so an
/// invite and an operator's owner are each how a user comes to be. Made with a password nobody
/// knows, since a user signs in by a mailed code only.
function userFor(app, email) {
  const lower = email.toLowerCase();
  try {
    return app.findAuthRecordByEmail("users", lower);
  } catch (_) {
    const user = new Record(app.findCollectionByNameOrId("users"));
    user.setEmail(lower);
    user.setRandomPassword();
    app.save(user);
    return user;
  }
}

/// The operator's settings, from the environment, applied to [app] on every start (docs/
/// DESIGN.md D18). The environment is the truth: a change made in PocketBase's dashboard to a
/// setting named here is undone by the next start, so a deployment says its settings once, in
/// its configuration, and never drifts from it.
///
/// - GALLEY_URL: the server's public address, which PocketBase puts in its mails.
/// - GALLEY_SMTP_HOST, with GALLEY_SMTP_PORT (587), GALLEY_SMTP_USERNAME,
///   GALLEY_SMTP_PASSWORD and GALLEY_SMTP_TLS ("true" for TLS from the first byte, as on 465;
///   otherwise STARTTLS, which PocketBase's mailer requires before it sends a password to any
///   host but this one): the relay the sign-in codes are mailed through. GALLEY_MAIL_FROM is
///   then required, and GALLEY_MAIL_NAME names the sender ("Galley").
/// - GALLEY_PROXY_HEADER: the header the proxy in front of the server names the client in
///   (Fly-Client-IP on Fly.io). Without it, behind a proxy, every client is the proxy, and the
///   rate limit is one limit for all of them.
/// - GALLEY_OWNERS: emails, comma separated, who may sign in uninvited, and so make a galley
///   ([owners]).
///
/// A setting the environment leaves out is left as it is. Settings it cannot read throw, and
/// the server does not start: a server that started with its mail half set would refuse every
/// sign-in later, where nobody is looking.
function operator(app) {
  const env = (name) => ($os.getenv(name) || "").trim();
  const settings = app.settings();
  let changed = false;

  const url = env("GALLEY_URL");
  if (url) {
    if (!/^https?:\/\/[^\s/]+/.test(url)) {
      throw new Error(`galley: GALLEY_URL is not an http(s) address: ${url}`);
    }
    settings.meta.appURL = url.replace(/\/+$/, "");
    changed = true;
  }

  const host = env("GALLEY_SMTP_HOST");
  const smtpRest = [
    "GALLEY_SMTP_PORT",
    "GALLEY_SMTP_USERNAME",
    "GALLEY_SMTP_PASSWORD",
    "GALLEY_SMTP_TLS",
    "GALLEY_MAIL_FROM",
    "GALLEY_MAIL_NAME",
  ].filter((n) => env(n));
  if (!host && smtpRest.length) {
    throw new Error(`galley: ${smtpRest.join(", ")} set without GALLEY_SMTP_HOST`);
  }
  if (host) {
    const portText = env("GALLEY_SMTP_PORT") || "587";
    const port = Number(portText);
    if (!/^[0-9]+$/.test(portText) || port < 1 || port > 65535) {
      throw new Error(`galley: GALLEY_SMTP_PORT is not a port: ${portText}`);
    }
    const tls = env("GALLEY_SMTP_TLS") || "false";
    if (tls !== "true" && tls !== "false") {
      throw new Error(`galley: GALLEY_SMTP_TLS is "true" or "false", not ${tls}`);
    }
    const from = env("GALLEY_MAIL_FROM");
    if (!/^[^\s@]+@[^\s@]+$/.test(from)) {
      throw new Error(`galley: GALLEY_SMTP_HOST needs GALLEY_MAIL_FROM, an address: "${from}"`);
    }
    const username = env("GALLEY_SMTP_USERNAME");
    const password = $os.getenv("GALLEY_SMTP_PASSWORD") || "";
    if (!username !== !password) {
      throw new Error("galley: GALLEY_SMTP_USERNAME and GALLEY_SMTP_PASSWORD are set together");
    }
    settings.smtp.enabled = true;
    settings.smtp.host = host;
    settings.smtp.port = port;
    settings.smtp.tls = tls === "true";
    settings.smtp.username = username;
    settings.smtp.password = password;
    settings.meta.senderAddress = from;
    settings.meta.senderName = env("GALLEY_MAIL_NAME") || "Galley";
    changed = true;
  }

  const header = env("GALLEY_PROXY_HEADER");
  if (header) {
    settings.trustedProxy.headers = [header];
    changed = true;
  }

  if (changed) app.save(settings);
  owners();
}

/// GALLEY_OWNERS, lower-cased: who may sign in without an invite. Throws for one that is not
/// an email.
function owners() {
  const listed = ($os.getenv("GALLEY_OWNERS") || "").trim();
  return (listed ? listed.split(",") : []).map((s) => {
    const email = s.trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+$/.test(email)) {
      throw new Error(`galley: GALLEY_OWNERS has something that is not an email: "${s.trim()}"`);
    }
    return email;
  });
}

module.exports = {
  judge,
  json,
  members,
  markRow,
  history,
  newest,
  finished,
  visitOf,
  userFor,
  operator,
  owners,
};
