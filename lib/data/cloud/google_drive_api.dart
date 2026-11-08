import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cloud_backup_target.dart';

/// The two Google Drive calls a backup needs, and nothing else.
///
/// Written against the REST API with a plain HTTP client rather than a
/// generated SDK: it is two requests, and keeping it this small means the
/// part that can go wrong — the request, the retry, the error — can be
/// tested here without a Google account.
///
/// The app asks for the `drive.file` scope, which can only see files the app
/// itself created. It cannot read her photos, her documents, or anything
/// else in her Drive, and Google does not put that scope through a review.
class GoogleDriveApi {
  GoogleDriveApi({
    required Future<String?> Function() accessToken,
    http.Client? client,
  }) : _accessToken = accessToken,
       _client = client ?? http.Client();

  final Future<String?> Function() _accessToken;
  final http.Client _client;

  static const String scope = 'https://www.googleapis.com/auth/drive.file';
  static const String _folderType = 'application/vnd.google-apps.folder';
  static const String _files = 'https://www.googleapis.com/drive/v3/files';
  static const String _upload =
      'https://www.googleapis.com/upload/drive/v3/files';

  /// The id of a folder with this name, creating it if it is not there.
  ///
  /// `drive.file` only sees what the app made, so this finds the folder it
  /// made last time rather than any folder of that name she may own.
  Future<String> folderNamed(String name) async {
    final Map<String, String> headers = await _headers();
    final Uri query = Uri.parse(_files).replace(
      queryParameters: <String, String>{
        'q':
            "mimeType='$_folderType' and name='${_escape(name)}' "
            'and trashed=false',
        'fields': 'files(id)',
        'pageSize': '1',
      },
    );

    final http.Response found = await _send(
      () => _client.get(query, headers: headers),
    );
    final Object? files =
        (jsonDecode(found.body) as Map<String, Object?>)['files'];
    if (files is List && files.isNotEmpty) {
      return (files.first as Map<String, Object?>)['id']! as String;
    }

    final http.Response created = await _send(
      () => _client.post(
        Uri.parse(
          _files,
        ).replace(queryParameters: <String, String>{'fields': 'id'}),
        headers: <String, String>{
          ...headers,
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode(<String, Object?>{
          'name': name,
          'mimeType': _folderType,
        }),
      ),
    );
    return (jsonDecode(created.body) as Map<String, Object?>)['id']! as String;
  }

  /// Uploads [bytes] as [name] into [folderId], and returns the file's id.
  ///
  /// One multipart request: the metadata and the file in the same body. A
  /// day's database is a few megabytes, which is well inside what a single
  /// request handles; a resumable upload would be three round trips to save
  /// nothing.
  Future<String> uploadFile({
    required String folderId,
    required String name,
    required List<int> bytes,
  }) async {
    const String boundary = 'kubo-backup-boundary';
    final List<int> body = <int>[
      ...utf8.encode(
        '--$boundary\r\n'
        'Content-Type: application/json; charset=utf-8\r\n\r\n'
        '${jsonEncode(<String, Object?>{
          'name': name,
          'parents': <String>[folderId],
        })}\r\n'
        '--$boundary\r\n'
        'Content-Type: application/x-sqlite3\r\n\r\n',
      ),
      ...bytes,
      ...utf8.encode('\r\n--$boundary--\r\n'),
    ];

    final http.Response response = await _send(
      () async => _client.post(
        Uri.parse(_upload).replace(
          queryParameters: <String, String>{
            'uploadType': 'multipart',
            'fields': 'id',
          },
        ),
        headers: <String, String>{
          ...await _headers(),
          'Content-Type': 'multipart/related; boundary=$boundary',
        },
        body: body,
      ),
    );
    return (jsonDecode(response.body) as Map<String, Object?>)['id']! as String;
  }

  Future<Map<String, String>> _headers() async {
    final String? token = await _accessToken();
    if (token == null || token.isEmpty) {
      throw const CloudBackupException(
        'Kubo is not signed in to Google Drive.',
        isAuthProblem: true,
      );
    }
    return <String, String>{'Authorization': 'Bearer $token'};
  }

  /// Runs a request and turns anything that is not a success into words.
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request();
    } on Object catch (error) {
      // No signal, aeroplane mode, Google down — all the same to her, and
      // all worth trying again later rather than signing in again.
      throw CloudBackupException('Google Drive could not be reached. $error');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const CloudBackupException(
        'Google Drive refused the sign-in. Connect the account again.',
        isAuthProblem: true,
      );
    }
    if (response.statusCode == 507 ||
        response.body.contains('storageQuotaExceeded')) {
      throw const CloudBackupException(
        'That Google account is out of space, so the backup was not saved.',
      );
    }
    throw CloudBackupException(
      'Google Drive answered ${response.statusCode}. The backup was not '
      'saved; it is still on the phone.',
    );
  }

  /// Drive's query language quotes names in single quotes.
  static String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
}
