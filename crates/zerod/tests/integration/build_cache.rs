//! Settings › Shared build cache: off unless the user turns it on; on, every CLI zerod starts compiles through the
//! compiler caches the user has (sccache for Rust, ccache for C/C++ built with CMake), so agents' worktrees of one
//! repo share their compiled dependencies instead of each building from cold.

use std::path::PathBuf;

#[test]
fn agents_share_a_compile_cache_only_when_the_user_turns_it_on_and_has_the_tool() {
    let both = |name: &str| Some(PathBuf::from(format!("/opt/bin/{name}")));
    let neither = |_: &str| None;
    let get = |vars: &[(String, String)], key: &str| vars.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone());

    let on = zerod::build_cache::variables(true, both);
    assert_eq!(get(&on, "RUSTC_WRAPPER").as_deref(), Some("/opt/bin/sccache"));
    assert_eq!(get(&on, "CMAKE_C_COMPILER_LAUNCHER").as_deref(), Some("/opt/bin/ccache"));
    assert_eq!(get(&on, "CMAKE_CXX_COMPILER_LAUNCHER").as_deref(), Some("/opt/bin/ccache"));
    assert!(zerod::build_cache::variables(false, both).is_empty(), "off, nothing");
    assert!(zerod::build_cache::variables(true, neither).is_empty(), "on without the tools, nothing that would break a build");

    // What the settings show: each supported tool and whether it's installed.
    let tools = zerod::build_cache::tools(|name: &str| (name == "ccache").then(|| PathBuf::from("/opt/bin/ccache")));
    assert_eq!(
        tools,
        serde_json::json!([
            {"tool": "sccache", "for": "Rust", "found": false},
            {"tool": "ccache", "for": "C and C++ (CMake)", "found": true},
        ])
    );

    // Kept as a setting, read as each process starts.
    let setting = |v: serde_json::Value| serde_json::from_value::<zerod::server::Settings>(v).unwrap().shares_build_cache();
    assert!(!setting(serde_json::json!({})), "off by default");
    assert!(setting(serde_json::json!({"buildCache": true})));

    let wrapper = || zerod::process::environment(std::iter::empty(), "s1").into_iter().any(|(k, _)| k == "RUSTC_WRAPPER");
    zerod::build_cache::set(false);
    assert!(!wrapper(), "off, the CLIs build as they would by hand");
    zerod::build_cache::set(true);
    assert_eq!(wrapper(), zerod::build_cache::environment().iter().any(|(k, _)| k == "RUSTC_WRAPPER"), "on, what this Mac has is passed");
    zerod::build_cache::set(false);
}
