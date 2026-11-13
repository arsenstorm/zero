//! What only zerod reads: the integrations' tokens (Slack, Linear) and the switches that let agents write through them.
//! The user's zerod keeps them in a Keychain item of its own, written with the Security framework, so the item trusts
//! zerod's code alone (its designated requirement: its identifier and team, which new builds keep). Any other process
//! of the user's, an agent's `security find-generic-password` or curl script among them, gets the Keychain's prompt for
//! the login password, which the user can deny; nothing is read without it. A zerod on another home (tests, a copy run
//! by hand) keeps its own in a file there.

use std::ffi::c_void;
use std::path::{Path, PathBuf};

/// The Keychain item: what its prompt names.
const SERVICE: &str = "Zero integrations";
const ACCOUNT: &str = "zerod";

pub enum Vault {
    /// zerod's Keychain item: in the user's keychains, or (a test) in the keychain file given.
    Keychain(Option<PathBuf>),
    /// A file readable by the user alone.
    File(PathBuf),
}

impl Vault {
    pub fn read(&self) -> Result<Option<Vec<u8>>, String> {
        match self {
            Vault::Keychain(keychain) => keychain_read(keychain.as_deref()),
            Vault::File(file) => match std::fs::read(file) {
                Ok(data) => Ok(Some(data)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(e) => Err(e.to_string()),
            },
        }
    }

    pub fn write(&self, data: &[u8]) -> Result<(), String> {
        match self {
            Vault::Keychain(keychain) => keychain_write(keychain.as_deref(), data),
            Vault::File(file) => crate::integrations::write_private(file, data),
        }
    }
}

/// The Keychain fails rather than prompting, for this process (a test of the Keychain item, which mustn't show the
/// user a dialog).
pub fn no_prompts() {
    unsafe { SecKeychainSetUserInteractionAllowed(0) };
}

pub(crate) type CFTypeRef = *const c_void;

/// A Core Foundation object this code owns: released when dropped.
pub(crate) struct Cf(pub CFTypeRef);

impl Drop for Cf {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CFRelease(self.0) }
        }
    }
}

const UTF8: u32 = 0x0800_0100;
const NOT_FOUND: i32 = -25300;

pub(crate) fn string(text: &str) -> Cf {
    Cf(unsafe { CFStringCreateWithBytes(std::ptr::null(), text.as_ptr(), text.len() as isize, UTF8, 0) })
}

pub(crate) fn data(bytes: &[u8]) -> Cf {
    Cf(unsafe { CFDataCreate(std::ptr::null(), bytes.as_ptr(), bytes.len() as isize) })
}

pub(crate) fn dictionary(pairs: &[(CFTypeRef, CFTypeRef)]) -> Cf {
    let (keys, values): (Vec<_>, Vec<_>) = pairs.iter().copied().unzip();
    Cf(unsafe {
        CFDictionaryCreate(
            std::ptr::null(),
            keys.as_ptr(),
            values.as_ptr(),
            pairs.len() as isize,
            &raw const kCFTypeDictionaryKeyCallBacks,
            &raw const kCFTypeDictionaryValueCallBacks,
        )
    })
}

/// A CFString's text.
pub(crate) fn text(string: CFTypeRef) -> Option<String> {
    let mut buffer = vec![0u8; 256];
    (!string.is_null() && unsafe { CFStringGetCString(string, buffer.as_mut_ptr().cast(), buffer.len() as isize, UTF8) } != 0)
        .then(|| String::from_utf8_lossy(&buffer[..buffer.iter().position(|b| *b == 0).unwrap_or(0)]).to_string())
}

/// The item's query: by service and account, in the keychain given (or the user's own).
fn with_item<T>(
    keychain: Option<&Path>, more: &[(CFTypeRef, CFTypeRef)], body: impl FnOnce(CFTypeRef, CFTypeRef) -> T,
) -> Result<T, String> {
    let (service, account) = (string(SERVICE), string(ACCOUNT));
    let opened = match keychain {
        Some(path) => {
            let path = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).map_err(|e| e.to_string())?;
            let mut opened = std::ptr::null();
            let status = unsafe { SecKeychainOpen(path.as_ptr(), &mut opened) };
            if status != 0 {
                return Err(format!("the keychain didn't open ({status})"));
            }
            Some(Cf(opened))
        }
        None => None,
    };
    let list = opened.as_ref().map(|k| Cf(unsafe { CFArrayCreate(std::ptr::null(), &k.0, 1, &raw const kCFTypeArrayCallBacks) }));
    unsafe {
        let mut pairs = vec![(kSecClass, kSecClassGenericPassword), (kSecAttrService, service.0), (kSecAttrAccount, account.0)];
        pairs.extend_from_slice(more);
        // Where to look (a search list) and where a new item goes (a keychain) are separate keys.
        let mut search = pairs.clone();
        if let Some(list) = &list {
            search.push((kSecMatchSearchList, list.0))
        }
        let search = dictionary(&search);
        let mut add = pairs;
        if let Some(keychain) = &opened {
            add.push((kSecUseKeychain, keychain.0))
        }
        let add = dictionary(&add);
        Ok(body(search.0, add.0))
    }
}

