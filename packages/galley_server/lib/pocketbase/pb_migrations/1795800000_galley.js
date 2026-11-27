/// <reference path="../pb_data/types.d.ts" />

// Galley's schema on PocketBase (docs/DESIGN.md D15): who may write what, and what the server
// itself refuses to do. What a write may say (a mark's anchor, an event the mark's history
// allows, a round's manifest) is not here: the hooks ask galley_validate, which judges it over
// galley_core. A rule here answers only "may this person write this row at all".
//
// Written by hand, as one migration, rather than as PocketBase's dashboard writes them (one
// file per change, with generated field ids): this file is the schema's source, and is read
// and reviewed as one. A later change is a later migration; this one is never edited once
// released, because a server that has run it will not run it again.
//
// Three things hold for every collection, and galley_cli's test/host_test.dart checks each one
// against the server, not this file:
// - no relation cascades on delete, and no collection has a delete rule: nothing is erased;
// - every rule that lets a member read or write requires that the membership is not revoked;
// - the galley a rule checks is the row's own (a create rule reads the row as it would be
//   stored), reached through its relations: a mark's round's, an event's mark's.

migrate((app) => {
  // A rule's "is a member of galley G, not revoked". Each use names its own alias, so two
  // memberships in one rule (a reviewer's own row, and the galley's owner) are two joins.
  // Conditions on one alias hold of one row: the user, the galley and `revoked` are one
  // membership's, not three memberships that each match one condition.
  const member = (galley, as = "m") =>
    `@collection.members:${as}.galley ?= ${galley} && ` +
    `@collection.members:${as}.user ?= @request.auth.id && ` +
    `@collection.members:${as}.revoked ?= false`;
  const owner = (galley, as = "o") =>
    `${member(galley, as)} && @collection.members:${as}.role ?= "owner"`;
  // The fields an update may not change. PocketBase's `:changed` is false for a field the
  // request leaves out, so this holds whatever the request sends.
  const unchanged = (...fields) =>
    fields.map((f) => `@request.body.${f}:changed = false`).join(" && ");
  // The fields a create may not set: the server sets them (a hook) or they start unset.
  const unset = (...fields) =>
    fields.map((f) => `@request.body.${f}:isset = false`).join(" && ");

  const users = app.findCollectionByNameOrId("users");
  // No sign-up and no password: an invite makes the user, and a code mailed to them signs
  // them in. A user sees only their own record, so no member reads another's email.
  unmarshal(
    {
      createRule: null,
      listRule: "id = @request.auth.id",
      viewRule: "id = @request.auth.id",
      updateRule: null,
      deleteRule: null,
      passwordAuth: { enabled: false },
      oauth2: { enabled: false },
      mfa: { enabled: false },
      otp: { enabled: true, duration: 300, length: 8 },
    },
    users,
  );
  app.save(users);

  // A relation that never cascades: deleting what it points to is refused while it points.
  const relation = (name, to) => ({
    name,
    type: "relation",
    collectionId: app.findCollectionByNameOrId(to).id,
    maxSelect: 1,
    required: true,
    cascadeDelete: false,
  });
  const text = (name, options = {}) => ({ name, type: "text", ...options });
  const bool = (name) => ({ name, type: "bool" });
  const json = (name, required) => ({ name, type: "json", required, maxSize: 4 << 20 });
  const timestamps = [
    { name: "created", type: "autodate", onCreate: true, onUpdate: false },
    { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
  ];
  // Every collection is made before any rule is set: a rule names collections that are made
  // after its own (the galleys' rules read members).
  const rules = {};
  const collection = (name, fields, rulesOf, indexes = []) => {
    app.save(new Collection({ type: "base", name, fields: [...fields, ...timestamps], indexes }));
    rules[name] = rulesOf;
  };

  collection(
    "galleys",
    [text("name", { required: true, max: 100 }), relation("owner", "users")],
    {
      listRule: member("id"),
      viewRule: member("id"),
      // Made together with the owner's membership, in one batch: see `members`.
      createRule: `@request.auth.id != "" && @request.body.owner = @request.auth.id`,
    },
  );

  collection(
    "members",
    [
      relation("galley", "galleys"),
      relation("user", "users"),
      { name: "role", type: "select", values: ["owner", "reviewer"], maxSelect: 1, required: true },
      // Judged by galley_validate ("member"): its length, its characters, and that no other
      // member of the galley has it.
      text("alias", { required: true, max: 40 }),
      bool("revoked"),
    ],
    {
      // Your own membership, revoked or not, so the client can say you were revoked; and the
      // galley's other members, while you are one.
      listRule: `user = @request.auth.id || (${member("galley")})`,
      viewRule: `user = @request.auth.id || (${member("galley")})`,
      createRule:
        `@request.auth.id != "" && @request.body.user = @request.auth.id && ` +
        `${unset("revoked")} && (` +
        // The galley's owner, in the batch that makes the galley: the galley names them.
        `(@request.body.role = "owner" && galley.owner = @request.auth.id) || ` +
        // An invitee, accepting: an invite for their email, not yet accepted. The hook burns it
        // in the same transaction.
        `(@request.body.role = "reviewer" && ` +
        `@collection.invites:i.galley ?= galley && ` +
        `@collection.invites:i.email ?= @request.auth.email && ` +
        `@collection.invites:i.accepted ?= false))`,
      // The owner revokes a reviewer, or gives a revoked one back their access. Nothing else of
      // a membership changes, and an alias is never changed by a member: a superuser corrects a
      // typo, and the correction reaches every mark at once.
      updateRule:
        `role = "reviewer" && ${owner("galley")} && ` +
        unchanged("galley", "user", "role", "alias"),
    },
    ["CREATE UNIQUE INDEX idx_members_galley_user ON members (galley, user)"],
  );

  collection(
    "invites",
    [relation("galley", "galleys"), { name: "email", type: "email", required: true }, bool("accepted")],
    {
      // The invitee sees theirs, to accept it; the owner sees the galley's.
      listRule: `email = @request.auth.email || (${owner("galley")})`,
      viewRule: `email = @request.auth.email || (${owner("galley")})`,
      createRule: `${owner("galley")} && ${unset("accepted")}`,
    },
    // One open invite per email in a galley. An accepted one is history, and stays.
    ["CREATE UNIQUE INDEX idx_invites_open ON invites (galley, email) WHERE accepted = FALSE"],
  );

  collection(
    "rounds",
    [
      relation("galley", "galleys"),
      { name: "number", type: "number", required: true, onlyInt: true, min: 1 },
      json("frames", true),
      json("manifest", true),
      json("placements", false),
      bool("finished"),
    ],
    {
      // A reviewer reads a round once it is finished; the owner, while pushing it.
      listRule: `${member("galley")} && (finished = true || ${owner("galley")})`,
      viewRule: `${member("galley")} && (finished = true || ${owner("galley")})`,
      createRule: `${owner("galley")} && ${unset("finished", "placements")}`,
      // Finishing is the one update: placements and `finished`, once.
      updateRule:
        `${owner("galley")} && finished = false && @request.body.finished = true && ` +
        unchanged("galley", "number", "frames", "manifest"),
    },
    ["CREATE UNIQUE INDEX idx_rounds_galley_number ON rounds (galley, number)"],
  );

  collection(
    "files",
    [
      relation("round", "rounds"),
      text("path", { required: true, max: 512 }),
      {
        name: "file",
        type: "file",
        required: true,
        maxSelect: 1,
        maxSize: 20 * 1024 * 1024,
        // Read with a file token, by members only (the rules below).
        protected: true,
      },
    ],
    {
      listRule: `${member("round.galley")} && (round.finished = true || ${owner("round.galley")})`,
      viewRule: `${member("round.galley")} && (round.finished = true || ${owner("round.galley")})`,
      createRule: owner("round.galley"),
    },
    ["CREATE UNIQUE INDEX idx_files_round_path ON files (round, path)"],
  );

  collection(
    "marks",
    [
      relation("round", "rounds"),
      text("frame", { required: true, max: 2000 }),
      json("anchor", true),
      json("pin", true),
      text("note", { required: true }),
      relation("author", "users"),
    ],
    {
      listRule: member("round.galley"),
      viewRule: member("round.galley"),
      createRule: `@request.body.author = @request.auth.id && ${member("round.galley")}`,
    },
  );

  collection(
    "events",
    [
      relation("mark", "marks"),
      // Set by the hook, never by the writer: the count of the mark's earlier events, plus one.
      { name: "seq", type: "number", onlyInt: true, min: 1 },
      // The core's names, judged by galley_validate; not a select, so the names are written
      // once, in galley_core.
      text("kind", { required: true, max: 40 }),
      text("answer", { max: 40 }),
      text("commit", { max: 40 }),
      text("note"),
      relation("author", "users"),
    ],
    {
      listRule: member("mark.round.galley"),
      viewRule: member("mark.round.galley"),
      createRule:
        `@request.body.author = @request.auth.id && ${member("mark.round.galley")} && ` +
        unset("seq"),
    },
    // Of two events written to one mark at once, the second is refused here.
    ["CREATE UNIQUE INDEX idx_events_mark_seq ON events (mark, seq)"],
  );

  for (const [name, rulesOf] of Object.entries(rules)) {
    const c = app.findCollectionByNameOrId(name);
    unmarshal(
      {
        listRule: null,
        viewRule: null,
        createRule: null,
        updateRule: null,
        deleteRule: null,
        ...rulesOf,
      },
      c,
    );
    app.save(c);
  }

  const settings = app.settings();
  settings.meta.appName = "Galley";
  // Set, not defaulted: PocketBase ships its limiter off.
  settings.rateLimits.enabled = true;
  // The galley and its owner's membership are made in one batch, which is one transaction.
  settings.batch.enabled = true;
  settings.batch.maxRequests = 10;
  app.save(settings);
});
