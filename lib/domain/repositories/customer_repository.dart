import '../entities/customer.dart';

abstract class CustomerRepository {
  /// Partial match on name or mobile. Must stay fast — the owner types this
  /// with a customer standing in front of her.
  Future<List<Customer>> search(String query, {int limit = 20});

  /// Most recent visitors, shown before she has typed anything.
  Future<List<Customer>> recent({int limit = 8});

  Future<Customer?> byId(int id);

  /// Adds somebody. [notes] is hers alone — it tells two people with the
  /// same name apart and never reaches a receipt.
  ///
  /// Refuses a name that is already taken unless the notes differ.
  Future<int> create({required String name, String? mobile, String? notes});

  Future<void> update(Customer customer);

  /// Takes a customer off the list, keeping everything they bought.
  Future<void> archive(int id);

  /// The ones taken off the list.
  Future<List<Customer>> archived({int limit});

  /// Puts an archived customer back on it.
  Future<void> restore(int id);

  /// Forgets a customer. Their past orders stay on the books, unattributed.
  Future<void> delete(int id);

  /// The customer's usual: the one saved by hand if there is one, otherwise
  /// the configuration they order most. Null when there is not enough history
  /// to say — a single past order is not a usual.
  Future<UsualOrder?> usualFor(int customerId);

  /// The last thing they actually ordered, however many times.
  ///
  /// Different from the usual on purpose. The usual is what they order
  /// *most*, and it needs a repeat before it exists at all — so a customer
  /// on their second visit, or one who orders something different every
  /// time, has none. "What did you have last time?" is a question she can
  /// always answer, and it is the one people are asked across a counter.
  Future<UsualOrder?> lastOrderedFor(int customerId);

  /// Regulars who have stopped coming.
  Future<List<LapsedCustomer>> lapsed({int minimumOrders = 2, int limit = 50});

  Future<List<CustomerOrderPattern>> patternsFor(int customerId);

  /// Pins one pattern as the customer's usual. Always an explicit act.
  Future<void> saveUsual({required int customerId, required int patternId});

  Future<void> clearUsual(int customerId);
}
