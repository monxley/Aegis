//! Byte encoding for a [`PrekeyBundle`] so it can be shared out of band (paste
//! / QR alongside the Aegis ID) and stored in a contact.

use aegis_session::PrekeyBundle;

fn put_lp(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    out.extend_from_slice(bytes);
}

/// Serialize a prekey bundle to bytes.
pub fn encode_bundle(b: &PrekeyBundle) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&b.identity_dh);
    out.extend_from_slice(&b.signed_prekey);
    put_lp(&mut out, &b.pq_prekey);
    put_lp(&mut out, &b.ratchet_kem_prekey);
    match b.one_time_prekey {
        Some(opk) => {
            out.push(1);
            out.extend_from_slice(&opk);
        }
        None => out.push(0),
    }
    put_lp(&mut out, &b.identity_signing_public);
    put_lp(&mut out, &b.signature);
    out
}

/// Parse the encoding produced by [`encode_bundle`]. `None` on malformation.
pub fn decode_bundle(bytes: &[u8]) -> Option<PrekeyBundle> {
    let mut r = Reader::new(bytes);
    let identity_dh = r.array32()?;
    let signed_prekey = r.array32()?;
    let pq_prekey = r.lp()?.to_vec();
    let ratchet_kem_prekey = r.lp()?.to_vec();
    let one_time_prekey = match r.u8()? {
        0 => None,
        1 => Some(r.array32()?),
        _ => return None,
    };
    let identity_signing_public = r.lp()?.to_vec();
    let signature = r.lp()?.to_vec();
    Some(PrekeyBundle {
        identity_dh,
        signed_prekey,
        pq_prekey,
        ratchet_kem_prekey,
        one_time_prekey,
        identity_signing_public,
        signature,
    })
}

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.pos.checked_add(n)?;
        let s = self.buf.get(self.pos..end)?;
        self.pos = end;
        Some(s)
    }
    fn u8(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }
    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }
    fn lp(&mut self) -> Option<&'a [u8]> {
        let n = self.u32()? as usize;
        self.take(n)
    }
    fn array32(&mut self) -> Option<[u8; 32]> {
        self.take(32)?.try_into().ok()
    }
}
