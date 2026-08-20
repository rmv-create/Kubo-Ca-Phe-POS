import '../entities/customer.dart';

abstract class CustomerRepository {
  /// Partial match on name or mobile. Must stay fast — the owner types this
  /// with a customer standing in front of her.
  Future<List<Customer>> search(String query, {int limit = 20});

  /// Most recent visitors, shown before she has typed anything.
  Future<List<Customer>> recent({int limit = 8});

  Future<Customer?> byId(int id);

  Future<int> create({required String name, String? mobile});

  Future<void> update(Customer customer);

  /// The customer's usual: the one saved by hand if there is one, otherwise
  /// the configuration they order most. Null when there is not enough history
  /// to say — a single past order is not a usual.
  Future<UsualOrder?> usualFor(int customerId);

  Future<List<CustomerOrderPattern>> patternsFor(int customerId);

  /// Pins one pattern as the customer's usual. Always an explicit act.
  Future<void> saveUsual({required int customerId, required int patternId});

  Future<void> clearUsual(int customerId);
}
