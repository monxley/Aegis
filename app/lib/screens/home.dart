import 'package:flutter/material.dart';

import '../engine.dart';
import '../theme.dart';
import 'chats.dart';
import 'contacts.dart';
import 'region_notice.dart';
import 'settings.dart';

/// The three places the app actually lives, behind one bar.
///
/// Everything used to hang off the chat list's app bar as an icon, which put
/// Settings — the screen with the panic wipe, the duress password and the proxy
/// chain in it — behind an unlabelled glyph competing with three others. A
/// destination people can find without guessing is worth more than the row of
/// pixels it costs.
///
/// An IndexedStack rather than swapping widgets: each screen keeps its scroll
/// position and its state when you come back to it, and the chat list does not
/// re-subscribe to the engine every time you glance at Settings.
class HomeShell extends StatefulWidget {
  final AegisEngineController engine;
  const HomeShell({super.key, required this.engine});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // After the first frame: a dialog needs a route that is actually mounted,
    // and this is the first screen that is.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeShowRegionNotice(context, widget.engine);
    });
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          ChatsScreen(engine: e),
          ContactsScreen(engine: e),
          SettingsScreen(engine: e),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: AegisColor.surface,
        indicatorColor: AegisColor.accent.withValues(alpha: 0.16),
        surfaceTintColor: Colors.transparent,
        // Labels always visible. An icon-only bar asks people to learn three
        // glyphs before they can find the setting that wipes the device.
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        height: 64,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum_rounded, color: AegisColor.accent),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline_rounded),
            selectedIcon: Icon(Icons.people_rounded, color: AegisColor.accent),
            label: 'Contacts',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded, color: AegisColor.accent),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
