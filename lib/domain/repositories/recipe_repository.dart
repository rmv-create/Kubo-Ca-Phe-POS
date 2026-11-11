import '../../core/quantity/quantity.dart';
import '../entities/menu.dart';
import '../entities/recipe.dart';

/// One recipe per drink per size, each with its own version history.
abstract class RecipeRepository {
  /// Every product/size pair, whether or not it has a recipe yet.
  Future<List<Recipe>> recipes({bool withCosts = true});

  Future<Recipe?> recipeFor({
    required int productId,
    required int sizeId,
    bool withCosts = true,
  });

  /// Starts a first version, or a new one when the current one is edited.
  ///
  /// Editing never rewrites a live version: the current one is retired with an
  /// end date and a new one takes over, so orders already sold keep their
  /// ingredients and their cost.
  Future<int> saveVersion({
    required int productId,
    required int sizeId,
    required Map<int, Quantity> lines,
    String? note,
  });

  Future<void> retireVersion(int versionId);

  /// What a customisation takes out of stock, line by line.
  Future<List<OptionEffect>> effectsForOption(int optionId);

  /// Writes one line of it. A zero amount removes the line.
  Future<void> saveEffect({
    required int optionId,
    required int ingredientId,
    required Quantity delta,
    int? productId,
    int? sizeId,
  });

  Future<void> removeEffect({
    required int optionId,
    required int ingredientId,
    int? productId,
    int? sizeId,
  });
}
