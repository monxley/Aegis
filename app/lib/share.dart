import 'dart:convert';
import 'dart:typed_data';

/// A shareable identity token: the Aegis ID and prekey bundle bundled into one
/// string you copy and send to a friend, who pastes it to add you. (The
/// post-quantum bundle is a few KB — too large for a QR code — so sharing is by
/// copy/paste.)
///
/// Format: `<aegis:…>#<base64url(bundle)>`. The Aegis ID keeps its `aegis:`
/// prefix so a token is self-describing.
class ShareCode {
  final String aegisId;
  final Uint8List bundle;

  const ShareCode(this.aegisId, this.bundle);

  String encode() => '$aegisId#${base64Url.encode(bundle)}';

  /// Parse a token. Throws [FormatException] if it is not a valid share code.
  static ShareCode decode(String token) {
    final t = token.trim();
    final hash = t.indexOf('#');
    if (hash <= 0 || !t.startsWith('aegis:')) {
      throw const FormatException('not an Aegis share code');
    }
    final id = t.substring(0, hash);
    final bundle = base64Url.decode(t.substring(hash + 1));
    return ShareCode(id, bundle);
  }
}
