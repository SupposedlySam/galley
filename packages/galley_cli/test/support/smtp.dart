import 'dart:async';
import 'dart:convert';
import 'dart:io';

// An SMTP relay on loopback that keeps what it is sent, for proving that a server set from
// the environment (DESIGN D18) mails its sign-in codes. It speaks as much of RFC 5321 as
// PocketBase's mailer uses: EHLO, AUTH PLAIN and LOGIN (RFC 4954), MAIL, RCPT, DATA, RSET,
// NOOP and QUIT. No STARTTLS is offered, so the mailer sends a password only because the
// relay is on loopback (net/smtp's PlainAuth sends one in the clear to localhost alone).

/// One mail the relay was given.
final class Mail {
  Mail(this.auth, this.from, this.to, this.data);

  /// The `user:password` it signed in with, or null.
  final String? auth;

  /// MAIL FROM's address, and RCPT TO's.
  final String from;
  final List<String> to;

  /// The message, as sent, dot-stuffing undone.
  final String data;

  /// The message's text with quoted-printable undone: soft line breaks joined, `=XX` read.
  String get text => data
      .replaceAll(RegExp(r'=\r?\n'), '')
      .replaceAllMapped(
        RegExp('=([0-9A-F]{2})'),
        (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
      );
}

/// A relay listening on loopback; [mails] are what it was sent.
final class SmtpSink {
  SmtpSink._(this._socket);

  final ServerSocket _socket;
  final mails = <Mail>[];
  final _arrived = StreamController<Mail>.broadcast();

  /// Its port on 127.0.0.1.
  int get port => _socket.port;

  static Future<SmtpSink> start() async {
    final sink = SmtpSink._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    sink._socket.listen(sink._serve);
    return sink;
  }

  /// The next mail to arrive, or null when none does in ten seconds.
  Future<Mail?> next() => _arrived.stream.first
      .then<Mail?>((m) => m)
      .timeout(const Duration(seconds: 10), onTimeout: () => null);

  Future<void> close() async {
    await _socket.close();
    await _arrived.close();
  }

  Future<void> _serve(Socket client) async {
    void say(String line) => client.write('$line\r\n');
    final lines = StreamIterator(
      client.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()),
    );
    Future<String?> read() async => await lines.moveNext() ? lines.current : null;

    String? auth, from;
    final to = <String>[];
    say('220 sink ESMTP');
    try {
      for (var line = await read(); line != null; line = await read()) {
        final verb = line.split(' ').first.toUpperCase();
        switch (verb) {
          case 'EHLO':
            say('250-sink');
            say('250-AUTH PLAIN LOGIN');
            say('250 8BITMIME');
          case 'HELO' || 'NOOP':
            say('250 ok');
          case 'RSET':
            from = null;
            to.clear();
            say('250 ok');
          case 'AUTH':
            final parts = line.split(' ');
            if (parts[1].toUpperCase() == 'PLAIN') {
              var b64 = parts.length > 2 ? parts[2] : null;
              if (b64 == null) {
                say('334 ');
                b64 = await read();
              }
              final fields = utf8.decode(base64.decode(b64!)).split('\u0000');
              auth = '${fields[1]}:${fields[2]}';
            } else {
              say('334 ${base64.encode(utf8.encode('Username:'))}');
              final user = utf8.decode(base64.decode((await read())!));
              say('334 ${base64.encode(utf8.encode('Password:'))}');
              final password = utf8.decode(base64.decode((await read())!));
              auth = '$user:$password';
            }
            say('235 ok');
          case 'MAIL':
            from = RegExp('<([^>]*)>').firstMatch(line)![1];
            say('250 ok');
          case 'RCPT':
            to.add(RegExp('<([^>]*)>').firstMatch(line)![1]!);
            say('250 ok');
          case 'DATA':
            say('354 go on');
            final data = StringBuffer();
            for (var l = await read(); l != null && l != '.'; l = await read()) {
              data.write('${l.startsWith('..') ? l.substring(1) : l}\r\n');
            }
            final mail = Mail(auth, from!, [...to], '$data');
            mails.add(mail);
            _arrived.add(mail);
            say('250 kept');
          case 'QUIT':
            say('221 bye');
            await client.close();
            return;
          default:
            say('502 not here');
        }
      }
    } finally {
      client.destroy();
    }
  }
}
