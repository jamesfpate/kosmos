import 'dart:async';
import 'dart:io';

import 'package:in_app_purchase/in_app_purchase.dart';

/// The optional Supporter purchase: a one-off "thank you" that unlocks nothing (everything in Winnow stays free).
/// Bought through Google Play on Android; elsewhere supporters use GitHub Sponsors.
class Support {
  static const productId = 'supporter';
  static const sponsorsUrl = 'https://github.com/sponsors/jamesfpate';

  /// Play billing only on Android; iPhone and computer builds link to GitHub Sponsors.
  static bool get inApp => Platform.isAndroid;

  StreamSubscription<List<PurchaseDetails>>? _sub;

  /// The product from the store, once loaded; null when billing isn't there (not installed from Play, offline).
  ProductDetails? product;

  /// Listens for purchases (new and restored) and calls [onSupporter] for each completed one.
  Future<void> start(void Function() onSupporter) async {
    if (!inApp) return;
    final iap = InAppPurchase.instance;
    _sub ??= iap.purchaseStream.listen((list) async {
      for (final p in list) {
        if (p.productID != productId) continue;
        if (p.status == PurchaseStatus.purchased || p.status == PurchaseStatus.restored) onSupporter();
        if (p.pendingCompletePurchase) await iap.completePurchase(p);
      }
    }, onError: (_) {});
    try {
      if (!await iap.isAvailable()) return;
      final r = await iap.queryProductDetails({productId});
      product = r.productDetails.firstOrNull;
      await iap.restorePurchases();
    } catch (_) {
      // No Play billing on this install: the GitHub Sponsors link stands in.
    }
  }

  Future<void> buy() async {
    final p = product;
    if (p == null) return;
    await InAppPurchase.instance.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: p));
  }

  void dispose() => _sub?.cancel();
}
