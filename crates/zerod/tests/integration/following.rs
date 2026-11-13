//! Following: a session follows a pull request, an issue or a thread; zerod polls it and tells the session what
//! changed between its turns, so an agent that ended its turn is woken by a review or a reply.

use std::sync::{Arc, Mutex};

use crate::common::temp_dir;
use serde_json::{Value, json};
use zerod::following::*;
use zerod::integrations::{Fetcher, Integrations};
use zerod::model::ItemKind;

#[derive(Default)]
struct Canned {
    answers: Mutex<Vec<Result<String, String>>>,
    asked: Mutex<Vec<Vec<String>>>,
    fed: Mutex<Vec<String>>,
}

impl Fetcher for Canned {
    fn run(&self, argv: Vec<String>, stdin: Option<String>) -> zerod::inbox::Fut<'_, Result<String, String>> {
        self.asked.lock().unwrap().push(argv);
        self.fed.lock().unwrap().push(stdin.unwrap_or_default());
        let answer = {
            let mut answers = self.answers.lock().unwrap();
            if answers.is_empty() { Err("nothing canned".to_string()) } else { answers.remove(0) }
        };
        Box::pin(async move { answer })
    }
}

fn canned(answers: Vec<Result<Value, &str>>) -> Arc<Canned> {
    Arc::new(Canned {
        answers: Mutex::new(answers.into_iter().map(|a| a.map(|v| v.to_string()).map_err(String::from)).collect()),
        ..Default::default()
    })
}

fn open(name: &str, fetcher: Arc<Canned>) -> Arc<Following> {
    let home = temp_dir(name);
    Following::open(&home, fetcher.clone(), Integrations::open(&home, fetcher))
}

/// A pull request as gh answers, with the comments, reviews, checks and commits given.
fn pr(
    comments: Vec<(&str, &str, &str)>, reviews: Vec<(&str, &str, &str, &str)>, checks: Vec<(&str, &str)>, head: &str, state: &str,
) -> Value {
    json!({"data": {"viewer": {"login": "arsen"}, "repository": {"pullRequest": {
        "title": "Fix vitals", "url": "https://github.com/o/r/pull/42", "state": state, "isDraft": false, "body": "Fixes the vitals chart.",
        "baseRefName": "main", "headRefName": "fix-vitals", "headRefOid": head, "mergeable": "MERGEABLE", "reviewDecision": null,
        "author": {"login": "arsen"}, "mergedBy": null, "assignees": {"nodes": []}, "labels": {"nodes": [{"name": "bug"}]}, "reviewRequests": {"nodes": []},
        "comments": {"nodes": comments.iter().map(|(id, who, body)| json!({"id": id, "author": {"login": who}, "body": body, "url": format!("https://github.com/o/r/pull/42#issuecomment-{id}"), "createdAt": "2026-10-31T10:00:00Z", "updatedAt": "2026-10-31T10:00:00Z"})).collect::<Vec<_>>()},
        "reviews": {"nodes": reviews.iter().map(|(id, who, state, body)| json!({"id": id, "author": {"login": who}, "state": state, "body": body, "url": format!("https://github.com/o/r/pull/42#pullrequestreview-{id}"), "submittedAt": "2026-10-31T10:00:00Z", "updatedAt": "2026-10-31T10:00:00Z"})).collect::<Vec<_>>()},
        "reviewThreads": {"nodes": []},
        "commits": {"totalCount": 1, "nodes": [{"commit": {"oid": head, "messageHeadline": "Fix vitals", "statusCheckRollup": {
            "state": if checks.iter().any(|(_, s)| *s == "FAILURE") { "FAILURE" } else if checks.is_empty() { "PENDING" } else { "SUCCESS" },
            "contexts": {"nodes": checks.iter().map(|(name, s)| json!({"__typename": "CheckRun", "name": name, "status": "COMPLETED", "conclusion": s, "detailsUrl": format!("https://ci/{name}")})).collect::<Vec<_>>()}}}}]}
    }}}})
}

#[test]
fn urls_and_topics_come_out_canonical() {
    assert_eq!(topic("https://github.com/acme/app/pull/42").unwrap(), "github/acme/app/42");
    assert_eq!(topic("https://github.com/o/r/pull/42/files#diff-abc").unwrap(), "github/o/r/42");
    assert_eq!(topic("github/O/R/pull/7").unwrap(), "github/o/r/7");
    assert_eq!(topic("https://linear.app/acme/issue/eng-9686/some-title#comment-abcd1234").unwrap(), "linear/ENG-9686/abcd1234");
    assert_eq!(topic("https://linear.app/acme/issue/ENG-9686/some-title").unwrap(), "linear/ENG-9686");
    assert_eq!(topic("linear/web-12").unwrap(), "linear/WEB-12");
    assert_eq!(
        topic("https://acme.slack.com/archives/C0123ABCD/p1712345678123456?thread_ts=1712345000.000100&cid=C0123ABCD").unwrap(),
        "slack/C0123ABCD/1712345000.000100"
    );
    assert_eq!(topic("https://acme.slack.com/archives/C0123ABCD/p1712345678123456").unwrap(), "slack/C0123ABCD/1712345678.123456");
    assert_eq!(topic("https://acme.slack.com/archives/C0123ABCD").unwrap(), "slack/C0123ABCD");
    assert_eq!(topic("slack/c0123abcd/p1712345678123456").unwrap(), "slack/C0123ABCD/1712345678.123456");
    assert!(topic("slack/C0123ABCD/17123").is_err());
    assert!(topic("https://github.com/o/r/issues/4").is_err());
    assert!(topic("gitlab/o/r/4").unwrap_err().contains("Not a topic"));
    assert!(topic("github/o/r").is_err());
}

