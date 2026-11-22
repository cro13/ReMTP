use std::sync::{Arc, Mutex};

use security_framework::item::{ItemSearchOptions, KeyClass, Location, Reference, SearchResult};
use security_framework::key::{Algorithm, GenerateKeyOptions, KeyType, SecKey};
use security_framework::os::macos::keychain::SecKeychain;

use crate::{Error, KeyStore, Result, key};

const LABEL: &str = "ReMTP ADB key";
const ITEM_NOT_FOUND: i32 = -25300;
static KEY_CREATION: Mutex<()> = Mutex::new(());

pub(crate) fn load() -> Result<Arc<dyn KeyStore>> {
    let _guard = KEY_CREATION.lock().map_err(key_error)?;
    let home = std::env::home_dir().ok_or_else(|| key_error("no home directory"))?;
    let login =
        SecKeychain::open(home.join("Library/Keychains/login.keychain-db")).map_err(key_error)?;
    let result = ItemSearchOptions::new()
        .keychains(std::slice::from_ref(&login))
        .key_class(KeyClass::private())
        .label(LABEL)
        .load_refs(true)
        .search();
    let private = match result {
        Ok(items) => match items.into_iter().next() {
            Some(SearchResult::Ref(Reference::Key(key))) => key,
            _ => {
                return Err(key_error(
                    "expected an RSA private key in the login Keychain",
                ));
            }
        },
        Err(error) if error.code() == ITEM_NOT_FOUND => {
            let mut options = GenerateKeyOptions::default();
            options
                .set_key_type(KeyType::rsa())
                .set_size_in_bits(2048)
                .set_label(LABEL)
                .set_location(Location::FileKeychain(login));
            SecKey::new(&options).map_err(key_error)?
        }
        Err(error) => return Err(key_error(error)),
    };
    Ok(Arc::new(LoginKey(private)))
}

struct LoginKey(SecKey);

impl KeyStore for LoginKey {
    fn adb_public_key(&self) -> Result<String> {
        let der = self
            .0
            .public_key()
            .and_then(|key| key.external_representation())
            .ok_or_else(|| key_error("cannot export the RSA public key"))?;
        key::encode_public_key(der.bytes())
            .ok_or_else(|| key_error("expected a DER RSA-2048 public key"))
    }

    fn sign(&self, token: &[u8]) -> Result<Vec<u8>> {
        if token.len() != 20 {
            return Err(key_error("invalid SHA-1 digest length"));
        }
        self.0
            .create_signature(Algorithm::RSASignatureDigestPKCS1v15SHA1, token)
            .map_err(key_error)
    }
}

fn key_error(error: impl std::fmt::Display) -> Error {
    Error::Key(error.to_string())
}
