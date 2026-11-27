part of 'cli.dart';

// The commands of a galley on a server (docs/DESIGN.md D15, "The commands follow the
// galley"): signing in, linking `.galley/` to a server's galley, pushing a round, and the
// owner's invites. Once linked, `mark`, `pull`, `answer`, `verify`, `reopen` and `withdraw`
// act on the server through `_GalleyCommand.acting`.

/// Where this user's sign-ins are kept: `sessions` in the galley cache.
SessionStore _sessions(GalleyContext c) => switch (cacheDirectory(c.environment)) {
  final root? => SessionStore('$root/sessions'),
  null => throw const Refused.environment(
    'there is nowhere to keep a sign-in: set GALLEY_CACHE, or HOME',
  ),
};

/// The session for [url], refused with what to run when there is none.
Session _signedIn(GalleyContext c, Uri url) =>
    _sessions(c).read(url) ??
    (throw Refused.environment('you are not signed in to $url: `galley login $url --email <you>`'));

/// A linked galley, opened: the server's galley as the signed-in user, and their membership.
final class _Linked {
  _Linked(this.galley, this.member);

  /// [link]'s galley as the user signed in to its server, who must be a member of it, and not
  /// revoked.
  static Future<_Linked> open(GalleyContext c, ServerLink link) async {
    final session = _signedIn(c, link.url);
    final server = PocketBase(c.client, link.url);
    final account = ServerAccount(server, session);
    final member = switch (await account.standingIn(link.galley)) {
      Joined(:final member) => member,
      RevokedFrom() => throw Refused.missing(
        '${session.email}\'s access to galley ${link.galley} on ${link.url} was revoked by its '
        'owner',
      ),
      InvitedTo() => throw Refused.missing(
        '${session.email} is invited to galley ${link.galley} on ${link.url}, and has not joined '
        'it: `galley link ${link.url} --galley ${link.galley} --alias <your name>`',
      ),
      Outside() => throw Refused.missing(
        '${session.email} is not a member of galley ${link.galley} on ${link.url}',
      ),
    };
    return _Linked(
      ServerGalley(server, galleyId: link.galley, session: session, now: c.now),
      member,
    );
  }

  final ServerGalley galley;
  final Member member;

  /// Refused unless the member is the galley's owner, naming what only an owner does.
  void mustOwn(String what) {
    if (member.role != MemberRole.owner) {
      throw Refused.invalid('only the galley\'s owner $what; ${member.alias} is a reviewer');
    }
  }
}

/// A command that needs the galley to be linked.
abstract class _LinkedCommand extends _GalleyCommand {
  _LinkedCommand(super.c);

  /// The link, refused with what to run when there is none.
  ServerLink get requireLink =>
      link ??
      (throw const Refused.invalid(
        'this galley is not linked to a server: `galley link <url> --galley <id>` links it',
      ));

  /// The linked galley, opened.
  Future<_Linked> open() => _linked ??= _Linked.open(c, requireLink);
}

final class _Login extends _GalleyCommand {
  _Login(super.c) {
    argParser.addOption('email', help: 'The email you were invited with.', valueHelp: 'email');
  }

  @override
  String get name => 'login';

  @override
  String get invocation => 'galley login <url> --email <email>';

  @override
  String get description =>
      'Sign in to a Galley server by the code it mails you. The sign-in is kept in your user '
      'cache, never in .galley/.';

  @override
  Future<int> run() async {
    final rest = _args.rest;
    if (rest.length != 1) throw UsageException('give the server\'s URL', usage);
    final url = serverUrl(rest.single);
    final email = _args.option('email');
    if (email == null || email.trim().isEmpty) {
      throw UsageException('--email is required', usage);
    }
    final sign = SignIn(PocketBase(c.client, url));
    final otpId = await sign.requestCode(email);
    // To err, so `out` stays what the command did. A code that never arrives is an email the
    // server has no user for: it answers the same, so as not to say who is invited.
    c.err.write('If $email is invited to a galley on $url, a code was sent to it. Type the code: ');
    final code = c.readLine();
    if (code == null || code.trim().isEmpty) {
      throw const Refused.invalid('no code was given');
    }
    final session = await sign.withCode(otpId, code);
    _sessions(c).write(url, session);
    c.out.writeln('Signed in to $url as ${session.email}.');
    return 0;
  }
}

final class _Link extends _GalleyCommand {
  _Link(super.c) {
    argParser
      ..addOption('galley', help: 'The galley\'s id on the server.', valueHelp: 'id')
      ..addOption('create', help: 'Make a galley with this name, owned by you.', valueHelp: 'name')
      ..addOption(
        'alias',
        help:
            'Your name in the galley, on everything you write: for --create, or to join one '
            'you were invited to.',
        valueHelp: 'name',
      );
  }

  @override
  String get name => 'link';

  @override
  String get invocation => 'galley link <url> (--galley <id> | --create <name>) [--alias <name>]';