#[test]
fn a_pull_requests_changes_become_events() {
    let before = github::snapshot(&pr(vec![("c1", "arsen", "First")], vec![], vec![("specs", "SUCCESS")], "aaa", "OPEN")["data"]).unwrap();
    let after = github::snapshot(
        &pr(
            vec![("c1", "arsen", "First"), ("c2", "sam", "Looks off on mobile")],
            vec![("r1", "sam", "APPROVED", "LGTM")],
            vec![("specs", "FAILURE"), ("lint", "SUCCESS")],
            "aaa",
            "OPEN",
        )["data"],
    )
    .unwrap();
    let events = github::diff(&before, &after, "github/o/r/42");
    let seen: Vec<(&str, &str)> = events.iter().map(|e| (e.kind.as_str(), e.summary.as_str())).collect();
    assert_eq!(
        seen,
        [
            ("check_failed", "check failed: specs (failure)"),
            ("checks", "CI failure: 1 passed, 1 failed, 2 total"),
            ("comment", "comment by @sam"),
            ("review", "review by @sam: approved"),
        ]
    );
    assert_eq!(
        (events[2].body.as_str(), events[2].url.as_str(), events[2].mine),
        ("Looks off on mobile", "https://github.com/o/r/pull/42#issuecomment-c2", false)
    );
    assert_eq!(github::describe(&after), "Fix vitals (open) https://github.com/o/r/pull/42");
    // The same reading again: nothing new.
    assert!(github::diff(&after, &after, "github/o/r/42").is_empty());
    // Merged, by the viewer.
    let mut merged = after.clone();
    merged["state"] = json!("MERGED");
    merged["merged_by"] = json!("arsen");
    let events = github::diff(&after, &merged, "github/o/r/42");
    assert_eq!((events[0].summary.as_str(), events[0].mine), ("PR merged into main by @arsen", true));
}

#[tokio::test]
async fn following_a_pull_request_reads_it_through_gh_and_tells_the_session_what_changes() {
    let fetcher = canned(vec![
        Ok(pr(vec![("c1", "arsen", "First")], vec![], vec![], "aaa", "OPEN")),
        Ok(pr(vec![("c1", "arsen", "First"), ("c2", "sam", "Looks off on mobile")], vec![], vec![], "aaa", "OPEN")),
        Ok(pr(vec![("c1", "arsen", "First"), ("c2", "sam", "Looks off on mobile")], vec![], vec![], "aaa", "OPEN")),
    ]);
    let home = temp_dir("following-gh");
    let following = Following::open(&home, fetcher.clone(), Integrations::open(&home, fetcher.clone()));
    let followed = following.follow("s1", "https://github.com/o/r/pull/42", false, vec![]).await.unwrap();
    assert_eq!(
        (followed.follow.topic.as_str(), followed.new, followed.summary.as_str()),
        ("github/o/r/42", true, "Fix vitals (open) https://github.com/o/r/pull/42")
    );
    let argv = fetcher.asked.lock().unwrap()[0].clone();
    // gh itself, on the login shell's PATH (read once), not a login shell per poll: one cost 94 ms of CPU and half a
    // second, for every poll of every pull request followed.
    assert!(!argv.contains(&"-lic".to_string()), "{argv:?}");
    let gh = argv.iter().position(|a| a == "gh").expect("runs gh");
    assert_eq!(&argv[gh..gh + 3], ["gh", "api", "graphql"]);
    assert!(
        argv.contains(&"owner=o".to_string()) && argv.contains(&"repo=r".to_string()) && argv.contains(&"number=42".to_string()),
        "{argv:?}"
    );
    // Following again is no new follow, and the fresh reading isn't read again.
    assert!(!following.follow("s1", "github/o/r/42", false, vec![]).await.unwrap().new);
    assert_eq!(fetcher.asked.lock().unwrap().len(), 1);

    let told = Arc::new(Mutex::new(vec![]));
    let tell = |session: &str, words: &str| told.lock().unwrap().push((session.to_string(), words.to_string()));
    following.tick(|_| true, |_| false, |s: &str, w: &str, _| tell(s, w)).await;
    assert!(told.lock().unwrap().is_empty(), "not due yet");
    following.hurry();
    following.tick(|_| true, |_| false, |s: &str, w: &str, _| tell(s, w)).await;
    let (session, words) = told.lock().unwrap()[0].clone();
    assert_eq!(session, "s1");
    assert_eq!(
        words,
        "1 new event on what you follow:\n\ngithub/o/r/42  —  Fix vitals (open) https://github.com/o/r/pull/42\n  comment by @sam\n    Looks off on mobile\n    https://github.com/o/r/pull/42#issuecomment-c2"
    );
    // Nothing changed: nothing said.
    following.hurry();
    following.tick(|_| true, |_| false, |s: &str, w: &str, _| tell(s, w)).await;
    assert_eq!(told.lock().unwrap().len(), 1);
    assert_eq!(fetcher.asked.lock().unwrap().len(), 3);

    // Kept in following.json; and gone with its session.
    let again = Following::open(&home, canned(vec![]), Integrations::open(&home, canned(vec![])));
    let listed = again.list(None);
    assert_eq!((listed.len(), listed[0].follow.session.as_str(), listed[0].follow.topic.as_str()), (1, "s1", "github/o/r/42"));
    again.tick(|_| false, |_| false, |_, _, _| panic!("nothing to tell")).await;
    assert!(again.list(None).is_empty());
    let kept: Value = serde_json::from_slice(&std::fs::read(home.join("following.json")).unwrap()).unwrap();
    assert!(
        kept["follows"].as_array().unwrap().is_empty() && kept["targets"].as_object().unwrap().is_empty(),
        "nothing left to poll: {kept}"
    );
}

