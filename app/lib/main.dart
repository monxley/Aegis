import 'package:flutter/material.dart';

import 'engine.dart';
import 'screens/chats.dart';
import 'screens/onboarding.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final engine = AegisEngineController();
  final hasAccount = await engine.boot();
  runApp(AegisApp(engine: engine, hasAccount: hasAccount));
}

class AegisApp extends StatelessWidget {
  final AegisEngineController engine;
  final bool hasAccount;

  const AegisApp({super.key, required this.engine, required this.hasAccount});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aegis',
      debugShowCheckedModeBanner: false,
      theme: AegisTheme.dark,
      home: hasAccount
          ? ChatsScreen(engine: engine)
          : OnboardingScreen(engine: engine),
    );
  }
}
