//! What wakes a task: commands and files watched for it, reminders and schedules.

use super::*;

impl Daemon {
    /// Watches kept from before a restart carry on from where they'd read to; wakes kept are armed again, any already
    /// due told now.
    pub(super) fn carry_on_watches_and_wakes(&self) {
        let kept: Vec<String> = self.watches.lock().unwrap().keys().cloned().collect();
        for id in kept { self.follow_file(id) }
        let due: Vec<crate::schedules::Schedule> = self.schedules.lock().unwrap().clone();
        for schedule in due { self.arm(schedule) }
    }

    /// Runs `command` in the session's folder and, when it ends, tells the session how: "wake me when CI finishes"
    /// without a polling loop.
    pub fn watch(&self, id: &str, command: &str) -> Result<(), String> {
        let cwd = PathBuf::from(self.get(id).ok_or_else(|| format!("No session {id}"))?.cwd);
        let (me, id, command) = (self.me.clone(), id.to_string(), command.to_string());
        tokio::spawn(async move {
            let (code, printed) = process::run(&command, &cwd, &id).await;
            let how = code.map(|c| format!("with exit {c}")).unwrap_or_else(|| "when it was stopped".into());
            let words = if printed.is_empty() { format!("`{command}` finished {how} and printed nothing.") } else { format!("`{command}` finished {how}:\n{printed}") };
            if let Some(daemon) = me.upgrade() { daemon.tell(&id, crate::model::from_line("zero", &words)) }
        });
        Ok(())
    }

    /// Watches the watch's file for its session from now on (watches.rs): lines with any of its `alerts` told with what
    /// led up to them, at most one alert a minute; the file not growing for `quiet` minutes told once; a line with
    /// `done` told, and the watch ended. Its id and how far it's read are zerod's. Its id.
    pub fn watch_file(&self, watch: crate::watches::Watch) -> Result<String, String> {
        self.session(&watch.session)?;
        let offset = std::fs::metadata(&watch.file).map_err(|e| format!("Can't watch {}: {e}", watch.file.display()))?.len();
        let alerts: Vec<String> = watch.alerts.into_iter().filter(|a| !a.is_empty()).collect();
        if alerts.is_empty() && watch.done.is_none() && watch.quiet.is_none() { return Err("Watch it for what? --alert TEXT, --until TEXT or --quiet MINUTES".into()) }
        if let Some(short) = alerts.iter().chain(watch.done.iter()).find(|text| text.trim().chars().count() < 3) {
            return Err(format!("`{short}` is in almost every line: watch for text only that line has"));
        }
        let watch = crate::watches::Watch { id: crate::ask::new_id(), alerts, offset, ..watch };
        crate::watches::Reading::new(&watch)?;
        let id = watch.id.clone();
        self.watches.lock().unwrap().insert(id.clone(), watch);
        self.keep_watches();
        self.follow_file(id.clone());
        Ok(id)
    }

    /// The watches, of `session` or everyone's.
    pub fn watches(&self, session: Option<&str>) -> Vec<crate::watches::Watch> {
        let mut all: Vec<_> = self.watches.lock().unwrap().values().filter(|w| session.is_none_or(|s| w.session == s)).cloned().collect();
        all.sort_by(|a, b| a.id.cmp(&b.id));
        all
    }

    pub fn unwatch(&self, id: &str) -> Result<(), String> {
        self.watches.lock().unwrap().remove(id).ok_or_else(|| format!("No watch {id}"))?;
        self.keep_watches();
        Ok(())
    }

    fn keep_watches(&self) {
        let all: Vec<_> = self.watches.lock().unwrap().values().cloned().collect();
        crate::watches::keep(&self.home, &all);
    }

