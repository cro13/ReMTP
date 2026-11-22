use unicode_normalization::UnicodeNormalization;

pub(crate) const MAX_UNITS: usize = 255;

pub(crate) fn insensitive_key(name: &str) -> String {
    name.nfc().flat_map(char::to_lowercase).collect()
}

pub fn card_safe_name(name: &str) -> String {
    sanitize(name, MAX_UNITS)
}

/// The name a transfer with `card_safe_names` writes: within the destination's limit (254 UTF-16 units on
/// a device, 255 bytes on a Unix Mac).
pub fn card_safe_name_to(name: &str, to_device: bool) -> String {
    if to_device {
        return sanitize(name, mtp_rs::mtp::MAX_NAME_UNITS);
    }
    let mut name = sanitize(name, MAX_UNITS);
    if cfg!(unix) && name.len() > 255 {
        let mut end = 255;
        while !name.is_char_boundary(end) {
            end -= 1;
        }
        name.truncate(end);
        name = sanitize(&name, MAX_UNITS);
    }
    name
}

pub(crate) fn sanitize(name: &str, limit: usize) -> String {
    let mut units = 0;
    let mut mapped: String = name
        .nfc()
        .map(|c| if unsafe_char(c) { '_' } else { c })
        .take_while(|c| {
            units += c.len_utf16();
            units <= limit
        })
        .collect();
    mapped.truncate(mapped.trim_end_matches(['.', ' ']).len());
    if mapped.is_empty() {
        "_".into()
    } else {
        mapped
    }
}

pub(crate) fn unsafe_char(c: char) -> bool {
    c.is_control() || matches!(c, '"' | '*' | '/' | ':' | '<' | '>' | '?' | '\\' | '|')
}

pub(crate) fn numbered_bounded(
    name: &str,
    number: usize,
    max_units: usize,
    max_bytes: usize,
) -> String {
    let (stem, extension) = name
        .rsplit_once('.')
        .filter(|(s, _)| !s.is_empty())
        .unwrap_or((name, ""));
    let suffix = format!(" ({number})");
    let mut units = suffix.len();
    let mut bytes = suffix.len();
    let mut take = |c: &char| {
        if units + c.len_utf16() > max_units || bytes + c.len_utf8() > max_bytes {
            return false;
        }
        units += c.len_utf16();
        bytes += c.len_utf8();
        true
    };
    let extension: String = if extension.is_empty() {
        String::new()
    } else {
        std::iter::once('.')
            .chain(extension.chars())
            .take_while(&mut take)
            .collect()
    };
    let stem: String = stem.chars().take_while(take).collect();
    format!("{stem}{suffix}{extension}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_and_maps_card_names() {
        assert_eq!(card_safe_name("cafe\u{301}?:|. "), "café___");
        assert_eq!(card_safe_name("..."), "_");
        assert_eq!(
            card_safe_name(&"😀".repeat(128)).encode_utf16().count(),
            254
        );
        assert_eq!(
            numbered_bounded("track.flac", 2, 255, 255),
            "track (2).flac"
        );
    }
}
