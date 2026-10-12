import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:workmanager/workmanager.dart';

import '../../data/repositories/saved_subscriptions.dart';
import '../../data/repositories/subscription_cache.dart';
import '../../data/repositories/subscription_repository.dart';

const _refreshTask = 'connecso.subscription.refresh';
const _refreshWorkName = 'connecso.periodic.subscription.refresh';

@pragma('vm:entry-point')
void connecsoBackgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    if (task != _refreshTask) return true;
    WidgetsFlutterBinding.ensureInitialized();
    const storage = FlutterSecureStorage();
    final profiles = SavedSubscriptionsStore(storage);
    final repository = SubscriptionRepository(
      cache: SecureSubscriptionCache(storage),
    );
    try {
      final saved = await profiles.read();
      var refreshedCount = 0;
      for (var index = 0; index < saved.length; index++) {
        final profile = saved[index];
        final endpoint = Uri.tryParse(profile.endpoint ?? '');
        if (endpoint == null || endpoint.scheme != 'https') continue;
        try {
          final result = await repository.refreshDirect(
            endpoint,
            subscriptionId: profile.id,
          );
          saved[index] = profile.copyWith(
            name: profile.nameCustomized
                ? profile.name
                : result.profileTitle ?? profile.name,
            quota: result.quota,
            supportUrl: result.supportUrl ?? profile.supportUrl,
            profileUrl: result.profileUrl ?? profile.profileUrl,
            announcement: result.announcement ?? profile.announcement,
            accountEmail: result.accountEmail ?? profile.accountEmail,
          );
          await profiles.write(saved);
          refreshedCount++;
        } catch (_) {
          // Keep the last validated cache and let a later scheduled run retry.
        }
      }
      return refreshedCount > 0 ||
          saved.every((profile) {
            final uri = Uri.tryParse(profile.endpoint ?? '');
            return uri == null || uri.scheme != 'https';
          });
    } finally {
      repository.close();
    }
  });
}

Future<void> scheduleBackgroundSubscriptionRefresh() async {
  final workmanager = Workmanager();
  await workmanager.initialize(connecsoBackgroundDispatcher);
  await workmanager.registerPeriodicTask(
    _refreshWorkName,
    _refreshTask,
    frequency: const Duration(hours: 6),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
}
