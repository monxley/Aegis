import 'package:flutter/material.dart';

import '../engine.dart';
import '../theme.dart';
import 'proxy.dart';

/// A launch notice for Russian-language devices: what to do when Aegis cannot
/// reach the network.
///
/// WHY IT IS KEYED ON LANGUAGE AND WORDED AS A CONDITIONAL
///
/// The device language is not where the device is. Russian-language phones are
/// everywhere, and plenty of people inside Russia run theirs in English. So the
/// language decides only *which language to write in*; the text itself never
/// claims where you are, and describes a symptom you either have or do not.
/// Telling someone in Berlin they need a VPN would be wrong, and worse, it would
/// teach them the app guesses at their location — which is the one thing a
/// messenger like this must not do.
///
/// It also says nothing about which country any node is in. That could change
/// with the next volunteer who runs one, and an app that names a country is
/// wrong the day after it moves.
///
/// WHAT IT DELIBERATELY DOES NOT SAY
///
/// That a VPN makes Aegis more secure. It does not: a VPN and the built-in
/// proxy change whether a packet arrives, not who can read it. Messages are
/// end-to-end encrypted either way. Leaving that unsaid invites exactly the
/// wrong conclusion, so it is said.

/// Shown once per launch, so the app does not nag between screens within one
/// session. A fresh start shows it again, which is what was asked for: the
/// people it is for are the ones who have just watched it fail to connect.
bool _shownThisLaunch = false;

/// Reset between tests, and after a wipe, so a fresh identity gets a fresh
/// notice rather than inheriting the last session's.
@visibleForTesting
void resetRegionNoticeForTesting() => _shownThisLaunch = false;

bool _isRussian() {
  // The platform locale rather than the app's: Aegis has no Russian
  // translation, so Localizations would resolve to English and tell us nothing
  // about the person holding the phone.
  final locale = WidgetsBinding.instance.platformDispatcher.locale;
  return locale.languageCode.toLowerCase() == 'ru';
}

Future<void> maybeShowRegionNotice(
  BuildContext context,
  AegisEngineController engine,
) async {
  if (_shownThisLaunch || !_isRussian()) return;
  _shownThisLaunch = true;
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      backgroundColor: AegisColor.surface,
      icon: const Icon(Icons.travel_explore_rounded,
          color: AegisColor.warning, size: 28),
      title: const Text('Если Shoal не подключается'),
      content: const SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Узлы сети Shoal могут быть недоступны из некоторых сетей и '
              'стран. Тогда в шапке видно «no connection», и сообщения не '
              'уходят.',
              style: TextStyle(
                  color: AegisColor.textSecondary, fontSize: 14, height: 1.5),
            ),
            SizedBox(height: AegisSpace.s3),
            Text(
              'Что помогает:',
              style: TextStyle(
                  color: AegisColor.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600),
            ),
            SizedBox(height: AegisSpace.s2),
            Text(
              '• Включить VPN.\n'
              '• Или настроить прокси прямо здесь: Настройки → SOCKS5 / Tor. '
              'Стороннее приложение для этого не нужно.',
              style: TextStyle(
                  color: AegisColor.textSecondary, fontSize: 14, height: 1.5),
            ),
            SizedBox(height: AegisSpace.s3),
            Text(
              'На шифрование это не влияет. VPN и прокси решают, дойдёт ли '
              'пакет, а не то, кто сможет его прочитать — переписка зашифрована '
              'от устройства до устройства в любом случае.',
              style: TextStyle(
                  color: AegisColor.textMuted, fontSize: 13, height: 1.45),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(),
          child: const Text('Понятно'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AegisColor.accent,
            foregroundColor: AegisColor.textOnAccent,
          ),
          onPressed: () {
            Navigator.of(dialog).pop();
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ProxyScreen(engine: engine),
            ));
          },
          child: const Text('Настроить прокси'),
        ),
      ],
    ),
  );
}
