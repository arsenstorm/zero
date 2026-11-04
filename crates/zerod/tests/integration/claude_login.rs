//! Signing a Claude account in through Claude Code's own `claude auth login`, in a folder of that account's own:
//! Claude Code opens its page and keeps the sign-in; Zero reads back who signed in from `claude auth status`.

use zerod::claude_login::{Commands, sign_in};

fn sh(script: &str) -> Vec<String> { vec!["/bin/sh".into(), "-c".into(), script.into()] }

#[tokio::test]
async fn a_claude_sign_in_passes_its_page_on_then_reads_who_signed_in() {
    let commands = Commands {
        login: sh("echo 'Opening browser to sign in…'; echo 'If it does not open: https://claude.ai/oauth/authorize?code=true&x=1'; sleep 0.2"),
        status: sh(r#"echo '{"loggedIn": true, "email": "a@example.com", "subscriptionType": "max"}'"#),
    };
    let (page, opened) = tokio::sync::oneshot::channel();
    let account = sign_in(&commands, &[], page).await.unwrap();
    assert_eq!(opened.await.unwrap().as_deref(), Some("https://claude.ai/oauth/authorize?code=true&x=1"), "its page, in case the browser didn't open");
    assert_eq!((account.email.as_deref(), account.plan.as_deref()), (Some("a@example.com"), Some("max")));
}

#[tokio::test]
async fn a_sign_in_that_didnt_finish_says_so() {
    let commands = Commands { login: sh("echo 'Login cancelled'; exit 1"), status: sh(r#"echo '{"loggedIn": false}'"#) };
    let (page, _opened) = tokio::sync::oneshot::channel();
    assert_eq!(sign_in(&commands, &[], page).await.unwrap_err(), "Claude Code didn't sign in");
}
