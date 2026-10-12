import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/repositories/saved_subscriptions.dart';
import '../../l10n/app_strings.dart';
import '../widgets/app_notice.dart';

class SubscriptionManagerSheet extends StatefulWidget {
  const SubscriptionManagerSheet({
    required this.language,
    required this.savedSubscriptions,
    required this.activeSubscriptionId,
    required this.canManageSubscriptions,
    required this.onSelectSubscription,
    required this.onEditSubscription,
    required this.onRefreshSubscription,
    required this.onDeleteSubscription,
    required this.onTogglePinned,
    required this.onSignOut,
    required this.onImportClipboard,
    required this.onScanQr,
    super.key,
  });

  final Locale language;
  final List<SavedSubscription> savedSubscriptions;
  final String? activeSubscriptionId;
  final bool canManageSubscriptions;
  final Future<void> Function(String) onSelectSubscription;
  final Future<void> Function(String, String, String?, bool, int?)
  onEditSubscription;
  final Future<void> Function(String) onRefreshSubscription;
  final Future<void> Function(String) onDeleteSubscription;
  final Future<void> Function(String, bool) onTogglePinned;
  final Future<void> Function() onSignOut;
  final Future<void> Function() onImportClipboard;
  final Future<void> Function() onScanQr;

  @override
  State<SubscriptionManagerSheet> createState() =>
      _SubscriptionManagerSheetState();
}

class _SubscriptionManagerSheetState extends State<SubscriptionManagerSheet> {
  late List<SavedSubscription> _profiles = _ordered(widget.savedSubscriptions);
  String? _selectedId;
  final Set<String> _working = {};
  final Set<String> _newProfileIds = {};

  void _wideNotice(String message) => AppNotice.show(context, message);

  @override
  void initState() {
    super.initState();
    _selectedId = widget.activeSubscriptionId;
  }

  @override
  void didUpdateWidget(covariant SubscriptionManagerSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.savedSubscriptions;
    final incomingIds = incoming.map((item) => item.id).toSet();
    final existingIds = _profiles.map((item) => item.id).toSet();
    final addedIds = incomingIds.difference(existingIds);
    final changed =
        oldWidget.savedSubscriptions != incoming ||
        _profiles.length != incoming.length ||
        _profiles.any(
          (profile) => !incoming.any(
            (item) =>
                item.id == profile.id &&
                item.name == profile.name &&
                item.pinned == profile.pinned &&
                item.endpoint == profile.endpoint,
          ),
        );
    if (changed) {
      _newProfileIds.addAll(addedIds);
      _profiles = _ordered(incoming, prioritizeIds: addedIds);
    }
    if (oldWidget.activeSubscriptionId != widget.activeSubscriptionId) {
      _selectedId = widget.activeSubscriptionId;
    }
  }

  List<SavedSubscription> _ordered(
    List<SavedSubscription> profiles, {
    Set<String> prioritizeIds = const <String>{},
  }) {
    final pinned = profiles.where((item) => item.pinned).toList();
    final regular = profiles.where((item) => !item.pinned).toList();
    List<SavedSubscription> prioritize(List<SavedSubscription> items) => [
      ...items.where((item) => prioritizeIds.contains(item.id)),
      ...items.where((item) => !prioritizeIds.contains(item.id)),
    ];
    return [...prioritize(pinned), ...prioritize(regular)];
  }

  Future<bool> _perform(String id, Future<void> Function() action) async {
    if (!widget.canManageSubscriptions || !_working.add(id)) return false;
    setState(() {});
    var succeeded = false;
    try {
      await action();
      succeeded = true;
    } catch (_) {
      if (mounted) {
        final strings = AppStrings(widget.language);
        _wideNotice(strings.subscriptionActionFailed);
      }
    } finally {
      _working.remove(id);
      if (mounted) setState(() {});
    }
    return succeeded;
  }