#[tokio::test]
async fn a_filtered_follow_hears_only_what_it_asked_for() {
    let fetcher = canned(vec![
        Ok(pr(vec![], vec![], vec![], "aaa", "OPEN")),
        Ok(pr(vec![("c1", "sam", "Deployed app#42 to production"), ("c2", "sam", "Deployed web#420 too")], vec![], vec![], "aaa", "OPEN")),
    ]);
    let following = open("following-filter", fetcher);
    following.follow("s1", "github/o/r/42", false, vec!["app#42".into()]).await.unwrap();
    following.follow("s2", "github/o/r/42", false, vec!["web".into()]).await.unwrap();
    following.follow("s3", "github/o/r/42", false, vec![]).await.unwrap();
    let told = Arc::new(Mutex::new(vec![]));
    following.hurry();
    following
        .tick(|_| true, |_| false, |session: &str, words: &str, _| told.lock().unwrap().push((session.to_string(), words.to_string())))
        .await;
    let mut told = told.lock().unwrap().clone();
    told.sort();
    assert_eq!(told.len(), 3);
    assert!(told[0].1.contains("app#42") && !told[0].1.contains("web#420"), "s1 hears its PR's comment only: {}", told[0].1);
    assert!(told[1].1.contains("web#420") && !told[1].1.contains("app#42"));
    assert!(told[2].1.starts_with("2 new events"));
    // Whole words: #42 isn't #420.
    assert!(passes(&["#42"], &["Deployed app#42"]) && !passes(&["#42"], &["Deployed #420"]));
    assert!(passes(&["Vitals"], &["the vitals chart"]) && !passes(&["vital"], &["the vitals chart"]));
}

#[tokio::test]
async fn polling_trouble_is_reported_once_and_so_is_its_end() {
    let fetcher = canned(vec![
        Ok(pr(vec![], vec![], vec![], "aaa", "OPEN")),
        Err("gh: HTTP 502"),
        Err("gh: HTTP 502"),
        Err("gh: HTTP 502"),
        Err("gh: HTTP 502"),
        Ok(pr(vec![], vec![], vec![], "aaa", "OPEN")),
    ]);
    let following = open("following-errors", fetcher);
    following.follow("s1", "github/o/r/42", false, vec![]).await.unwrap();
    let told = Arc::new(Mutex::new(vec![]));
    let tell = |_: &str, words: &str| told.lock().unwrap().push(words.to_string());
    for _ in 0..4 {
        following.hurry();
        following.tick(|_| true, |_| false, |s: &str, w: &str, _| tell(s, w)).await;
    }
    assert_eq!(told.lock().unwrap().len(), 1, "the third failure says so, the fourth doesn't again");
    assert!(told.lock().unwrap()[0].contains("polling is failing: gh: HTTP 502"));
    assert_eq!(following.list(None)[0].error.as_deref(), Some("gh: HTTP 502"));
    following.hurry();
    following.tick(|_| true, |_| false, |s: &str, w: &str, _| tell(s, w)).await;
    assert!(told.lock().unwrap()[1].contains("polling works again"));
    assert_eq!(following.list(None)[0].error, None);
}

#[tokio::test]
async fn a_pull_request_gh_cant_read_isnt_followed() {
    let following = open("following-missing", canned(vec![Err("gh: Could not resolve to a PullRequest")]));
    let error = following.follow("s1", "github/o/r/999", false, vec![]).await.unwrap_err();
    assert_eq!(error, "Can't follow github/o/r/999: gh: Could not resolve to a PullRequest");
    assert!(following.list(None).is_empty());
    assert_eq!(following.unfollow("s1", None), 0);
}

