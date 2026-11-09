import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/app/providers.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/domain/entities/app_user.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/services/sign_in_service.dart';

import '../support/test_database.dart';

/// The door in front of the whole app.
///
/// The POS used to be open to anybody holding the phone, and nothing ever
/// asked for a PIN to be set — so a shop could trade for a month with no
/// lock on it and nobody would be told. A lock nobody is asked to set is
/// not a lock.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProviderContainer app;
  late SignInService people;

  setUp(() async {
    db = await openTestDatabase();
    people = SignInService(database: db, clock: testClock());
    app = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(testClock()),
        initialSettingsProvider.overrideWithValue(BusinessSettings.defaults),
      ],
    );
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Future<PeopleGate> gate() => app.read(peopleGateProvider.future);

  group('before anybody is set up', () {
    test('it asks for a PIN rather than letting her straight in', () async {
      expect(await gate(), PeopleGate.needsPins);
    });
  });

  group('once somebody is set up', () {
    setUp(() async {
      await people.addUser(name: 'Ate', role: UserRole.owner, pin: '123456');
      app.invalidate(peopleGateProvider);
    });

    test('the app is locked until somebody signs in', () async {
      expect(await gate(), PeopleGate.locked);
    });

    test('the right PIN opens it', () async {
      final AppUser? who = await people.signIn(
        userId: (await people.users()).single.id,
        pin: '123456',
      );
      expect(who, isNotNull);

      app.read(signedInUserProvider.notifier).set(who);
      app.invalidate(peopleGateProvider);
      expect(await gate(), PeopleGate.open);
    });

    test('the wrong PIN does not', () async {
      expect(
        await people.signIn(
          userId: (await people.users()).single.id,
          pin: '999999',
        ),
        isNull,
      );
      expect(await gate(), PeopleGate.locked);
    });

    test('locking it again shuts the door', () async {
      final AppUser who = (await people.users()).single;
      app.read(signedInUserProvider.notifier).set(who);
      app.invalidate(peopleGateProvider);
      expect(await gate(), PeopleGate.open);

      app.read(signedInUserProvider.notifier).signOut();
      app.invalidate(peopleGateProvider);
      expect(await gate(), PeopleGate.locked);
    });
  });

  group('the way back in', () {
    test('the owner can be given a new PIN without the old one', () async {
      // A PIN lives on the phone and nowhere else, so there is nobody to
      // ask. Proving the shop's own account is at least as strong as
      // knowing six digits, and it is the only door that cannot be shut
      // on her.
      final AppUser owner = await people.addUser(
        name: 'Ate',
        role: UserRole.owner,
        pin: '123456',
      );

      await people.setPin(userId: owner.id, pin: '654321');

      expect(await people.signIn(userId: owner.id, pin: '123456'), isNull);
      expect(await people.signIn(userId: owner.id, pin: '654321'), isNotNull);
    });
  });

  group('two people, two PINs', () {
    test('each signs in as themselves, and the roles differ', () async {
      final AppUser owner = await people.addUser(
        name: 'Ate',
        role: UserRole.owner,
        pin: '111111',
      );
      final AppUser barista = await people.addUser(
        name: 'Ana',
        role: UserRole.barista,
        pin: '222222',
      );

      expect(
        (await people.signIn(userId: owner.id, pin: '111111'))!.role,
        UserRole.owner,
      );
      expect(
        (await people.signIn(userId: barista.id, pin: '222222'))!.role,
        UserRole.barista,
      );
      // And neither can wear the other's hat by typing their own PIN.
      expect(await people.signIn(userId: owner.id, pin: '222222'), isNull);
      expect(await people.signIn(userId: barista.id, pin: '111111'), isNull);
    });
  });
}
