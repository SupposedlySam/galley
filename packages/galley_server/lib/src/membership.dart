import 'dart:convert';
import 'dart:math';

import 'package:galley_core/galley_core.dart';

import 'pocketbase.dart';
import 'sign_in.dart';

/// A galley's owner or reviewer (docs/DESIGN.md D15), by the alias every mark and event they
/// write is signed with.
final class Member {
  /// [alias], [user]'s membership of [galley] as [role].
  const Member({
    required this.id,
    required this.galley,
    required this.user,
    required this.alias,
    required this.role,
    required this.revoked,
  });

  /// A `members` row.
  factory Member.fromRow(JsonMap row) {
    try {
      return Member._fromRow(row);
    } on FormatException catch (e) {
      throw Refused.damaged('the server\'s member ${row['id']} does not read: ${e.message}');
    }
  }

  factory Member._fromRow(JsonMap row) {
    final r = JsonReader(row, 'a member');
    return Member(
      id: r.string('id'),
      galley: r.string('galley'),
      user: r.string('user'),
      alias: r.string('alias'),
      role: switch (r.string('role')) {
        'owner' => MemberRole.owner,
        'reviewer' => MemberRole.reviewer,
        final other => throw Refused.damaged('member ${row['id']} has no role "$other"'),
      },
      // PocketBase writes false for a bool it was not sent; a row without one is not a member
      // the server wrote, and is not read as one who was never revoked.
      revoked: r.boolean('revoked'),
    );
  }

  /// The membership's record id.
  final String id;

  /// The galley's record id.
  final String galley;

  /// The user's record id.
  final String user;

  /// What they sign with.
  final String alias;

  /// What they may do.
  final MemberRole role;

  /// Whether the owner has taken their access away. What they wrote stays, signed.
  final bool revoked;
}

/// What a member may do: the owner pushes rounds and answers marks; a reviewer raises marks,
/// and verifies or reopens the answers.
enum MemberRole {
  /// Pushes rounds, answers marks, and invites and revokes reviewers.
  owner,

  /// Raises marks, and verifies or reopens their answers.
  reviewer,
}

/// One galley's members, as its owner manages them.
final class GalleyMembers {
  /// The members of [galleyId] on [server], as [session]'s user.
  const GalleyMembers(this.server, {required this.galleyId, required this.session});

  /// The server.
  final PocketBase server;

  /// The galley's record id.
  final String galleyId;

  /// Who is signed in.
  final Session session;

  /// Every member, revoked ones too, in the order they joined.
  Future<List<Member>> members() async => [
    for (final row in await server.list(
      'members',
      filter: 'galley = ${jsonEncode(galleyId)}',
      token: session.token,
    ))
      Member.fromRow(row),
  ];

  /// Invites [email]: the server makes them a user if they are not one, and they sign in by
  /// the code it mails them, then join under the alias they choose. Only the owner invites.
  Future<void> invite(String email) => server.send(
    'POST',
    server.api(['collections', 'invites', 'records']),
    token: session.token,
    body: {'galley': galleyId, 'email': email.trim().toLowerCase()},
  );

  /// Takes [alias]'s access away ([revoked] true), or gives it back. What they wrote stays,
  /// signed with their alias; nothing is erased. Only the owner does this, and only to a
  /// reviewer.
  Future<Member> setRevoked(String alias, {bool revoked = true}) async {
    final all = await members();
    final member = all.where((m) => m.alias == alias).firstOrNull;
    if (member == null) {
      throw Refused.missing(
        'the galley has no member "$alias"; its members are ${all.map((m) => m.alias).join(', ')}',
      );
    }
    final row = await server.send(
      'PATCH',
      server.api(['collections', 'members', 'records', member.id]),
      token: session.token,
      body: {'revoked': revoked},
    );
    return switch (row) {
      final JsonMap m => Member.fromRow(m),
      _ => throw const Refused.environment(
        'the server answered the revoke with something not a member',
      ),
    };
  }
}

/// What a signed-in user does across galleys: makes one, joins one they were invited to, and
/// lists the ones they are in.
final class ServerAccount {
  /// [session]'s user on [server]. [random] makes new record ids.
  ServerAccount(this.server, this.session, {Random? random}) : _random = random ?? Random.secure();

  /// The server.
  final PocketBase server;

  /// Who is signed in.
  final Session session;

  final Random _random;

  /// Makes a galley named [name] owned by the user, who signs as [alias], and returns its id.
  ///
  /// The galley and the owner's membership are one batch, one transaction: a galley nobody is
  /// a member of could never be read or changed by anyone (DESIGN D15). The id is made here,
  /// since the membership's create names it, in PocketBase's form.
  Future<String> create(String name, {required String alias}) async {
    final id = newRecordId(_random);
    await server.send(
      'POST',
      server.api(['batch']),
      token: session.token,
      body: {
        'requests': [
          {
            'method': 'POST',
            'url': '/api/collections/galleys/records',
            'body': {'id': id, 'name': name, 'owner': session.userId},
          },
          {
            'method': 'POST',
            'url': '/api/collections/members/records',
            'body': {'galley': id, 'user': session.userId, 'role': 'owner', 'alias': alias},
          },
        ],
      },
    );
    return id;
  }

  /// Joins [galleyId] as a reviewer who signs as [alias], by the open invite to the user's
  /// email, which the server burns in the same transaction.
  Future<Member> join(String galleyId, {required String alias}) async {
    final row = await server.send(
      'POST',
      server.api(['collections', 'members', 'records']),
      token: session.token,
      body: {'galley': galleyId, 'user': session.userId, 'role': 'reviewer', 'alias': alias},
    );
    return switch (row) {
      final JsonMap m => Member.fromRow(m),
      _ => throw const Refused.environment(
        'the server answered the join with something not a member',
      ),
    };
  }

  /// The user's own memberships, revoked ones too, so a revoked member is told so rather than
  /// shown nothing.
  Future<List<Member>> memberships() async => [
    for (final row in await server.list(
      'members',
      filter: 'user = ${jsonEncode(session.userId)}',
      token: session.token,
    ))
      Member.fromRow(row),
  ];

  /// The galleys the user has an open invite to, by id. Their names are not readable until
  /// the user joins: a galley is shown only to its members.
  Future<List<String>> invites() async => [
    for (final row in await server.list(
      'invites',
      filter: 'email = ${jsonEncode(session.email)} && accepted = false',
      token: session.token,
    ))
      JsonReader(row, 'an invite').string('galley'),
  ];
}

/// A new record id in PocketBase's form: 15 of `[a-z0-9]`, the form of every id the server
/// makes, and the one its `id` field takes by default, from [random]. 36^15 ids leave a collision to chance
/// far below anything else that could go wrong; the server refuses one anyway, by its index.
String newRecordId(Random random) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return String.fromCharCodes([
    for (var i = 0; i < 15; i++) alphabet.codeUnitAt(random.nextInt(alphabet.length)),
  ]);
}
