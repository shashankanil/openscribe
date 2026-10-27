//! Live dictation input. The WAV remains authoritative until every streamed turn is final.
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use tauri::{Emitter, Manager};
use tokio::sync::{mpsc, Notify};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, Message},
};

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Transport {
    OpenAi,
    Deepgram,
    AssemblyAi,
    Mistral,
}

struct Capability {
    transport: Transport,
    model: String,
    url: reqwest::Url,
    rate: u32,
}
impl Capability {
    // Match StreamingCapability.swift exactly. Compatible file APIs do not imply live input.
    fn resolve(
        config: &crate::provider::ProviderConfig,
        hints: &crate::provider::SpeechHints,
    ) -> Option<Self> {
        let base = reqwest::Url::parse(config.base_url.trim()).ok()?;
        if base.scheme() != "https"
            || !base.username().is_empty()
            || base.password().is_some()
            || base.query().is_some()
            || base.fragment().is_some()
            || base.port_or_known_default() != Some(443)
        {
            return None;
        }
        let model = config.model.trim();
        let (transport, endpoint, rate) = match (
            config.provider.as_str(),
            base.host_str()?,
            base.path().trim_matches('/'),
        ) {
            ("openAI", "api.openai.com", "v1")
                if [
                    "gpt-live-transcribe",
                    "gpt-transcribe",
                    "gpt-realtime-whisper",
                    "gpt-4o-transcribe",
                    "gpt-4o-mini-transcribe",
                    "gpt-4o-mini-transcribe-2025-12-15",
                    "whisper-1",
                ]
                .contains(&model) =>
            {
                (Transport::OpenAi, "wss://api.openai.com/v1/realtime", 24000)
            }
            ("deepgram", "api.deepgram.com", "v1")
                if [
                    "nova-3",
                    "nova-3-general",
                    "nova-2",
                    "nova-2-general",
                    "nova-2-meeting",
                    "nova-2-phonecall",
                    "nova-2-medical",
                    "nova-2-conversationalai",
                ]
                .contains(&model) =>
            {
                (
                    Transport::Deepgram,
                    "wss://api.deepgram.com/v1/listen",
                    16000,
                )
            }
            ("assemblyAI", "api.assemblyai.com", "v2")
                if [
                    "universal-3-5-pro",
                    "universal-streaming-english",
                    "universal-streaming-multilingual",
                ]
                .contains(&model) =>
            {
                (
                    Transport::AssemblyAi,
                    "wss://streaming.assemblyai.com/v3/ws",
                    16000,
                )
            }
            ("mistral", "api.mistral.ai", "v1")
                if model == "voxtral-mini-transcribe-realtime-2602" =>
            {
                (
                    Transport::Mistral,
                    "wss://api.mistral.ai/v1/audio/transcriptions/realtime",
                    16000,
                )
            }
            _ => return None,
        };
        let mut url = reqwest::Url::parse(endpoint).ok()?;
        {
            let mut query = url.query_pairs_mut();
            match transport {
                Transport::OpenAi => {
                    query.append_pair("intent", "transcription");
                }
                Transport::Mistral => {
                    query.append_pair("model", model);
                }
                Transport::Deepgram => {
                    for (key, value) in [
                        ("model", model),
                        ("encoding", "linear16"),
                        ("sample_rate", "16000"),
                        ("channels", "1"),
                        ("interim_results", "true"),
                        ("smart_format", "true"),
                    ] {
                        query.append_pair(key, value);
                    }
                    for term in hints.terms.iter().take(50) {
                        query.append_pair(
                            if model.starts_with("nova-3") {
                                "keyterm"
                            } else {
                                "keywords"
                            },
                            term,
                        );
                    }
                }
                Transport::AssemblyAi => {
                    for (key, value) in [
                        ("speech_model", model),
                        ("sample_rate", "16000"),
                        ("encoding", "pcm_s16le"),
                        ("format_turns", "true"),
                    ] {
                        query.append_pair(key, value);
                    }
                    if !hints.terms.is_empty() {
                        query.append_pair(
                            "keyterms_prompt",
                            &json!(hints.terms.iter().take(50).collect::<Vec<_>>()).to_string(),
                        );
                    }
                }
            }
        }
        Some(Self {
            transport,
            model: model.into(),
            url,
            rate,
        })
    }
}

