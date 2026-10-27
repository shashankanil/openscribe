use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use serde::Serialize;
use std::{
    fs::File,
    io::BufWriter,
    path::PathBuf,
    sync::{mpsc, Arc, Mutex},
    thread,
    time::{Duration, Instant},
};
use tauri::Emitter;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioInput {
    pub id: String,
    pub name: String,
    pub likely_system_audio: bool,
}

pub struct ActiveRecording {
    pub path: PathBuf,
    pub started: Instant,
    stop: mpsc::Sender<()>,
    thread: thread::JoinHandle<Result<(), String>>,
    live: Option<crate::realtime::LiveSession>,
}

#[derive(Default)]
pub struct RecorderState(pub Mutex<Option<ActiveRecording>>);

/// Contended startup/finalization is busy as well as an established stream.
pub fn is_busy(state: &RecorderState) -> bool {
    state
        .0
        .try_lock()
        .map(|active| active.is_some())
        .unwrap_or(true)
}

pub fn inputs() -> Result<Vec<AudioInput>, String> {
    let host = cpal::default_host();
    let devices = host.input_devices().map_err(|error| error.to_string())?;
    let mut result = Vec::new();
    for device in devices {
        let name = device.name().unwrap_or_else(|_| "Audio input".into());
        let lower = name.to_lowercase();
        result.push(AudioInput {
            id: name.clone(),
            name,
            likely_system_audio: lower.contains("monitor")
                || lower.contains("stereo mix")
                || lower.contains("loopback")
                || lower.contains("what u hear"),
        });
    }
    result.sort_by_key(|input| input.name.to_lowercase());
    Ok(result)
}

pub fn start(
    state: &RecorderState,
    device_id: Option<String>,
    directory: PathBuf,
    app: tauri::AppHandle,
) -> Result<PathBuf, String> {
    let mut guard = state
        .0
        .lock()
        .map_err(|_| "Recorder is unavailable".to_string())?;
    if guard.is_some() {
        return Err("A recording is already active.".into());
    }
    std::fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
    let path = directory.join(format!("{}.wav", crate::apple_time::Id::default()));
    let thread_path = path.clone();
    let (sink, live) = match crate::realtime::LiveSession::start(&app, &path) {
        Some((sink, live)) => (Some(sink), Some(live)),
        None => (None, None),
    };
    let (stop_tx, stop_rx) = mpsc::channel();
    let (ready_tx, ready_rx) = mpsc::channel();
    let thread = thread::spawn(move || {
        let result = record(thread_path, device_id, stop_rx, &ready_tx, app, sink);
        if let Err(error) = &result {
            let _ = ready_tx.send(Err(error.clone()));
        }
        result
    });
    match ready_rx.recv_timeout(Duration::from_secs(5)) {
        Ok(Ok(())) => {
            *guard = Some(ActiveRecording {
                path: path.clone(),
                started: Instant::now(),
                stop: stop_tx,
                thread,
                live,
            });
            Ok(path)
        }
        Ok(Err(error)) => {
            let _ = thread.join();
            Err(error)
        }
        Err(_) => {
            let _ = stop_tx.send(());
            let _ = thread.join();
            Err("The audio device did not start in time.".into())
        }
    }
}

pub fn stop(
    state: &RecorderState,
) -> Result<(PathBuf, f64, Option<crate::realtime::LiveSession>), String> {
    let mut guard = state
        .0
        .lock()
        .map_err(|_| "Recorder is unavailable".to_string())?;
    let active = guard
        .take()
        .ok_or_else(|| "No recording is active.".to_string())?;
    let duration = active.started.elapsed().as_secs_f64();
    let _ = active.stop.send(());
    active
        .thread
        .join()
        .map_err(|_| "The recorder stopped unexpectedly.".to_string())??;
    Ok((active.path, duration, active.live))
}

/// Build both real WASAPI clients without playing streams or writing audio.
/// CPAL initializes IAudioClient here, so privacy/device errors fail readiness.
/// Classic desktop WASAPI does not request consent; users enable it in Settings.
#[cfg(windows)]
pub fn calendar_capture_ready(microphone: &str, system_audio: &str) -> Result<(), String> {
    let host = cpal::default_host();
    let input = if microphone.is_empty() {
        host.default_input_device()
            .ok_or("No microphone was found.")?
    } else {
        host.input_devices()
            .map_err(|e| e.to_string())?
            .find(|d| d.name().ok().as_deref() == Some(microphone))
            .ok_or("The selected microphone is no longer available.")?
    };
    let output = if system_audio.is_empty() {
        host.default_output_device()
            .ok_or("No system audio output device was found.")?
    } else {
        host.output_devices()
            .map_err(|e| e.to_string())?
            .find(|d| d.name().ok().as_deref() == Some(system_audio))
            .ok_or("The selected system audio output is no longer available.")?
    };
    let input_config = input.default_input_config().map_err(|e| e.to_string())?;
    let output_config = output.default_output_config().map_err(|e| e.to_string())?;
    fn probe(
        device: &cpal::Device,
        config: cpal::SupportedStreamConfig,
    ) -> Result<cpal::Stream, String> {
        if !matches!(
            config.sample_format(),
            cpal::SampleFormat::F32 | cpal::SampleFormat::I16 | cpal::SampleFormat::U16
        ) {
            return Err(format!(
                "Unsupported audio sample format: {:?}",
                config.sample_format()
            ));
        }
        device.build_input_stream_raw(&config.config(), config.sample_format(), |_, _| {}, |_| {}, None)
            .map_err(|e| format!("Audio access is not ready. Check Windows microphone privacy and audio devices: {e}"))
    }
    let _microphone = probe(&input, input_config)?;
    // An input stream on a WASAPI render endpoint is real loopback capture.
    let _system_audio = probe(&output, output_config)?;
    Ok(())
}
#[cfg(not(windows))]
pub fn calendar_capture_ready(_: &str, _: &str) -> Result<(), String> {
    Err("Automatic system audio capture is not supported on this platform.".into())
}

