//! zerod's own sessions as one of the inbox's runtimes.

use super::*;

/// zerod's own sessions as a runtime for the inbox: an agent in one that asks with `zero ask --async` gets its answer
/// between turns, the way a worker's report reaches its lead.
pub struct Sessions(Weak<Daemon>);

impl Sessions {
    pub fn of(daemon: &Arc<Daemon>) -> Sessions {
        Sessions(Arc::downgrade(daemon))
    }

    fn session(agent: &crate::ask::AgentIdentity) -> Option<&str> {
        (agent.runtime.as_deref() == Some("zerod")).then_some(agent.reference.as_deref()).flatten()
    }
}

impl crate::inbox::Runtime for Sessions {
    fn name(&self) -> &str { "Zero" }
    fn can_reach(&self, agent: &crate::ask::AgentIdentity) -> bool { Sessions::session(agent).is_some() && self.0.upgrade().is_some() }
    fn send<'a>(&'a self, text: &'a str, agent: &'a crate::ask::AgentIdentity) -> crate::inbox::Fut<'a, Result<(), String>> {
        Box::pin(async move {
            let (daemon, id) = (self.0.upgrade().ok_or("zerod is stopping")?, Sessions::session(agent).ok_or("not a zerod session")?);
            daemon.notify(id, text)
        })
    }
    fn display_name<'a>(&'a self, agent: &'a crate::ask::AgentIdentity) -> crate::inbox::Fut<'a, Option<String>> {
        Box::pin(async move {
            let conversation = self.0.upgrade()?.get(Sessions::session(agent)?)?;
            conversation.label.or(conversation.title)
        })
    }
    fn offline<'a>(&'a self, agents: &'a [crate::ask::AgentIdentity]) -> crate::inbox::Fut<'a, std::collections::HashSet<String>> {
        Box::pin(async move {
            let Some(daemon) = self.0.upgrade() else { return Default::default() };
            agents.iter().filter(|a| Sessions::session(a).and_then(|id| daemon.get(id)).is_some_and(|c| c.status == Status::Offline)).map(|a| a.name.clone()).collect()
        })
    }
    fn gone<'a>(&'a self, agents: &'a [crate::ask::AgentIdentity]) -> crate::inbox::Fut<'a, std::collections::HashSet<String>> {
        Box::pin(async move {
            let Some(daemon) = self.0.upgrade() else { return Default::default() };
            agents.iter().filter(|a| Sessions::session(a).is_some_and(|id| daemon.get(id).is_none())).map(|a| a.name.clone()).collect()
        })
    }
    fn stop<'a>(&'a self, agent: &'a crate::ask::AgentIdentity) -> crate::inbox::Fut<'a, ()> {
        Box::pin(async move { if let (Some(daemon), Some(id)) = (self.0.upgrade(), Sessions::session(agent)) { let _ = daemon.stop(id); } })
    }
}