#[test]
fn a_linear_issues_changes_become_events_on_the_issue_and_its_threads() {
    let issue = |state: &str, comments: Vec<(&str, Option<&str>, &str, &str)>| {
        json!({"data": {"viewer": {"id": "me", "name": "Arsen"}, "issue": {
            "id": "iss", "identifier": "ENG-9686", "title": "Vitals chart", "description": "Line one\nLine two", "url": "https://linear.app/acme/issue/ENG-9686", "priorityLabel": "High",
            "estimate": null, "dueDate": null, "state": {"name": state}, "assignee": {"id": "me", "name": "Arsen"}, "project": {"name": "Charts"}, "cycle": null, "parent": null,
            "labels": {"nodes": [{"name": "Bug"}]},
            "comments": {"nodes": comments.iter().map(|(id, parent, who, body)| json!({"id": id, "body": body, "url": format!("https://linear.app/acme/issue/ENG-9686#comment-{}", &id[..id.len().min(8)]),
                "createdAt": format!("2026-10-31T10:0{}:00Z", comments.iter().position(|c| c.0 == *id).unwrap()), "updatedAt": "2026-10-31T10:00:00Z", "user": {"id": if *who == "Arsen" { "me" } else { "u2" }, "name": who}, "parent": parent.map(|p| json!({"id": p}))})).collect::<Vec<_>>()}
        }}})
    };
    let before = linear::poll(&issue("In Progress", vec![("abcdef0123", None, "Arsen", "On it")]), None, "linear/ENG-9686").unwrap();
    assert_eq!(before.summary, "ENG-9686: Vitals chart [In Progress] https://linear.app/acme/issue/ENG-9686");
    let after = linear::poll(
        &issue(
            "PM review",
            vec![
                ("abcdef0123", None, "Arsen", "On it"),
                ("9999999999", Some("abcdef0123"), "Lee", "Ship it"),
                ("5555555555", None, "Dana", "Tested"),
            ],
        ),
        Some(&before.state),
        "linear/ENG-9686",
    )
    .unwrap();
    let seen: Vec<(&str, &str, &str)> = after.events.iter().map(|e| (e.topic.as_str(), e.kind.as_str(), e.summary.as_str())).collect();
    assert_eq!(
        seen,
        [
            ("linear/ENG-9686", "state", "status: In Progress → PM review"),
            ("linear/ENG-9686/abcdef01", "comment", "reply by Lee"),
            ("linear/ENG-9686/55555555", "comment", "comment by Dana"),
        ]
    );
    // A thread topic resolves to its root comment, whoever's comment in it was linked.
    assert_eq!(
        linear::resolve("linear/ENG-9686/99999999", &after.state).unwrap(),
        ("linear/ENG-9686/abcdef01".to_string(), "thread by Arsen: On it".to_string())
    );
    assert!(linear::resolve("linear/ENG-9686/0000", &after.state).is_err());
    // A follow of the issue hears every event; a follow of one thread hears its comments only.
    let all: Vec<&Event> = after.events.iter().collect();
    let words = format(&all, |_| "ENG-9686: Vitals chart".into());
    assert!(words.starts_with(
        "3 new events on what you follow:\n\nlinear/ENG-9686  —  ENG-9686: Vitals chart\n  status: In Progress → PM review\n"
    ));
}

#[test]
fn a_slack_threads_changes_become_events() {
    let message = |ts: &str, user: &str, text: &str, reactions: Vec<(&str, u64)>| {
        json!({"ts": ts, "user": user, "text": text,
        "reactions": reactions.iter().map(|(name, count)| json!({"name": name, "count": count})).collect::<Vec<_>>()})
    };
    let before = vec![message("1712345000.000100", "U1", "Deploying <@U2>'s PR", vec![]), message("1712345001.000100", "U2", "ok", vec![])];
    let after = vec![
        message("1712345000.000100", "U1", "Deploying <@U2>'s PR", vec![("eyes", 1)]),
        message("1712345001.000100", "U2", "ok!", vec![]),
        message("1712345002.000100", "U3", "Done", vec![]),
    ];
    let who = |m: &Value| match m["user"].as_str() {
        Some("U1") => "Dana".to_string(),
        Some("U2") => "Arsen".into(),
        _ => "Sam".into(),
    };
    let text = |m: &Value| m["text"].as_str().unwrap_or("").to_string();
    let events =
        slack::thread_events(&slack::thread_snapshot(&before), &after, &who, &text, "U2", ("acme", "C0123ABCD", "1712345000.000100"));
    let seen: Vec<(&str, &str, bool)> = events.iter().map(|e| (e.kind.as_str(), e.summary.as_str(), e.mine)).collect();
    assert_eq!(
        seen,
        [
            ("reaction", ":eyes: added to message by Dana", false),
            ("message_edited", "message by Arsen edited", true),
            ("message", "reply by Sam", false),
        ]
    );
    assert_eq!(
        (events[2].topic.as_str(), events[2].url.as_str(), events[2].dedupe.as_deref()),
        (
            "slack/C0123ABCD/1712345000.000100",
            "https://acme.slack.com/archives/C0123ABCD/p1712345002000100?thread_ts=1712345000.000100&cid=C0123ABCD",
            Some("msg:1712345002.000100")
        )
    );
    assert_eq!(slack::thread_snapshot(&after)["root_text"], "Deploying <@U2>'s PR");
}

