/// Base type for every failure this application raises deliberately.
///
/// Each carries a message that is safe and useful to show the owner — she is
/// the only operator, so an error must tell her what to do, not what class
/// threw.
sealed class AppException implements Exception {
  const AppException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() =>
      '$runtimeType: $message${cause == null ? '' : ' ($cause)'}';
}

/// The data the operator entered cannot be accepted.
class ValidationException extends AppException {
  const ValidationException(super.message, {this.field, super.cause});

  final String? field;
}

/// A record that must exist does not.
class NotFoundException extends AppException {
  const NotFoundException(super.message, {super.cause});
}

/// The requested action conflicts with the current state of the business,
/// e.g. completing an order whose GCash payment has not been confirmed.
class BusinessRuleException extends AppException {
  const BusinessRuleException(super.message, {super.cause});
}

/// Something went wrong at the storage layer. The transaction has been rolled
/// back; no partial data was written.
class StorageException extends AppException {
  const StorageException(super.message, {super.cause});
}

/// Backup or restore could not complete safely.
class BackupException extends AppException {
  const BackupException(super.message, {super.cause});
}
