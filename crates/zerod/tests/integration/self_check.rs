//! zerod's own state, for the app's Health checks: who started it, whether the files it makes are quarantined, how
//! many descriptors it holds against its limit, and whether its build on disk has been replaced since it started.

use crate::common::temp_dir;

#[test]
fn a_self_check_says_who_started_zerod_and_what_it_holds() {
    let home = temp_dir("self-check");
    let check = zerod::self_check::report(&home);
    assert_eq!(check["pid"], std::process::id());
    assert_eq!(check["parent"]["pid"], std::os::unix::process::parent_id());
    assert!(check["parent"]["path"].as_str().is_some_and(|p| p.starts_with('/')), "{check}");
    let (open, limit) = (check["descriptors"]["open"].as_u64().unwrap(), check["descriptors"]["limit"].as_u64().unwrap());
    assert!(open > 2 && open <= limit, "{check}");
    assert!(check["quarantined"].is_boolean());
    assert!(!home.join("quarantine-probe").exists(), "the probe is cleaned up");
    assert_eq!(check["exe"], std::env::current_exe().unwrap().to_str().unwrap());
    assert_eq!(check["replaced"], false);
}

#[test]
fn a_build_rewritten_unchanged_is_not_replaced() {
    use std::time::{Duration, SystemTime};
    let path = temp_dir("self-check-build").join("zerod");
    std::fs::write(&path, b"build one").unwrap();
    let was = zerod::self_check::fingerprint(&path);
    assert!(!zerod::self_check::replaced(&path, was));
    // An install that copies the same build again: a newer date, the same bytes.
    std::fs::write(&path, b"build one").unwrap();
    let later = SystemTime::now() + Duration::from_secs(60);
    std::fs::File::options().write(true).open(&path).unwrap().set_modified(later).unwrap();
    assert!(!zerod::self_check::replaced(&path, was), "same bytes, newer date");
    std::fs::write(&path, b"build two").unwrap();
    assert!(zerod::self_check::replaced(&path, was), "another build");
    std::fs::remove_file(&path).unwrap();
    assert!(zerod::self_check::replaced(&path, was), "gone");
}

/// A Mach-O with only its header and an LC_UUID, then `signature`: what codesign appends and rewrites at each install.
fn mach_o(uuid: u8, signature: &[u8]) -> Vec<u8> {
    let mut bytes = Vec::new();
    for word in [0xfeed_facf_u32, 0x0100_000c, 0, 2, 1, 24, 0, 0] {
        bytes.extend(word.to_le_bytes());
    }
    bytes.extend(0x1b_u32.to_le_bytes());
    bytes.extend(24_u32.to_le_bytes());
    bytes.extend([uuid; 16]);
    bytes.extend(signature);
    bytes
}

#[test]
fn a_build_signed_again_is_not_replaced() {
    let path = temp_dir("self-check-signed").join("zerod");
    std::fs::write(&path, mach_o(1, b"signed at 18:00")).unwrap();
    let was = zerod::self_check::fingerprint(&path);
    // Each install signs the same build again: its signature's time differs, its build (LC_UUID) doesn't.
    std::fs::write(&path, mach_o(1, b"signed at 18:18")).unwrap();
    let later = std::time::SystemTime::now() + std::time::Duration::from_secs(60);
    std::fs::File::options().write(true).open(&path).unwrap().set_modified(later).unwrap();
    assert!(!zerod::self_check::replaced(&path, was), "the same build, signed again");
    std::fs::write(&path, mach_o(2, b"signed at 18:18")).unwrap();
    assert!(zerod::self_check::replaced(&path, was), "another build");
}
