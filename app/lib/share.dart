import 'dart:convert';
import 'dart:typed_data';

/// A shareable identity token: the Shoal ID and prekey bundle bundled into one
/// string you copy and send to a friend, who pastes it to add you. (The
/// post-quantum bundle is a few KB — too large for a QR code — so sharing is by
/// copy/paste.)
///
/// Format: `<shoal:…>#<base64url(bundle)>`. The Shoal ID keeps its `shoal:`
/// prefix so a token is self-describing.
class ShareCode {
  final String shoalId;
  final Uint8List bundle;

  const ShareCode(this.shoalId, this.bundle);

  String encode() => '$shoalId#${base64Url.encode(bundle)}';

  /// Parse a token. Throws [FormatException] if it is not a valid share code.
  static ShareCode decode(String token) {
    final t = token.trim();
    final hash = t.indexOf('#');
    if (hash <= 0 || !t.startsWith('shoal:')) {
      throw const FormatException('not a Shoal share code');
    }
    final id = t.substring(0, hash);
    final bundle = base64Url.decode(t.substring(hash + 1));
    return ShareCode(id, bundle);
  }
}
