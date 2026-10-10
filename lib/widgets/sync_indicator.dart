import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// Cloud icon showing sync state; tap to sync now.
class SyncIndicator extends StatelessWidget {
  const SyncIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final (icon, label) = switch (app.status) {
      SyncStatus.notConfigured => (Icons.cloud_off_outlined, '동기화 설정 안 됨'),
      SyncStatus.idle => (Icons.cloud_done_outlined, '동기화됨'),
      SyncStatus.syncing => (Icons.cloud_sync_outlined, '동기화 중…'),
      SyncStatus.offline => (Icons.cloud_off, '오프라인 (로컬 저장됨)'),
      SyncStatus.error => (Icons.error_outline, '동기화 오류'),
    };
    final when = app.lastSync == null
        ? ''
        : '\n마지막 동기화: ${DateFormat('M/d HH:mm').format(app.lastSync!)}';
    final error = app.lastError == null ? '' : '\n${app.lastError}';
    return IconButton(
      tooltip: '$label$when$error',
      icon: app.status == SyncStatus.syncing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              icon,
              color: app.status == SyncStatus.error
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
      onPressed: () {
        if (app.status == SyncStatus.notConfigured) {
          Navigator.of(context).pushNamed('/settings');
          return;
        }
        app.syncNow();
        if (app.lastError != null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(app.lastError!)));
        }
      },
    );
  }
}