/// A pull request followed, merged as `5425391615…`: gh's answer, with the deployments of its merge commit (an
/// environment, its latest status) and whether the repository has any at all.
fn merged(deploys: Vec<(&str, &str, &str)>, repo_deploys: u64) -> Value {
    let mut reply = pr(vec![], vec![], vec![], "aaa", "MERGED");
    reply["data"]["repository"]["deployments"] = json!({"totalCount": repo_deploys});
    reply["data"]["repository"]["pullRequest"]["mergeCommit"] = json!({"oid": "5425391615abcdef0123456789abcdef01234567", "deployments": {"nodes":
        deploys.iter().map(|(id, env, state)| json!({"databaseId": id, "environment": env, "state": "ACTIVE",
            "latestStatus": if state.is_empty() { Value::Null } else { json!({"state": state, "description": "", "logUrl": format!("https://ci/deploys/{id}"), "environmentUrl": ""}) }})).collect::<Vec<_>>()}});
    reply
}

/// A deploy bot posts each step of a deploy as its own message, some naming the merged commit and some nothing
/// ("Running migrations", "Deploy complete"). Once a filtered follow passes one of its messages, the bot's next ones
/// in the channel pass too, as one sequence, each saying what it continues: until the bot names something else
/// (another commit or pull request), half an hour passes quietly, or twenty have passed.
#[tokio::test]
async fn a_matched_authors_next_messages_continue_it() {
    let bot =
        |at: u64, text: &str| json!({"ts": format!("{at}.000100"), "username": "Deploy: app (production)", "bot_id": "B1", "text": text});
    let person = |at: u64, text: &str| json!({"ts": format!("{at}.000100"), "user": "U9", "text": text});
    let history = |messages: Vec<Value>| Ok(json!({"ok": true, "messages": messages.into_iter().rev().collect::<Vec<_>>()}));
    const T: u64 = 1_700_000_000;
    let mut later = vec![
        person(T - 100, "morning"),
        bot(T, "Waiting until commit 5425391615 is built"),
        bot(T + 60, "Pulling image for commit 5425391615"),
        bot(T + 120, "Running migrations"),
        bot(T + 180, "Migrations finished"),
        bot(T + 240, "Deploying commit 5425391615"),
        bot(T + 300, "Deploy complete"),
        person(T + 360, "Deploy complete?"),
        bot(T + 400, "Waiting until commit 9f8e7d6c5b is built"),
        bot(T + 460, "Deploy complete"),
        bot(T + 500, "Deploying commit 5425391615 again"),
        bot(T + 500 + 31 * 60, "Deploy complete after the quiet"),
        bot(T + 5000, "Deploying commit 5425391615 once more"),
    ];
    later.extend((1..=25).map(|k| bot(T + 5000 + 60 * k, &format!("step {k}"))));
    let fetcher = canned(vec![
        Ok(json!({"ok": true, "team_id": "T0AB", "team": "Acme", "url": "https://acme.slack.com/", "user_id": "U2"})),
        Ok(json!({"ok": true, "channels": [{"id": "C0DEPLOY1", "name": "deploys"}], "response_metadata": {"next_cursor": ""}})),
        Ok(merged(vec![], 0)),
        history(vec![person(T - 100, "morning")]),
        Ok(merged(vec![], 0)),
        history(later),
        Ok(json!({"ok": true, "user": {"name": "sam"}})),
    ]);
    let home = temp_dir("following-sequences");
    let integrations = Integrations::open(&home, fetcher.clone());
    integrations.connect_slack("xoxp-1").await.unwrap();
    let following = Following::open(&home, fetcher.clone(), integrations);
    following.follow("s1", "github/o/r/42", false, vec![]).await.unwrap();
    following.follow("s1", "slack/C0DEPLOY1", true, vec![]).await.unwrap();
    let told = Arc::new(Mutex::new(vec![]));
    following.hurry();
    following.tick(|_| true, |_| false, |_: &str, words: &str, _| told.lock().unwrap().push(words.to_string())).await;
    // A bot's words only confirm (Event::settled): told on a line each, what it said and what it continues.
    let told = told.lock().unwrap().join("; ");
    let passed: Vec<&str> = told
        .split("; ")
        .map(|line| line.split_once("#deploys: ").map_or(line, |(_, said)| said))
        .map(|said| said.split(" (continuing: ").next().unwrap())
        .collect();
    let mut expected = vec![
        "Waiting until commit 5425391615 is built",
        "Pulling image for commit 5425391615",
        "Running migrations",
        "Migrations finished",
        "Deploying commit 5425391615",
        "Deploy complete",
        "Deploying commit 5425391615 again",
        "Deploying commit 5425391615 once more",
    ];
    let steps: Vec<String> = (1..=20).map(|k| format!("step {k}")).collect();
    expected.extend(steps.iter().map(String::as_str));
    assert_eq!(passed, expected, "{told}");
    assert!(told.contains(": Deploy complete (continuing: Deploying commit 5425391615);"), "{told}");
    assert!(told.contains(": Running migrations (continuing: Pulling image for commit 5425391615);"), "{told}");
    assert!(
        slack::cites("see ENG-9429")
            && slack::cites("fixed in #12")
            && slack::cites("https://x")
            && slack::cites("commit 9f8e7d6c5b")
            && !slack::cites("Deploy complete")
            && !slack::cites("Extracting assets to 2 node(s)")
    );
}

