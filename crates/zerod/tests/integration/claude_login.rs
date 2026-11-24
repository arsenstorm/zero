//! Signing a Claude account in through Claude Code's own `claude auth login`, in a folder of that account's own:
//! Claude Code opens its page and keeps the sign-in; Zero reads back who signed in from `claude auth status`.

use zerod::claude_login::{Commands, sign_in, usage};

fn sh(script: &str) -> Vec<String> {
    vec!["/bin/sh".into(), "-c".into(), script.into()]
}

#[tokio::test]
async fn a_claude_sign_in_passes_its_page_on_then_reads_who_signed_in() {
    let commands = Commands {
        login: sh(
            "echo 'Opening browser to sign in…'; echo 'If it does not open: https://claude.ai/oauth/authorize?code=true&x=1'; sleep 0.2",
        ),
        status: sh(r#"echo '{"loggedIn": true, "email": "a@example.com", "subscriptionType": "max"}'"#),
    };
    let (page, opened) = tokio::sync::oneshot::channel();
    let account = sign_in(&commands, &[], page).await.unwrap();
    assert_eq!(
        opened.await.unwrap().as_deref(),
        Some("https://claude.ai/oauth/authorize?code=true&x=1"),
        "its page, in case the browser didn't open"
    );
    assert_eq!((account.email.as_deref(), account.plan.as_deref()), (Some("a@example.com"), Some("max")));
}

#[tokio::test]
async fn a_sign_in_that_didnt_finish_says_so() {
    let commands = Commands { login: sh("echo 'Login cancelled'; exit 1"), status: sh(r#"echo '{"loggedIn": false}'"#) };
    let (page, _opened) = tokio::sync::oneshot::channel();
    assert_eq!(sign_in(&commands, &[], page).await.unwrap_err(), "Claude Code didn't sign in");
}

#[tokio::test]
async fn an_accounts_usage_is_asked_of_claude_code_without_a_turn() {
    // As Claude Code 2.1.319 answers `get_usage`: percentages, and resets as ISO dates. A window it has no figure for
    // (null) isn't one.
    let answer = r#"{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":100,"resets_at":"2026-11-06T14:00:00.5+00:00"},"seven_day":{"utilization":58,"resets_at":"2026-11-09T10:00:00.121844+00:00"},"seven_day_opus":null}}}}"#;
    let script = format!(
        "read request; case \"$request\" in *skip_behaviors*get_usage*) echo '{{\"type\":\"system\",\"subtype\":\"init\"}}'; echo '{answer}';; esac; sleep 5"
    );
    let usage = usage(&sh(&script), &[]).await.unwrap();
    let windows: Vec<_> = usage.windows.iter().map(|w| (w.name.as_str(), w.used, w.resets_at)).collect();
    assert_eq!(windows, [("5 hours", 1.0, Some(1793973600)), ("7 days", 0.58, Some(1794218400))]);
    assert!(usage.limited, "a window used up");
    assert_eq!(usage.resets_at, Some(1793973600));
}

/// A limit the plan sets one model (`limits`, scoped to it) is a window of that model's.
#[tokio::test]
async fn a_limit_on_one_model_is_that_models_window() {
    let answer = serde_json::json!({
        "type": "control_response", "response": {
            "subtype": "success", "request_id": "usage", "response": {
                "subscription_type": "max", "rate_limits_available": true,
                "rate_limits": {
                    "five_hour": null, "seven_day": {"utilization": 70, "resets_at": "2026-11-30T09:59:59+00:00"},
                    "limits": [
                        {"kind": "weekly_all", "group": "weekly", "percent": 70, "resets_at": "2026-11-30T09:59:59+00:00", "scope": null},
                        {"kind": "weekly_scoped", "group": "weekly", "percent": 100, "resets_at": "2026-11-30T09:59:59+00:00",
                         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
                    ]
                }
            }
        }
    });
    let script = format!("read request; echo '{answer}'; sleep 5");
    let usage = usage(&sh(&script), &[]).await.unwrap();
    assert!(!usage.limited, "the account isn't");
    let windows: Vec<_> = usage.windows.iter().map(|w| (w.name.as_str(), w.used, w.model.as_deref())).collect();
    assert_eq!(windows, [("7 days", 0.7, None), ("7 days · Fable", 1.0, Some("fable"))]);
}

#[tokio::test]
async fn a_weekly_only_plan_has_no_five_hour_limit() {
    let answer = serde_json::json!({
        "type": "control_response", "response": {
            "subtype": "success", "request_id": "usage", "response": {
                "subscription_type": "max", "rate_limits_available": true,
                "rate_limits": {"five_hour": null, "seven_day": {"utilization": 3, "resets_at": "2026-11-23T10:00:00+00:00"}}
            }
        }
    });
    let script = format!("read request; echo '{answer}'; sleep 5");
    let usage = usage(&sh(&script), &[]).await.unwrap();
    assert!(!usage.limited);
    assert_eq!(usage.resets_at, None);
    assert_eq!(usage.windows.len(), 1);
    assert_eq!((usage.windows[0].name.as_str(), usage.windows[0].used), ("7 days", 0.03));
}

/// An account whose plan has no windows (an API-billed one) says so through `get_usage`: no plan limits, rather than
/// nothing known.
#[tokio::test]
async fn an_account_without_plan_limits_says_so() {
    let answer = r#"{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}}}"#;
    let script = format!("read request; echo '{answer}'; sleep 5");
    let usage = usage(&sh(&script), &[]).await.unwrap();
    assert!(usage.no_limits && usage.windows.is_empty() && !usage.limited);
}

/// Claude Code's own model list for an account, as its `/model` picker has it: asked with `initialize`, no turn.
#[tokio::test]
async fn an_accounts_models_are_asked_of_claude_code_without_a_turn() {
    let answer = r#"{"type":"control_response","response":{"subtype":"success","request_id":"models","response":{"commands":[],"models":[{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","description":"Opus 5.5 · Best for everyday, complex tasks"},{"value":"claude-opus-4-8","displayName":"Opus 4.8","description":"Best for everyday, complex tasks","supportedEffortLevels":["low","high"]}],"claude_code_version":"2.1.323"}}}"#;
    let script =
        format!("read request; case \"$request\" in *initialize*) echo '{{\"type\":\"system\"}}'; echo '{answer}';; esac; sleep 5");
    let models = zerod::claude_login::models(&sh(&script), &[]).await.unwrap();
    let values: Vec<_> = models.iter().map(|m| m["value"].as_str().unwrap()).collect();
    assert_eq!(values, ["default", "claude-opus-4-8"]);
    assert_eq!(models[1]["supportedEffortLevels"], serde_json::json!(["low", "high"]));
}

/// Claude Code that has answered is left to finish on its own, its input closed, never killed: it may be renewing the
/// account's sign-in, and killed between Anthropic's new refresh token and its write to the Keychain, the account is
/// signed out for good (the old token no longer works).
#[tokio::test]
async fn claude_code_that_has_answered_finishes_on_its_own() {
    let finished = std::env::temp_dir().join(format!("zerod-claude-finished-{}", std::process::id()));
    let _ = std::fs::remove_file(&finished);
    let answer = r#"{"type":"control_response","response":{"subtype":"success","request_id":"models","response":{"models":[]}}}"#;
    let script = format!("read request; echo '{answer}'; while read more; do :; done; sleep 0.3; touch '{}'", finished.display());
    zerod::claude_login::models(&sh(&script), &[]).await.unwrap();
    for _ in 0..40 {
        if finished.exists() {
            let _ = std::fs::remove_file(&finished);
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("Claude Code was killed after it answered");
}
