import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

void main() {
  test('each kind is answered with its status', () {
    expect(
      {for (final k in RefusalKind.values) k: k.status},
      {
        RefusalKind.invalid: 422,
        RefusalKind.missing: 404,
        RefusalKind.conflict: 409,
        RefusalKind.environment: 500,
        RefusalKind.damaged: 500,
      },
    );
  });

  test('a status is read back as its kind, and one nobody sends as the environment', () {
    expect(
      {
        for (final s in [400, 422, 404, 409, 500, 200, 403, 502, 503])
          s: Refused.ofStatus(s, 'x').kind,
      },
      {
        400: RefusalKind.invalid,
        422: RefusalKind.invalid,
        404: RefusalKind.missing,
        409: RefusalKind.conflict,
        // Both 500s read as damaged: the galley's own files, which is what serve sends it for.
        500: RefusalKind.damaged,
        200: RefusalKind.environment,
        403: RefusalKind.environment,
        502: RefusalKind.environment,
        503: RefusalKind.environment,
      },
    );
    expect(Refused.ofStatus(409, 'why').message, 'why');
  });
}