/// Revisions replace provisional text; OpenAI completions replace their deltas.
#[derive(Default)]
struct Transcript {
    parts: HashMap<String, String>,
    order: Vec<String>,
    previous: HashMap<String, Option<String>>,
    committed: HashSet<String>,
    completed: HashSet<String>,
    interim: String,
    terminal: bool,
}
impl Transcript {
    fn text(&self) -> String {
        self.order
            .iter()
            .filter_map(|id| self.parts.get(id))
            .chain(std::iter::once(&self.interim))
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
    }
    fn consume(&mut self, event: &Value, transport: Transport) -> Result<(), ()> {
        let kind = event["type"].as_str().unwrap_or_default();
        if matches!(kind, "error" | "Error" | "ConfigureFailure") || kind.ends_with(".failed") {
            return Err(());
        }
        match transport {
            Transport::OpenAi => {
                if let Some(id) = event["item_id"].as_str() {
                    let id = id.to_owned();
                    if !self.order.contains(&id) {
                        self.order.push(id.clone());
                    }
                    if kind == "input_audio_buffer.committed" {
                        self.committed.insert(id.clone());
                        self.previous.insert(
                            id.clone(),
                            event["previous_item_id"].as_str().map(str::to_owned),
                        );
                        // Completions can arrive out of order. Rebuild the committed linked order.
                        let mut ordered: Vec<String> = Vec::new();
                        let mut previous = None;
                        while let Some(next) = self.order.iter().find(|key| {
                            !ordered.contains(*key) && self.previous.get(*key) == Some(&previous)
                        }) {
                            ordered.push(next.clone());
                            previous = Some(next.clone());
                        }
                        ordered.extend(
                            self.order
                                .iter()
                                .filter(|key| !ordered.contains(key))
                                .cloned()
                                .collect::<Vec<_>>(),
                        );
                        self.order = ordered;
                    }
                    if kind == "conversation.item.input_audio_transcription.delta"
                        && !self.completed.contains(&id)
                    {
                        self.parts
                            .entry(id.clone())
                            .or_default()
                            .push_str(event["delta"].as_str().ok_or(())?);
                    }
                    if kind == "conversation.item.input_audio_transcription.completed" {
                        self.parts
                            .insert(id.clone(), event["transcript"].as_str().ok_or(())?.into());
                        self.completed.insert(id);
                    }
                }
            }
            Transport::Deepgram => {
                if kind == "Results" {
                    let text = event["channel"]["alternatives"][0]["transcript"]
                        .as_str()
                        .ok_or(())?;
                    if event["is_final"] == true {
                        let key = event["start"].as_f64().ok_or(())?.to_string();
                        if !self.order.contains(&key) {
                            self.order.push(key.clone());
                        }
                        self.parts.insert(key, text.into());
                        self.interim.clear();
                    } else {
                        self.interim = text.into();
                    }
                }
                if kind == "Metadata" {
                    self.terminal = true;
                }
            }
            Transport::AssemblyAi => {
                if kind == "Turn" {
                    let key = event["turn_order"].as_u64().ok_or(())?.to_string();
                    self.parts
                        .insert(key, event["transcript"].as_str().ok_or(())?.into());
                    self.order = self.parts.keys().cloned().collect();
                    self.order
                        .sort_by_key(|s| s.parse::<u64>().unwrap_or_default());
                }
                if kind == "Termination" {
                    self.terminal = true;
                }
            }
            Transport::Mistral => {
                if kind == "transcription.text.delta" {
                    self.interim.push_str(event["text"].as_str().ok_or(())?);
                }
                if kind == "transcription.done" {
                    self.interim = event["text"].as_str().ok_or(())?.into();
                    self.terminal = true;
                }
            }
        }
        Ok(())
    }
    fn complete(&self, transport: Transport, ended: bool, commits: usize) -> bool {
        ended
            && if transport == Transport::OpenAi {
                commits > 0
                    && self.committed.len() == commits
                    && self.completed == self.committed
                    && self.parts.keys().all(|key| self.completed.contains(key))
            } else {
                self.terminal
                    && (transport != Transport::Deepgram || self.interim.trim().is_empty())
            }
    }
}

struct Audio {
    samples: Vec<i16>,
    rate: u32,
    channels: u16,
}

/// Stateful linear resampling, with an integer clock to avoid drift at callback boundaries.
#[derive(Default)]
struct Pcm16 {
    rate: u32,
    target: u32,
    channels: u16,
    frame: Vec<i16>,
    frames: u64,
    next: u64,
    last: f64,
    peak: f64,
}
impl Pcm16 {
    fn append(&mut self, audio: Audio, target: u32) -> Result<Vec<u8>, ()> {
        if audio.rate == 0 || audio.channels == 0 {
            return Err(());
        }
        if self.rate != 0 && (self.rate != audio.rate || self.channels != audio.channels) {
            return Err(());
        }
        self.rate = audio.rate;
        self.channels = audio.channels;
        self.target = target;
        let mut out = Vec::new();
        for sample in audio.samples {
            self.frame.push(sample);
            if self.frame.len() != usize::from(self.channels) {
                continue;
            }
            let mono = self
                .frame
                .iter()
                .map(|s| f64::from(*s) / 32768.0)
                .sum::<f64>()
                / f64::from(self.channels);
            self.frame.clear();
            self.peak = self.peak.max(mono.abs());
            let mono =
                crate::meeting_audio::lift(mono, crate::meeting_audio::gain_for_peak(self.peak));
            let clock = self.frames * u64::from(target);
            while self.next <= clock {
                let fraction = if self.frames == 0 {
                    1.0
                } else {
                    (self.next as f64 - (clock - u64::from(target)) as f64) / f64::from(target)
                };
                Self::write(&mut out, self.last + (mono - self.last) * fraction);
                self.next += u64::from(self.rate);
            }
            self.frames += 1;
            self.last = mono;
        }
        Ok(out)
    }
    fn finish(&mut self) -> Result<Vec<u8>, ()> {
        if !self.frame.is_empty() {
            return Err(());
        }
        let mut out = Vec::new();
        while self.next < self.frames * u64::from(self.target) {
            Self::write(&mut out, self.last);
            self.next += u64::from(self.rate);
        }
        Ok(out)
    }
    fn write(out: &mut Vec<u8>, sample: f64) {
        out.extend_from_slice(
            &((sample * 32768.0).round().clamp(-32768.0, 32767.0) as i16).to_le_bytes(),
        );
    }
}

/// Decides when a turn is committed for transcription. Cutting at a fixed interval splits words
/// and leaves each piece without the sentence around it, so a turn ends at a pause instead.
#[derive(Default)]
struct Pause {
    /// The loudest 100 ms packet in the current turn.
    loudest: f64,
    /// Bytes of quiet audio at the end of the current turn.
    quiet: usize,
}
impl Pause {
    /// A turn shorter than this is held back, so a breath between words never ends a sentence.
    const SHORTEST_SECONDS: usize = 3;
    /// A turn is committed regardless at this length, so text keeps arriving during long speech.
    const LONGEST_SECONDS: usize = 15;
    /// About the length of a pause between sentences.
    const PAUSE_MILLISECONDS: usize = 400;
    /// Quiet relative to the loudest speech in the turn.
    const QUIET_FRACTION: f64 = 0.15;