/// A followed pull request, once merged, follows the GitHub deployments of its merge commit in the same read: each
/// one created, under way, done or failed reaches the task. Its follow ends once they've settled, at the merge when
/// the repository has none, or two hours after it when none comes.
#[tokio::test]
async fn a_merged_pull_requests_deployments_are_followed_until_they_settle() {
    let fetcher = canned(vec![
        Ok(pr(vec![], vec![], vec![], "aaa", "OPEN")),
        Ok(merged(vec![], 3)),
        Ok(merged(vec![("7", "production", "IN_PROGRESS")], 3)),
        Ok(merged(vec![("7", "production", "SUCCESS"), ("8", "staging", "FAILURE")], 3)),
    ]);
    let home = temp_dir("following-deployments");
    let following = Following::open(&home, fetcher.clone(), Integrations::open(&home, fetcher.clone()));
    following.follow("s1", "github/o/r/42", false, vec![]).await.unwrap();
    let query = fetcher.asked.lock().unwrap()[0].join(" ");
    assert!(query.contains("mergeCommit") && query.contains("deployments"), "one read: {query}");
    let told: Told = Arc::new(Mutex::new(vec![]));
    for _ in 0..3 {
        following.hurry();
        following.tick(|_| true, |_| false, listener(&told)).await;
        if told.lock().unwrap().len() < 3 {
            assert!(!following.finished("s1"), "merged, its deploy still to come");
        }
    }
    let told = told.lock().unwrap().clone();
    let words: Vec<(&str, Heard)> = told.iter().map(|(_, w, h)| (w.as_str(), *h)).collect();
    assert_eq!(words[0], ("r#42 PR merged into main", Heard::Settled));
    assert_eq!(words[1].1, Heard::Settled);
    assert!(words[1].0.contains("deploy to production in progress"), "{}", words[1].0);
    assert_eq!(words[2].1, Heard::News, "a failed deploy is news");
    assert!(words[2].0.contains("deployed to production") && words[2].0.contains("deploy to staging failed"), "{}", words[2].0);
    assert!(words[2].0.contains("https://ci/deploys/8"), "{}", words[2].0);
    assert!(following.finished("s1"), "its deploys settled: nothing more to come");

    // No deployments in the repository: merged is the end. None in two hours: so is that.
    let none = zerod::following::github::snapshot(&merged(vec![], 0)["data"]).unwrap();
    assert!(github::ended(&none));
    let mut waiting = zerod::following::github::snapshot(&merged(vec![], 3)["data"]).unwrap();
    waiting["merged_seen"] = json!(zerod::now());
    assert!(!github::ended(&waiting));
    waiting["merged_seen"] = json!(zerod::now() - 2 * 3600 - 1);
    assert!(github::ended(&waiting));
}

#[tokio::test]
async fn several_slack_workspaces_each_read_with_their_own_connection() {
    let workspace = |team: &str, name: &str, domain: &str, user: &str| {
        Ok(json!({"ok": true, "team_id": team, "team": name, "url": format!("https://{domain}.slack.com/"), "user_id": user}))
    };
    let channels =
        |id: &str, name: &str| Ok(json!({"ok": true, "channels": [{"id": id, "name": name}], "response_metadata": {"next_cursor": ""}}));
    let fetcher = canned(vec![
        workspace("T0AB", "Acme", "acme", "U2"),
        channels("C0D", "deploys"),
        workspace("T0BE", "Beta", "beta", "U7"),
        channels("C9Z", "general"),
        Ok(json!({"ok": true, "messages": [{"ts": "1700000000.000100", "user": "U7", "text": "hi"}]})),
    ]);
    let home = temp_dir("following-slack-workspaces");
    let integrations = Integrations::open(&home, fetcher.clone());
    integrations.connect_slack("xoxp-acme").await.unwrap();
    integrations.connect_slack("xoxp-beta").await.unwrap();
    let teams: Vec<Value> = integrations.slack_state().as_array().unwrap().iter().map(|s| s["team"]["name"].clone()).collect();
    assert_eq!(teams, [json!("Acme"), json!("Beta")], "both kept, in the order connected");
    // Beta's channel: read with Beta's token, linked on Beta's domain.
    let polled = slack::poll(&integrations, &["C9Z"], None).await.unwrap();
    assert_eq!(polled.summary, "#general https://beta.slack.com/archives/C9Z/p1700000000000100");
    let fed = fetcher.fed.lock().unwrap().last().cloned().unwrap();
    assert!(fed.contains("xoxp-beta") && !fed.contains("xoxp-acme"));
    // One goes; the other stays, as zerod started again finds it.
    integrations.disconnect_slack("T0AB").unwrap();
    let again = Integrations::open(&home, fetcher.clone());
    let teams: Vec<Value> = again.slack_state().as_array().unwrap().iter().map(|s| s["team"]["id"].clone()).collect();
    assert_eq!(teams, [json!("T0BE")]);
}

