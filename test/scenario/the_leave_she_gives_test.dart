import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/domain/entities/app_user.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/services/sign_in_service.dart';

import '../support/pos_fixture.dart';

/// The owner standing at the till and saying yes to one thing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late SignInService signIn;

  setUp(() async {
    shop = await PosFixture.open();
    signIn = SignInService(database: shop.db, clock: shop.clock);
    await signIn.addUser(
      name: 'Jamie',
      role: UserRole.owner,
      pin: '314159',
    );
    await signIn.addUser(name: 'Jaja', role: UserRole.barista, pin: '271828');
  });
  tearDown(() async => shop.close());

  test('her PIN allows it', () async {
    expect(await signIn.ownerSaysYes('314159'), 'Jamie');
  });

  test("the barista's own PIN does not", () async {
    expect(await signIn.ownerSaysYes('271828'), isNull);
  });

  test('nor does a wrong one, nor a short one', () async {
    expect(await signIn.ownerSaysYes('000000'), isNull);
    expect(await signIn.ownerSaysYes('31415'), isNull);
    expect(await signIn.ownerSaysYes(''), isNull);
  });

  test('an owner who has been switched off cannot allow anything', () async {
    final AppUser her = (await signIn.users()).firstWhere(
      (AppUser u) => u.name == 'Jamie',
    );
    await signIn.addUser(name: 'Second', role: UserRole.owner, pin: '999999');
    await signIn.setActive(userId: her.id, isActive: false);

    expect(await signIn.ownerSaysYes('314159'), isNull);
    expect(await signIn.ownerSaysYes('999999'), 'Second');
  });

  test('saying yes is written down beside what was done', () async {
    await shop.sales.noteOwnerAllowed(
      orderId: 1,
      what: 'void KUBO-0001',
      owner: 'Jamie',
    );

    final List<Map<String, Object?>> rows = await shop.db.db.rawQuery(
      "SELECT summary FROM audit_log WHERE action = 'owner_allowed'",
    );
    expect(rows.single['summary'], 'Jamie allowed it: void KUBO-0001');
  });

  test('the right she gives travels with the shop, not the phone', () async {
    final BusinessSettings granted = BusinessSettings.defaults.copyWith(
      baristaMayCorrectOrders: true,
    );
    await shop.settingsRepository.save(granted);

    expect(
      (await shop.settingsRepository.load()).baristaMayCorrectOrders,
      isTrue,
    );
    // It is in the settings table, which is what the two tills reconcile.
    final List<Map<String, Object?>> rows = await shop.db.db.rawQuery(
      "SELECT value FROM app_settings WHERE key = 'staff.barista_may_correct'",
    );
    expect(rows.single['value'], '1');
  });

  test('and she can take it back', () async {
    await shop.settingsRepository.save(
      BusinessSettings.defaults.copyWith(baristaMayCorrectOrders: true),
    );
    await shop.settingsRepository.save(
      BusinessSettings.defaults.copyWith(baristaMayCorrectOrders: false),
    );
    expect(
      (await shop.settingsRepository.load()).baristaMayCorrectOrders,
      isFalse,
    );
  });

  test('nobody has it until she says so', () async {
    expect(BusinessSettings.defaults.baristaMayCorrectOrders, isFalse);
  });
}
