//! What an ask is about: a message of its task's conversation. The agent's words just before the ask go with it, unless
//! it names a heading (`zero ask --about "#bench-plan"`, GitHub's anchors as pads have them) or an item; so the user
//! answering it needn't scroll up through a lead's other work to find what it means. And what the agent answers to the
//! user's own words on an ask is kept with that ask (`reply`).

use crate::ask::{About, Ask, AskKind, AskState, Reply};
use crate::model::{Item, ItemKind};

/// How much of a passage an ask carries: enough to decide on, not the conversation copied into the inbox.
const PASSAGE: usize = 4000;
/// A title made of a message's first words: about a line of a card.
const TITLE: usize = 60;

/// An ask of the user's (a question, a choice, an approval, a run): a note or a message is about nothing.
pub fn asks(ask: &Ask) -> bool {
    matches!(ask.kind, AskKind::Question | AskKind::Choice | AskKind::Approve | AskKind::Run)
}

/// The agent's last words in this turn (since the last message to it): none when it has said nothing yet.
pub fn automatic(items: &[Item]) -> Option<About> {
    let turn = items.iter().rposition(|i| matches!(i.kind, ItemKind::User { .. })).map_or(0, |at| at + 1);
    items[turn..].iter().rev().find_map(|item| words(item).filter(|t| !t.trim().is_empty()).map(|text| whole(item, text)))
}

/// The latest heading with `anchor` ("#bench-plan" or "bench-plan"), its section alone; or the item with that id.
pub fn linked(items: &[Item], anchor: &str) -> Result<About, String> {
    let anchor = anchor.trim().trim_start_matches('#');
    for item in items.iter().rev() {
        let Some(text) = words(item) else { continue };
        if item.id == anchor {
            return Ok(whole(item, text));
        }
        let sections = crate::pads::sections(text);
        let Some(at) = sections.iter().position(|s| s.slug == anchor) else { continue };
        let (section, lines) = (&sections[at], text.lines().collect::<Vec<_>>());
        let end = sections[at + 1..].iter().find(|s| s.level <= section.level).map_or(lines.len(), |s| s.line - 1);
        return Ok(About {
            item: item.id.clone(),
            anchor: Some(anchor.into()),
            title: section.title.clone(),
            text: clip(lines[section.line - 1..end].join("\n").trim()),
            at: item.at,
        });
    }
    let mut known: Vec<String> = vec![];
    for slug in items.iter().rev().filter_map(words).flat_map(crate::pads::sections).map(|s| format!("#{}", s.slug)) {
        if !known.contains(&slug) {
            known.push(slug)
        }
    }
    known.truncate(20);
    let there = if known.is_empty() { "it has no headings".to_string() } else { format!("its latest are {}", known.join(", ")) };
    Err(format!("No heading #{anchor} in this task's conversation: {there}"))
}

/// The agent's answer to the user's own words on an ask, as its turn ends: the turn they started (given to the agent
/// in this turn's message), and what it answered. Their words on an ask: its answer in their words, or what they wrote
/// to the task while it was the one open (`said`, by ask). None when the turn wasn't one.
pub fn reply(items: &[Item], asks: &[Ask], said: &[(String, String)]) -> Option<(String, Reply)> {
    let at = items.iter().rposition(|i| matches!(i.kind, ItemKind::User { .. }))?;
    let ItemKind::User { text: told, .. } = &items[at].kind else { return None };
    let answer = items[at + 1..].iter().rev().find(|i| matches!(i.kind, ItemKind::Agent { final_answer: true, .. }))?;
    let text = words(answer)?.trim();
    let answered = |a: &Ask| typed(a) && told.contains(&crate::inbox::Inbox::delivery_text(a));
    let written = |a: &Ask| said.iter().any(|(id, words)| *id == a.id && !words.is_empty() && told.contains(words.as_str()));
    let ask = asks.iter().rev().find(|a| a.replies.iter().all(|r| r.item != answer.id) && (answered(a) || written(a)))?;
    (!text.is_empty()).then(|| (ask.id.clone(), Reply { item: answer.id.clone(), text: text.into(), at: answer.at }))
}

/// Answered in the user's own words (a reply typed, an option that takes words): a question back, maybe, and the
/// agent's next answer is its. An option picked is a decision, and what follows is the work.
fn typed(ask: &Ask) -> bool {
    asks(ask)
        && matches!(ask.state, AskState::Answered | AskState::Declined)
        && match ask.choice {
            None => ask.answer.is_some(),
            Some(index) => ask.options.get(index).is_some_and(|o| Ask::expects_text(o)),
        }
}

/// What the agent said in an item, Zero's ending left out.
fn words(item: &Item) -> Option<&str> {
    match &item.kind {
        ItemKind::Agent { text, .. } => Some(crate::board::without_ending(text)),
        _ => None,
    }
}

/// A whole message: titled by its first heading, or its first words.
fn whole(item: &Item, text: &str) -> About {
    let title = match crate::pads::sections(text).first() {
        Some(heading) => heading.title.clone(),
        None => first_words(text),
    };
    About { item: item.id.clone(), anchor: None, title, text: clip(text.trim()), at: item.at }
}

/// The first line, without Markdown's marks, cut at a word near TITLE characters.
fn first_words(text: &str) -> String {
    let line = text.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    let line = line.trim_start_matches(['#', '>', '-', '*', ' ']).replace(['*', '`'], "");
    if line.chars().count() <= TITLE {
        return line;
    }
    let cut: String = line.chars().take(TITLE).collect();
    let cut = cut.rsplit_once(' ').map_or(cut.as_str(), |(head, _)| head);
    format!("{}…", cut.trim_end_matches([',', ';', ':', '.', ' ']))
}

fn clip(text: &str) -> String {
    match text.char_indices().nth(PASSAGE) {
        Some((at, _)) => format!("{}…", &text[..at]),
        None => text.into(),
    }
}
