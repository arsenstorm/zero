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