fn keychain_read(keychain: Option<&Path>) -> Result<Option<Vec<u8>>, String> {
    let status_and_data = with_item(keychain, &unsafe { [(kSecReturnData, kCFBooleanTrue)] }, |query, _| {
        let mut found = std::ptr::null();
        let status = unsafe { SecItemCopyMatching(query, &mut found) };
        let found = Cf(found);
        let bytes = (status == 0 && !found.0.is_null())
            .then(|| unsafe { std::slice::from_raw_parts(CFDataGetBytePtr(found.0), CFDataGetLength(found.0) as usize).to_vec() });
        (status, bytes)
    })?;
    match status_and_data {
        (0, bytes) => Ok(bytes),
        (NOT_FOUND, _) => Ok(None),
        (status, _) => Err(format!("the Keychain refused zerod its item ({status})")),
    }
}

/// Updated in place, so the item keeps the access it was made with; made, the first time, trusting zerod alone (the
/// Security framework's default for an item a program adds: the program, and its team's partition).
fn keychain_write(keychain: Option<&Path>, bytes: &[u8]) -> Result<(), String> {
    let value = data(bytes);
    let label = string(SERVICE);
    let status = with_item(keychain, &[], |query, _| {
        let change = dictionary(&unsafe { [(kSecValueData, value.0)] });
        unsafe { SecItemUpdate(query, change.0) }
    })?;
    let status = match status {
        NOT_FOUND => with_item(keychain, &unsafe { [(kSecValueData, value.0), (kSecAttrLabel, label.0)] }, |_, add| unsafe {
            SecItemAdd(add, std::ptr::null_mut())
        })?,
        status => status,
    };
    if status == 0 { Ok(()) } else { Err(format!("the Keychain didn't keep zerod's item ({status})")) }
}

#[repr(C)]
pub(crate) struct Callbacks {
    _private: [u8; 0],
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFTypeDictionaryKeyCallBacks: Callbacks;
    static kCFTypeDictionaryValueCallBacks: Callbacks;
    static kCFTypeArrayCallBacks: Callbacks;
    static kCFBooleanTrue: CFTypeRef;
    fn CFRelease(object: CFTypeRef);
    fn CFStringCreateWithBytes(allocator: CFTypeRef, bytes: *const u8, length: isize, encoding: u32, external: u8) -> CFTypeRef;
    fn CFStringGetCString(string: CFTypeRef, buffer: *mut i8, size: isize, encoding: u32) -> u8;
    fn CFDataCreate(allocator: CFTypeRef, bytes: *const u8, length: isize) -> CFTypeRef;
    fn CFDataGetBytePtr(data: CFTypeRef) -> *const u8;
    fn CFDataGetLength(data: CFTypeRef) -> isize;
    fn CFArrayCreate(allocator: CFTypeRef, values: *const CFTypeRef, count: isize, callbacks: *const Callbacks) -> CFTypeRef;
    fn CFDictionaryCreate(
        allocator: CFTypeRef, keys: *const CFTypeRef, values: *const CFTypeRef, count: isize, key_callbacks: *const Callbacks,
        value_callbacks: *const Callbacks,
    ) -> CFTypeRef;
    pub(crate) fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
}

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    static kSecClass: CFTypeRef;
    static kSecClassGenericPassword: CFTypeRef;
    static kSecAttrService: CFTypeRef;
    static kSecAttrAccount: CFTypeRef;
    static kSecAttrLabel: CFTypeRef;
    static kSecValueData: CFTypeRef;
    static kSecReturnData: CFTypeRef;
    static kSecMatchSearchList: CFTypeRef;
    static kSecUseKeychain: CFTypeRef;
    fn SecItemCopyMatching(query: CFTypeRef, result: *mut CFTypeRef) -> i32;
    fn SecItemUpdate(query: CFTypeRef, change: CFTypeRef) -> i32;
    fn SecItemAdd(attributes: CFTypeRef, result: *mut CFTypeRef) -> i32;
    fn SecKeychainOpen(path: *const std::ffi::c_char, keychain: *mut CFTypeRef) -> i32;
    fn SecKeychainSetUserInteractionAllowed(allowed: u8) -> i32;
}