    /// Reads a watch's file as it grows, until the watch is stopped or its file says it's done.
    fn follow_file(&self, id: String) {
        let me = self.me.clone();
        tokio::spawn(async move {
            use std::io::{Read, Seek};
            let Some(first) = me.upgrade().and_then(|daemon| daemon.watches.lock().unwrap().get(&id).cloned()) else { return };
            let Ok(mut reading) = crate::watches::Reading::new(&first) else { return };
            let mut alerted = std::time::Instant::now().checked_sub(crate::watches::COOL_DOWN).unwrap_or_else(std::time::Instant::now);
            let (mut grew, mut said_quiet, mut kept) = (std::time::Instant::now(), false, std::time::Instant::now());
            loop {
                tokio::time::sleep(crate::watches::poll()).await;
                let Some(daemon) = me.upgrade() else { return };
                let Some(mut watch) = daemon.watches.lock().unwrap().get(&id).cloned() else { return };
                // Its task archived: nobody to tell.
                if daemon.session(&watch.session).is_err() { let _ = daemon.unwatch(&id); return }
                let length = std::fs::metadata(&watch.file).map(|m| m.len()).unwrap_or(watch.offset);
                // Started again (truncated or replaced): from its top.
                if length < watch.offset { watch.offset = 0 }
                if length > watch.offset {
                    let mut bytes = vec![];
                    if let Ok(mut file) = std::fs::File::open(&watch.file) && file.seek(std::io::SeekFrom::Start(watch.offset)).is_ok() {
                        let _ = file.take(crate::watches::CHUNK).read_to_end(&mut bytes);
                    }
                    watch.offset += bytes.len() as u64;
                    reading.read(&watch, &String::from_utf8_lossy(&bytes));
                    (grew, said_quiet) = (std::time::Instant::now(), false);
                    if let Some(kept_watch) = daemon.watches.lock().unwrap().get_mut(&id) { kept_watch.offset = watch.offset }
                    if kept.elapsed() > Duration::from_secs(30) { daemon.keep_watches(); kept = std::time::Instant::now() }
                }
                if !reading.hits.is_empty() && alerted.elapsed() >= crate::watches::COOL_DOWN {
                    let hits = std::mem::take(&mut reading.hits);
                    daemon.tell(&watch.session, crate::model::from_line("zero", &watch.alert(&hits, reading.latest.as_deref())));
                    alerted = std::time::Instant::now();
                }
                if let Some(line) = reading.done.take() {
                    daemon.tell(&watch.session, crate::model::from_line("zero", &watch.finished(&line)));
                    let _ = daemon.unwatch(&id);
                    return;
                }
                if let Some(minutes) = watch.quiet && !said_quiet && grew.elapsed() >= Duration::from_secs(minutes * 60) {
                    daemon.tell(&watch.session, crate::model::from_line("zero", &watch.quieted(reading.latest.as_deref())));
                    said_quiet = true;
                }
            }
        });
    }

    /// Tells the session `text` after `after`. ponytail: held in memory, so a daemon restart forgets it; keep it on disk
    /// beside pending.json if reminders start spanning restarts.
    pub fn remind(&self, id: &str, after: Duration, text: &str) -> Result<(), String> {
        self.schedule(id, now() + after.as_secs() as i64, text).map(|_| ())
    }

    /// Wakes `id` at `at` (seconds since 1970) with `text`: kept on disk, told as Zero's word when due.
    pub fn schedule(&self, id: &str, at: i64, text: &str) -> Result<crate::schedules::Schedule, String> {
        self.session(id)?;
        let text = text.trim();
        if text.is_empty() { return Err("Schedule it with what for: the words to hear then".into()) }
        let schedule = crate::schedules::Schedule { id: new_id(), session: id.into(), at, text: text.into() };
        self.schedules.lock().unwrap().push(schedule.clone());
        self.keep_schedules();
        self.arm(schedule.clone());
        Ok(schedule)
    }

    /// The wakes scheduled, soonest first: `session`'s, or everyone's.
    pub fn schedules(&self, session: Option<&str>) -> Vec<crate::schedules::Schedule> {
        let mut list: Vec<_> = self.schedules.lock().unwrap().iter().filter(|s| session.is_none_or(|id| s.session == id)).cloned().collect();
        list.sort_by_key(|s| s.at);
        list
    }

    pub fn unschedule(&self, schedule: &str) -> Result<(), String> {
        let mut list = self.schedules.lock().unwrap();
        let before = list.len();
        list.retain(|s| s.id != schedule);
        if list.len() == before { return Err(format!("Nothing is scheduled as {schedule}")) }
        drop(list);
        self.keep_schedules();
        Ok(())
    }

    /// When `id` next wakes, for its board row.
    pub fn next_wake(&self, id: &str) -> Option<i64> { self.schedules.lock().unwrap().iter().filter(|s| s.session == id).map(|s| s.at).min() }

    fn keep_schedules(&self) { crate::schedules::keep(&self.home, &self.schedules.lock().unwrap()) }

    /// Told when due, if it's still scheduled then (not taken back); once.
    fn arm(&self, schedule: crate::schedules::Schedule) {
        let me = self.me.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs((schedule.at - now()).max(0) as u64)).await;
            let Some(daemon) = me.upgrade() else { return };
            let still = { let mut list = daemon.schedules.lock().unwrap(); let before = list.len(); list.retain(|s| s.id != schedule.id); list.len() < before };
            if !still { return }
            daemon.keep_schedules();
            daemon.tell_from_zero(&schedule.session, &schedule.told(now()));
        });
    }
}
