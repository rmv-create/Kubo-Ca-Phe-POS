import '../../core/time/clock.dart';
import '../../data/cloud/account_service.dart';
import '../../data/cloud/shop_directory.dart';
import '../../data/db/app_database.dart';
import '../../data/db/seed/menu_seeder.dart';
import '../../data/db/seed/pantry_seeder.dart';
import '../../data/db/sync/sync_engine.dart';
import '../entities/business_settings.dart';
import '../repositories/settings_repository.dart';

/// How this phone stands in relation to a shop.
enum ShopStanding {
  /// Nothing here yet. The app shows the way in and nothing else.
  outside,

  /// Admitted, and the shop is on this phone.
  inside,
}

/// Lets a phone into a shop, or makes a shop for it to be let into.
///
/// This is the piece that was missing, and its absence was the whole
/// problem. The app's PIN locks one phone's own copy of the data; it is not
/// an account. So a second phone opening the same link got a blank shop of
/// its own, and there was no way for the owner to let her barista into
/// *hers*.
///
/// Three ways in, and only three:
///
///  * **She opens a shop.** An email and a password of her own, and the shop
///    is made under that account. Her phone becomes its first till.
///  * **She signs in** on another phone with the same account, and her shop
///    comes down from the log.
///  * **Somebody joins** with an invite she read out, and is a barista.
///
/// A phone that has done none of those holds no shop and is shown no prices,
/// no takings and no setup. The page is public — anybody can load it, and
/// there is no honest way around that — but a public page with nothing in it
/// is not a way into her business.
class ShopAccessService {
  ShopAccessService({
    required AppDatabase database,
    required SettingsRepository settings,
    required Clock clock,
    required AccountService account,
    required ShopDirectory directory,
    required SyncEngine engine,
  }) : _db = database,
       _settings = settings,
       _clock = clock,
       _account = account,
       _directory = directory,
       _engine = engine;

  final AppDatabase _db;
  final SettingsRepository _settings;
  final Clock _clock;
  final AccountService _account;
  final ShopDirectory _directory;
  final SyncEngine _engine;

  /// Whether this phone already holds a shop.
  ///
  /// Deliberately generous about what counts. A phone that was trading
  /// before any of this existed has a menu and a PIN and no account, and
  /// locking its owner out of her own books to make a point about security
  /// would be the worst thing this code could do.
  Future<ShopStanding> standing() async {
    final String? shop = await _settings.readRaw(SettingKeys.syncShopId);
    if (shop != null && shop.isNotEmpty) return ShopStanding.inside;
    return await _hasLocalShop() ? ShopStanding.inside : ShopStanding.outside;
  }

  Future<bool> _hasLocalShop() async {
    for (final String table in <String>['products', 'app_users']) {
      final List<Map<String, Object?>> rows = await _db.db.rawQuery(
        'SELECT 1 FROM $table LIMIT 1',
      );
      if (rows.isNotEmpty) return true;
    }
    return false;
  }

  Future<String?> shopId() async {
    final String? id = await _settings.readRaw(SettingKeys.syncShopId);
    return id == null || id.isEmpty ? null : id;
  }

  Future<String> role() async =>
      await _settings.readRaw(SettingKeys.syncRole) ?? 'owner';

  Future<bool> get isOwner async => await role() == 'owner';

  // ───────────────────────────── opening ─────────────────────────────

  /// Makes the account, makes the shop, and fills this phone with the menu.
  ///
  /// In that order, and each step only if the one before it worked. An
  /// account with no shop can be signed into again tomorrow; a shop with no
  /// owner could never be reached by anybody.
  Future<AccessOutcome> openShop({
    required String email,
    required String password,
    String deviceLabel = 'Owner’s phone',
  }) async {
    final AccountOutcome made = await _account.createAccount(
      email: email,
      password: password,
    );
    if (!made.succeeded) return AccessOutcome.failed(made.problem!);

    final String shopId = ShopDirectory.newShopId();
    try {
      await _directory.createShop(
        shopId: shopId,
        ownerUid: made.user!.uid,
        deviceId: await _engine.deviceId(),
        label: deviceLabel,
      );
    } on Object {
      return const AccessOutcome.failed(
        'The account was made but the shop could not be opened. Find signal '
        'and sign in again.',
      );
    }

    await _remember(shopId: shopId, role: 'owner', label: deviceLabel);
    await _fillWithTheMenu();
    // Everything just written has to reach the barista's phone later, so it
    // all goes in the outbox now rather than only what changes from here.
    await _engine.enqueueEverything();
    return const AccessOutcome.ok(ShopStanding.inside);
  }

