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
