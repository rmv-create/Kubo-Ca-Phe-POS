/// On a phone or a desktop the receipt is drawn by the app itself, so there
/// is nothing to fetch and nothing to wait for.
Future<bool> readyToDrawReceipts() async => true;