fn record(
    path: PathBuf,
    device_id: Option<String>,
    stop: mpsc::Receiver<()>,
    ready: &mpsc::Sender<Result<(), String>>,
    app: tauri::AppHandle,
    live: Option<crate::realtime::LiveSink>,
) -> Result<(), String> {
    let host = cpal::default_host();
    let device = if let Some(id) = device_id.filter(|value| !value.is_empty()) {
        host.input_devices()
            .map_err(|error| error.to_string())?
            .find(|device| device.name().ok().as_deref() == Some(id.as_str()))
            .ok_or_else(|| format!("Audio input ‘{id}’ is no longer available."))?
    } else {
        host.default_input_device()
            .ok_or_else(|| "No microphone was found.".to_string())?
    };
    let supported = device
        .default_input_config()
        .map_err(|error| error.to_string())?;
    let spec = hound::WavSpec {
        channels: supported.channels(),
        sample_rate: supported.sample_rate().0,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let writer = hound::WavWriter::create(&path, spec).map_err(|error| error.to_string())?;
    let writer = Arc::new(Mutex::new(Some(writer)));
    let errors = Arc::new(Mutex::new(None::<String>));
    let error_slot = errors.clone();
    let on_error = move |error: cpal::StreamError| {
        if let Ok(mut value) = error_slot.lock() {
            *value = Some(error.to_string());
        }
    };
    let level = Arc::new(Mutex::new(0.0_f32));
    let config = supported.config();
    let stream = match supported.sample_format() {
        cpal::SampleFormat::F32 => build_stream::<f32>(
            &device,
            &config,
            writer.clone(),
            on_error,
            level.clone(),
            live,
        ),
        cpal::SampleFormat::I16 => build_stream::<i16>(
            &device,
            &config,
            writer.clone(),
            on_error,
            level.clone(),
            live,
        ),
        cpal::SampleFormat::U16 => build_stream::<u16>(
            &device,
            &config,
            writer.clone(),
            on_error,
            level.clone(),
            live,
        ),
        format => Err(format!("Unsupported audio sample format: {format:?}")),
    }?;
    stream.play().map_err(|error| error.to_string())?;
    let _ = ready.send(Ok(()));
    while let Err(mpsc::RecvTimeoutError::Timeout) = stop.recv_timeout(Duration::from_millis(50)) {
        let value = level.lock().map(|v| *v).unwrap_or_default();
        let _ = app.emit("dictation://level", serde_json::json!({"level":value}));
        if errors.lock().ok().is_some_and(|e| e.is_some()) {
            break;
        }
    }
    drop(stream);
    if let Some(writer) = writer
        .lock()
        .map_err(|_| "Could not finish audio file".to_string())?
        .take()
    {
        writer.finalize().map_err(|error| error.to_string())?;
    }
    if let Some(error) = errors.lock().ok().and_then(|mut value| value.take()) {
        return Err(error);
    }
    Ok(())
}

trait ToI16 {
    fn to_i16(self) -> i16;
}
impl ToI16 for f32 {
    fn to_i16(self) -> i16 {
        (self.clamp(-1.0, 1.0) * i16::MAX as f32) as i16
    }
}
impl ToI16 for i16 {
    fn to_i16(self) -> i16 {
        self
    }
}
impl ToI16 for u16 {
    fn to_i16(self) -> i16 {
        (self as i32 - 32768) as i16
    }
}

fn build_stream<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    writer: Arc<Mutex<Option<hound::WavWriter<BufWriter<File>>>>>,
    on_error: impl FnMut(cpal::StreamError) + Send + 'static,
    level: Arc<Mutex<f32>>,
    live: Option<crate::realtime::LiveSink>,
) -> Result<cpal::Stream, String>
where
    T: cpal::SizedSample + ToI16,
{
    let rate = config.sample_rate.0;
    let channels = config.channels;
    device
        .build_input_stream(
            config,
            move |samples: &[T], _| {
                let pcm: Vec<i16> = samples.iter().map(|s| (*s).to_i16()).collect();
                if let Ok(mut meter) = level.lock() {
                    *meter = crate::meeting_audio::meter_level(&pcm);
                }
                if let Some(sink) = &live {
                    sink.append(pcm, rate, channels);
                }
                if let Ok(mut guard) = writer.lock() {
                    if let Some(writer) = guard.as_mut() {
                        for sample in samples {
                            let _ = writer.write_sample((*sample).to_i16());
                        }
                    }
                }
            },
            on_error,
            None,
        )
        .map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn calendar_treats_contended_recorder_start_and_stop_as_busy() {
        let recorder = RecorderState::default();
        assert!(!is_busy(&recorder));
        let transition = recorder.0.lock().unwrap();
        assert!(is_busy(&recorder));
        drop(transition);
        assert!(!is_busy(&recorder));
    }
}
