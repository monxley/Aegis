import 'dart:io' show Platform;

/// Built-in **bootstrap nodes**: the mix addresses a fresh install contacts to
/// discover the network. From one reachable entry the app learns the whole
/// current node directory (which then changes as volunteers join, without a new
/// build).
///
/// These are injected at build time so a real deployment bakes in its own seed
/// nodes without editing source:
///
/// ```sh
/// flutter build apk --dart-define=AEGIS_BOOTSTRAP=seed1.example:5078,seed2.example:5078
/// ```
///
/// If none are compiled in, the app asks the user for a node address on first
/// run (Advanced → "mixnet node"), so there are no fake/placeholder hosts that
/// look real but go nowhere.
const String _envBootstrap =
    String.fromEnvironment('AEGIS_BOOTSTRAP', defaultValue: '');

List<String> get kBootstrapNodes => _envBootstrap.isEmpty
    ? const <String>[]
    : _envBootstrap.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

/// Whether this platform should run an opt-in mix node **by default**.
/// Always-on, reachable machines (desktop/Linux) make good nodes; battery-
/// powered, NATed phones do not, so Android defaults off (still user-enableable).
bool get kNodeDefaultOn {
  try {
    return Platform.isLinux || Platform.isMacOS || Platform.isWindows;
  } catch (_) {
    return false; // web or unknown
  }
}
