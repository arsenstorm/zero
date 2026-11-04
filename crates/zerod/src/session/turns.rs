//! What a turn is given and how it goes to the agent: the first turn, a resume, a message, a model picked, an
//! interrupt, and answers to what the agent asked.

use super::*;

impl Session {
    /// Starts the runtime's side of the session, with `message` as its first turn; its images (their files) kept as
    /// any message's are.
    pub async fn start(&self, transport: Transport, message: Message<'_>, choice: ModelChoice<'_>) -> Result<(), String> {
        self.keep_images(message.images);
        match self.provider() {
            Provider::Codex => codex::start(self, transport, message.text, message.images, choice.model, choice.effort).await,
            Provider::Claude => claude::start(self, transport, message.text, message.images).await,
            Provider::Opencode => acp::start(self, transport, message, choice).await,
        }
    }

    /// The images go on the next message of yours, now and on replay.
    fn keep_images(&self, images: &[String]) {
        if images.is_empty() { return }
        let mut inner = self.lock();
        inner.record(json!({"attach": images}));
        inner.core().attach(images.to_vec());
    }

    /// Gives an offline session a new process on its conversation.
    pub async fn resume(&self, transport: Transport) -> Result<(), String> {
        match self.provider() {
            Provider::Codex => codex::resume(self, transport).await,
            Provider::Claude => claude::resume(self, transport).await,
            Provider::Opencode => acp::resume(self, transport).await,
        }
    }

    /// A model (and effort) picked without a message, for the turns from here: told to the agent now where it takes
    /// that (Claude Code, OpenCode), and kept so the next turn carries it (Codex) and a restart starts with it.
    pub async fn set_model(&self, choice: ModelChoice<'_>) -> Result<(), String> {
        let ModelChoice { model, effort } = choice;
        if model.is_none() && effort.is_none() { return Ok(()) }
        let conversation = self.snapshot();
        let thread = conversation.thread.clone()
            .ok_or_else(|| format!("{} hasn't started yet: pick the model with your next message", conversation.provider.title()))?;
        if self.is_attached() {
            match conversation.provider {
                Provider::Claude => if let Some(model) = model { claude::set_model(self, model).await? },
                Provider::Opencode => acp::configure(self, choice).await?,
                Provider::Codex => {}
            }
        }
        self.change(Change::Thread { thread, model: model.map(Into::into), effort: effort.map(Into::into) });
        Ok(())
    }

    /// Arsen's words: steering or queued behind the turn in progress where the provider allows it, else a new turn.
    /// Their images (files) are kept in the transcript first, so the message keeps them on replay.
    pub async fn send(&self, message: Message<'_>, choice: ModelChoice<'_>) -> Result<(), String> {
        let conversation = self.snapshot();
        if !self.is_attached() { return Err(format!("{} is offline; resume it first", conversation.id)) }
        self.keep_images(message.images);
        match conversation.provider {
            Provider::Codex => codex::send(self, message.text, message.images, choice.model, choice.effort).await,
            Provider::Claude => claude::send(self, message.text, message.images, choice.model).await,
            Provider::Opencode => acp::send(self, message, choice).await,
        }
    }

    pub async fn interrupt(&self) -> Result<(), String> {
        match self.provider() {
            Provider::Codex => codex::interrupt(self).await,
            Provider::Claude => claude::interrupt(self).await,
            Provider::Opencode => acp::interrupt(self).await,
        }
    }

    /// Answers an open approval with one of the choices it offers, once.
    pub async fn decide(&self, approval: &str, choice: &str) -> Result<(), String> {
        let mut inner = self.lock();
        if inner.answered.contains(approval) { return Err(format!("{approval} was already answered")) }
        let line = inner.core().answer(approval, choice)?;
        inner.send(line)?;
        inner.answered.insert(approval.into());
        Ok(())
    }

    /// Answers an open question, every field of it, once.
    pub async fn answer(&self, question: &str, answers: &crate::adapter::Answers) -> Result<(), String> {
        let mut inner = self.lock();
        if inner.answered.contains(question) { return Err(format!("{question} was already answered")) }
        let line = inner.core().reply(question, answers)?;
        inner.send(line)?;
        inner.answered.insert(question.into());
        Ok(())
    }
}

/// What a turn is given: your words and their images (files), and for a new thread the conversation so far as
/// context, for OpenCode, which can't be handed a conversation (handoff.rs): it goes with the words, not as yours.
#[derive(Clone, Copy, Default)]
pub struct Message<'a> {
    pub text: &'a str,
    pub images: &'a [String],
    pub context: Option<&'a str>,
}

impl<'a> Message<'a> {
    /// Words alone.
    pub fn text(text: &'a str) -> Self { Message { text, ..Default::default() } }
}

/// The model and effort a turn runs on; none, the session's own.
#[derive(Clone, Copy, Default)]
pub struct ModelChoice<'a> {
    pub model: Option<&'a str>,
    pub effort: Option<&'a str>,
}