    /// Records one packet of 16-bit audio and reports whether the turn should be committed now.
    fn observe(&mut self, packet: &[u8], pending: usize, rate: u32) -> bool {
        let samples = packet.len() / 2;
        let level = if samples == 0 {
            0.0
        } else {
            let sum = packet
                .as_chunks::<2>()
                .0
                .iter()
                .map(|b| f64::from(i16::from_le_bytes(*b)) / 32768.0)
                .map(|s| s * s)
                .sum::<f64>();
            (sum / samples as f64).sqrt()
        };
        self.loudest = self.loudest.max(level);
        if level < self.loudest * Self::QUIET_FRACTION {
            self.quiet += packet.len();
        } else {
            self.quiet = 0;
        }
        let second = rate as usize * 2;
        let commit = pending >= second * Self::LONGEST_SECONDS
            || (pending >= second * Self::SHORTEST_SECONDS
                && self.quiet >= second * Self::PAUSE_MILLISECONDS / 1000);
        if commit {
            *self = Self::default();
        }
        commit
    }
}

#[derive(Clone)]
pub(crate) struct LiveSink {
    tx: mpsc::Sender<Audio>,
    failed: Arc<AtomicBool>,
    failure: Arc<Notify>,
}
impl LiveSink {
    pub fn append(&self, samples: Vec<i16>, rate: u32, channels: u16) {
        if !self.failed.load(Ordering::SeqCst)
            && self
                .tx
                .try_send(Audio {
                    samples,
                    rate,
                    channels,
                })
                .is_err()
        {
            self.failed.store(true, Ordering::SeqCst);
            self.failure.notify_one();
        }
    }
}

