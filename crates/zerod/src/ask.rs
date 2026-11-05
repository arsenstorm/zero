//! An ask: something an agent needs from the user (a question, a choice, an approval, a command run on their machine), or
//! a note saying where it is. The JSON is the one the Swift app wrote to ~/.zero/asks.jsonl and the `zero` CLI speaks, field
//! for field, so the log and every client carry over (apps/macos/Sources/ZeroCore/Model.swift is the other side).

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// `note` needs no answer: the agent saying where it is. `message` goes the other way, the user to the agent.
/// `permission` is an agent's tool asking to run.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AskKind {
    Question,
    Choice,
    Approve,
    Run,
    Note,
    Message,
    Permission,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AskState {
    Waiting,
    /// Answered, but still in the take-back window.
    Pending,
    Running,
    Answered,
    Declined,
    Expired,
}

impl AskState {
    pub fn is_final(self) -> bool {
        matches!(self, AskState::Answered | AskState::Declined | AskState::Expired)
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Delivery {
    Sending,
    Delivered,
    Failed,
}

/// Who asked, and everything known about how to reach them again.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct AgentIdentity {
    pub name: String,
    pub host: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(rename = "soloProcessID", default, skip_serializing_if = "Option::is_none")]
    pub solo_process_id: Option<i64>,
    /// Solo scopes its calls to a project; every call about the process carries this one.
    #[serde(rename = "soloProjectID", default, skip_serializing_if = "Option::is_none")]
    pub solo_project_id: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ticket: Option<String>,
    /// What to show for the agent (its session's title once it has one); `name` stays the key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// The runtime's session id (a Claude Code session), so the conversation can be resumed and titled.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    /// For runtimes other than Solo: which one ("rex", "zero" for Zero's own terminals, "zerod"), its id for the agent
    /// there, the group it lives in, and the command line it was started with.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<String>,
    #[serde(rename = "ref", default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<String>,
    #[serde(rename = "refGroup", default, skip_serializing_if = "Option::is_none")]
    pub ref_group: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch: Option<Vec<String>>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Ask {
    pub id: String,
    pub kind: AskKind,
    pub title: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub options: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    pub agent: AgentIdentity,
    pub created_at: Time,
    pub expires_at: Time,
    pub state: AskState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answer: Option<String>,
    #[serde(default)]
    pub output: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answered_at: Option<Time>,
    /// For notes: "blocked", "done" or "closed"; none means working. "withdrawn" on a withdrawn ask.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    /// The option picked, when one was.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub choice: Option<usize>,
    /// False when the agent asked with --async: nothing waits for the answer, so it is typed into its session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waits: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delivery: Option<Delivery>,
    /// For a question: what the user may want to know to answer it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// For a run of a script file: the script, so the user reads what will run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub script: Option<String>,
    /// A run asking exactly what another's open run asks: it shares that run's outcome.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub same_as: Option<String>,
    /// For an approval or question of a zerod session: its id there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request: Option<String>,
    /// For a note: what the agent hands to the user, without waiting for it ("mark the PR ready and merge it").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub needs: Option<String>,
}

impl Ask {
    pub fn new(kind: AskKind, title: &str, agent: AgentIdentity, ttl_seconds: i64) -> Ask {
        let now = Time::now();
        Ask {
            id: new_id(), kind, title: title.into(), body: String::new(), options: vec![], command: None, cwd: None, agent,
            created_at: now, expires_at: Time(now.0 + ttl_seconds), state: AskState::Waiting, answer: None, output: String::new(),
            exit_code: None, answered_at: None, status: None, choice: None, waits: None, delivery: None, detail: None, script: None,
            same_as: None, request: None, needs: None,
        }
    }

    /// An option ending with "…" asks for words: picking it takes text, and the answer is "label: text".
    pub fn expects_text(option: &str) -> bool {
        option.ends_with('…') || option.ends_with("...")
    }
}

/// Six letters and digits without the ones that read alike.
pub fn new_id() -> String {
    const ALPHABET: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";
    let mut bytes = [0u8; 6];
    if let Ok(mut random) = std::fs::File::open("/dev/urandom") { let _ = std::io::Read::read_exact(&mut random, &mut bytes); }
    bytes.iter().map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char).collect()
}

/// A moment, to the second, written as Swift's ISO 8601 ("2026-10-26T12:00:00Z").
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Time(pub i64);

impl Time {
    pub fn now() -> Time {
        Time(crate::now())
    }

    pub fn iso(self) -> String {
        let (days, seconds) = (self.0.div_euclid(86400), self.0.rem_euclid(86400));
        let (year, month, day) = civil(days);
        format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }

    /// Reads "2026-10-26T12:00:00Z", with or without fractions of a second or an offset of "+00:00".
    pub fn parse(text: &str) -> Option<Time> {
        let (date, rest) = text.split_once('T')?;
        let mut d = date.split('-').map(|p| p.parse::<i64>().ok());
        let (year, month, day) = (d.next()??, d.next()??, d.next()??);
        let clock = rest.trim_end_matches('Z');
        let (clock, offset) = match clock.find(['+', '-']) {
            Some(i) => (&clock[..i], &clock[i..]),
            None => (clock, ""),
        };
        let mut t = clock.split(':');
        let (hour, minute) = (t.next()?.parse::<i64>().ok()?, t.next()?.parse::<i64>().ok()?);
        let second = t.next().unwrap_or("0").split('.').next()?.parse::<i64>().ok()?;
        let offset_seconds = if offset.is_empty() { 0 } else {
            let sign = if offset.starts_with('-') { -1 } else { 1 };
            let mut o = offset[1..].split(':');
            sign * (o.next()?.parse::<i64>().ok()? * 3600 + o.next().unwrap_or("0").parse::<i64>().ok()? * 60)
        };
        Some(Time(days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset_seconds))
    }
}

impl Serialize for Time {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.iso())
    }
}

impl<'de> Deserialize<'de> for Time {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Time, D::Error> {
        let text = String::deserialize(deserializer)?;
        Time::parse(&text).ok_or_else(|| serde::de::Error::custom(format!("not a time: {text}")))
    }
}

/// Days since 1970-01-01 → (year, month, day), and back (Howard Hinnant's algorithms).
fn civil(days: i64) -> (i64, i64, i64) {
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(month <= 2), month, day)
}

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let yoe = year - era * 400;
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times_read_and_write_as_swift_does() {
        for text in ["1970-01-01T00:00:00Z", "2026-10-26T12:30:50Z", "2000-02-29T23:59:59Z", "2100-03-01T00:00:00Z"] {
            assert_eq!(Time::parse(text).unwrap().iso(), text);
        }
        assert_eq!(Time::parse("2026-10-26T12:30:50Z").unwrap().0, 1793017850);
        assert_eq!(Time::parse("2026-10-26T12:30:50.123Z").unwrap().iso(), "2026-10-26T12:30:50Z");
        assert_eq!(Time::parse("2026-10-26T14:30:50+02:00").unwrap().iso(), "2026-10-26T12:30:50Z");
        assert!(Time::parse("yesterday").is_none());
    }

    #[test]
    fn ids_are_six_characters_that_read_unambiguously() {
        let id = new_id();
        assert_eq!(id.len(), 6);
        assert!(id.chars().all(|c| "abcdefghjkmnpqrstuvwxyz23456789".contains(c)));
    }
}