  Future<void> _edit(SavedSubscription profile, AppStrings strings) async {
    final result = await showDialog<_SubscriptionEdit>(
      context: context,
      builder: (_) => _EditSubscriptionDialog(
        initialName: profile.name,
        initialEndpoint: profile.endpoint ?? '',
        initialAutoRefresh: profile.autoRefreshEnabled,
        initialIntervalHours:
            profile.refreshIntervalHours ??
            (profile.id == widget.activeSubscriptionId ? 6 : 12),
        title: strings.editSubscription,
        nameLabel: strings.subscriptionName,
        linkLabel: strings.subscriptionLink,
        copyLabel: strings.copyLink,
        copiedLabel: strings.linkCopied,
        cancel: strings.cancel,
        save: strings.save,
        autoRefreshLabel: strings.autoRefresh,
        refreshIntervalLabel: strings.refreshInterval,
      ),
    );
    if (result == null || !mounted) return;
    final succeeded = await _perform(
      profile.id,
      () => widget.onEditSubscription(
        profile.id,
        result.name,
        result.endpoint,
        result.autoRefresh,
        result.intervalHours,
      ),
    );
    if (!succeeded || !mounted) return;
    setState(() {
      final index = _profiles.indexWhere((item) => item.id == profile.id);
      if (index >= 0) {
        _profiles[index] = profile.copyWith(
          name: result.name,
          endpoint: result.endpoint,
          nameCustomized: true,
          autoRefreshEnabled: result.autoRefresh,
          refreshIntervalHours: result.intervalHours,
        );
      }
    });
  }

  Future<void> _select(SavedSubscription profile) async {
    setState(() => _selectedId = profile.id);
    final succeeded = await _perform(
      profile.id,
      () => widget.onSelectSubscription(profile.id),
    );
    if (!succeeded && mounted) {
      setState(() => _selectedId = widget.activeSubscriptionId);
    }
  }

  Future<void> _refresh(SavedSubscription profile, AppStrings strings) async {
    final succeeded = await _perform(
      profile.id,
      () => widget.onRefreshSubscription(profile.id),
    );
    if (!succeeded || !mounted) return;
    _wideNotice(strings.subscriptionRefreshed);
  }