pub(crate) struct LiveSession {
    task: tauri::async_runtime::JoinHandle<Result<String, ()>>,
    failed: Arc<AtomicBool>,
    app: tauri::AppHandle,
    path: String,
}
impl Drop for LiveSession {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn publish(app: &tauri::AppHandle, path: &str, text: &str, fallback: bool) {
    // Clear provisional words on failure without surfacing an error or fallback notice.
    let _ = app.emit("dictation://partial", json!({"path":path,"text":text,"hint":if fallback { "" } else { "Streaming transcription" }}));
}

impl LiveSession {
    pub fn start(app: &tauri::AppHandle, path: &std::path::Path) -> Option<(LiveSink, Self)> {
        let path = path.to_string_lossy().into_owned();
        let settings =
            crate::storage::with_profile(app, &app.state::<crate::storage::ProfileState>(), |p| {
                Ok(p.settings.clone())
            })
            .ok()?;
        if !settings.flag("dictationLiveTranscription")
            || settings.0.get("automaticStreaming") == Some(&Value::Bool(false))
        {
            return None;
        }
        let config = crate::provider::ProviderConfig {
            provider: settings.string("speechProvider").into(),
            base_url: settings.string("speechBaseURL").into(),
            model: settings.string("speechModel").into(),
            credential_account: format!(
                "speech:{}:{}",
                settings.string("speechProvider"),
                settings.string("speechBaseURL")
            ),
        };
        let hints =
            crate::integration::hints_for_provider(&settings, &config.provider, &config.model);
        let capability = Capability::resolve(&config, &hints)?;
        let key = crate::credentials::read(&config.credential_account)
            .ok()
            .flatten()?;
        let (tx, rx) = mpsc::channel(200);
        let failed = Arc::new(AtomicBool::new(false));
        let failure = Arc::new(Notify::new());
        let sink = LiveSink {
            tx,
            failed: failed.clone(),
            failure: failure.clone(),
        };
        let app = app.clone();
        let task_failed = failed.clone();
        let generation = app
            .state::<crate::integration::ActivityState>()
            .generation();
        publish(&app, &path, "", false);
        let session_app = app.clone();
        let session_path = path.clone();
        let task = tauri::async_runtime::spawn(async move {
            let activity = app.state::<crate::integration::ActivityState>();
            let result = tokio::select! {
                result = exchange(capability, key, hints, rx, |text| publish(&app, &path, text, false)) => result,
                () = failure.notified() => Err(()),
                () = activity.cancelled(generation) => { return Err(()); },
            };
            if result.is_err() {
                task_failed.store(true, Ordering::SeqCst);
                publish(&app, &path, "", true);
            }
            result
        });
        Some((
            sink,
            Self {
                task,
                failed,
                app: session_app,
                path: session_path,
            },
        ))
    }
    pub async fn finish(mut self, cancel: bool) -> Option<String> {
        if cancel || self.failed.load(Ordering::SeqCst) {
            return None;
        }
        let result = tokio::time::timeout(Duration::from_secs(15), &mut self.task).await;
        match result {
            Ok(Ok(Ok(text))) if !self.failed.load(Ordering::SeqCst) && !text.trim().is_empty() => {
                Some(text)
            }
            _ => {
                publish(&self.app, &self.path, "", true);
                None
            }
        }
    }
}

async fn send(socket: &mut Socket, message: Message) -> Result<(), ()> {
    tokio::time::timeout(Duration::from_secs(10), socket.send(message))
        .await
        .map_err(|_| ())?
        .map_err(|_| ())
}
async fn send_json(socket: &mut Socket, event: Value) -> Result<(), ()> {
    send(socket, Message::Text(event.to_string().into())).await
}
async fn receive(socket: &mut Socket) -> Result<Value, ()> {
    loop {
        match socket.next().await.ok_or(())?.map_err(|_| ())? {
            Message::Text(text) => return serde_json::from_str(&text).map_err(|_| ()),
            Message::Binary(bytes) => return serde_json::from_slice(&bytes).map_err(|_| ()),
            Message::Ping(bytes) => send(socket, Message::Pong(bytes)).await?,
            Message::Close(_) => return Err(()),
            _ => {}
        }
    }
}
async fn expect(socket: &mut Socket, kind: &str) -> Result<(), ()> {
    if receive(socket).await?["type"] == kind {
        Ok(())
    } else {
        Err(())
    }
}

async fn exchange(
    capability: Capability,
    key: String,
    hints: crate::provider::SpeechHints,
    mut audio: mpsc::Receiver<Audio>,
    partial: impl Fn(&str),
) -> Result<String, ()> {
    let mut request = capability
        .url
        .as_str()
        .into_client_request()
        .map_err(|_| ())?;
    let authorization = match capability.transport {
        Transport::Deepgram => {
            if key.trim().starts_with("Token ") {
                key.trim().to_owned()
            } else {
                format!("Token {}", key.trim())
            }
        }
        Transport::AssemblyAi => key.trim().into(),
        _ => format!("Bearer {}", key.trim()),
    };
    // Never format transport errors or requests: they can contain authorization headers.
    let mut authorization = authorization
        .parse::<tokio_tungstenite::tungstenite::http::HeaderValue>()
        .map_err(|_| ())?;
    authorization.set_sensitive(true);
    request.headers_mut().insert("Authorization", authorization);
    let (mut socket, _) = tokio::time::timeout(Duration::from_secs(10), connect_async(request))
        .await
        .map_err(|_| ())?
        .map_err(|_| ())?;
    tokio::time::timeout(Duration::from_secs(10), async {
        match capability.transport {
            Transport::OpenAi => {
                expect(&mut socket, "session.created").await?;
                let mut transcription = json!({"model":capability.model});
                if let Some(prompt) = hints.prompt { transcription["prompt"] = json!(prompt); }
                send_json(&mut socket, json!({"type":"session.update","session":{"type":"transcription","audio":{"input":{"format":{"type":"audio/pcm","rate":24000},"transcription":transcription,"turn_detection":null}}}})).await?;
                expect(&mut socket, "session.updated").await?;
            }
            Transport::Mistral => {
                expect(&mut socket, "session.created").await?;
                send_json(&mut socket, json!({"type":"session.update","session":{"audio_format":{"encoding":"pcm_s16le","sample_rate":16000}}})).await?;
                expect(&mut socket, "session.updated").await?;
            }
            Transport::AssemblyAi => expect(&mut socket, "Begin").await?,
            Transport::Deepgram => {}
        }
        Ok::<_, ()>(())
    }).await.map_err(|_| ())??;
    let mut transcript = Transcript::default();
    let mut converter = Pcm16::default();
    let mut pending = Vec::new();
    let mut pending_bytes = 0;
    let mut pause = Pause::default();
    let mut commits = 0;
    let mut ended = false;
    let mut last_text = String::new();
    let deadline = tokio::time::sleep(Duration::from_secs(15));
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            packet = audio.recv(), if !ended => {
                match packet {
                    Some(packet) => pending.extend(converter.append(packet, capability.rate)?),
                    None => { pending.extend(converter.finish()?); ended = true; }
                }
                let packet_bytes = capability.rate as usize / 10 * 2;
                while pending.len() >= packet_bytes || (ended && !pending.is_empty()) {
                    let count = pending.len().min(packet_bytes);
                    let mut bytes = pending.drain(..count).collect::<Vec<_>>();
                    if capability.transport == Transport::AssemblyAi && bytes.len() < 1600 { bytes.resize(1600, 0); }
                    match capability.transport {
                        Transport::OpenAi => {
                            send_json(&mut socket, json!({"type":"input_audio_buffer.append","audio":BASE64.encode(&bytes)})).await?;
                            pending_bytes += bytes.len();
                            if !["gpt-live-transcribe", "gpt-realtime-whisper"].contains(&capability.model.as_str()) && pause.observe(&bytes, pending_bytes, capability.rate) {
                                send_json(&mut socket, json!({"type":"input_audio_buffer.commit"})).await?;
                                commits += 1; pending_bytes = 0;
                            }
                        }
                        Transport::Mistral => send_json(&mut socket, json!({"type":"input_audio.append","audio":BASE64.encode(bytes)})).await?,
                        _ => send(&mut socket, Message::Binary(bytes.into())).await?,
                    }
                }
                if ended {
                    match capability.transport {
                        Transport::OpenAi => {
                            // A nonempty short tail requires at least 100 ms. Do not create an empty extra turn.
                            if pending_bytes > 0 || commits == 0 {
                                if pending_bytes < 4800 { send_json(&mut socket, json!({"type":"input_audio_buffer.append","audio":BASE64.encode(vec![0;4800-pending_bytes])})).await?; }
                                send_json(&mut socket, json!({"type":"input_audio_buffer.commit"})).await?; commits += 1;
                            }
                        }
                        Transport::Deepgram => send_json(&mut socket, json!({"type":"CloseStream"})).await?,
                        Transport::AssemblyAi => send_json(&mut socket, json!({"type":"Terminate"})).await?,
                        Transport::Mistral => send_json(&mut socket, json!({"type":"input_audio.end"})).await?,
                    }
                    deadline.as_mut().reset(tokio::time::Instant::now() + Duration::from_secs(15));
                }
            }
            event = receive(&mut socket) => {
                transcript.consume(&event?, capability.transport)?;
                if transcript.terminal && !ended { return Err(()); }
                let text = transcript.text();
                if text != last_text { partial(&text); last_text = text; }
            }
            () = &mut deadline, if ended => return Err(()),
        }
        if transcript.complete(capability.transport, ended, commits) {
            return Ok(transcript.text());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turns_end_at_a_pause_not_mid_word() {
        let packet = |level: i16| level.to_le_bytes().repeat(2400);
        let (speech, quiet) = (packet(4000), packet(100));
        let mut pause = Pause::default();
        let mut pending = 0;
        let mut feed = |pause: &mut Pause, bytes: &[u8]| {
            pending += bytes.len();
            let commit = pause.observe(bytes, pending, 24000);
            if commit {
                pending = 0;
            }
            commit
        };
        // A short breath inside the first seconds never ends the turn.
        for _ in 0..10 {
            assert!(!feed(&mut pause, &speech));
        }
        for _ in 0..5 {
            assert!(!feed(&mut pause, &quiet));
        }
        for _ in 0..20 {
            assert!(!feed(&mut pause, &speech));
        }
        // After three seconds, 400 ms of quiet ends it.
        for _ in 0..3 {
            assert!(!feed(&mut pause, &quiet));
        }
        assert!(feed(&mut pause, &quiet));
        // Unbroken speech is still committed at fifteen seconds.
        assert!((0..149).all(|_| !feed(&mut pause, &speech)));
        assert!(feed(&mut pause, &speech));
    }

    fn config(provider: &str, base: &str, model: &str) -> crate::provider::ProviderConfig {
        crate::provider::ProviderConfig {
            provider: provider.into(),
            base_url: base.into(),
            model: model.into(),
            credential_account: "unused-test-account".into(),
        }
    }

    #[test]
    fn exact_capabilities_and_dictionary_hints_match_swift() {
        let hints = crate::provider::SpeechHints {
            prompt: Some("OpenScribe".into()),
            terms: vec!["OpenScribe".into()],
        };
        for (provider, base, model, transport, rate) in [
            (
                "openAI",
                "https://api.openai.com/v1",
                "gpt-4o-mini-transcribe",
                Transport::OpenAi,
                24000,
            ),
            (
                "deepgram",
                "https://api.deepgram.com/v1",
                "nova-3",
                Transport::Deepgram,
                16000,
            ),
            (
                "assemblyAI",
                "https://api.assemblyai.com/v2",
                "universal-streaming-english",
                Transport::AssemblyAi,
                16000,
            ),
            (
                "mistral",
                "https://api.mistral.ai/v1",
                "voxtral-mini-transcribe-realtime-2602",
                Transport::Mistral,
                16000,
            ),
        ] {
            let cap = Capability::resolve(&config(provider, base, model), &hints).unwrap();
            assert_eq!(cap.transport, transport);
            assert_eq!(cap.rate, rate);
            if transport == Transport::Deepgram {
                assert!(cap
                    .url
                    .query_pairs()
                    .any(|(k, v)| k == "keyterm" && v == "OpenScribe"));
            }
            if transport == Transport::OpenAi {
                assert_eq!(cap.url.query(), Some("intent=transcription"));
            }
        }
        for base in [
            "http://api.openai.com/v1",
            "https://custom.example/v1",
            "https://api.openai.com/v1?x=1",
            "https://user@api.openai.com/v1",
            "https://api.openai.com/v1#fragment",
            "https://api.openai.com:444/v1",
            "https://api.openai.com/v2",
        ] {
            assert!(
                Capability::resolve(&config("openAI", base, "gpt-4o-mini-transcribe"), &hints)
                    .is_none()
            );
        }
        assert!(Capability::resolve(
            &config(
                "openAI",
                "https://api.openai.com/v1",
                "unknown-mini-transcribe"
            ),
            &hints
        )
        .is_none());
        assert!(Capability::resolve(
            &config(
                "openRouter",
                "https://api.openai.com/v1",
                "gpt-4o-mini-transcribe"
            ),
            &hints
        )
        .is_none());
    }

    fn resample(samples: &[i16], rate: u32, channels: u16, target: u32, chunk: usize) -> Vec<u8> {
        let mut pcm = Pcm16::default();
        let mut out = Vec::new();
        for samples in samples.chunks(chunk) {
            out.extend(
                pcm.append(
                    Audio {
                        samples: samples.into(),
                        rate,
                        channels,
                    },
                    target,
                )
                .unwrap(),
            );
        }
        out.extend(pcm.finish().unwrap());
        out
    }

    #[test]
    fn pcm_resampling_has_exact_duration_without_callback_drift() {
        for rate in [16000, 24000, 44100, 48000] {
            for target in [16000, 24000] {
                let samples = (0..rate)
                    .map(|n| ((f64::from(n) * 0.05).sin() * 1200.0) as i16)
                    .collect::<Vec<_>>();
                let entire = resample(&samples, rate, 1, target, samples.len());
                assert_eq!(entire.len(), target as usize * 2);
                assert_eq!(entire, resample(&samples, rate, 1, target, 127));
            }
        }
    }

    #[test]
    fn pcm_downmix_lifts_quiet_speech_and_soft_limits_loud_samples() {
        let quiet = resample(&[1200; 960], 48000, 2, 24000, 7);
        assert!(quiet
            .as_chunks::<2>()
            .0
            .iter()
            .all(|s| i16::from_le_bytes([s[0], s[1]]) == 12000));
        let opposite = (0..100).flat_map(|_| [1200, -1200]).collect::<Vec<_>>();
        assert!(resample(&opposite, 48000, 2, 16000, 9)
            .iter()
            .all(|s| *s == 0));
        assert_eq!(
            crate::meeting_audio::gain_for_peak(0.037),
            crate::meeting_audio::MAX_SPEECH_GAIN
        );
        assert!(crate::meeting_audio::lift(0.2, 10.0) < 1.0);
        assert!(crate::meeting_audio::lift(-0.2, 10.0) > -1.0);
        assert!(resample(&[0; 96], 48000, 1, 16000, 13)
            .iter()
            .all(|s| *s == 0));
    }

    #[test]
    fn pcm_rejects_format_changes_and_incomplete_channel_frames() {
        let mut pcm = Pcm16::default();
        pcm.append(
            Audio {
                samples: vec![1],
                rate: 48000,
                channels: 2,
            },
            16000,
        )
        .unwrap();
        assert!(pcm.finish().is_err());
        assert!(pcm
            .append(
                Audio {
                    samples: vec![1],
                    rate: 44100,
                    channels: 2
                },
                16000
            )
            .is_err());
        assert!(Pcm16::default()
            .append(
                Audio {
                    samples: vec![1],
                    rate: 0,
                    channels: 1
                },
                16000
            )
            .is_err());
    }

    #[test]
    fn openai_assembles_out_of_order_completions_and_replaces_deltas() {
        let mut t = Transcript::default();
        for event in [
            json!({"type":"conversation.item.input_audio_transcription.delta","item_id":"b","delta":"sec"}),
            json!({"type":"input_audio_buffer.committed","item_id":"b","previous_item_id":"a"}),
            json!({"type":"conversation.item.input_audio_transcription.completed","item_id":"b","transcript":"Second."}),
            json!({"type":"input_audio_buffer.committed","item_id":"a","previous_item_id":null}),
            json!({"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"Fir"}),
            json!({"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"st"}),
        ] {
            t.consume(&event, Transport::OpenAi).unwrap();
        }
        assert_eq!(t.text(), "First Second.");
        assert!(!t.complete(Transport::OpenAi, true, 2));
        t.consume(&json!({"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"First."}), Transport::OpenAi).unwrap();
        t.consume(&json!({"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"late"}), Transport::OpenAi).unwrap();
        assert_eq!(t.text(), "First. Second.");
        assert!(t.complete(Transport::OpenAi, true, 2));
        assert!(!t.complete(Transport::OpenAi, false, 2));
        assert!(!t.complete(Transport::OpenAi, true, 3));
    }

    #[test]
    fn deepgram_revisions_never_duplicate_provisional_words() {
        let mut t = Transcript::default();
        let result = |start, text, final_result| json!({"type":"Results","start":start,"is_final":final_result,"channel":{"alternatives":[{"transcript":text}]}});
        t.consume(&result(0.0, "one", false), Transport::Deepgram)
            .unwrap();
        t.consume(&result(0.0, "One two.", true), Transport::Deepgram)
            .unwrap();
        t.consume(&result(1.0, "th", false), Transport::Deepgram)
            .unwrap();
        t.consume(&result(1.0, "three", false), Transport::Deepgram)
            .unwrap();
        assert_eq!(t.text(), "One two. three");
        t.consume(&result(1.0, "Three.", true), Transport::Deepgram)
            .unwrap();
        t.consume(&json!({"type":"Metadata"}), Transport::Deepgram)
            .unwrap();
        assert_eq!(t.text(), "One two. Three.");
        assert!(t.complete(Transport::Deepgram, true, 0));
    }

    #[test]
    fn assembly_turn_revisions_sort_numerically() {
        let mut t = Transcript::default();
        for (turn, text) in [(10, "Last."), (2, "First"), (2, "First.")] {
            t.consume(
                &json!({"type":"Turn","turn_order":turn,"transcript":text}),
                Transport::AssemblyAi,
            )
            .unwrap();
        }
        assert_eq!(t.text(), "First. Last.");
        assert!(!t.complete(Transport::AssemblyAi, true, 0));
        t.consume(&json!({"type":"Termination"}), Transport::AssemblyAi)
            .unwrap();
        assert!(t.complete(Transport::AssemblyAi, true, 0));
    }

    #[test]
    fn mistral_final_replaces_deltas_and_provider_errors_require_recovery() {
        let mut t = Transcript::default();
        t.consume(
            &json!({"type":"transcription.text.delta","text":"hel"}),
            Transport::Mistral,
        )
        .unwrap();
        t.consume(
            &json!({"type":"transcription.text.delta","text":"lo"}),
            Transport::Mistral,
        )
        .unwrap();
        assert_eq!(t.text(), "hello");
        assert!(!t.complete(Transport::Mistral, true, 0));
        t.consume(
            &json!({"type":"transcription.done","text":"Hello."}),
            Transport::Mistral,
        )
        .unwrap();
        assert_eq!(t.text(), "Hello.");
        assert!(t.complete(Transport::Mistral, true, 0));
        for kind in [
            "error",
            "Error",
            "conversation.item.input_audio_transcription.failed",
        ] {
            assert!(t.consume(&json!({"type":kind}), Transport::OpenAi).is_err());
        }
    }

    #[test]
    fn unfinalized_or_unacknowledged_audio_always_requires_whole_take_recovery() {
        let mut t = Transcript::default();
        t.consume(&json!({"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"Only the beginning"}), Transport::OpenAi).unwrap();
        assert!(!t.complete(Transport::OpenAi, true, 1));
        let mut dg = Transcript::default();
        dg.consume(&json!({"type":"Results","start":0.0,"is_final":false,"channel":{"alternatives":[{"transcript":"Unfinished"}]}}), Transport::Deepgram).unwrap();
        dg.consume(&json!({"type":"Metadata"}), Transport::Deepgram)
            .unwrap();
        assert!(!dg.complete(Transport::Deepgram, true, 0));
    }

    #[tokio::test]
    async fn overloaded_audio_queue_marks_the_entire_stream_failed() {
        let (tx, _rx) = mpsc::channel(1);
        let failed = Arc::new(AtomicBool::new(false));
        let sink = LiveSink {
            tx,
            failed: failed.clone(),
            failure: Arc::new(Notify::new()),
        };
        sink.append(vec![1; 100], 48000, 1);
        assert!(!failed.load(Ordering::SeqCst));
        sink.append(vec![1; 100], 48000, 1);
        assert!(failed.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn openai_socket_streams_before_stop_then_waits_for_the_final_tail() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            socket
                .send(Message::Text(
                    json!({"type":"session.created"}).to_string().into(),
                ))
                .await
                .unwrap();
            let update: Value =
                serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap())
                    .unwrap();
            assert_eq!(update["session"]["audio"]["input"]["format"]["rate"], 24000);
            assert_eq!(
                update["session"]["audio"]["input"]["transcription"]["model"],
                "gpt-4o-mini-transcribe"
            );
            assert!(update["session"]["audio"]["input"]["turn_detection"].is_null());
            socket
                .send(Message::Text(
                    json!({"type":"session.updated"}).to_string().into(),
                ))
                .await
                .unwrap();
            let mut commits = 0;
            let mut bytes = 0;
            while let Some(Ok(message)) = socket.next().await {
                let event: Value = serde_json::from_str(message.to_text().unwrap()).unwrap();
                if event["type"] == "input_audio_buffer.append" {
                    bytes += BASE64
                        .decode(event["audio"].as_str().unwrap())
                        .unwrap()
                        .len();
                }
                if event["type"] == "input_audio_buffer.commit" {
                    commits += 1;
                    let id = if commits == 1 { "first" } else { "tail" };
                    for event in [
                        json!({"type":"input_audio_buffer.committed","item_id":id,"previous_item_id":if commits == 1 { None } else { Some("first") }}),
                        json!({"type":"conversation.item.input_audio_transcription.delta","item_id":id,"delta":"provisional"}),
                        json!({"type":"conversation.item.input_audio_transcription.completed","item_id":id,"transcript":if commits == 1 { "First words." } else { "Last words." }}),
                    ] {
                        socket
                            .send(Message::Text(event.to_string().into()))
                            .await
                            .unwrap();
                    }
                    if commits == 2 {
                        // Four seconds of speech, a pause, then the rest: the first turn ends in the pause.
                        assert_eq!(bytes, 240000);
                        break;
                    }
                }
            }
        });
        let (tx, rx) = mpsc::channel(4);
        let (partial_tx, mut partial_rx) = mpsc::unbounded_channel();
        let client = tokio::spawn(exchange(
            Capability {
                transport: Transport::OpenAi,
                model: "gpt-4o-mini-transcribe".into(),
                url: reqwest::Url::parse(&url).unwrap(),
                rate: 24000,
            },
            "local-test-placeholder".into(),
            crate::provider::SpeechHints::default(),
            rx,
            move |text| {
                let _ = partial_tx.send(text.to_owned());
            },
        ));
        for samples in [vec![1200; 48000 * 4 * 2], vec![0; 48000], vec![1200; 48000]] {
            tx.send(Audio {
                samples,
                rate: 48000,
                channels: 2,
            })
            .await
            .unwrap();
        }
        let partial = tokio::time::timeout(Duration::from_secs(5), partial_rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(!partial.is_empty()); // sender remains open: text is delivered while still recording.
        drop(tx);
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(5), client)
                .await
                .unwrap()
                .unwrap(),
            Ok("First words. Last words.".into())
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn disconnected_socket_never_returns_a_partial_success() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            socket.send(Message::Text(json!({"type":"Results","start":0.0,"is_final":true,"channel":{"alternatives":[{"transcript":"Beginning only."}]}}).to_string().into())).await.unwrap();
            socket.close(None).await.unwrap();
        });
        let (_tx, rx) = mpsc::channel(1);
        let result = exchange(
            Capability {
                transport: Transport::Deepgram,
                model: "nova-3".into(),
                url: reqwest::Url::parse(&url).unwrap(),
                rate: 16000,
            },
            "local-test-placeholder".into(),
            crate::provider::SpeechHints::default(),
            rx,
            |_| {},
        )
        .await;
        assert_eq!(result, Err(()));
        server.await.unwrap();
    }

    #[tokio::test]
    #[allow(clippy::result_large_err)] // The WebSocket library fixes the callback's error type.
    async fn deepgram_streams_pcm_before_stop_and_waits_for_final_results_and_metadata() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_hdr_async(
                stream,
                |request: &tokio_tungstenite::tungstenite::handshake::server::Request, response| {
                    // Use a boolean assertion so an authentication failure cannot print a key.
                    assert!(request.headers()["Authorization"] == "Token local-test-placeholder");
                    Ok(response)
                },
            )
            .await
            .unwrap();
            let first = socket.next().await.unwrap().unwrap();
            assert!(first.is_binary());
            assert_eq!(first.len(), 3200); // 100 ms of mono PCM16 at 16 kHz.
            socket.send(Message::Text(json!({"type":"Results","start":0.0,"is_final":false,"channel":{"alternatives":[{"transcript":"provisional"}]}}).to_string().into())).await.unwrap();
            let mut bytes = first.len();
            while let Some(Ok(message)) = socket.next().await {
                if let Message::Binary(packet) = message {
                    bytes += packet.len();
                    continue;
                }
                let event: Value = serde_json::from_str(message.to_text().unwrap()).unwrap();
                assert_eq!(event["type"], "CloseStream");
                assert_eq!(bytes, 3680); // Includes the 15 ms tail, without padding.
                for event in [
                    json!({"type":"Results","start":0.0,"is_final":true,"channel":{"alternatives":[{"transcript":"All the final words."}]}}),
                    json!({"type":"Metadata"}),
                ] {
                    socket
                        .send(Message::Text(event.to_string().into()))
                        .await
                        .unwrap();
                }
                break;
            }
        });
        let (tx, rx) = mpsc::channel(4);
        let (partial_tx, mut partial_rx) = mpsc::unbounded_channel();
        let client = tokio::spawn(exchange(
            Capability {
                transport: Transport::Deepgram,
                model: "nova-3".into(),
                url: reqwest::Url::parse(&url).unwrap(),
                rate: 16000,
            },
            "local-test-placeholder".into(),
            crate::provider::SpeechHints::default(),
            rx,
            move |text| {
                let _ = partial_tx.send(text.to_owned());
            },
        ));
        tx.send(Audio {
            samples: vec![1200; 5520],
            rate: 48000,
            channels: 1,
        })
        .await
        .unwrap();
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(5), partial_rx.recv())
                .await
                .unwrap()
                .unwrap(),
            "provisional"
        );
        assert!(!client.is_finished());
        drop(tx);
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(5), client)
                .await
                .unwrap()
                .unwrap(),
            Ok("All the final words.".into())
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn openai_pads_a_short_final_turn_and_replaces_continuous_deltas() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            socket
                .send(Message::Text(
                    json!({"type":"session.created"}).to_string().into(),
                ))
                .await
                .unwrap();
            let update: Value =
                serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap())
                    .unwrap();
            assert_eq!(
                update["session"]["audio"]["input"]["transcription"]["model"],
                "gpt-live-transcribe"
            );
            assert_eq!(
                update["session"]["audio"]["input"]["transcription"]["prompt"],
                "OpenScribe"
            );
            socket
                .send(Message::Text(
                    json!({"type":"session.updated"}).to_string().into(),
                ))
                .await
                .unwrap();
            // This take is shorter than one packet, so the client sends it on stop.
            let append: Value =
                serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap())
                    .unwrap();
            assert_eq!(append["type"], "input_audio_buffer.append");
            let mut bytes = BASE64
                .decode(append["audio"].as_str().unwrap())
                .unwrap()
                .len();
            socket.send(Message::Text(json!({"type":"conversation.item.input_audio_transcription.delta","item_id":"one","delta":"Live"}).to_string().into())).await.unwrap();
            while let Some(Ok(message)) = socket.next().await {
                let event: Value = serde_json::from_str(message.to_text().unwrap()).unwrap();
                if event["type"] == "input_audio_buffer.append" {
                    bytes += BASE64
                        .decode(event["audio"].as_str().unwrap())
                        .unwrap()
                        .len();
                    continue;
                }
                assert_eq!(event["type"], "input_audio_buffer.commit");
                assert_eq!(bytes, 4800); // Minimum 100 ms, including silence padding.
                for event in [
                    json!({"type":"input_audio_buffer.committed","item_id":"one","previous_item_id":null}),
                    json!({"type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"Live words."}),
                ] {
                    socket
                        .send(Message::Text(event.to_string().into()))
                        .await
                        .unwrap();
                }
                break;
            }
        });
        let (tx, rx) = mpsc::channel(4);
        let client = tokio::spawn(exchange(
            Capability {
                transport: Transport::OpenAi,
                model: "gpt-live-transcribe".into(),
                url: reqwest::Url::parse(&url).unwrap(),
                rate: 24000,
            },
            "local-test-placeholder".into(),
            crate::provider::SpeechHints {
                prompt: Some("OpenScribe".into()),
                terms: vec![],
            },
            rx,
            |_| {},
        ));
        tx.send(Audio {
            samples: vec![1200; 240],
            rate: 24000,
            channels: 1,
        })
        .await
        .unwrap();
        drop(tx);
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(5), client)
                .await
                .unwrap()
                .unwrap(),
            Ok("Live words.".into())
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn cancelling_a_stalled_session_handshake_closes_the_socket() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let (connected_tx, connected_rx) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            connected_tx.send(()).unwrap();
            // Never send session.created: cancellation must interrupt readiness too.
            let message = tokio::time::timeout(Duration::from_secs(5), socket.next())
                .await
                .unwrap();
            assert!(
                message.is_none()
                    || message.is_some_and(
                        |message| message.is_err() || matches!(message, Ok(Message::Close(_)))
                    )
            );
        });
        let (_tx, rx) = mpsc::channel(1);
        let client = tauri::async_runtime::spawn(exchange(
            Capability {
                transport: Transport::OpenAi,
                model: "gpt-4o-mini-transcribe".into(),
                url: reqwest::Url::parse(&url).unwrap(),
                rate: 24000,
            },
            "local-test-placeholder".into(),
            crate::provider::SpeechHints::default(),
            rx,
            |_| {},
        ));
        tokio::time::timeout(Duration::from_secs(5), connected_rx)
            .await
            .unwrap()
            .unwrap();
        client.abort(); // LiveSession::drop uses the same runtime abort handle.
        assert!(client.await.is_err());
        server.await.unwrap();
    }
}