#[test]
fn a_slack_connection_kept_before_there_could_be_several_still_loads() {
    let home = temp_dir("following-slack-one");
    std::fs::write(
        home.join("slack.json"),
        r#"{"token":"xoxp-1","team":{"id":"T0AB","name":"Acme","domain":"acme"},"userId":"U2","channels":{"deploys":"C0D"}}"#,
    )
    .unwrap();
    let integrations = Integrations::open(&home, canned(vec![]));
    assert_eq!(
        integrations.slack_state(),
        json!([{"team": {"id": "T0AB", "name": "Acme", "domain": "acme"}, "channels": {"deploys": "C0D"}}])
    );
}

/// A poll that finds the thing as it was doesn't write following.json again: with many things followed, the whole
/// file (hundreds of kilobytes) was written after every poll of every one of them.
#[tokio::test]
async fn a_poll_that_finds_nothing_new_writes_nothing() {
    let same = || Ok(pr(vec![("c1", "arsen", "First")], vec![], vec![], "aaa", "OPEN"));
    let fetcher = canned(vec![same(), same()]);
    let home = temp_dir("following-quiet");
    let following = Following::open(&home, fetcher.clone(), Integrations::open(&home, fetcher.clone()));
    following.follow("s1", "https://github.com/o/r/pull/42", false, vec![]).await.unwrap();
    let file = home.join("following.json");
    let written = std::fs::metadata(&file).unwrap().modified().unwrap();
    std::thread::sleep(std::time::Duration::from_millis(20));
    following.hurry();
    following.tick(|_| true, |_| false, |_, _, _| {}).await;
    assert_eq!(fetcher.asked.lock().unwrap().len(), 2, "it was polled");
    assert_eq!(std::fs::metadata(&file).unwrap().modified().unwrap(), written, "and nothing was written");
}

/// A Linear issue as Linear answers: its status and its comments `(id, author id, body)`.
fn issue(state: &str, comments: Vec<(&str, &str, &str)>) -> Value {
    json!({"data": {"viewer": {"id": "me", "name": "Arsen"}, "issue": {
        "id": "iss", "identifier": "ENG-1", "title": "Vitals", "description": "", "url": "https://linear.app/acme/issue/ENG-1",
        "priorityLabel": "High", "estimate": null, "dueDate": null, "state": {"name": state}, "assignee": null, "project": null,
        "cycle": null, "parent": null, "labels": {"nodes": []},
        "comments": {"nodes": comments.iter().map(|(id, who, body)| json!({"id": id, "body": body, "url": "https://linear.app/acme/issue/ENG-1",
            "createdAt": "2026-11-13T10:00:00Z", "updatedAt": "2026-11-13T10:00:00Z", "user": {"id": who, "name": who}, "parent": null})).collect::<Vec<_>>()}
    }}})
}

type Told = Arc<Mutex<Vec<(String, String, Heard)>>>;

fn listener(told: &Told) -> impl Fn(&str, &str, Heard) + '_ {
    |session: &str, words: &str, heard: Heard| told.lock().unwrap().push((session.into(), words.into(), heard))
}