  Future<void> _delete(SavedSubscription profile, AppStrings strings) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.deleteSubscription),
        content: Text(strings.deleteSubscriptionMessage(profile.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final succeeded = await _perform(
      profile.id,
      () => widget.onDeleteSubscription(profile.id),
    );
    if (!succeeded || !mounted) return;
    setState(() => _profiles.removeWhere((item) => item.id == profile.id));
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(widget.language);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(strings.subscriptions, style: theme.textTheme.titleLarge),
            const SizedBox(height: 10),
            Flexible(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: ListView(
                  shrinkWrap: true,
                  children: _profiles.isEmpty
                      ? [
                          Padding(
                            key: const ValueKey('empty-subscriptions'),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(strings.noSavedSubscriptions),
                          ),
                        ]
                      : [
                          for (final profile in _profiles)
                            _buildAnimatedProfileRow(
                              context,
                              profile,
                              strings,
                              theme,
                            ),
                        ],
                ),
              ),
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.canManageSubscriptions
                        ? widget.onImportClipboard
                        : null,
                    icon: const Icon(Icons.content_paste_rounded, size: 18),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        strings.pasteClipboard,
                        maxLines: 1,
                        softWrap: false,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.canManageSubscriptions
                        ? widget.onScanQr
                        : null,
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                    label: Text(strings.scanQr),
                  ),
                ),
              ],
            ),
            if (_selectedId != null) ...[
              const SizedBox(height: 10),
              _buildSelectedDetails(context, strings, theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedDetails(
    BuildContext context,
    AppStrings strings,
    ThemeData theme,
  ) {
    final selected = _profiles
        .where((item) => item.id == _selectedId)
        .firstOrNull;
    if (selected == null) return const SizedBox.shrink();
    final hasLinks = selected.supportUrl != null || selected.profileUrl != null;
    final hasAnnouncement = selected.announcement != null;
    if (!hasLinks && !hasAnnouncement) {
      return Padding(
        padding: const EdgeInsetsDirectional.only(start: 4, end: 4, bottom: 2),
        child: Text(
          strings.noSubscriptionDetails,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasLinks) ...[
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (selected.supportUrl != null)
                  _metadataLink(
                    context,
                    theme,
                    icon: Icons.support_agent_outlined,
                    label: strings.supportLink,
                    value: selected.supportUrl!,
                  ),
                if (selected.profileUrl != null)
                  _metadataLink(
                    context,
                    theme,
                    icon: Icons.language_outlined,
                    label: strings.profileLink,
                    value: selected.profileUrl!,
                  ),
              ],
            ),
          ],
          if (selected.announcement != null) ...[
            const SizedBox(height: 10),
            Text(
              strings.announcement,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            Directionality(
              textDirection:
                  RegExp(r'[\u0600-\u06FF]').hasMatch(selected.announcement!)
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              child: Text(
                selected.announcement!,
                textAlign:
                    RegExp(r'[\u0600-\u06FF]').hasMatch(selected.announcement!)
                    ? TextAlign.right
                    : TextAlign.left,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _metadataLink(
    BuildContext context,
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
  }) => TextButton.icon(
    onPressed: () => _openMetadataLink(context, value),
    icon: Icon(icon, size: 18),
    label: Text(label),
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.standard,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      textStyle: const TextStyle(fontWeight: FontWeight.w600),
    ),
  );

  Future<void> _openMetadataLink(BuildContext context, String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      _wideNotice(AppStrings(widget.language).linkOpenFailed);
      return;
    }
    try {
      await const MethodChannel(
        'com.connecso.client/vpn',
      ).invokeMethod<void>('openExternalUrl', {'url': uri.toString()});
    } on PlatformException {
      if (context.mounted)
        _wideNotice(AppStrings(widget.language).linkOpenFailed);
    }
  }

  Widget _buildAnimatedProfileRow(
    BuildContext context,
    SavedSubscription profile,
    AppStrings strings,
    ThemeData theme,
  ) {
    final selected = profile.id == _selectedId;
    final busy = _working.contains(profile.id);
    final account = profile.accountEmail;
    final title = account == null || account.trim().isEmpty
        ? profile.displayName
        : account.trim();
    final subscriptionTitle = profile.nameCustomized
        ? profile.name
        : (profile.serverName ?? profile.name);
    final subtitle = subscriptionTitle == title
        ? (selected ? strings.activeSubscription : strings.savedSubscription)
        : subscriptionTitle;
    final row = Padding(
      key: ValueKey('profile-row-${profile.id}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            selected ? Icons.check_circle_rounded : Icons.cloud_outlined,
            size: 25,
            color: selected ? theme.colorScheme.primary : null,
          ),
          const SizedBox(width: 8),
          _action(
            tooltip: profile.pinned
                ? strings.unpinSubscription
                : strings.pinSubscription,
            icon: profile.pinned
                ? Icons.push_pin_rounded
                : Icons.push_pin_outlined,
            enabled: widget.canManageSubscriptions && !busy,
            selected: profile.pinned,
            onPressed: () async {
              final pinned = !profile.pinned;
              final succeeded = await _perform(
                profile.id,
                () => widget.onTogglePinned(profile.id, pinned),
              );
              if (!succeeded || !mounted) return;
              setState(() {
                final itemIndex = _profiles.indexWhere(
                  (item) => item.id == profile.id,
                );
                if (itemIndex >= 0) {
                  _profiles[itemIndex] = profile.copyWith(pinned: pinned);
                  _profiles = _ordered(_profiles);
                }
              });
            },
          ),
          const SizedBox(width: 2),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: !widget.canManageSubscriptions || selected
                  ? null
                  : () => unawaited(_select(profile)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 230),
                      child: Text(
                        title,
                        key: ValueKey(title),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          _action(
            tooltip: strings.copyLink,
            icon: Icons.copy_rounded,
            enabled:
                widget.canManageSubscriptions &&
                !busy &&
                profile.endpoint != null,
            onPressed: () => _copyLink(profile, strings),
          ),
          _action(
            tooltip: strings.editSubscription,
            icon: Icons.edit_outlined,
            enabled: widget.canManageSubscriptions && !busy,
            onPressed: () => _edit(profile, strings),
          ),
          _action(
            tooltip: strings.refreshSubscription,
            icon: Icons.refresh_rounded,
            enabled: widget.canManageSubscriptions && !busy,
            onPressed: () => _refresh(profile, strings),
          ),
          _action(
            tooltip: strings.deleteSubscription,
            icon: Icons.delete_outline_rounded,
            enabled: widget.canManageSubscriptions && !busy,
            onPressed: () => _delete(profile, strings),
          ),
        ],
      ),
    );
    if (!_newProfileIds.contains(profile.id)) return row;
    return TweenAnimationBuilder<double>(
      key: ValueKey('new-profile-${profile.id}'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
      onEnd: () {
        if (!mounted || !_newProfileIds.remove(profile.id)) return;
        setState(() {});
      },
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - value)),
          child: Transform.scale(
            alignment: Alignment.topCenter,
            scale: 0.96 + (value * 0.04),
            child: child,
          ),
        ),
      ),
      child: row,
    );
  }

  Future<void> _copyLink(SavedSubscription profile, AppStrings strings) async {
    final endpoint = profile.endpoint;
    if (endpoint == null) return;
    await Clipboard.setData(ClipboardData(text: endpoint));
    if (!mounted) return;
    _wideNotice(strings.linkCopied);
  }

  Widget _action({
    required String tooltip,
    required IconData icon,
    required bool enabled,
    required VoidCallback onPressed,
    bool selected = false,
  }) => Padding(
    padding: const EdgeInsetsDirectional.only(start: 1),
    child: IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 29, height: 29),
      padding: EdgeInsets.zero,
      onPressed: enabled ? onPressed : null,
      color: selected ? Theme.of(context).colorScheme.primary : null,
      icon: Icon(icon, size: 16),
    ),
  );
}

