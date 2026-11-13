//! Who is at the other end of a zerod.sock connection: Zero.app, by its code signature, or anything else. Answering
//! the user's asks, changing settings, sign-ins and connections are the app's alone (server.rs, APP_ONLY): an agent
//! running as the same user can connect to the socket, but can't make its connection Zero.app's.

use std::ffi::c_void;

use crate::vault::{CFDictionaryGetValue, CFTypeRef, Cf, data, dictionary, string, text};

/// Zero.app's identifier, as it's signed.
const APP: &str = "com.arsen.zero";

/// The audit token of a Unix socket's peer (its pid is the sixth word): what the kernel says, not what the peer does.
pub fn audit_token(fd: std::os::fd::RawFd) -> Option<[u32; 8]> {
    // <sys/un.h>: SOL_LOCAL, LOCAL_PEERTOKEN.
    const SOL_LOCAL: i32 = 0;
    const LOCAL_PEERTOKEN: i32 = 6;
    let mut token = [0u32; 8];
    let mut length = std::mem::size_of_val(&token) as u32;
    let read = unsafe { getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, token.as_mut_ptr().cast(), &mut length) };
    (read == 0 && length as usize == std::mem::size_of_val(&token)).then_some(token)
}

/// Whether the process with this audit token is Zero.app: valid code signed by zerod's own team, as the app's
/// identifier. Checked on the running process, so a copy re-signed by anyone else, or a process that isn't the app,
/// fails.
pub fn is_zero_app(token: Option<[u32; 8]>) -> bool {
    let Some(token) = token else { return false };
    let bytes: Vec<u8> = token.iter().flat_map(|word| word.to_ne_bytes()).collect();
    let audit = data(&bytes);
    let attributes = dictionary(&unsafe { [(kSecGuestAttributeAudit, audit.0)] });
    let mut code = std::ptr::null();
    if unsafe { SecCodeCopyGuestWithAttributes(std::ptr::null(), attributes.0, 0, &mut code) } != 0 {
        return false;
    }
    let code = Cf(code);
    let mut requirement = std::ptr::null();
    if unsafe { SecRequirementCreateWithString(string(app_requirement()).0, 0, &mut requirement) } != 0 {
        return false;
    }
    let requirement = Cf(requirement);
    unsafe { SecCodeCheckValidity(code.0, 0, requirement.0) == 0 }
}

/// What the app's signature must meet: Apple's chain to zerod's own team, and the app's identifier.
fn app_requirement() -> &'static str {
    static REQUIREMENT: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    REQUIREMENT.get_or_init(|| match own_team() {
        Some(team) => format!("anchor apple generic and certificate leaf[subject.OU] = \"{team}\" and identifier \"{APP}\""),
        // ponytail: an unsigned zerod (built from source and run by hand) has no team to hold the app to, so the
        // identifier alone, which anyone can sign with; the builds `make` signs always have one.
        None => format!("identifier \"{APP}\""),
    })
}

/// The team zerod itself is signed by; none when it isn't.
fn own_team() -> Option<String> {
    // <Security/SecCode.h>: kSecCSSigningInformation.
    const SIGNING_INFORMATION: u32 = 1 << 1;
    let mut me = std::ptr::null();
    if unsafe { SecCodeCopySelf(0, &mut me) } != 0 {
        return None;
    }
    let me = Cf(me);
    let mut info = std::ptr::null();
    if unsafe { SecCodeCopySigningInformation(me.0, SIGNING_INFORMATION, &mut info) } != 0 {
        return None;
    }
    let info = Cf(info);
    text(unsafe { CFDictionaryGetValue(info.0, kSecCodeInfoTeamIdentifier) }).filter(|team| !team.is_empty())
}

unsafe extern "C" {
    fn getsockopt(socket: i32, level: i32, name: i32, value: *mut c_void, length: *mut u32) -> i32;
}

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    static kSecGuestAttributeAudit: CFTypeRef;
    static kSecCodeInfoTeamIdentifier: CFTypeRef;
    fn SecCodeCopyGuestWithAttributes(host: CFTypeRef, attributes: CFTypeRef, flags: u32, guest: *mut CFTypeRef) -> i32;
    fn SecRequirementCreateWithString(text: CFTypeRef, flags: u32, requirement: *mut CFTypeRef) -> i32;
    fn SecCodeCheckValidity(code: CFTypeRef, flags: u32, requirement: CFTypeRef) -> i32;
    fn SecCodeCopySelf(flags: u32, me: *mut CFTypeRef) -> i32;
    fn SecCodeCopySigningInformation(code: CFTypeRef, flags: u32, information: *mut CFTypeRef) -> i32;
}
