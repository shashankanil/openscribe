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
}

#[derive(Default)]
pub struct RecorderState(pub Mutex<Option<ActiveRecording>>);

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
) -> Result<PathBuf, String> {
    let mut guard = state
        .0
        .lock()
        .map_err(|_| "Recorder is unavailable".to_string())?;
    if guard.is_some() {
        return Err("A recording is already active.".into());
    }
    std::fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
    let path = directory.join(format!("{}.wav", uuid::Uuid::new_v4()));
    let thread_path = path.clone();
    let (stop_tx, stop_rx) = mpsc::channel();
    let (ready_tx, ready_rx) = mpsc::channel();
    let thread = thread::spawn(move || record(thread_path, device_id, stop_rx, ready_tx));
    match ready_rx.recv_timeout(Duration::from_secs(5)) {
        Ok(Ok(())) => {
            *guard = Some(ActiveRecording {
                path: path.clone(),
                started: Instant::now(),
                stop: stop_tx,
                thread,
            });
            Ok(path)
        }
        Ok(Err(error)) => {
            let _ = thread.join();
            Err(error)
        }
        Err(_) => Err("The audio device did not start in time.".into()),
    }
}

pub fn stop(state: &RecorderState) -> Result<(PathBuf, f64), String> {
    let active = state
        .0
        .lock()
        .map_err(|_| "Recorder is unavailable".to_string())?
        .take()
        .ok_or_else(|| "No recording is active.".to_string())?;
    let duration = active.started.elapsed().as_secs_f64();
    let _ = active.stop.send(());
    active
        .thread
        .join()
        .map_err(|_| "The recorder stopped unexpectedly.".to_string())??;
    Ok((active.path, duration))
}

fn record(
    path: PathBuf,
    device_id: Option<String>,
    stop: mpsc::Receiver<()>,
    ready: mpsc::Sender<Result<(), String>>,
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
    let config = supported.config();
    let stream = match supported.sample_format() {
        cpal::SampleFormat::F32 => build_stream::<f32>(&device, &config, writer.clone(), on_error),
        cpal::SampleFormat::I16 => build_stream::<i16>(&device, &config, writer.clone(), on_error),
        cpal::SampleFormat::U16 => build_stream::<u16>(&device, &config, writer.clone(), on_error),
        format => Err(format!("Unsupported audio sample format: {format:?}")),
    }?;
    stream.play().map_err(|error| error.to_string())?;
    let _ = ready.send(Ok(()));
    let _ = stop.recv();
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
) -> Result<cpal::Stream, String>
where
    T: cpal::SizedSample + ToI16,
{
    device
        .build_input_stream(
            config,
            move |samples: &[T], _| {
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
