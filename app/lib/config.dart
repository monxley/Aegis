import 'dart:io' show Platform;

/// Built-in **bootstrap nodes**: the addresses a fresh install contacts to
/// discover the mixnet. The user configures nothing — this is what makes it
/// "download and use". The set only needs one reachable entry; from it the app
/// learns the whole current node directory (which then changes as volunteers
/// join, without shipping a new build).
///
/// These are operated by the project as seed nodes. Add or replace them with
/// your own if you run a private network.
const List<String> kBootstrapNodes = <String>[
  // TODO: point these at real, project-operated seed nodes before release.
  'bootstrap1.aegis.example:5077',
  'bootstrap2.aegis.example:5077',
];

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
