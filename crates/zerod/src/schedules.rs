//! A task waking itself at a time (`zero schedule`): a check due tomorrow morning, a deploy to look at in an hour.
//! Kept on disk so a restart loses none; when one is due, its task hears it as Zero's word (a parked task is woken for
//! it), and one that fell due while zerod was down is told as soon as it's back, saying it's late.

use std::path::Path;

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Schedule {
    pub id: String,
    pub session: String,
    /// When, in seconds since 1970.
    pub at: i64,
    /// What it's for, in the agent's words: told back to it then.
    pub text: String,
}

impl Schedule {
    /// What the task hears when it's due; `now` past its time by more than a minute, that it's late and why.
    pub fn told(&self, now: i64) -> String {
        let late = if now - self.at > 60 { format!(" (late: it was due {} minutes ago, while Zero wasn't running)", (now - self.at) / 60) } else { String::new() };
        format!("Scheduled: {}{late}", self.text)
    }
}

pub fn load(home: &Path) -> Vec<Schedule> {
    std::fs::read(home.join("schedules.json")).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
}

pub fn keep(home: &Path, schedules: &[Schedule]) {
    if let Ok(data) = serde_json::to_vec_pretty(schedules) { let _ = std::fs::write(home.join("schedules.json"), data); }
}
