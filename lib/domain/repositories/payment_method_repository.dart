import '../entities/order_draft.dart';

/// The ways the shop can take money, as the owner has set them up.
abstract class PaymentMethodRepository {
  /// Every method, active first, in the order the buttons appear.
  Future<List<PaymentMethod>> all({bool includeInactive = false});

  /// Adds a method. The code is derived from the name and must be unique.
  Future<PaymentMethod> add(PaymentMethod method);

  /// Saves the editable parts: the label, its behaviour, its order, whether it
  /// is offered. The code is never changed — old payments point at it.
  Future<void> update(PaymentMethod method);

  /// Removes a method entirely.
  ///
  /// Only possible while it has never taken money. Once it has, the database
  /// refuses, because deleting it would orphan those payments — retire it
  /// instead, which hides the button and leaves history intact.
  Future<void> delete(String code);

  /// How many payments were taken with this method. Zero means it can still be
  /// deleted rather than retired.
  Future<int> paymentCount(String code);
}