  @override
  String get description =>
      'Link this galley to one on a server: from then on its commands act there, as you.';

  @override
  Future<int> run() async {
    final rest = _args.rest;
    if (rest.length != 1) throw UsageException('give the server\'s URL', usage);
    final url = serverUrl(rest.single);
    final (id, create, alias) = (
      _args.option('galley'),
      _args.option('create'),
      _args.option('alias'),
    );
    if ((id == null) == (create == null)) {
      throw UsageException('give one of --galley and --create', usage);
    }
    if (link case final l? when !(l.url == url && l.galley == id)) {
      throw Refused.conflict(
        'this galley is already linked to galley ${l.galley} on ${l.url}: `galley unlink` first',
      );
    }
    final session = _signedIn(c, url);
    final account = ServerAccount(PocketBase(c.client, url), session);
    final String galleyId;
    final String how;
    if (create != null) {
      if (alias == null) throw UsageException('--create needs --alias <your name>', usage);
      galleyId = await account.create(create, alias: alias);
      how = 'Made galley "$create" ($galleyId), which you own as $alias.';
    } else {
      galleyId = id!;
      how = switch (await account.standingIn(galleyId)) {
        Joined(:final member) => 'You are ${member.alias} in galley $galleyId.',
        RevokedFrom() => throw Refused.missing(
          'your access to galley $galleyId was revoked by its owner',
        ),
        Outside() => throw Refused.missing(
          '${session.email} is not a member of galley $galleyId on $url, and has no open '
          'invite to it',
        ),
        InvitedTo() when alias == null => throw UsageException(
          'you are invited to $galleyId: --alias <your name> joins it',
          usage,
        ),
        InvitedTo() => await _joined(account, galleyId, alias!),
      };
    }
    ServerLink(url, galleyId).write(galley.path);
    c.out
      ..writeln(how)
      ..writeln('Linked ${galley.path} to it on $url.')
      ..writeln('Its canvas: ${canvasLink(url, galleyId)}');
    if (galley.marks().isNotEmpty) {
      // Said, not done: importing a local galley's marks is not built (D15), and they are not
      // lost. `galley unlink` brings them back.
      c.err.writeln(
        'galley: the ${galley.marks().length} marks kept in ${galley.path} are not on the '
        'server, and the commands now act there. They are kept; `galley unlink` shows them '
        'again.',
      );
    }
    return 0;
  }
}

final class _Unlink extends _GalleyCommand {
  _Unlink(super.c);

  @override
  String get name => 'unlink';

  @override
  String get description =>
      'Unlink this galley from its server: its commands act on the directory again. Nothing '
      'on the server changes.';

  @override
  Future<int> run() async {
    final l = link;
    if (!ServerLink.remove(galley.path) || l == null) {
      c.out.writeln('${galley.path} was not linked.');
      return 0;
    }
    c.out.writeln('Unlinked ${galley.path} from galley ${l.galley} on ${l.url}.');
    return 0;
  }
}

final class _Push extends _LinkedCommand {
  _Push(super.c) {
    argParser
      ..addOption('test', defaultsTo: 'test/galley_test.dart', help: 'The app\'s galley test.')
      ..addOption(
        'flutter',
        defaultsTo: 'flutter',
        help: 'The flutter executable (one path, not a command).',
      )
      ..addFlag(
        'resume',
        negatable: false,
        help: 'Push the render a push that stopped kept, rather than rendering again.',
      );
  }

  @override
  String get name => 'push';

  @override
  String get invocation => 'galley push [options] [-- <flutter test args>]';

  @override
  String get description =>
      'Render a new round, push it to the linked server, and carry every mark into it.';

  /// Where a push renders: kept until the round is finished on the server, so a push that
  /// stops can be finished without rendering again.
  String get _pending => '${galley.path}/push';

