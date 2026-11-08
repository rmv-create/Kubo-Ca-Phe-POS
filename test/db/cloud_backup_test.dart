import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kubo_pos/core/time/clock.dart';
import 'package:kubo_pos/data/cloud/cloud_backup_service.dart';
import 'package:kubo_pos/data/cloud/cloud_backup_target.dart';
import 'package:kubo_pos/data/cloud/google_drive_api.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/db/backup_service.dart';
import 'package:kubo_pos/data/repositories/settings_repository_impl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_database.dart';

/// Getting the closing backup off the phone by itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('talking to Google Drive', () {
    late List<http.Request> sent;

    GoogleDriveApi apiThat(
      http.Response Function(http.Request request) answer, {
      String? token = 'token-123',
    }) {
      sent = <http.Request>[];
      return GoogleDriveApi(
        accessToken: () async => token,
        client: MockClient((http.Request request) async {
          sent.add(request);
          return answer(request);
        }),
      );
    }

    test('finds the folder it made last time', () async {
      final GoogleDriveApi api = apiThat(
        (http.Request request) => http.Response(
          jsonEncode(<String, Object?>{
            'files': <Object?>[
              <String, Object?>{'id': 'folder-1'},
            ],
          }),
          200,
        ),
      );

      expect(await api.folderNamed('Kubo Cà Phê backups'), 'folder-1');
      expect(sent, hasLength(1), reason: 'nothing is created needlessly');
      expect(sent.single.method, 'GET');
      expect(sent.single.headers['Authorization'], 'Bearer token-123');
    });

    test('creates it the first time, and only then', () async {
      final GoogleDriveApi api = apiThat(
        (http.Request request) => request.method == 'GET'
            ? http.Response(
                jsonEncode(<String, Object?>{'files': <Object?>[]}),
                200,
              )
            : http.Response(
                jsonEncode(<String, Object?>{'id': 'new-folder'}),
                200,
              ),
      );

      expect(await api.folderNamed('Kubo Cà Phê backups'), 'new-folder');
      expect(sent.map((http.Request r) => r.method), <String>['GET', 'POST']);
    });

    test('a quote in the folder name cannot break the query', () async {
      final GoogleDriveApi api = apiThat(
        (http.Request request) =>
            http.Response(jsonEncode(<String, Object?>{'id': 'x'}), 200),
      );

      await api.folderNamed("Kubo's backups");

      expect(sent.first.url.queryParameters['q'], contains(r"Kubo\'s"));
    });

    test('the file goes up with its name and its folder', () async {
      final GoogleDriveApi api = apiThat(
        (http.Request request) =>
            http.Response(jsonEncode(<String, Object?>{'id': 'file-9'}), 200),
      );

      final String id = await api.uploadFile(
        folderId: 'folder-1',
        name: 'kubo_20260315.db',
        bytes: <int>[1, 2, 3, 4],
      );

      expect(id, 'file-9');
      final http.Request request = sent.single;
      expect(request.url.queryParameters['uploadType'], 'multipart');
      expect(request.headers['Content-Type'], contains('multipart/related'));
      expect(request.body, contains('kubo_20260315.db'));
      expect(request.body, contains('folder-1'));
      expect(
        request.bodyBytes,
        containsAllInOrder(<int>[1, 2, 3, 4]),
        reason: 'the database itself has to be in there',
      );
    });

    test('no token is a sign-in problem, not a network one', () async {
      final GoogleDriveApi api = apiThat(
        (http.Request request) => http.Response('{}', 200),
        token: null,
      );

      await expectLater(
        api.folderNamed('x'),
        throwsA(
          isA<CloudBackupException>().having(
            (CloudBackupException e) => e.isAuthProblem,
            'isAuthProblem',
            isTrue,
          ),
        ),
      );
    });

    test('a refused token asks her to sign in again', () async {
      final GoogleDriveApi api = apiThat(
        (http.Request request) => http.Response('no', 401),
      );

      await expectLater(
        api.folderNamed('x'),
        throwsA(
          isA<CloudBackupException>().having(
            (CloudBackupException e) => e.isAuthProblem,
            'isAuthProblem',
            isTrue,
          ),
        ),
      );
    });

    test('a full Drive says so in words', () async {
      final GoogleDriveApi api = apiThat(
        (http.Request request) => http.Response(
          '{"error":{"errors":[{"reason":'
          '"storageQuotaExceeded"}]}}',
          403,
        ),
      );

      await expectLater(
        api.uploadFile(folderId: 'f', name: 'n', bytes: <int>[1]),
        throwsA(isA<CloudBackupException>()),
      );
    });

    test('no signal is worth trying again, not signing in again', () async {
      final GoogleDriveApi api = GoogleDriveApi(
        accessToken: () async => 'token',
        client: MockClient(
          (http.Request request) => throw const SocketException('offline'),
        ),
      );

      await expectLater(
        api.folderNamed('x'),
        throwsA(
          isA<CloudBackupException>().having(
            (CloudBackupException e) => e.isAuthProblem,
            'isAuthProblem',
            isFalse,
          ),
        ),
      );
    });
  });

  group('sending the closing backup', () {
    late Directory workDir;
    late AppDatabase database;
    late BackupService backups;
    late SettingsRepositoryImpl settings;
    late FixedClock clock;
    late _FakeTarget target;
    late CloudBackupService cloud;

    setUp(() async {
      sqfliteFfiInit();
      workDir = await Directory.systemTemp.createTemp('kubo_cloud_test');
      clock = testClock();
      final String dbPath = p.join(workDir.path, 'kubo_pos.db');
      database = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: dbPath,
      );
      backups = BackupService(
        databasePath: dbPath,
        backupDirectory: Directory(p.join(workDir.path, 'backups')),
        clock: clock,
        checkpoint: () async => database.checkpoint(),
        schemaVersion: () async => 1,
      );
      settings = SettingsRepositoryImpl(database, clock);
      target = _FakeTarget();
      cloud = CloudBackupService(
        backups: backups,
        settings: settings,
        clock: clock,
        target: target,
      );
    });

    tearDown(() async {
      await database.close();
      if (workDir.existsSync()) await workDir.delete(recursive: true);
    });

    test('the newest backup goes up, and is marked as gone', () async {
      await backups.create();

      expect(await cloud.sendNewest(), CloudBackupOutcome.sent);

      expect(target.uploaded, hasLength(1));
      expect((await backups.listBackups()).single.isOffDevice, isTrue);
      expect(await cloud.lastUploadAt(), isNotNull);
      expect(await cloud.lastError(), isNull);
    });

    test('it is not sent twice', () async {
      await backups.create();
      await cloud.sendNewest();

      expect(await cloud.sendNewest(), CloudBackupOutcome.alreadySent);
      expect(target.uploaded, hasLength(1));
    });

    test('a failure keeps the backup on the phone and says why', () async {
      await backups.create();
      target.failWith = const CloudBackupException('Drive is full');

      expect(await cloud.sendNewest(), CloudBackupOutcome.failed);

      expect(
        (await backups.listBackups()).single.isOffDevice,
        isFalse,
        reason: 'it never left, so it must not be recorded as having left',
      );
      expect(await cloud.lastError(), 'Drive is full');
      expect(await cloud.lastUploadAt(), isNull);
    });

    test(
      'a lapsed sign-in is told apart from a bad night for signal',
      () async {
        await backups.create();
        target.failWith = const CloudBackupException(
          'expired',
          isAuthProblem: true,
        );

        expect(await cloud.sendNewest(), CloudBackupOutcome.signInExpired);
      },
    );

    test('the next day clears the last failure', () async {
      await backups.create();
      target.failWith = const CloudBackupException('no signal');
      await cloud.sendNewest();
      expect(await cloud.lastError(), isNotNull);

      target.failWith = null;
      clock.advance(const Duration(days: 1));
      await backups.create();

      expect(await cloud.sendNewest(), CloudBackupOutcome.sent);
      expect(await cloud.lastError(), isNull);
    });

    test('no account connected is not an error, just nothing done', () async {
      await backups.create();
      target.connected = false;

      expect(await cloud.sendNewest(), CloudBackupOutcome.notConnected);
      expect(target.uploaded, isEmpty);
    });

    test('nothing to send is not a failure either', () async {
      expect(await cloud.sendNewest(), CloudBackupOutcome.nothingToSend);
    });
  });
}

class _FakeTarget implements CloudBackupTarget {
  bool connected = true;
  CloudBackupException? failWith;
  final List<String> uploaded = <String>[];

  @override
  String get label => 'Test cloud';

  @override
  Future<bool> isConnected() async => connected;

  @override
  Future<String?> accountLabel() async => connected ? 'her@example.test' : null;

  @override
  Future<bool> connect() async => connected = true;

  @override
  Future<void> disconnect() async => connected = false;

  @override
  Future<void> upload(File file, {required String name}) async {
    final CloudBackupException? failure = failWith;
    if (failure != null) throw failure;
    uploaded.add(name);
  }
}
