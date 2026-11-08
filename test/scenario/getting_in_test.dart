import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/time/clock.dart';
import 'package:kubo_pos/data/cloud/account_service.dart';
import 'package:kubo_pos/data/cloud/shop_directory.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/data/repositories/settings_repository_impl.dart';
import 'package:kubo_pos/domain/services/shop_access_service.dart';

import '../support/test_database.dart';

/// Who can get into the shop, and who cannot.
///
/// The question behind all of this: the link is public, so what stops a
/// stranger who has it? The answer is that a phone holds no shop until it is
/// let in, and there are exactly three ways to be let in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late FixedClock clock;
  late _Account account;
  late _Directory directory;
  late ShopAccessService access;

  Future<void> build({bool separate = false}) async {
    clock = testClock();
    db = separate
        ? await openSeparateTestDatabase()
        : await openTestDatabase();
    account = _Account();
    directory = _Directory();
    access = ShopAccessService(
      database: db,
      settings: SettingsRepositoryImpl(db, clock),
      clock: clock,
      account: account,
      directory: directory,
      engine: SyncEngine(database: db, clock: clock),
    );
  }

  setUp(() async => build());
  tearDown(() async => db.close());

  Future<int> drinkCount() async {
    final List<Map<String, Object?>> rows = await db.db.rawQuery(
      'SELECT COUNT(*) AS n FROM products',
    );
    return rows.first['n']! as int;
  }

  group('a phone nobody has let in', () {
    test('holds no shop, so there is nothing to show', () async {
      expect(await access.standing(), ShopStanding.outside);
      expect(await drinkCount(), 0, reason: 'no menu, not even a blank one');
      expect(await access.shopId(), isNull);
    });

    test('is not let in by a code somebody guessed', () async {
      directory.liveInvite = 'K7PQM39X';
      directory.shopOfInvite = 'shop-1';

      final AccessOutcome tried = await access.joinWithInvite(
        code: 'AAAA-BBBB',
        deviceLabel: 'A stranger',
      );

      expect(tried.succeeded, isFalse);
      expect(tried.problem, contains('wrong or has run out'));
      expect(await access.standing(), ShopStanding.outside);
      expect(await drinkCount(), 0);
    });

    test('is not let in by an account with no shop', () async {
      account.knownPassword = 'correct-horse';
      // Signs in fine; owns nothing.
      final AccessOutcome tried = await access.signIn(
        email: 'someone@example.com',
        password: 'correct-horse',
      );

      expect(tried.succeeded, isFalse);
      expect(tried.problem, contains('no shop yet'));
      expect(await access.standing(), ShopStanding.outside);
    });

    test('is not let in by the wrong password', () async {
      account.knownPassword = 'correct-horse';
      final AccessOutcome tried = await access.signIn(
        email: 'her@example.com',
        password: 'guess',
      );

      expect(tried.succeeded, isFalse);
      expect(await access.standing(), ShopStanding.outside);
    });
  });

  group('the owner opens her shop', () {
    test('makes the account, the shop, and the menu — in that order', () async {
      final AccessOutcome opened = await access.openShop(
        email: 'her@example.com',
        password: 'a-good-password',
      );

      expect(opened.succeeded, isTrue);
      expect(await access.standing(), ShopStanding.inside);
      expect(await access.role(), 'owner');
      expect(await drinkCount(), greaterThan(0), reason: 'her menu is here');
      expect(directory.createdShop, isNotNull);
      expect(directory.createdOwner, account.current!.uid);
    });

    test('a shop that could not be opened leaves no half-shop behind', () async {
      directory.refuseToCreate = true;

      final AccessOutcome opened = await access.openShop(
        email: 'her@example.com',
        password: 'a-good-password',
      );

      expect(opened.succeeded, isFalse);
      expect(await access.standing(), ShopStanding.outside);
      expect(await drinkCount(), 0, reason: 'no orphan menu');
    });

    test('everything she already has is queued for the barista', () async {
      await access.openShop(
        email: 'her@example.com',
        password: 'a-good-password',
      );

      final SyncEngine engine = SyncEngine(database: db, clock: clock);
      expect(
        await engine.pendingCount(),
        greaterThan(100),
        reason: 'the whole menu has to reach the other phone, not just '
            'what changes from now on',
      );
    });
  });

  group('the owners list', () {
    test('an email nobody approved opens no shop, and leaves no account',
        () async {
      directory.refuseAsUnapproved = true;

      final AccessOutcome tried = await access.openShop(
        email: 'a.stranger@example.com',
        password: 'a-good-password',
      );

      expect(tried.succeeded, isFalse);
      expect(tried.problem, contains('not approved'));
      expect(await access.standing(), ShopStanding.outside);
      expect(await drinkCount(), 0, reason: 'no shop, not even a blank one');
      expect(
        account.discarded,
        isTrue,
        reason: 'a refused attempt should not leave a dead account behind',
      );
    });

    test('being refused reads differently from having no signal', () async {
      directory.refuseToCreate = true;

      final AccessOutcome tried = await access.openShop(
        email: 'her@example.com',
        password: 'a-good-password',
      );

      expect(tried.succeeded, isFalse);
      expect(tried.problem, contains('no connection'));
      expect(
        tried.problem,
        isNot(contains('not approved')),
        reason: 'bad weather is not a decision about who she is',
      );
    });

    test('an approved email opens the shop as before', () async {
      final AccessOutcome opened = await access.openShop(
        email: 'her@example.com',
        password: 'a-good-password',
      );

      expect(opened.succeeded, isTrue);
      expect(account.discarded, isFalse);
      expect(await drinkCount(), greaterThan(0));
    });
  });

  group('the barista joins', () {
    test('is let in by a live invite, as a barista', () async {
      directory.liveInvite = 'K7PQM39X';
      directory.shopOfInvite = 'her-shop';

      final AccessOutcome joined = await access.joinWithInvite(
        code: 'k7pq-m39x',
        deviceLabel: 'Ana',
      );

      expect(joined.succeeded, isTrue, reason: 'typed in lower case, hyphen');
      expect(await access.standing(), ShopStanding.inside);
      expect(await access.role(), 'barista');
      expect(await access.isOwner, isFalse);
      expect(directory.joinedAs, 'Ana');
    });

    test('gets no menu of her own — the shop comes down the wire', () async {
      directory.liveInvite = 'K7PQM39X';
      directory.shopOfInvite = 'her-shop';

      await access.joinWithInvite(code: 'K7PQ-M39X', deviceLabel: 'Ana');

      // Two separately seeded shops have two of everything under different
      // names, and no merge afterwards can tell that one shop's Spanish
      // Latte is the other's. So her phone starts empty and is filled from
      // the owner's log.
      expect(await drinkCount(), 0);
    });

    test('an invite the owner has already withdrawn does not work', () async {
      directory.liveInvite = null;

      final AccessOutcome tried = await access.joinWithInvite(
        code: 'K7PQ-M39X',
        deviceLabel: 'Ana',
      );

      expect(tried.succeeded, isFalse);
      expect(await access.standing(), ShopStanding.outside);
    });

    test('an invite the shop refuses is refused here too', () async {
      directory.liveInvite = 'K7PQM39X';
      directory.shopOfInvite = 'her-shop';
      directory.refuseToJoin = true;

      final AccessOutcome tried = await access.joinWithInvite(
        code: 'K7PQ-M39X',
        deviceLabel: 'Ana',
      );

      expect(tried.succeeded, isFalse);
      expect(await access.standing(), ShopStanding.outside);
    });
  });

  group('a phone that was already trading', () {
    test('is never locked out of its own books', () async {
      // Her sister set the app up before any of this existed: a menu and a
      // PIN on the phone, and no account anywhere. Demanding she sign in
      // would be taking her shop away to make a point about security.
      await db.db.insert('product_categories', <String, Object?>{
        'name': 'Coffee',
        'display_order': 1,
        'is_active': 1,
        'created_at': clock.nowIso(),
        'updated_at': clock.nowIso(),
      });
      await db.db.insert('products', <String, Object?>{
        'category_id': 1,
        'name': 'Spanish Latte',
        'is_active': 1,
        'created_at': clock.nowIso(),
        'updated_at': clock.nowIso(),
      });

      expect(await access.standing(), ShopStanding.inside);
      expect(await access.role(), 'owner');
    });
  });

  group('a shop that was already running', () {
    /// Her sister set Kubo up before any of this existed. The shop is on
    /// the phone, there is no account anywhere, and she must not lose it.
    Future<void> alreadyTrading() async {
      await db.db.insert('product_categories', <String, Object?>{
        'name': 'Coffee',
        'display_order': 1,
        'is_active': 1,
        'created_at': clock.nowIso(),
        'updated_at': clock.nowIso(),
      });
      await db.db.insert('products', <String, Object?>{
        'category_id': 1,
        'name': 'Spanish Latte',
        'is_active': 1,
        'created_at': clock.nowIso(),
        'updated_at': clock.nowIso(),
      });
    }

    test('can be claimed, and nothing of it is touched', () async {
      await alreadyTrading();

      final AccessOutcome claimed = await access.claimThisShop(
        email: 'her@example.com',
        password: 'a-good-password',
      );

      expect(claimed.succeeded, isTrue);
      expect(await access.role(), 'owner');
      expect(await access.shopId(), isNotNull);
      expect(await drinkCount(), 1, reason: 'her drink, not a fresh seed');
    });

    test('claiming sends the shop she already has, not just what is next',
        () async {
      await alreadyTrading();
      await access.claimThisShop(
        email: 'her@example.com',
        password: 'a-good-password',
      );

      final SyncEngine engine = SyncEngine(database: db, clock: clock);
      expect(await engine.pendingCount(), greaterThan(0));
    });

    test('a refused claim changes nothing on the phone', () async {
      await alreadyTrading();
      directory.refuseAsUnapproved = true;

      final AccessOutcome tried = await access.claimThisShop(
        email: 'a.stranger@example.com',
        password: 'a-good-password',
      );

      expect(tried.succeeded, isFalse);
      expect(tried.problem, contains('not approved'));
      expect(await access.shopId(), isNull);
      expect(await drinkCount(), 1, reason: 'her shop is still here');
      expect(await access.standing(), ShopStanding.inside);
    });

    test('no signal leaves the shop exactly as it was', () async {
      await alreadyTrading();
      directory.refuseToCreate = true;

      final AccessOutcome tried = await access.claimThisShop(
        email: 'her@example.com',
        password: 'a-good-password',
      );

      expect(tried.succeeded, isFalse);
      expect(tried.problem, contains('no connection'));
      expect(await access.shopId(), isNull);
      expect(await drinkCount(), 1);
    });

    test('a shop that already has an owner is not claimed twice', () async {
      await alreadyTrading();
      await access.claimThisShop(
        email: 'her@example.com',
        password: 'a-good-password',
      );

      final AccessOutcome again = await access.claimThisShop(
        email: 'her@example.com',
        password: 'a-good-password',
      );

      expect(again.succeeded, isFalse);
      expect(again.problem, contains('already belongs'));
    });
  });

  group('the owner hands out an invite', () {
    test('only once she has a shop and is signed in', () async {
      expect(await access.newInvite(), isNull);

      await access.openShop(
        email: 'her@example.com',
        password: 'a-good-password',
      );

      final String? invite = await access.newInvite();
      expect(invite, isNotNull);
      expect(invite, matches(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$')));
      expect(directory.offeredUntil, isNotNull);
      expect(
        directory.offeredUntil!.difference(clock.now().toUtc()).inMinutes,
        10,
        reason: 'a code that never expires is a password that was shouted',
      );
    });
  });
}

// ───────────────────────────── stand-ins ─────────────────────────────

/// Firebase Auth, without Firebase.
class _Account extends AccountService {
  _Account() : super();

  String knownPassword = '';
  AccountUser? _user;

  @override
  bool get isAvailable => true;

  @override
  AccountUser? get current => _user;

  @override
  String? get deviceUid => _user?.uid ?? 'anonymous-device';

  @override
  Future<AccountOutcome> createAccount({
    required String email,
    required String password,
  }) async {
    if (password.length < 6) {
      return const AccountOutcome.failed('That password is too short.');
    }
    knownPassword = password;
    _user = AccountUser(uid: 'uid-of-$email', email: email);
    return AccountOutcome.ok(_user!);
  }

  @override
  Future<AccountOutcome> signIn({
    required String email,
    required String password,
  }) async {
    if (password != knownPassword) {
      return const AccountOutcome.failed(
        'That email and password do not match an account.',
      );
    }
    _user = AccountUser(uid: 'uid-of-$email', email: email);
    return AccountOutcome.ok(_user!);
  }

  @override
  Future<bool> signInAsDevice() async => true;

  bool discarded = false;

  @override
  Future<void> discardCurrentAccount() async {
    discarded = true;
    _user = null;
    knownPassword = '';
  }
}

/// Firestore, without Firestore.
class _Directory extends ShopDirectory {
  _Directory() : super();

  String? liveInvite;
  String? shopOfInvite;
  bool refuseToCreate = false;
  bool refuseToJoin = false;

  bool refuseAsUnapproved = false;
  String? createdShop;
  String? createdOwner;
  String? joinedAs;
  DateTime? offeredUntil;
  final Map<String, String> _owned = <String, String>{};

  @override
  Future<void> createShop({
    required String shopId,
    required String ownerUid,
    required String deviceId,
    required String label,
  }) async {
    if (refuseAsUnapproved) throw const NotApproved();
    if (refuseToCreate) throw const CloudUnreachable();
    createdShop = shopId;
    createdOwner = ownerUid;
    _owned[ownerUid] = shopId;
  }

  @override
  Future<String?> shopOwnedBy(String uid) async => _owned[uid];

  @override
  Future<void> offerInvite({
    required String shopId,
    required String code,
    required DateTime until,
    required String byUid,
  }) async {
    liveInvite = ShopDirectory.tidy(code);
    shopOfInvite = shopId;
    offeredUntil = until;
  }

  @override
  Future<String?> shopForInvite(String code) async =>
      ShopDirectory.tidy(code) == liveInvite ? shopOfInvite : null;

  @override
  Future<bool> join({
    required String shopId,
    required String code,
    required String uid,
    required String deviceId,
    required String label,
  }) async {
    if (refuseToJoin) return false;
    joinedAs = label;
    return true;
  }
}
