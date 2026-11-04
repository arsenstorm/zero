//! The conversation a page at a time: its latest items, the page before an item or after one, its outline.

use super::*;

impl Session {
    /// The conversation with its latest `count` items (more, back to the start of their turn), and how many came before.
    pub fn recent(&self, count: usize) -> (Conversation, usize) {
        let mut inner = self.lock();
        if let Some(parked) = inner.parked.as_ref().filter(|p| count <= p.tail.len() || p.tail.len() == p.total) {
            let start = turn_start(&parked.tail, parked.tail.len().saturating_sub(count));
            return (parked.summary.with_items(parked.tail[start..].to_vec()), parked.total - (parked.tail.len() - start));
        }
        let conversation = inner.core().conversation();
        let start = turn_start(&conversation.items, conversation.items.len().saturating_sub(count));
        (conversation.with_items(conversation.items[start..].to_vec()), start)
    }

    /// Items before `before` (all of them with none): from `from` if given, else the last `limit` of them.
    pub fn items(&self, before: Option<&str>, from: Option<&str>, limit: usize) -> Vec<Item> {
        let mut inner = self.lock();
        let items = &inner.core().conversation().items;
        let end = before.and_then(|id| items.iter().position(|i| i.id == id)).unwrap_or(items.len());
        let start = match from.and_then(|id| items[..end].iter().position(|i| i.id == id)) {
            Some(start) => start,
            None => turn_start(items, end.saturating_sub(limit)),
        };
        items[start..end].to_vec()
    }

    /// A page of the conversation anywhere in it, and how many items lie before and after it: from a message (the
    /// rail's jump), after one (scrolled to the page's foot), or the latest page. ponytail: positions by scanning
    /// for the id; index them if conversations reach the hundreds of thousands of items.
    pub fn window(&self, from: Option<&str>, after: Option<&str>, limit: usize) -> (Vec<Item>, usize, usize) {
        let mut inner = self.lock();
        let items = &inner.core().conversation().items;
        let find = |id: &str| items.iter().position(|i| i.id == id);
        let start = match (from, after) {
            (Some(id), _) => match find(id) { Some(at) => at, None => return (vec![], 0, 0) },
            (None, Some(id)) => match find(id) { Some(at) => at + 1, None => return (vec![], 0, 0) },
            (None, None) => turn_start(items, items.len().saturating_sub(limit)),
        };
        let end = if from.is_none() && after.is_none() { items.len() } else { (start + limit).min(items.len()) };
        (items[start..end].to_vec(), start, items.len() - end)
    }

    /// Each message of yours with the start of its answer: the app's rail, whole however little of the conversation
    /// is loaded.
    pub fn outline(&self) -> Value {
        let mut inner = self.lock();
        let items = &inner.core().conversation().items;
        let mut marks: Vec<Value> = vec![];
        for (index, item) in items.iter().enumerate() {
            // Yours only: what Zero gave the session (a worker's report) isn't a mark of yours.
            let ItemKind::User { text, .. } = &item.kind else { continue };
            if crate::model::from(text).is_some() { continue }
            let answer = items[index + 1..].iter().take_while(|i| !matches!(i.kind, ItemKind::User { .. }))
                .find_map(|i| match &i.kind { ItemKind::Agent { text, final_answer: true } => Some(text.chars().take(400).collect::<String>()), _ => None });
            marks.push(json!({"id": item.id, "text": text.chars().take(300).collect::<String>(), "answer": answer}));
        }
        Value::Array(marks)
    }
}

/// Where the turn holding `items[start]` begins (the message of yours it answers), so a page never splits a turn: the
/// app folds a turn into one row, and half of one shows the wrong time.
pub(super) fn turn_start(items: &[Item], start: usize) -> usize {
    if start >= items.len() { return start }
    items[..=start].iter().rposition(|i| matches!(i.kind, ItemKind::User { .. })).unwrap_or(0)
}
