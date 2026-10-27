//! Meeting manifests, transcript presentation, and the capture/processing state machine.
use crate::{
    apple_time::{apple_now, Id, APPLE_EPOCH},
    meeting_audio::{self, TrackRecording},
    storage::{self, AppSettings, ProfileState},
    summary::{self, MeetingSummary},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    cmp::Ordering as CmpOrdering,
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Instant,
};
use tauri::{Emitter, Manager};

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MeetingStatus {
    Recording,
    Paused,
    #[default]
    Saved,
    Transcribing,
    Summarizing,
    Ready,
    Interrupted,
    Failed,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct MeetingSegment {
    pub id: String,
    pub track: String,
    pub start: f64,
    pub duration: f64,
    pub text: String,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct MeetingRecord {
    pub id: Id,
    pub title: String,
    pub created_at: f64,
    pub duration: f64,
    pub status: MeetingStatus,
    pub summarize_on_stop: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub live_transcription: Option<bool>,
    pub includes_microphone: bool,
    pub includes_system_audio: bool,
    #[serde(serialize_with = "AppSettings::meeting_snapshot")]
    pub settings: AppSettings,
    pub segments: Vec<MeetingSegment>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<MeetingSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovery_notice: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    pub microphone_label: String,
    pub system_label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_notes: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary_needs_confirmation: Option<bool>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}
impl Default for MeetingRecord {
    fn default() -> Self {
        Self {
            id: Id::default(),
            title: String::new(),
            created_at: apple_now(),
            duration: 0.0,
            status: MeetingStatus::Saved,
            summarize_on_stop: true,
            live_transcription: None,
            includes_microphone: true,
            includes_system_audio: true,
            settings: AppSettings::default(),
            segments: vec![],
            summary: None,
            recovery_notice: None,
            last_error: None,
            microphone_label: "Microphone".into(),
            system_label: "System audio".into(),
            user_notes: None,
            summary_needs_confirmation: None,
            extra: BTreeMap::new(),
        }
    }
}
pub fn segment_order(a: &MeetingSegment, b: &MeetingSegment) -> CmpOrdering {
    a.start.total_cmp(&b.start).then_with(|| a.id.cmp(&b.id))
}
pub fn timestamp(seconds: f64) -> String {
    let seconds = seconds.max(0.0) as u64;
    format!("{:02}:{:02}", seconds / 60, seconds % 60)
}
#[derive(Clone, Debug, PartialEq)]
pub struct Passage {
    pub id: String,
    pub start: f64,
    pub track: String,
    pub text: String,
    pub segment_ids: Vec<String>,
}
pub fn passages(segments: &[MeetingSegment], track: Option<&str>) -> Vec<Passage> {
    let mut sorted: Vec<_> = segments
        .iter()
        .filter(|s| track.is_none_or(|t| s.track == t) && !s.text.trim().is_empty())
        .collect();
    sorted.sort_by(|a, b| segment_order(a, b));
    let mut passages: Vec<Passage> = vec![];
    let mut last: BTreeMap<&str, (usize, f64)> = BTreeMap::new();
    for s in sorted {
        if let Some((index, end)) = last
            .get(s.track.as_str())
            .copied()
            .filter(|(i, end)| s.start - end <= 3.0 && s.start - passages[*i].start < 90.0)
        {
            passages[index].text.push(' ');
            passages[index].text.push_str(s.text.trim());
            passages[index].segment_ids.push(s.id.clone());
            let _ = end;
            last.insert(&s.track, (index, s.start + s.duration));
        } else {
            let index = passages.len();
            passages.push(Passage {
                id: s.id.clone(),
                start: s.start,
                track: s.track.clone(),
                text: s.text.trim().into(),
                segment_ids: vec![s.id.clone()],
            });
            last.insert(&s.track, (index, s.start + s.duration));
        }
    }
    passages.sort_by(|a, b| a.start.total_cmp(&b.start).then_with(|| a.id.cmp(&b.id)));
    passages
}
impl MeetingRecord {
    pub fn checkpoint(&mut self, chunk: MeetingSegment) {
        if !self.segments.iter().any(|s| s.id == chunk.id) {
            self.duration = self.duration.max(chunk.start + chunk.duration);
            self.segments.push(chunk);
            self.segments.sort_by(segment_order);
        }
    }
    pub fn needs_summary_confirmation(&self, summarize: bool, summary_only: bool) -> bool {
        summarize && !summary_only && self.word_count() < 80
    }
    pub fn word_count(&self) -> usize {
        self.segments
            .iter()
            .map(|s| s.text.split_whitespace().count())
            .sum()
    }
    pub fn transcript(&self) -> String {
        passages(&self.segments, None)
            .iter()
            .map(|p| {
                format!(
                    "[{}] {}\n{}",
                    timestamp(p.start),
                    if p.track == "microphone" {
                        &self.microphone_label
                    } else {
                        &self.system_label
                    },
                    p.text
                )
            })
            .collect::<Vec<_>>()
            .join("\n\n")
    }
    pub fn markdown_with_date(&self, formatted_date: &str) -> String {
        let mut result = format!("# {}\n\n{formatted_date}\n\n", self.title);
        if let Some(notes) = self
            .user_notes
            .as_deref()
            .map(str::trim)
            .filter(|n| !n.is_empty())
        {
            result.push_str(&format!("## My notes\n\n{notes}\n\n"));
        }
        if let Some(summary) = &self.summary {
            for (heading, points) in [
                ("Summary", &summary.overview),
                ("Decisions", &summary.decisions),
                ("Action items", &summary.actions),
            ] {
                result.push_str(&format!("## {heading}\n\n"));
                if points.is_empty() {
                    result.push_str("None identified.\n\n");
                } else {
                    result.push_str(
                        &points
                            .iter()
                            .map(|p| {
                                let stamps = p
                                    .sources
                                    .iter()
                                    .filter_map(|id| self.segments.iter().find(|s| &s.id == id))
                                    .map(|s| timestamp(s.start))
                                    .collect::<Vec<_>>()
                                    .join(", ");
                                format!("- {} [{stamps}]", p.text)
                            })
                            .collect::<Vec<_>>()
                            .join("\n"),
                    );
                    result.push_str("\n\n");
                }
            }
        }
        result.push_str("## Transcript\n\n");
        result.push_str(&self.transcript());
        result
    }
    pub fn markdown(&self) -> String {
        let unix = (self.created_at + APPLE_EPOCH) as i64;
        let date = chrono::DateTime::from_timestamp(unix, 0)
            .unwrap_or_default()
            .with_timezone(&chrono::Local);
        self.markdown_with_date(&crate::apple_time::formatted_local_date(date))
    }
}

pub struct MeetingStore {
    pub root: PathBuf,
    pub records: BTreeMap<Id, MeetingRecord>,
    pub errors: Vec<String>,
}
impl MeetingStore {
    pub fn open(root: PathBuf) -> Self {
        let mut store = Self {
            root,
            records: BTreeMap::new(),
            errors: vec![],
        };
        if let Err(e) = fs::create_dir_all(&store.root) {
            store.errors.push(e.to_string());
            return store;
        }
        let dirs = match fs::read_dir(&store.root) {
            Ok(d) => d,
            Err(e) => {
                store.errors.push(e.to_string());
                return store;
            }
        };
        for entry in dirs.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            let id = match name.parse::<Id>() {
                Ok(id) if id.to_string() == name => id,
                _ => continue,
            };
            if storage::safe_path(&store.root, &name).is_err() {
                store.errors.push(
                    "A meeting directory is outside the profile. Its files were preserved.".into(),
                );
                continue;
            }
            match storage::read_json::<MeetingRecord>(&entry.path().join("meeting.json")) {
                Ok(mut record) if record.id == id => {
                    if matches!(
                        record.status,
                        MeetingStatus::Recording
                            | MeetingStatus::Paused
                            | MeetingStatus::Transcribing
                            | MeetingStatus::Summarizing
                    ) {
                        record.status = MeetingStatus::Interrupted;
                        record.last_error = Some("Interrupted session. Saved audio and completed transcript sections are available for recovery.".into());
                        match meeting_audio::inventory(&entry.path(), false) {
                            Ok(inventory) => {
                                for chunk in &inventory.chunks {
                                    record.duration =
                                        record.duration.max(chunk.start + chunk.duration);
                                }
                                record.recovery_notice = recovery_notice(inventory.unreadable);
                            }
                            Err(e) => store.errors.push(e),
                        }
                        if let Err(e) =
                            storage::atomic_json(&entry.path().join("meeting.json"), &record)
                        {
                            store.errors.push(e);
                        }
                    }
                    store.records.insert(id, record);
                }
                Ok(_) => {}
                Err(e) => store.errors.push(format!(
                    "A meeting could not be loaded. Its files have been preserved: {e}"
                )),
            }
        }
        store
    }
    pub fn directory(&self, id: Id) -> PathBuf {
        self.root.join(id.to_string())
    }
    pub fn validated_directory(&self, id: Id) -> Result<PathBuf, String> {
        storage::safe_path(&self.root, &id.to_string())
    }
    pub fn get(&self, id: Id) -> Result<MeetingRecord, String> {
        self.records
            .get(&id)
            .cloned()
            .ok_or("The meeting was not found.".into())
    }
    pub fn save(&mut self, record: MeetingRecord) -> Result<(), String> {
        storage::atomic_json(
            &self.validated_directory(record.id)?.join("meeting.json"),
            &record,
        )
        .map_err(|e| format!("Meeting changes could not be saved: {e}"))?;
        self.records.insert(record.id, record);
        Ok(())
    }
    pub fn audio_path(&self, id: Id, segment_id: &str) -> Result<PathBuf, String> {
        if Path::new(segment_id).extension().and_then(|s| s.to_str()) != Some("wav") {
            return Err("Only meeting WAV files can be opened.".into());
        }
        storage::safe_path(&self.validated_directory(id)?, segment_id)
    }
    pub fn list(&self) -> Vec<MeetingRecord> {
        let mut records: Vec<_> = self.records.values().cloned().collect();
        records.sort_by(|a, b| b.created_at.total_cmp(&a.created_at));
        records
    }
}
fn recovery_notice(count: usize) -> Option<String> {
    (count>0).then(||format!("Recovered readable audio, but {count} audio section(s) could not be read. This transcript may be incomplete; the original files were preserved."))
}
struct ActiveMeeting {
    id: Id,
    origin: Instant,
    tracks: Vec<TrackRecording>,
    failure: Arc<Mutex<Option<String>>>,
    meter: Arc<Mutex<[f32; 2]>>,
    live_stop: Arc<AtomicBool>,
    live_cancel: Arc<AtomicBool>,
    live_running: Arc<AtomicBool>,
}
struct Controller {
    store: MeetingStore,
    active: Option<ActiveMeeting>,
    busy: Option<Id>,
    cancel: Arc<AtomicBool>,
}
#[derive(Default)]
pub struct MeetingState {
    inner: Mutex<Option<Controller>>,
    pipeline: tokio::sync::Mutex<()>,
}
fn controller<T>(
    app: &tauri::AppHandle,
    operation: impl FnOnce(&mut Controller) -> Result<T, String>,
) -> Result<T, String> {
    let state = app.state::<MeetingState>();
    let mut inner = state
        .inner
        .lock()
        .map_err(|_| "Meetings are unavailable.")?;
    if inner.is_none() {
        // Run profile migration before opening meeting manifests.
        storage::with_profile(app, &app.state::<ProfileState>(), |_| Ok(()))?;
        *inner = Some(Controller {
            store: MeetingStore::open(
                app.path()
                    .app_data_dir()
                    .map_err(|e| e.to_string())?
                    .join("Meetings"),
            ),
            active: None,
            busy: None,
            cancel: Arc::new(AtomicBool::new(false)),
        });
    }
    operation(inner.as_mut().expect("initialized meetings"))
}
fn emit(app: &tauri::AppHandle, record: &MeetingRecord) {
    let _ = app.emit("meeting://changed", record);
}
fn save(app: &tauri::AppHandle, c: &mut Controller, record: MeetingRecord) -> Result<(), String> {
    c.store.save(record.clone())?;
    emit(app, &record);
    Ok(())
}
fn progress(app: &tauri::AppHandle, id: Id, message: &str) {
    let _ = app.emit("meeting://progress", json!({"id":id,"message":message}));
}
fn start_sources(
    _app: &tauri::AppHandle,
    c: &mut Controller,
    record: &MeetingRecord,
) -> Result<(), String> {
    let active = c.active.as_mut().ok_or("No meeting is active.")?;
    *active
        .meter
        .lock()
        .map_err(|_| "Audio meter is unavailable.")? = [0.0; 2];
    *active
        .failure
        .lock()
        .map_err(|_| "Audio recorder is unavailable.")? = None;
    let part = meeting_audio::part_directory(&c.store.validated_directory(record.id)?);
    let mut tracks = vec![];
    let settings = &record.settings;
    if record.includes_system_audio {
        tracks.push(meeting_audio::start_track(
            part.join("system"),
            true,
            settings.string("systemAudioDeviceId").into(),
            active.origin,
            active.failure.clone(),
            active.meter.clone(),
        )?);
    }
    if record.includes_microphone {
        tracks.push(meeting_audio::start_track(
            part.join("microphone"),
            false,
            settings.string("microphoneDeviceUID").into(),
            active.origin,
            active.failure.clone(),
            active.meter.clone(),
        )?);
    }
    active.tracks = tracks;
    Ok(())
}
fn stop_sources(
    app: &tauri::AppHandle,
    c: &mut Controller,
    final_stop: bool,
) -> Result<Id, String> {
    let active = c.active.as_mut().ok_or("No meeting is active.")?;
    let id = active.id;
    let elapsed = active.origin.elapsed().as_secs_f64();
    let mut failure = None;
    for track in std::mem::take(&mut active.tracks) {
        if let Err(e) = track.stop() {
            failure = Some(e);
        }
    }
    if let Ok(mut meter) = active.meter.lock() {
        *meter = [0.0; 2];
    }
    let mut record = c.store.get(id)?;
    record.duration = elapsed;
    record.status = if final_stop {
        MeetingStatus::Saved
    } else {
        MeetingStatus::Paused
    };
    record.last_error = failure.clone();
    save(app, c, record)?;
    if let Some(e) = failure {
        progress(app, id, &e);
    }
    Ok(id)
}
#[tauri::command]
pub fn list_meetings(app: tauri::AppHandle) -> Result<Vec<MeetingRecord>, String> {
    controller(&app, |c| {
        if !c.store.errors.is_empty() {
            return Err(c.store.errors.join("\n\n"));
        }
        Ok(c.store.list())
    })
}
#[tauri::command]
pub fn start_meeting(
    app: tauri::AppHandle,
    title: String,
    microphone: bool,
    system_audio: bool,
    summarize_on_stop: bool,
    live_transcription: bool,
) -> Result<MeetingRecord, String> {
    let activity = app.state::<crate::integration::ActivityState>();
    let _start = activity.start_gate()?;
    if crate::integration::dictation_busy(&app) {
        return Err("Finish your dictation before starting a meeting.".into());
    }
    let result = controller(&app, |c| {
        if c.active.is_some() || c.busy.is_some() {
            return Err("A meeting is already active or processing.".into());
        }
        if !microphone && !system_audio {
            return Err("Choose microphone, system audio, or both.".into());
        }
        let settings = storage::with_profile(&app, &app.state::<ProfileState>(), |s| {
            Ok(s.settings.clone())
        })?;
        let title = if title.trim().is_empty() {
            format!(
                "Meeting {}",
                chrono::Local::now().format("%b %-d, %Y, %-I:%M %p")
            )
        } else {
            title
        };
        let mut record = MeetingRecord {
            title,
            status: MeetingStatus::Recording,
            includes_microphone: microphone,
            includes_system_audio: system_audio,
            summarize_on_stop,
            live_transcription: Some(live_transcription),
            settings,
            ..MeetingRecord::default()
        };
        c.store.save(record.clone())?;
        if let Err(error) = storage::with_profile(&app, &app.state::<ProfileState>(), |s| {
            s.link_meeting(&record)
        }) {
            record.status = MeetingStatus::Failed;
            record.last_error = Some(error.clone());
            save(&app, c, record)?;
            return Err(error);
        }
        c.active = Some(ActiveMeeting {
            id: record.id,
            origin: Instant::now(),
            tracks: vec![],
            failure: Arc::new(Mutex::new(None)),
            meter: Arc::new(Mutex::new([0.0; 2])),
            live_stop: Arc::new(AtomicBool::new(false)),
            live_cancel: Arc::new(AtomicBool::new(false)),
            live_running: Arc::new(AtomicBool::new(false)),
        });
        if let Err(e) = start_sources(&app, c, &record) {
            c.active = None;
            record.status = MeetingStatus::Failed;
            record.last_error = Some(e.clone());
            save(&app, c, record)?;
            return Err(e);
        }
        emit(&app, &record);
        Ok(record)
    })?;
    start_monitor(app.clone(), result.id);
    if live_transcription {
        start_live(app.clone(), result.id)?;
    }
    Ok(result)
}
fn start_monitor(app: tauri::AppHandle, id: Id) {
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            let keep = controller(&app, |c| {
                let Some(active) = c.active.as_ref().filter(|a| a.id == id) else {
                    return Ok(false);
                };
                if c.store.get(id)?.status == MeetingStatus::Recording {
                    let level = active.meter.lock().map(|v| v[0].max(v[1])).unwrap_or(0.0);
                    let _ = app.emit("meeting://level", json!({"level":level}));
                }
                let error = active.failure.lock().ok().and_then(|mut e| e.take());
                if let Some(error) = error {
                    let _ = stop_sources(&app, c, false);
                    let mut record = c.store.get(id)?;
                    record.last_error = Some(error.clone());
                    save(&app, c, record)?;
                    progress(&app, id, &error);
                }
                Ok(true)
            })
            .unwrap_or(false);
            if !keep {
                break;
            }
        }
    });
}
/// Screenshots link to a meeting only while it records or is paused.
pub fn active_meeting_id(app: &tauri::AppHandle) -> Option<String> {
    capture_status(app)
        .ok()
        .and_then(|(id, _)| id.map(|id| id.to_string()))
}
/// Includes stop-time uploads/summaries. Startup/pause/resume are synchronous
/// controller transitions; a status read waits until their actual state is known.
/// Unlike controller(), a status read never opens/migrates storage.
pub fn capture_status(app: &tauri::AppHandle) -> Result<(Option<Id>, bool), String> {
    let state = app.state::<MeetingState>();
    let inner = state
        .inner
        .lock()
        .map_err(|_| "Meetings are unavailable.")?;
    let Some(c) = inner.as_ref() else {
        return Ok((None, false));
    };
    Ok(controller_capture_status(c))
}
fn controller_capture_status(c: &Controller) -> (Option<Id>, bool) {
    let id = c.active.as_ref().and_then(|active| {
        c.store
            .records
            .get(&active.id)
            .filter(|record| {
                matches!(
                    record.status,
                    MeetingStatus::Recording | MeetingStatus::Paused
                )
            })
            .map(|record| record.id)
    });
    (id, c.busy.is_some())
}
#[tauri::command]
pub fn pause_meeting(app: tauri::AppHandle) -> Result<(), String> {
    controller(&app, |c| {
        let id = c.active.as_ref().ok_or("No meeting is active.")?.id;
        if c.store.get(id)?.status != MeetingStatus::Recording {
            return Err("The meeting is not recording.".into());
        }
        stop_sources(&app, c, false).map(|_| ())
    })
}
#[tauri::command]
pub fn resume_meeting(app: tauri::AppHandle) -> Result<(), String> {
    let id = controller(&app, |c| {
        let id = c.active.as_ref().ok_or("No meeting is active.")?.id;
        let mut record = c.store.get(id)?;
        if record.status != MeetingStatus::Paused {
            return Err("The meeting is not paused.".into());
        }
        start_sources(&app, c, &record)?;
        record.status = MeetingStatus::Recording;
        record.last_error = None;
        save(&app, c, record)?;
        Ok(id)
    })?;
    start_live(app, id)
}
#[tauri::command]
pub async fn finish_meeting(app: tauri::AppHandle, summarize: Option<bool>) -> Result<(), String> {
    let finish = prepare_finish(&app, summarize)?;
    complete_finish(app, finish).await
}
struct PendingFinish {
    id: Id,
    process: bool,
    summarize: bool,
    cancel: Arc<AtomicBool>,
}
fn prepare_finish(
    app: &tauri::AppHandle,
    summarize: Option<bool>,
) -> Result<PendingFinish, String> {
    controller(app, |c| {
        if c.busy.is_some() {
            return Err("The meeting is busy. Wait for the current operation to finish.".into());
        }
        let id = stop_sources(app, c, true)?;
        reserve_finish(c, id, summarize)
    })
}
fn reserve_finish(
    c: &mut Controller,
    id: Id,
    summarize: Option<bool>,
) -> Result<PendingFinish, String> {
    let record = c.store.get(id)?;
    let active = c.active.take().ok_or("No meeting is active.")?;
    active.live_stop.store(true, Ordering::SeqCst);
    if summarize == Some(false) {
        active.live_cancel.store(true, Ordering::SeqCst);
    }
    // Reserve until the live upload has checkpointed and processing finishes.
    c.busy = Some(id);
    c.cancel = active.live_cancel;
    let summary = summarize.unwrap_or(record.summarize_on_stop);
    Ok(PendingFinish {
        id,
        process: summarize != Some(false) && (summary || record.live_transcription == Some(true)),
        summarize: summary,
        cancel: c.cancel.clone(),
    })
}
/// Calendar calls this under its own mutex: reserve/stop synchronously, then
/// schedule the async tail without block_on or any calendar state access.
pub fn finish_in_background(app: tauri::AppHandle, summarize: Option<bool>) -> Result<(), String> {
    let finish = prepare_finish(&app, summarize)?;
    let id = finish.id;
    tauri::async_runtime::spawn(async move {
        if let Err(error) = complete_finish(app.clone(), finish).await {
            progress(&app, id, &error);
        }
    });
    Ok(())
}
async fn complete_finish(app: tauri::AppHandle, finish: PendingFinish) -> Result<(), String> {
    // Wait for the in-flight live upload to checkpoint before taking missing chunks.
    if finish.process {
        run_processing(app, finish.id, false, finish.summarize, finish.cancel).await
    } else {
        let state = app.state::<MeetingState>();
        let _gate = state.pipeline.lock().await;
        controller(&app, |c| {
            c.busy = None;
            Ok(())
        })
    }
}
async fn cancelled<T>(
    token: &Arc<AtomicBool>,
    future: impl std::future::Future<Output = Result<T, String>>,
) -> Result<T, String> {
    if token.load(Ordering::SeqCst) {
        return Err("Processing stopped. Completed sections are saved; you can resume.".into());
    }
    tokio::select! {result=future=>result,_=async{while !token.load(Ordering::SeqCst){tokio::time::sleep(std::time::Duration::from_millis(50)).await;}}=>Err("Processing stopped. Completed sections are saved; you can resume.".into())}
}
fn previous_track_text(segments: &[MeetingSegment], track: &str, start: f64) -> String {
    let mut previous: Vec<_> = segments
        .iter()
        .filter(|s| s.track == track && s.start < start)
        .collect();
    previous.sort_by(|a, b| segment_order(a, b));
    previous[previous.len().saturating_sub(2)..]
        .iter()
        .map(|s| s.text.trim())
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}
struct ChunkAudio {
    original: PathBuf,
    parts: Vec<PathBuf>,
}
impl Drop for ChunkAudio {
    fn drop(&mut self) {
        // Keep the recording, even when upload fails or its future is cancelled.
        for part in self.parts.iter().filter(|part| *part != &self.original) {
            let _ = fs::remove_file(part);
        }
    }
}
async fn transcribe_chunk(
    app: &tauri::AppHandle,
    id: Id,
    mut chunk: MeetingSegment,
    cancel: &Arc<AtomicBool>,
) -> Result<(), String> {
    let config = controller(app, |c| {
        let record = c.store.get(id)?;
        if record.segments.iter().any(|s| s.id == chunk.id) {
            return Ok(None);
        }
        let previous = previous_track_text(&record.segments, &chunk.track, chunk.start);
        Ok(Some((
            c.store.audio_path(id, &chunk.id)?,
            record.settings,
            previous,
        )))
    })?;
    let Some((path, settings, previous)) = config else {
        return Ok(());
    };
    let hints = crate::provider::hints_for_settings(&settings);
    // Carry sentences across chunk boundaries without mixing the two tracks.
    let hints = crate::provider::with_context(hints.as_ref(), &previous);
    let audio = tokio::task::spawn_blocking(move || {
        // Lift quiet speech in a copy; an hour keeps each short chunk in one part.
        let gain = crate::meeting_audio::speech_gain(&path).unwrap_or(1.0);
        let parts = if gain > 1.0 {
            crate::meeting_audio::split_wav_with_gain(&path, 3600, gain)?
        } else {
            vec![path.clone()]
        };
        // Own cleanup here too, in case the waiting future is dropped.
        Ok::<_, String>(ChunkAudio {
            original: path,
            parts,
        })
    })
    .await
    .map_err(|_| "Could not prepare the audio upload.".to_string())??;
    let path = audio.parts.first().unwrap_or(&audio.original);
    let result = cancelled(
        cancel,
        crate::provider::transcribe_reliably(path, &settings.provider_config(true), hints.as_ref()),
    )
    .await;
    drop(audio);
    let result = result?;
    if cancel.load(Ordering::SeqCst) {
        return Err("Processing stopped. Completed sections are saved; you can resume.".into());
    }
    chunk.text = if let Some(filter) = crate::provider::TRANSCRIPT_FILTER.get() {
        filter(&result.text, &settings)
    } else {
        result.text
    };
    controller(app, |c| {
        let mut latest = c.store.get(id)?;
        latest.checkpoint(chunk);
        save(app, c, latest)
    })
}
fn start_live(app: tauri::AppHandle, id: Id) -> Result<(), String> {
    let tokens = controller(&app, |c| {
        let active = c
            .active
            .as_ref()
            .filter(|a| a.id == id)
            .ok_or("No meeting is active.")?;
        if c.store.get(id)?.live_transcription != Some(true) {
            return Ok(None);
        }
        if active.live_running.swap(true, Ordering::SeqCst) {
            return Ok(None);
        }
        active.live_stop.store(false, Ordering::SeqCst);
        Ok(Some((
            active.live_stop.clone(),
            active.live_cancel.clone(),
            active.live_running.clone(),
        )))
    })?;
    if let Some((stop, cancel, running)) = tokens {
        tauri::async_runtime::spawn(async move {
            while !stop.load(Ordering::SeqCst) {
                let state = app.state::<MeetingState>();
                let gate = state.pipeline.lock().await;
                if stop.load(Ordering::SeqCst) {
                    break;
                }
                let next = controller(&app, |c| {
                    let record = c.store.get(id)?;
                    let inventory =
                        meeting_audio::inventory(&c.store.validated_directory(id)?, true)?;
                    Ok(inventory
                        .chunks
                        .into_iter()
                        .find(|s| !record.segments.iter().any(|done| done.id == s.id)))
                });
                let result = match next {
                    Ok(Some(chunk)) => {
                        progress(
                            &app,
                            id,
                            &format!("Transcribing {} Â· {}", chunk.track, timestamp(chunk.start)),
                        );
                        transcribe_chunk(&app, id, chunk, &cancel).await
                    }
                    Ok(None) => {
                        drop(gate);
                        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                        continue;
                    }
                    Err(e) => Err(e),
                };
                drop(gate);
                if let Err(error) = result {
                    if !stop.load(Ordering::SeqCst) {
                        let message = format!(
                            "Live transcription paused: {error} Audio is still being saved."
                        );
                        let _ = controller(&app, |c| {
                            let mut record = c.store.get(id)?;
                            record.last_error = Some(message.clone());
                            save(&app, c, record)
                        });
                        progress(&app, id, &message);
                    }
                    break;
                }
            }
            running.store(false, Ordering::SeqCst);
        });
    }
    Ok(())
}
#[tauri::command]
pub fn retry_live_transcription(app: tauri::AppHandle) -> Result<(), String> {
    let id = controller(&app, |c| {
        c.active
            .as_ref()
            .map(|a| a.id)
            .ok_or("No meeting is active.".into())
    })?;
    start_live(app, id)
}
#[tauri::command]
pub async fn process_meeting(app: tauri::AppHandle, id: Id) -> Result<(), String> {
    process(app, id, false, true).await
}
async fn process(
    app: tauri::AppHandle,
    id: Id,
    summary_only: bool,
    summarize: bool,
) -> Result<(), String> {
    let cancel = controller(&app, |c| {
        if c.active.is_some() || c.busy.is_some() {
            return Err("A meeting is already active or processing.".into());
        }
        c.store.get(id)?;
        c.busy = Some(id);
        c.cancel = Arc::new(AtomicBool::new(false));
        Ok(c.cancel.clone())
    })?;
    run_processing(app, id, summary_only, summarize, cancel).await
}
async fn run_processing(
    app: tauri::AppHandle,
    id: Id,
    summary_only: bool,
    summarize: bool,
    cancel: Arc<AtomicBool>,
) -> Result<(), String> {
    let state = app.state::<MeetingState>();
    let _gate = state.pipeline.lock().await;
    let result = process_inner(&app, id, summary_only, summarize, &cancel).await;
    controller(&app, |c| {
        c.busy = None;
        if let Err(e) = &result {
            let mut record = c.store.get(id)?;
            record.status = MeetingStatus::Failed;
            record.last_error = Some(e.clone());
            save(&app, c, record)?;
        }
        Ok(())
    })?;
    result
}
async fn process_inner(
    app: &tauri::AppHandle,
    id: Id,
    summary_only: bool,
    summarize: bool,
    cancel: &Arc<AtomicBool>,
) -> Result<(), String> {
    if cancel.load(Ordering::SeqCst) {
        return Err("Processing stopped. Completed sections are saved; you can resume.".into());
    }
    if !summary_only {
        let chunks = controller(app, |c| {
            let inventory = meeting_audio::inventory(&c.store.validated_directory(id)?, false)?;
            let mut record = c.store.get(id)?;
            // Migrated meetings have their transcript already, without new-layout WAVs.
            if inventory.chunks.is_empty() && record.segments.is_empty() {
                return Err(
                    "No readable audio was found. Check the selected sources and permissions."
                        .into(),
                );
            }
            record.recovery_notice = recovery_notice(inventory.unreadable);
            record.status = MeetingStatus::Transcribing;
            record.last_error = None;
            record.summary = None;
            save(app, c, record)?;
            Ok(inventory.chunks)
        })?;
        let mut last_failure = None;
        for (index, chunk) in chunks.iter().enumerate() {
            if cancel.load(Ordering::SeqCst) {
                return Err(
                    "Processing stopped. Completed sections are saved; you can resume.".into(),
                );
            }
            progress(
                app,
                id,
                &format!("Transcribing section {} of {}â€¦", index + 1, chunks.len()),
            );
            if let Err(error) = transcribe_chunk(app, id, chunk.clone(), cancel).await {
                if !crate::provider::is_transient(&error) {
                    return Err(error);
                }
                last_failure = Some(error);
            }
        }
        if let Some(error) = last_failure {
            return Err(error);
        }
    }
    let record = controller(app, |c| c.store.get(id))?;
    if !record.segments.iter().any(|s| !s.text.is_empty()) {
        return Err(
            "No readable audio was found. Check the selected sources and permissions.".into(),
        );
    }
    let short = record.needs_summary_confirmation(summarize, summary_only);
    if summarize && !short {
        controller(app, |c| {
            let mut record = c.store.get(id)?;
            record.status = MeetingStatus::Summarizing;
            save(app, c, record)
        })?;
        progress(app, id, "Summarizing with transcript referencesâ€¦");
        let result = cancelled(cancel, summary::summarize(&record)).await?;
        if cancel.load(Ordering::SeqCst) {
            return Err("Processing stopped. Completed sections are saved; you can resume.".into());
        }
        controller(app, |c| {
            let mut latest = c.store.get(id)?;
            latest.summary = Some(result);
            latest.summary_needs_confirmation = None;
            save(app, c, latest)
        })?;
    }
    if cancel.load(Ordering::SeqCst) {
        return Err("Processing stopped. Completed sections are saved; you can resume.".into());
    }
    controller(app, |c| {
        let mut latest = c.store.get(id)?;
        latest.status = MeetingStatus::Ready;
        latest.last_error = None;
        if short {
            latest.summary_needs_confirmation = Some(true);
        }
        save(app, c, latest)
    })
}
#[tauri::command]
pub async fn summarize_short_meeting(app: tauri::AppHandle, id: Id) -> Result<(), String> {
    skip_summary(app.clone(), id)?;
    process(app, id, true, true).await
}
#[tauri::command]
pub fn skip_summary(app: tauri::AppHandle, id: Id) -> Result<(), String> {
    controller(&app, |c| {
        let mut record = c.store.get(id)?;
        record.summary_needs_confirmation = None;
        save(&app, c, record)
    })
}
#[tauri::command]
pub fn cancel_processing(app: tauri::AppHandle) -> Result<(), String> {
    controller(&app, |c| {
        if c.active.is_none() {
            c.cancel.store(true, Ordering::SeqCst);
        }
        Ok(())
    })
}
#[tauri::command]
pub fn update_meeting(app: tauri::AppHandle, record: MeetingRecord) -> Result<(), String> {
    controller(&app, |c| {
        let mut latest = c.store.get(record.id)?;
        latest.title = record.title;
        latest.microphone_label = record.microphone_label;
        latest.system_label = record.system_label;
        latest.user_notes = record.user_notes;
        save(&app, c, latest)
    })
}
#[tauri::command]
pub fn delete_meeting(app: tauri::AppHandle, id: Id) -> Result<(), String> {
    controller(&app, |c| {
        if c.active.as_ref().is_some_and(|a| a.id == id) || c.busy == Some(id) {
            return Err("Stop recording or processing before deleting this meeting.".into());
        }
        c.store.get(id)?;
        storage::with_profile(&app, &app.state::<ProfileState>(), |s| {
            s.remove_meeting_entries(id)
        })?;
        let root = c.store.root.canonicalize().map_err(|e| e.to_string())?;
        let path = c
            .store
            .validated_directory(id)?
            .canonicalize()
            .map_err(|e| e.to_string())?;
        if path.parent() != Some(root.as_path()) {
            return Err("Invalid meeting directory.".into());
        }
        fs::remove_dir_all(path).map_err(|e| e.to_string())?;
        c.store.records.remove(&id);
        Ok(())
    })
}
#[tauri::command]
pub fn export_meeting_markdown(app: tauri::AppHandle, id: Id) -> Result<String, String> {
    controller(&app, |c| Ok(c.store.get(id)?.markdown()))
}
#[tauri::command]
pub fn list_meeting_audio_chunks(
    app: tauri::AppHandle,
    id: Id,
) -> Result<Vec<MeetingSegment>, String> {
    controller(&app, |c| {
        c.store.get(id)?;
        Ok(meeting_audio::inventory(&c.store.validated_directory(id)?, true)?.chunks)
    })
}
#[tauri::command]
pub fn meeting_audio_path(
    app: tauri::AppHandle,
    id: Id,
    segment_id: String,
) -> Result<String, String> {
    controller(&app, |c| {
        c.store.get(id)?;
        c.store
            .audio_path(id, &segment_id)
            .map(|p| p.to_string_lossy().into())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn capture_controller(record: MeetingRecord) -> Controller {
        let id = record.id;
        let mut store = MeetingStore {
            root: PathBuf::new(),
            records: BTreeMap::new(),
            errors: vec![],
        };
        store.records.insert(id, record);
        Controller {
            store,
            active: Some(ActiveMeeting {
                id,
                origin: Instant::now(),
                tracks: vec![],
                failure: Arc::new(Mutex::new(None)),
                meter: Arc::new(Mutex::new([0.0; 2])),
                live_stop: Arc::new(AtomicBool::new(false)),
                live_cancel: Arc::new(AtomicBool::new(false)),
                live_running: Arc::new(AtomicBool::new(false)),
            }),
            busy: None,
            cancel: Arc::new(AtomicBool::new(false)),
        }
    }
    #[test]
    fn chunk_context_uses_latest_two_earlier_segments_from_same_track() {
        let segment = |track: &str, start: f64, text: &str| MeetingSegment {
            track: track.into(),
            start,
            text: text.into(),
            ..MeetingSegment::default()
        };
        let segments = vec![
            segment("microphone", 45.0, "current"),
            segment("microphone", 30.0, " second "),
            segment("system", 40.0, "other track"),
            segment("microphone", 0.0, "oldest"),
            segment("microphone", 60.0, "future"),
            segment("microphone", 15.0, " first "),
        ];
        assert_eq!(
            previous_track_text(&segments, "microphone", 45.0),
            "first second"
        );
        assert_eq!(previous_track_text(&segments, "microphone", 15.0), "oldest");
        assert_eq!(
            previous_track_text(&segments, "system", 45.0),
            "other track"
        );
        assert_eq!(previous_track_text(&segments, "microphone", 0.0), "");
        assert_eq!(previous_track_text(&[], "microphone", 45.0), "");
    }
    #[test]
    fn chunk_audio_cleanup_removes_parts_and_preserves_original() {
        let dir = tempfile::tempdir().unwrap();
        let original = dir.path().join("chunk.wav");
        let part1 = dir.path().join("chunk-part1.wav");
        let part2 = dir.path().join("chunk-part2.wav");
        fs::write(&original, b"original").unwrap();
        fs::write(&part1, b"lifted").unwrap();
        fs::write(&part2, b"lifted").unwrap();
        drop(ChunkAudio {
            original: original.clone(),
            parts: vec![original.clone(), part1.clone(), part2.clone()],
        });
        assert_eq!(fs::read(&original).unwrap(), b"original");
        assert!(!part1.exists());
        assert!(!part2.exists());
    }
    #[test]
    fn capture_status_exposes_only_recording_or_paused_actual_id_and_processing_busy() {
        let record = MeetingRecord {
            status: MeetingStatus::Recording,
            ..Default::default()
        };
        let id = record.id;
        let mut controller = capture_controller(record);
        assert_eq!(controller_capture_status(&controller), (Some(id), false));
        for status in [
            MeetingStatus::Paused,
            MeetingStatus::Saved,
            MeetingStatus::Transcribing,
            MeetingStatus::Ready,
        ] {
            controller.store.records.get_mut(&id).unwrap().status = status;
            assert_eq!(
                controller_capture_status(&controller),
                ((status == MeetingStatus::Paused).then_some(id), false)
            );
        }
        controller.active = None;
        controller.busy = Some(id);
        assert_eq!(controller_capture_status(&controller), (None, true));
    }
    #[test]
    fn synchronous_calendar_finish_reserves_actual_id_and_honors_all_stop_modes() {
        for (summarize, preferred, live, process, summary, cancelled) in [
            (None, true, false, true, true, false),
            (None, false, true, true, false, false),
            (None, false, false, false, false, false),
            (Some(false), true, true, false, false, true),
            (Some(true), false, false, true, true, false),
        ] {
            let record = MeetingRecord {
                status: MeetingStatus::Saved,
                summarize_on_stop: preferred,
                live_transcription: Some(live),
                ..Default::default()
            };
            let id = record.id;
            let mut controller = capture_controller(record);
            let stopped = controller.active.as_ref().unwrap().live_stop.clone();
            let pending = reserve_finish(&mut controller, id, summarize).unwrap();
            assert_eq!(pending.id, id);
            assert_eq!(pending.process, process);
            assert_eq!(pending.summarize, summary);
            assert!(stopped.load(Ordering::SeqCst));
            assert_eq!(pending.cancel.load(Ordering::SeqCst), cancelled);
            assert_eq!(controller_capture_status(&controller), (None, true));
        }
    }
    #[test]
    fn silence_checkpoints_once_and_summary_threshold_requires_confirmation() {
        let mut record = MeetingRecord::default();
        let silence = MeetingSegment {
            id: "silence".into(),
            start: 15.0,
            duration: 15.0,
            ..MeetingSegment::default()
        };
        record.checkpoint(silence.clone());
        record.checkpoint(silence);
        assert_eq!(record.segments.len(), 1);
        assert_eq!(record.duration, 30.0);
        assert_eq!(record.segments[0].text, "");
        record.segments[0].text = "word ".repeat(79);
        assert!(record.needs_summary_confirmation(true, false));
        assert!(!record.needs_summary_confirmation(false, false));
        assert!(!record.needs_summary_confirmation(true, true));
        record.segments[0].text.push_str("eightieth");
        assert!(!record.needs_summary_confirmation(true, false));
    }
    #[tokio::test]
    async fn explicit_cancellation_stops_pending_work_but_normal_completion_returns() {
        let token = Arc::new(AtomicBool::new(false));
        assert_eq!(cancelled(&token, async { Ok(42) }).await.unwrap(), 42);
        let trigger = token.clone();
        let cancel = async move {
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
            trigger.store(true, Ordering::SeqCst);
        };
        let work = cancelled::<()>(&token, std::future::pending());
        let (_, result) = tokio::join!(cancel, work);
        assert!(result.unwrap_err().contains("Completed sections are saved"));
        let polled = AtomicBool::new(false);
        assert!(cancelled(&token, async {
            polled.store(true, Ordering::SeqCst);
            Ok(())
        })
        .await
        .is_err());
        assert!(!polled.load(Ordering::SeqCst));
    }
    #[test]
    fn swift_manifest_fixture_dates_defaults_snapshot_and_unknown_fields() {
        let fixture = r#"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","title":"Call","createdAt":782570000,"settings":{"speechProvider":"openAI"},"future":42}"#;
        let record: MeetingRecord = serde_json::from_str(fixture).unwrap();
        assert_eq!(record.created_at, 782570000.0);
        assert_eq!(record.status, MeetingStatus::Saved);
        assert_eq!(record.microphone_label, "Microphone");
        assert!(record.summarize_on_stop);
        assert!(record.live_transcription.is_none());
        let value = serde_json::to_value(record).unwrap();
        assert_eq!(value["future"], 42);
        assert!(value["createdAt"].is_number());
        assert!(value["settings"].get("shortcuts").is_none());
        assert_eq!(value["settings"]["microphoneDeviceUID"], "");
        assert_eq!(value["settings"].as_object().unwrap().len(), 10);
    }
    #[test]
    fn passages_group_each_track_with_gap_and_ninety_second_limit() {
        let s = |id: &str, track: &str, start: f64| MeetingSegment {
            id: id.into(),
            track: track.into(),
            start,
            duration: 15.0,
            text: id.into(),
            ..MeetingSegment::default()
        };
        let p = passages(
            &[
                s("a", "microphone", 0.0),
                s("b", "system", 0.0),
                s("c", "microphone", 15.0),
                s("d", "system", 15.0),
                s("e", "microphone", 90.0),
            ],
            None,
        );
        assert_eq!(p.len(), 3);
        assert_eq!(p[0].text, "a c");
        assert_eq!(p[1].text, "b d");
        assert_eq!(p[0].segment_ids, ["a", "c"]);
        assert_eq!(timestamp(-4.0), "00:00");
        assert_eq!(timestamp(3601.5), "60:01");
    }
    #[test]
    fn markdown_matches_swift_structure_and_citations() {
        let mut record = MeetingRecord {
            title: "Planning".into(),
            user_notes: Some("  Focus on release  ".into()),
            segments: vec![MeetingSegment {
                id: "a".into(),
                track: "microphone".into(),
                start: 65.0,
                duration: 1.0,
                text: "Ship Friday.".into(),
                ..MeetingSegment::default()
            }],
            ..MeetingRecord::default()
        };
        record.summary=Some(serde_json::from_value(json!({"overview":[{"text":"Release","sources":["a"]}],"decisions":[],"actions":[]})).unwrap());
        assert_eq!(record.markdown_with_date("10/19/2026, 4:28 PM"),"# Planning\n\n10/19/2026, 4:28 PM\n\n## My notes\n\nFocus on release\n\n## Summary\n\n- Release [01:05]\n\n## Decisions\n\nNone identified.\n\n## Action items\n\nNone identified.\n\n## Transcript\n\n[01:05] Microphone\nShip Friday.");
    }
    #[test]
    fn restart_marks_stale_and_preserves_completed_segments() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = MeetingStore::open(dir.path().into());
        let record = MeetingRecord {
            status: MeetingStatus::Recording,
            segments: vec![MeetingSegment {
                id: "kept".into(),
                text: "Already done".into(),
                ..MeetingSegment::default()
            }],
            ..MeetingRecord::default()
        };
        let id = record.id;
        store.save(record).unwrap();
        let part = meeting_audio::part_directory(&store.directory(id));
        let mut writer =
            meeting_audio::ChunkWriter::new(part.join("microphone"), 1, 10, 45.0).unwrap();
        writer.append(&[1; 10]).unwrap();
        writer.finish().unwrap();
        fs::write(part.join("microphone/chunk-00001.wav"), b"corrupt").unwrap();
        let store = MeetingStore::open(dir.path().into());
        let r = store.get(id).unwrap();
        assert_eq!(r.status, MeetingStatus::Interrupted);
        assert_eq!(r.segments[0].text, "Already done");
        assert!(r.last_error.is_some());
        assert_eq!(r.duration, 46.0);
        assert!(r
            .recovery_notice
            .as_deref()
            .unwrap()
            .contains("1 audio section(s)"));
        assert_eq!(
            meeting_audio::inventory(&store.directory(id), false)
                .unwrap()
                .chunks
                .len(),
            1
        );
        let persisted: MeetingRecord =
            storage::read_json(&store.directory(id).join("meeting.json")).unwrap();
        assert_eq!(persisted.status, MeetingStatus::Interrupted);
        assert!(store.audio_path(id, "../outside.wav").is_err());
        assert!(store.audio_path(id, "meeting.json").is_err());
    }
    #[test]
    fn corrupt_manifest_is_preserved_and_lowercase_directory_ignored() {
        let dir = tempfile::tempdir().unwrap();
        let id = Id::default();
        let path = dir.path().join(id.to_string());
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("meeting.json"), b"bad").unwrap();
        let store = MeetingStore::open(dir.path().into());
        assert_eq!(store.errors.len(), 1);
        assert_eq!(fs::read(path.join("meeting.json")).unwrap(), b"bad");
        let dir = tempfile::tempdir().unwrap();
        let r = MeetingRecord::default();
        storage::atomic_json(
            &dir.path()
                .join(r.id.to_string().to_lowercase())
                .join("meeting.json"),
            &r,
        )
        .unwrap();
        assert!(MeetingStore::open(dir.path().into()).records.is_empty());
    }
}