class _SubscriptionEdit {
  const _SubscriptionEdit(
    this.name,
    this.endpoint,
    this.autoRefresh,
    this.intervalHours,
  );
  final String name;
  final String? endpoint;
  final bool autoRefresh;
  final int? intervalHours;
}

class _EditSubscriptionDialog extends StatefulWidget {
  const _EditSubscriptionDialog({
    required this.initialName,
    required this.initialEndpoint,
    required this.initialAutoRefresh,
    required this.initialIntervalHours,
    required this.title,
    required this.nameLabel,
    required this.linkLabel,
    required this.copyLabel,
    required this.copiedLabel,
    required this.cancel,
    required this.save,
    required this.autoRefreshLabel,
    required this.refreshIntervalLabel,
  });

  final String initialName;
  final String initialEndpoint;
  final bool initialAutoRefresh;
  final int? initialIntervalHours;
  final String title;
  final String nameLabel;
  final String linkLabel;
  final String copyLabel;
  final String copiedLabel;
  final String cancel;
  final String save;
  final String autoRefreshLabel;
  final String refreshIntervalLabel;

  @override
  State<_EditSubscriptionDialog> createState() =>
      _EditSubscriptionDialogState();
}

class _EditSubscriptionDialogState extends State<_EditSubscriptionDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  late final TextEditingController _endpoint = TextEditingController(
    text: widget.initialEndpoint,
  );
  late bool _autoRefresh = widget.initialAutoRefresh;
  late int _intervalHours = widget.initialIntervalHours ?? 12;

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        Expanded(child: Text(widget.title)),
        Text(
          widget.autoRefreshLabel,
          style: Theme.of(context).textTheme.labelMedium,
        ),
        Switch(
          value: _autoRefresh,
          onChanged: (value) => setState(() => _autoRefresh = value),
        ),
      ],
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: 40,
          decoration: InputDecoration(labelText: widget.nameLabel),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _endpoint,
                onChanged: (_) => setState(() {}),
                maxLines: 2,
                minLines: 1,
                keyboardType: TextInputType.url,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(labelText: widget.linkLabel),
              ),
            ),
            IconButton(
              tooltip: widget.copyLabel,
              onPressed: _endpoint.text.trim().isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(
                        ClipboardData(text: _endpoint.text.trim()),
                      );
                      if (!mounted) return;
                      AppNotice.show(context, widget.copiedLabel);
                    },
              icon: const Icon(Icons.copy_rounded),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text(widget.refreshIntervalLabel)),
            DropdownButton<int>(
              value: _intervalHours,
              items: const [6, 12, 24]
                  .map(
                    (hours) =>
                        DropdownMenuItem(value: hours, child: Text('$hours h')),
                  )
                  .toList(),
              onChanged: _autoRefresh
                  ? (value) =>
                        setState(() => _intervalHours = value ?? _intervalHours)
                  : null,
            ),
          ],
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(widget.cancel),
      ),
      FilledButton(
        onPressed: () {
          final text = _endpoint.text.trim();
          Navigator.of(context).pop(
            _SubscriptionEdit(
              _name.text.trim(),
              text.isEmpty ? null : text,
              _autoRefresh,
              _intervalHours,
            ),
          );
        },
        child: Text(widget.save),
      ),
    ],
  );
}
