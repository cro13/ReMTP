use std::cmp::Ordering;

const MODULUS_BYTES: usize = 256;

pub(crate) fn encode_public_key(der: &[u8]) -> Option<String> {
    let mut encoded = base64(&adb_key_blob(der)?);
    encoded.push_str(" ReMTP");
    Some(encoded)
}

fn adb_key_blob(mut der: &[u8]) -> Option<Vec<u8>> {
    let mut sequence = der_value(&mut der, 0x30)?;
    let modulus = positive_integer(&mut sequence)?;
    let exponent = positive_integer(&mut sequence)?;
    if !der.is_empty()
        || !sequence.is_empty()
        || modulus.len() != MODULUS_BYTES
        || modulus[0] < 0x80
        || modulus[MODULUS_BYTES - 1] & 1 == 0
        || exponent.len() > 4
    {
        return None;
    }
    let exponent = exponent
        .iter()
        .fold(0u32, |acc, &byte| (acc << 8) | u32::from(byte));
    if exponent < 3 || exponent & 1 == 0 {
        return None;
    }

    let modulus: Vec<_> = modulus
        .rchunks_exact(4)
        .map(|word| u32::from_be_bytes(word.try_into().unwrap()))
        .collect();
    Some(
        [modulus.len() as u32, negative_inverse(modulus[0])]
            .into_iter()
            .chain(modulus.iter().copied())
            .chain(montgomery_rr(&modulus))
            .chain([exponent])
            .flat_map(u32::to_le_bytes)
            .collect(),
    )
}

fn der_value<'a>(input: &mut &'a [u8], tag: u8) -> Option<&'a [u8]> {
    let [actual_tag, first_len, tail @ ..] = *input else {
        return None;
    };
    if *actual_tag != tag {
        return None;
    }
    let (len, tail) = if *first_len < 0x80 {
        (usize::from(*first_len), tail)
    } else {
        // This key's values fit in at most two length bytes. Reject non-minimal encodings.
        match (*first_len, tail) {
            (0x81, [length, rest @ ..]) if *length >= 0x80 => (usize::from(*length), rest),
            (0x82, [high, low, rest @ ..]) if *high != 0 => {
                (usize::from(u16::from_be_bytes([*high, *low])), rest)
            }
            _ => return None,
        }
    };
    let (value, rest) = tail.split_at_checked(len)?;
    *input = rest;
    Some(value)
}

fn positive_integer<'a>(input: &mut &'a [u8]) -> Option<&'a [u8]> {
    match der_value(input, 0x02)? {
        value @ [0, first, ..] if *first >= 0x80 => Some(&value[1..]),
        value @ [first, ..] if (1..0x80).contains(first) => Some(value),
        _ => None,
    }
}

fn negative_inverse(odd: u32) -> u32 {
    // Newton iteration doubles the number of correct low bits each time, starting with bit 0.
    let mut inverse = 1u32;
    for _ in 0..5 {
        inverse = inverse.wrapping_mul(2u32.wrapping_sub(odd.wrapping_mul(inverse)));
    }
    inverse.wrapping_neg()
}

fn montgomery_rr(modulus: &[u32]) -> Vec<u32> {
    let mut limbs = vec![0; modulus.len()];
    limbs[0] = 1u32;
    if limbs == modulus {
        limbs[0] = 0;
    }
    // R = 2^(32 * limbs). Repeated modular doubling avoids allocating a double-width integer.
    for _ in 0..64 * modulus.len() {
        let mut carry = 0;
        for limb in &mut limbs {
            let top = *limb >> 31;
            *limb = (*limb << 1) | carry;
            carry = top;
        }
        if carry != 0 || limbs.iter().rev().cmp(modulus.iter().rev()) != Ordering::Less {
            // If doubling overflowed, the final borrow consumes that carry.
            let mut borrow = 0;
            for (limb, &word) in limbs.iter_mut().zip(modulus) {
                let difference = i64::from(*limb) - i64::from(word) - borrow;
                *limb = difference as u32;
                borrow = i64::from(difference < 0);
            }
        }
    }
    limbs
}

fn base64(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let first = chunk[0];
        let second = chunk.get(1).copied().unwrap_or(0);
        let third = chunk.get(2).copied().unwrap_or(0);
        let digit = |index: u8| char::from(DIGITS[usize::from(index)]);
        text.push(digit(first >> 2));
        text.push(digit(((first & 3) << 4) | (second >> 4)));
        text.push(if chunk.len() >= 2 {
            digit(((second & 15) << 2) | (third >> 6))
        } else {
            '='
        });
        text.push(if chunk.len() == 3 {
            digit(third & 63)
        } else {
            '='
        });
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn montgomery_parameters_match_native_arithmetic() {
        for (count, modulus) in [
            (1, 1),
            (1, 19),
            (1, 4_294_967_291),
            (2, 65_537),
            (2, u128::from(u64::MAX) - 18),
            (3, (1u128 << 96) - 31),
        ] {
            let words: Vec<_> = (0..count)
                .map(|index| (modulus >> (32 * index)) as u32)
                .collect();
            let expected = (0..64 * count).fold(1 % modulus, |acc, _| (acc * 2) % modulus);
            let actual = montgomery_rr(&words)
                .iter()
                .rev()
                .fold(0u128, |acc, &word| (acc << 32) | u128::from(word));
            assert_eq!(actual, expected, "{modulus}");
            assert_eq!(negative_inverse(words[0]).wrapping_mul(words[0]), u32::MAX);
        }
    }

    fn public_key_der() -> Vec<u8> {
        let mut der = vec![0x30, 0x82, 0x01, 0x0a, 0x02, 0x82, 0x01, 0x01, 0];
        der.extend([0xff; MODULUS_BYTES - 1]);
        der.extend([0xef, 0x02, 0x03, 0x01, 0x00, 0x01]);
        der
    }

    #[test]
    fn adb_struct_has_little_endian_words_and_expected_montgomery_values() {
        let der = public_key_der();
        let blob = adb_key_blob(&der).unwrap();
        assert_eq!(blob.len(), 524);
        let words: Vec<_> = blob
            .chunks_exact(4)
            .map(|word| u32::from_le_bytes(word.try_into().unwrap()))
            .collect();
        assert_eq!(words[0], 64);
        let modulus = &words[2..66];
        assert_eq!(modulus[0], u32::MAX - 16);
        assert_eq!(&modulus[1..], &[u32::MAX; 63]);
        assert_eq!(words[1].wrapping_mul(modulus[0]), u32::MAX);
        let rr = &words[66..130];
        assert!(rr.iter().rev().cmp(modulus.iter().rev()).is_lt());
        assert_eq!(rr[0], 289);
        assert_eq!(&rr[1..], &[0; 63]);
        assert_eq!(words[130], 65_537);
        let text = encode_public_key(&der).unwrap();
        let encoded = text.strip_suffix(" ReMTP").unwrap();
        assert_eq!(encoded.len(), 700);
        assert!(encoded.starts_with("QAAA") && encoded.ends_with('='));
    }

    #[test]
    fn malformed_public_key_is_rejected() {
        let mut der = public_key_der();
        assert!(encode_public_key(&der[..der.len() - 1]).is_none());
        der[9] = 0x7f;
        assert!(encode_public_key(&der).is_none());
    }

    #[test]
    fn standard_base64_alphabet_and_padding() {
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(&[0xfb, 0xff]), "+/8=");
    }
}
