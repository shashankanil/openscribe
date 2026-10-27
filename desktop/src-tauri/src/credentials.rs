const SERVICE: &str = "org.open-source.openscribe";

pub fn save(account: &str, secret: &str) -> Result<(), String> {
    let entry = keyring::Entry::new(SERVICE, account).map_err(|error| error.to_string())?;
    entry
        .set_password(secret)
        .map_err(|error| error.to_string())
}

pub fn read(account: &str) -> Result<Option<String>, String> {
    let entry = keyring::Entry::new(SERVICE, account).map_err(|error| error.to_string())?;
    match entry.get_password() {
        // A blank entry counts as no key, so callers report "add your key" instead of a 401.
        Ok(secret) => Ok(Some(secret.trim().to_string()).filter(|secret| !secret.is_empty())),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

pub fn copy(from: &str, to: &str) -> Result<(), String> {
    let secret = read(from)?.ok_or("There is no saved key to reuse.")?;
    save(to, &secret)
}

pub fn remove(account: &str) -> Result<(), String> {
    let entry = keyring::Entry::new(SERVICE, account).map_err(|error| error.to_string())?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(error.to_string()),
    }
}