/// A task that moved an issue itself isn't woken by its own move coming back: the conversation notes it, quietly.
/// Someone else's move, or a comment it didn't write, wakes it as before.
#[tokio::test]
async fn a_tasks_own_change_coming_back_doesnt_wake_it() {
    let fetcher = canned(vec![
        Ok(issue("Working on", vec![])),
        Ok(issue("PM review", vec![("c1", "me", "Ready for **PM review**:\nthe fix is live.")])),
        Ok(issue("Done", vec![("c1", "me", "Ready for **PM review**:\nthe fix is live."), ("c2", "u2", "Thanks")])),
    ]);
    let home = temp_dir("following-own");
    std::fs::write(home.join("linear.json"), r#"{"name":"Acme","url_key":"acme","access":"lin_tok","refresh":null,"expires":9999999999}"#)
        .unwrap();
    let following = Following::open(&home, fetcher.clone(), Integrations::open(&home, fetcher));
    following.follow("s1", "linear/ENG-1", false, vec![]).await.unwrap();
    following.follow("s2", "linear/ENG-1", false, vec![]).await.unwrap();
    // s1 moves it and comments, through Linear's MCP server.
    following.touched(
        "s1",
        &ItemKind::Tool {
            name: "mcp__linear-server__save_issue".into(),
            detail: r#"{"id":"ENG-1","state":"PM review"}"#.into(),
            output: String::new(),
        },
    );
    following.touched(
        "s1",
        &ItemKind::Tool {
            name: "linear-server.save_comment".into(),
            detail: r#"{"issueId":"eng-1","body":"Ready for **PM review**:\n\nthe fix is live."}"#.into(),
            output: String::new(),
        },
    );
    let told: Told = Arc::default();
    following.hurry();
    following.tick(|_| true, |_| false, listener(&told)).await;
    let mut heard = told.lock().unwrap().clone();
    heard.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(heard.len(), 2, "{heard:?}");
    assert_eq!(heard[0].0, "s1");
    assert_eq!(heard[0].2, Heard::Own, "s1 isn't woken by its own move");
    assert!(heard[0].1.contains("status: Working on → PM review") && heard[0].1.contains("comment by me"), "{}", heard[0].1);
    assert_eq!((heard[1].0.as_str(), heard[1].2), ("s2", Heard::News), "another task hears it as news");

    // Within the window, someone else moves it on and comments: that wakes s1.
    told.lock().unwrap().clear();
    following.hurry();
    following.tick(|_| true, |_| false, listener(&told)).await;
    let heard: Vec<_> = told.lock().unwrap().iter().filter(|t| t.0 == "s1").cloned().collect();
    assert_eq!(heard.len(), 1);
    assert_eq!(heard[0].2, Heard::News);
    assert!(heard[0].1.starts_with("2 new events") && heard[0].1.contains("PM review → Done"), "{}", heard[0].1);
}

/// Own changes on GitHub and Slack go through the same check: a merge, a comment, a push, a message.
#[test]
fn what_a_step_did_is_matched_to_the_events_it_causes() {
    let following = open("following-own-steps", canned(vec![]));
    let command = |command: &str| ItemKind::Command {
        command: command.into(),
        cwd: "/tmp".into(),
        output: String::new(),
        exit_code: Some(0),
        duration_ms: None,
        description: String::new(),
    };
    following
        .touched("s1", &command("gh pr merge 42 --squash -R o/r && gh pr comment https://github.com/o/r/pull/7 --body 'Merged, thanks'"));
    following.touched("s1", &command("git push origin fix-vitals"));
    following.touched(
        "s1",
        &ItemKind::Tool {
            name: "mcp__slack__post_message".into(),
            detail: r#"{"channel_id":"C0D","text":"Deployed app#42"}"#.into(),
            output: String::new(),
        },
    );
    let event = |topic: &str, kind: &str, summary: &str, body: &str| Event {
        topic: topic.into(),
        kind: kind.into(),
        summary: summary.into(),
        body: body.into(),
        ..Default::default()
    };
    let own = |e: Event| following.own("s1", &e);
    assert!(own(event("github/o/r/42", "merged", "PR merged into main by @arsen", "")));
    assert!(!own(event("github/o/r/43", "merged", "PR merged into main", "")), "another pull request");
    assert!(!own(event("github/x/r/42", "merged", "PR merged into main", "")), "another repository");
    assert!(own(event("github/o/r/7", "comment", "comment by @arsen", "Merged, thanks")));
    assert!(!own(event("github/o/r/7", "comment", "comment by @sam", "Why?")), "someone else's comment");
    assert!(own(event("github/o/r/7", "push", "1 new commit pushed to fix-vitals", "")));
    assert!(!own(event("github/o/r/7", "checks", "CI failure: 3 passed, 1 failed, 4 total", "")), "CI isn't its own change");
    assert!(own(event("slack/C0D", "message", "message by Arsen", "Deployed app#42")));
    assert!(!own(event("slack/C0D", "message", "message by Dana", "Deployed app#42 to staging too")));
    assert!(!following.own("s2", &event("github/o/r/42", "merged", "PR merged into main", "")), "another task's merge");
}

/// Events for a task between turns that land close together wake it once, with all of them; one after the window
/// wakes it again. A task mid-turn gets them at once (they wait in its queue for the turn's end).
#[tokio::test]
async fn a_burst_of_events_wakes_an_idle_task_once() {
    let comments = |n: usize| (1..=n).map(|i| (["c1", "c2", "c3", "c4", "c5"][i - 1], "sam", "More")).collect::<Vec<_>>();
    let fetcher = canned((0..=4).map(|n| Ok(pr(comments(n), vec![], vec![], "aaa", "OPEN"))).collect());
    let following = open("following-burst", fetcher);
    following.follow("s1", "github/o/r/42", false, vec![]).await.unwrap();
    let told: Told = Arc::default();
    for _ in 0..3 {
        following.hurry();
        following.tick(|_| true, |_| true, listener(&told)).await;
    }
    assert!(told.lock().unwrap().is_empty(), "held while the window is open");
    following.set_window(0);
    following.tick(|_| true, |_| true, listener(&told)).await;
    assert_eq!(told.lock().unwrap().len(), 1);
    assert!(told.lock().unwrap()[0].1.starts_with("3 new events on what you follow:"), "{}", told.lock().unwrap()[0].1);
    following.hurry();
    following.tick(|_| true, |_| true, listener(&told)).await;
    assert_eq!(told.lock().unwrap().len(), 2, "one after the window is its own wake");
    assert!(told.lock().unwrap()[1].1.starts_with("1 new event"));
}
