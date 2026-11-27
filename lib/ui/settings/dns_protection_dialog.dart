import 'package:flutter/material.dart';

Future<bool?> showDnsProtectionDialog(
  BuildContext context, {
  required bool persian,
  required bool enabled,
}) => showDialog<bool>(
  context: context,
  animationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (dialogContext) => AlertDialog(
    title: Text(persian ? 'محافظت DNS' : 'DNS protection'),
    content: SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: Text(persian ? 'محافظت DNS و FakeDNS' : 'DNS leak protection'),
      subtitle: Text(
        persian
            ? 'درخواست‌های DNS را داخل مسیر تونل مدیریت می‌کند.'
            : 'Handles DNS requests inside the tunnel with FakeDNS.',
      ),
      value: enabled,
      onChanged: (value) => Navigator.of(dialogContext).pop(value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: Text(persian ? 'بستن' : 'Close'),
      ),
    ],
  ),
);