  /// Signs in on a phone that has no shop on it yet — a new one, or one
  /// whose browser storage was cleared.
  ///
  /// Nothing is seeded here. The shop comes down from the log, because a
  /// freshly seeded menu and the real one are two different shops that no
  /// merge could afterwards tell apart.
  Future<AccessOutcome> signIn({
    required String email,
    required String password,
    String deviceLabel = 'Owner’s phone',
  }) async {
    final AccountOutcome in_ = await _account.signIn(
      email: email,
      password: password,
    );
    if (!in_.succeeded) return AccessOutcome.failed(in_.problem!);

    final String? shopId = await _directory.shopOwnedBy(in_.user!.uid);
    if (shopId == null) {
      return const AccessOutcome.failed(
        'That account has no shop yet. If this is your first time, open the '
        'shop instead.',
      );
    }

    await _remember(shopId: shopId, role: 'owner', label: deviceLabel);
    return const AccessOutcome.ok(ShopStanding.inside);
  }

  // ───────────────────────────── joining ─────────────────────────────

  /// Takes an invite the owner read out and becomes a barista's till.
  Future<AccessOutcome> joinWithInvite({
    required String code,
    required String deviceLabel,
  }) async {
    if (!await _account.signInAsDevice()) {
      return const AccessOutcome.failed(
        'No connection. Joining a shop needs signal, just this once.',
      );
    }

    final String? shopId = await _directory.shopForInvite(code);
    if (shopId == null) {
      return const AccessOutcome.failed(
        'That code is wrong or has run out. Ask for a new one — they '
        'last ten minutes.',
      );
    }

    final String? uid = _account.deviceUid;
    if (uid == null) {
      return const AccessOutcome.failed('This phone could not sign in.');
    }

    final bool welcomed = await _directory.join(
      shopId: shopId,
      code: code,
      uid: uid,
      deviceId: await _engine.deviceId(),
      label: deviceLabel.trim().isEmpty ? 'Barista' : deviceLabel.trim(),
    );
    if (!welcomed) {
      return const AccessOutcome.failed(
        'That code was refused. Ask for a new one.',
      );
    }

    await _remember(shopId: shopId, role: 'barista', label: deviceLabel);
    return const AccessOutcome.ok(ShopStanding.inside);
  }

  /// An invite for somebody else's phone, good for ten minutes.
  Future<String?> newInvite() async {
    final String? shop = await shopId();
    final AccountUser? owner = _account.current;
    if (shop == null || owner == null) return null;
    final String code = ShopDirectory.newInvite();
    try {
      await _directory.offerInvite(
        shopId: shop,
        code: code,
        until: _clock.now().toUtc().add(const Duration(minutes: 10)),
        byUid: owner.uid,
      );
      return code;
    } on Object {
      return null;
    }
  }

  Future<List<AdmittedTill>> tills() async {
    final String? shop = await shopId();
    if (shop == null) return <AdmittedTill>[];
    try {
      return await _directory.tills(shop);
    } on Object {
      return <AdmittedTill>[];
    }
  }

  Future<bool> removeTill(String uid) async {
    final String? shop = await shopId();
    if (shop == null) return false;
    try {
      await _directory.removeTill(shopId: shop, uid: uid);
      return true;
    } on Object {
      return false;
    }
  }

  // ──────────────────────────── the rest ────────────────────────────

  Future<void> _remember({
    required String shopId,
    required String role,
    required String label,
  }) async {
    await _settings.writeRaw(SettingKeys.syncShopId, shopId);
    await _settings.writeRaw(SettingKeys.syncRole, role);
    await _settings.writeRaw(SettingKeys.syncDeviceLabel, label);
    await _settings.writeRaw(
      SettingKeys.syncAdmittedAt,
      _clock.now().toUtc().toIso8601String(),
    );
  }

  Future<void> _fillWithTheMenu() async {
    await MenuSeeder(_db, _clock).seedIfEmpty();
    await PantrySeeder(_db, _clock).seedIfEmpty();
  }
}

/// What happened, in words a screen can show.
class AccessOutcome {
  const AccessOutcome.ok(ShopStanding this.standing) : problem = null;
  const AccessOutcome.failed(String this.problem) : standing = null;

  final ShopStanding? standing;
  final String? problem;

  bool get succeeded => standing != null;
}
