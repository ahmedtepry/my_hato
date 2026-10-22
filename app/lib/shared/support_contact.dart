import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/config.dart';
import '../core/l10n.dart';
import '../core/theme.dart';

/// Customer support on WhatsApp (and phone). The number comes from AppConfig.
Uri whatsappUri([String? message]) => Uri.parse(
    'https://wa.me/${AppConfig.supportWhatsapp}${message == null ? '' : '?text=${Uri.encodeComponent(message)}'}');

String get supportPhoneLocal =>
    AppConfig.supportPhone.startsWith('+20') ? '0${AppConfig.supportPhone.substring(3)}' : AppConfig.supportPhone;

/// Bottom sheet: "contact support" with WhatsApp and call buttons.
Future<void> showSupportSheet(BuildContext context, {required String title, required String body, String? whatsappMessage}) =>
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(color: const Color(0xFF25D366).withValues(alpha: 0.12), shape: BoxShape.circle),
                child: const Icon(Icons.support_agent_rounded, size: 38, color: Color(0xFF128C7E)),
              ),
            ),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray, height: 1.6)),
            const SizedBox(height: 12),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(supportPhoneLocal, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20, letterSpacing: 1)),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF25D366)),
              icon: const Icon(Icons.chat_rounded),
              label: Text(context.tr('contact_whatsapp')),
              onPressed: () => launchUrl(whatsappUri(whatsappMessage), mode: LaunchMode.externalApplication),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.call_outlined),
              label: Text(context.tr('call_us')),
              onPressed: () => launchUrl(Uri.parse('tel:${AppConfig.supportPhone}')),
            ),
          ]),
        ),
      ),
    );