  @override
  Future<int> run() async {
    final linked = await open();
    linked.mustOwn('pushes a round');
    final pending = Directory(_pending);
    final rendered = File('${pending.path}/index.json').existsSync();
    if (_args.flag('resume')) {
      if (!rendered) throw Refused.missing('there is no render kept in ${pending.path} to push');
    } else {
      if (rendered) {
        throw Refused.conflict(
          'a push stopped, and its render is kept in ${pending.path}. `galley push --resume` '
          'pushes it; remove the directory to render anew',
        );
      }
      // A mark that does not read refuses the push (RoundPush), so it is asked before the
      // render, which takes minutes, rather than after it, which would keep a render that
      // cannot be pushed until the mark is mended. RoundPush asks again: the marks may change
      // while this renders.
      (await linked.galley.marks()).whole;
      // A render with no index.json never finished, so no push began from it: it is replaced.
      if (pending.existsSync()) pending.deleteSync(recursive: true);
      final exit = await c
          .renderer(
            app: app,
            test: _args.option('test')!,
            flutter: _args.option('flutter')!,
            testArgs: _args.rest,
          )
          .render(pending.path);
      if (!File('${pending.path}/index.json').existsSync()) {
        throw Refused.environment(
          'the render did not finish: the galley test exited $exit and wrote no index.json. '
          'What it did write is in ${pending.path}, and the next push replaces it.',
        );
      }
      if (exit != 0) {
        c.out.writeln(
          'The galley test exited $exit: each error frame failed its test. The round is '
          'pushed with those frames as errors.',
        );
      }
    }

    final stored = await GalleyDirectory.readRendered(pending.path, 'the render');
    final files = await pushFilesOf(pending.path);
    c.out.writeln('Pushing ${files.length} files to ${requireLink.url}');
    final Pushed pushed;
    try {
      pushed = await RoundPush(linked.galley).push(
        frames: [for (final f in stored.frames) f.record.key],
        files: files,
        round: stored.round,
      );
    } on Refused catch (e) {
      throw _kept(e, 'The render is kept in ${pending.path}; `galley push --resume` sends it.');
    }
    pending.deleteSync(recursive: true);

    final errors = stored.frames.where((f) => f.record.status == FrameStatus.error).length;
    c.out
      ..writeln(
        'Round ${pushed.number}${pushed.resumed ? ', which an earlier push began,' : ''}: '
        '${stored.frames.length} of ${stored.manifest.planned} planned frames, $errors errors. '
        '${_Pack._provenance(stored.provenance)}',
      )
      ..writeln(_Pack._placementCounts(pushed.carried));
    for (final p in pushed.carried) {
      c.out.writeln('  ${p.mark.id}  ${p.placement.name}  ${p.mark.frame}');
    }
    return 0;
  }

  /// [e] with [more] said after it, as the same kind of refusal.
  static Refused _kept(Refused e, String more) {
    final message = '${e.message}. $more';
    return switch (e.kind) {
      RefusalKind.invalid => Refused.invalid(message),
      RefusalKind.missing => Refused.missing(message),
      RefusalKind.conflict => Refused.conflict(message),
      RefusalKind.environment => Refused.environment(message),
      RefusalKind.damaged => Refused.damaged(message),
    };
  }
}

final class _Invite extends _LinkedCommand {
  _Invite(super.c);

  @override
  String get name => 'invite';

  @override
  String get invocation => 'galley invite <email>';

  @override
  String get description =>
      'Invite a reviewer to the linked galley. They sign in by a code mailed to them, and '
      'join under a name they choose.';

  @override
  Future<int> run() async {
    final rest = _args.rest;
    if (rest.length != 1) throw UsageException('give the email to invite', usage);
    final linked = await open();
    linked.mustOwn('invites');
    final l = requireLink;
    await GalleyMembers(
      linked.galley.server,
      galleyId: l.galley,
      session: linked.galley.session,
    ).invite(rest.single);
    c.out
      ..writeln('Invited ${rest.single.trim().toLowerCase()} to galley ${l.galley}.')
      ..writeln(
        'They open ${canvasLink(l.url, l.galley)} and sign in with that email; or, with the '
        'CLI, run `galley login ${l.url} --email <theirs>`, then '
        '`galley link ${l.url} --galley ${l.galley} --alias <their name>`.',
      );
    return 0;
  }
}

final class _Members extends _LinkedCommand {
  _Members(super.c);

  @override
  String get name => 'members';

  @override
  String get description => 'The linked galley\'s members: their aliases, roles, and access.';

  @override
  Future<int> run() async {
    final linked = await open();
    final members = await GalleyMembers(
      linked.galley.server,
      galleyId: requireLink.galley,
      session: linked.galley.session,
    ).members();
    for (final m in members) {
      c.out.writeln('${m.alias}  ${m.role.name}${m.revoked ? '  revoked' : ''}');
    }
    return 0;
  }
}

final class _Revoke extends _LinkedCommand {
  _Revoke(super.c) {
    argParser.addFlag('restore', negatable: false, help: 'Give their access back.');
  }

  @override
  String get name => 'revoke';

  @override
  String get invocation => 'galley revoke <alias> [--restore]';

  @override
  String get description =>
      'Take a reviewer\'s access to the linked galley away. What they wrote is kept, signed.';

  @override
  Future<int> run() async {
    final rest = _args.rest;
    if (rest.length != 1) throw UsageException('give the reviewer\'s alias', usage);
    final linked = await open();
    linked.mustOwn('revokes a reviewer');
    final restore = _args.flag('restore');
    final m = await GalleyMembers(
      linked.galley.server,
      galleyId: requireLink.galley,
      session: linked.galley.session,
    ).setRevoked(rest.single, revoked: !restore);
    c.out.writeln(
      restore ? '${m.alias} has their access back.' : '${m.alias}\'s access is revoked.',
    );
    return 0;
  }
}

Future<String> _joined(ServerAccount account, String galleyId, String alias) async {
  await account.join(galleyId, alias: alias);
  return 'Joined galley $galleyId as $alias.';
}
