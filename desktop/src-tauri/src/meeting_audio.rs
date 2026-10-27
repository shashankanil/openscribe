//! Durable 15-second PCM chunks. A descriptor becomes final only after WAV finalization.
use crate::{
    apple_time::Id,
    meetings::MeetingSegment,
    storage::{atomic_json, read_json, safe_path},
};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File},
    io::BufWriter,
    path::{Path, PathBuf},
    sync::{mpsc, Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AudioChunkDescriptor {
    pub filename: String,
    pub start: f64,
    pub duration: f64,
}
struct OpenChunk {
    writer: hound::WavWriter<BufWriter<File>>,
    path: PathBuf,
    descriptor: AudioChunkDescriptor,
    samples: u32,
}
pub struct ChunkWriter {
    directory: PathBuf,
    spec: hound::WavSpec,
    index: u32,
    next_start: f64,
    current: Option<OpenChunk>,
}
impl ChunkWriter {
    pub fn new(directory: PathBuf, channels: u16, rate: u32, start: f64) -> Result<Self, String> {
        if channels == 0 || rate == 0 {
            return Err("Invalid audio format.".into());
        }
        fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        Ok(Self {
            directory,
            spec: hound::WavSpec {
                channels,
                sample_rate: rate,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            },
            index: 0,
            next_start: start,
            current: None,
        })
    }
    fn open(&mut self) -> Result<(), String> {
        let filename = format!("chunk-{:05}.wav", self.index);
        self.index += 1;
        let path = self.directory.join(&filename);
        let writer = hound::WavWriter::create(&path, self.spec).map_err(|e| e.to_string())?;
        let descriptor = AudioChunkDescriptor {
            filename,
            start: self.next_start,
            duration: 0.0,
        };
        atomic_json(&descriptor_path(&path), &descriptor)?;
        self.current = Some(OpenChunk {
            writer,
            path,
            descriptor,
            samples: 0,
        });
        Ok(())
    }
    pub fn append(&mut self, samples: &[i16]) -> Result<(), String> {
        let limit = self.spec.sample_rate as usize * self.spec.channels as usize * 15;
        let mut rest = samples;
        while !rest.is_empty() {
            if self.current.is_none() {
                self.open()?;
            }
            let chunk = self.current.as_mut().expect("open chunk");
            let count = rest.len().min(limit - chunk.samples as usize);
            for sample in &rest[..count] {
                chunk
                    .writer
                    .write_sample(*sample)
                    .map_err(|e| e.to_string())?;
            }
            chunk.samples += count as u32;
            rest = &rest[count..];
            if chunk.samples as usize >= limit {
                self.finish()?;
            }
        }
        Ok(())
    }
    pub fn append_at(&mut self, samples: &[i16], timestamp: f64) -> Result<(), String> {
        if let Some(chunk) = &self.current {
            let expected = chunk.descriptor.start
                + chunk.samples as f64 / self.spec.channels as f64 / self.spec.sample_rate as f64;
            if (timestamp - expected).abs() > 0.25 {
                self.finish()?;
            }
        }
        if self.current.is_none() {
            self.next_start = timestamp.max(0.0);
        }
        self.append(samples)
    }
    pub fn finish(&mut self) -> Result<(), String> {
        if let Some(mut chunk) = self.current.take() {
            chunk.writer.finalize().map_err(|e| e.to_string())?;
            if chunk.samples > 0 {
                chunk.descriptor.duration =
                    chunk.samples as f64 / self.spec.channels as f64 / self.spec.sample_rate as f64;
                atomic_json(&descriptor_path(&chunk.path), &chunk.descriptor)?;
                self.next_start = chunk.descriptor.start + chunk.descriptor.duration;
            } else {
                fs::remove_file(&chunk.path).map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }
}
fn descriptor_path(wav: &Path) -> PathBuf {
    wav.with_extension("wav.json")
}
#[derive(Default)]
pub struct Inventory {
    pub chunks: Vec<MeetingSegment>,
    pub unreadable: usize,
}
pub fn inventory(base: &Path, finalized_only: bool) -> Result<Inventory, String> {
    let mut result = Inventory::default();
    if !base.exists() {
        return Ok(result);
    }
    let canonical_base = base.canonicalize().map_err(|e| e.to_string())?;
    for part in fs::read_dir(&canonical_base).map_err(|e| e.to_string())? {
        let part = part.map_err(|e| e.to_string())?;
        if !part.file_type().map_err(|e| e.to_string())?.is_dir() {
            continue;
        }
        // Symlink/junction traversal is checked again for each WAV.
        for track in ["microphone", "system"] {
            let dir = part.path().join(track);
            if !dir.is_dir() {
                continue;
            }
            for entry in fs::read_dir(dir).map_err(|e| e.to_string())? {
                let entry = entry.map_err(|e| e.to_string())?;
                if entry.path().extension().and_then(|s| s.to_str()) != Some("wav") {
                    continue;
                }
                let relative = format!(
                    "{}/{}/{}",
                    part.file_name().to_string_lossy(),
                    track,
                    entry.file_name().to_string_lossy()
                );
                let path = match safe_path(&canonical_base, &relative) {
                    Ok(p) => p,
                    Err(_) => continue,
                };
                let descriptor = read_json::<AudioChunkDescriptor>(&descriptor_path(&path)).ok();
                if finalized_only
                    && !descriptor.as_ref().is_some_and(|d| {
                        d.duration > 0.0
                            && d.duration.is_finite()
                            && d.filename == entry.file_name().to_string_lossy()
                    })
                {
                    continue;
                }
                let audio = match hound::WavReader::open(&path) {
                    Ok(a) if a.duration() > 0 && a.spec().sample_rate > 0 => a,
                    _ => {
                        result.unreadable += 1;
                        continue;
                    }
                };
                let duration = audio.duration() as f64 / audio.spec().sample_rate as f64;
                let start = descriptor
                    .as_ref()
                    .map(|d| d.start)
                    .filter(|s| s.is_finite() && *s >= 0.0)
                    .unwrap_or(0.0);
                result.chunks.push(MeetingSegment {
                    id: relative,
                    track: track.into(),
                    start,
                    duration,
                    text: String::new(),
                    ..MeetingSegment::default()
                });
            }
        }
    }
    result.chunks.sort_by(crate::meetings::segment_order);
    Ok(result)
}

pub struct TrackRecording {
    stop: mpsc::Sender<()>,
    thread: Option<thread::JoinHandle<Result<(), String>>>,
}
impl TrackRecording {
    pub fn stop(mut self) -> Result<(), String> {
        let _ = self.stop.send(());
        self.thread
            .take()
            .expect("recorder thread")
            .join()
            .map_err(|_| "The audio recorder stopped unexpectedly.".to_string())?
    }
}
impl Drop for TrackRecording {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
pub fn start_track(
    directory: PathBuf,
    system: bool,
    device_id: String,
    origin: Instant,
    failure: Arc<Mutex<Option<String>>>,
    meter: Arc<Mutex<[f32; 2]>>,
) -> Result<TrackRecording, String> {
    let (stop_tx, stop_rx) = mpsc::channel();
    let (ready_tx, ready_rx) = mpsc::channel();
    let thread = thread::spawn(move || {
        let result = record(
            directory, system, device_id, origin, stop_rx, &ready_tx, meter,
        );
        if let Err(error) = &result {
            let _ = ready_tx.send(Err(error.clone()));
            if let Ok(mut slot) = failure.lock() {
                *slot = Some(error.clone());
            }
        }
        result
    });
    let recording = TrackRecording {
        stop: stop_tx,
        thread: Some(thread),
    };
    match ready_rx.recv_timeout(Duration::from_secs(10)) {
        Ok(Ok(())) => Ok(recording),
        Ok(Err(e)) => Err(e),
        Err(_) => Err("The audio device did not start in time.".into()),
    }
}
#[allow(clippy::too_many_arguments)]
fn record(
    directory: PathBuf,
    system: bool,
    device_id: String,
    origin: Instant,
    stop: mpsc::Receiver<()>,
    ready: &mpsc::Sender<Result<(), String>>,
    meter: Arc<Mutex<[f32; 2]>>,
) -> Result<(), String> {
    let host = cpal::default_host();
    let (device, supported) = if system {
        loopback_device(&host, &device_id)?
    } else {
        let device = if device_id.is_empty() {
            host.default_input_device()
                .ok_or("No microphone was found.")?
        } else {
            host.input_devices()
                .map_err(|e| e.to_string())?
                .find(|d| d.name().ok().as_deref() == Some(&device_id))
                .ok_or("The selected microphone is no longer available.")?
        };
        let supported = device.default_input_config().map_err(|e| e.to_string())?;
        (device, supported)
    };
    let writer = Arc::new(Mutex::new(ChunkWriter::new(
        directory,
        supported.channels(),
        supported.sample_rate().0,
        origin.elapsed().as_secs_f64(),
    )?));
    let error = Arc::new(Mutex::new(None));
    let level = Arc::new(Mutex::new(0.0_f32));
    let config = supported.config();
    let stream = match supported.sample_format() {
        cpal::SampleFormat::F32 => build::<f32>(
            &device,
            &config,
            writer.clone(),
            error.clone(),
            level.clone(),
            origin,
        ),
        cpal::SampleFormat::I16 => build::<i16>(
            &device,
            &config,
            writer.clone(),
            error.clone(),
            level.clone(),
            origin,
        ),
        cpal::SampleFormat::U16 => build::<u16>(
            &device,
            &config,
            writer.clone(),
            error.clone(),
            level.clone(),
            origin,
        ),
        format => Err(format!("Unsupported audio sample format: {format:?}")),
    }?;
    stream.play().map_err(|e| e.to_string())?;
    let _ = ready.send(Ok(()));
    loop {
        match stop.recv_timeout(Duration::from_millis(50)) {
            Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
        if let Some(e) = error
            .lock()
            .map_err(|_| "Audio recorder is unavailable.")?
            .take()
        {
            drop(stream);
            let _ = writer.lock().map(|mut w| w.finish());
            return Err(e);
        }
        let value = *level.lock().map_err(|_| "Audio meter is unavailable.")?;
        if let Ok(mut levels) = meter.lock() {
            levels[usize::from(system)] = value.clamp(0.0, 1.0);
        }
    }
    drop(stream);
    let result = writer
        .lock()
        .map_err(|_| "Could not finish the audio file.")?
        .finish();
    result
}
#[cfg(windows)]
fn loopback_device(
    host: &cpal::Host,
    device_id: &str,
) -> Result<(cpal::Device, cpal::SupportedStreamConfig), String> {
    let device = if device_id.is_empty() {
        host.default_output_device()
            .ok_or("No system audio output device was found.")?
    } else {
        host.output_devices()
            .map_err(|e| e.to_string())?
            .find(|d| d.name().ok().as_deref() == Some(device_id))
            .ok_or("The selected system audio output is no longer available.")?
    };
    // cpal's WASAPI backend enables AUDCLNT_STREAMFLAGS_LOOPBACK when building an
    // INPUT stream on a RENDER endpoint. No Stereo Mix device is involved.
    let supported = device.default_output_config().map_err(|e| e.to_string())?;
    Ok((device, supported))
}
#[cfg(not(windows))]
fn loopback_device(
    _: &cpal::Host,
    _: &str,
) -> Result<(cpal::Device, cpal::SupportedStreamConfig), String> {
    Err("System audio capture is not supported on this platform.".into())
}
fn build<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    writer: Arc<Mutex<ChunkWriter>>,
    errors: Arc<Mutex<Option<String>>>,
    level: Arc<Mutex<f32>>,
    origin: Instant,
) -> Result<cpal::Stream, String>
where
    T: cpal::SizedSample,
    i16: cpal::FromSample<T>,
{
    let error_slot = errors.clone();
    let samples_per_second = config.channels as f64 * config.sample_rate.0 as f64;
    device
        .build_input_stream(
            config,
            move |samples: &[T], info| {
                let timing = info.timestamp();
                let latency = timing
                    .callback
                    .duration_since(&timing.capture)
                    .unwrap_or_default();
                let duration = samples.len() as f64 / samples_per_second;
                let timestamp = origin.elapsed().as_secs_f64() - latency.as_secs_f64() - duration;
                let pcm: Vec<i16> = samples
                    .iter()
                    .map(|s| cpal::Sample::from_sample(*s))
                    .collect();
                if let Ok(mut meter) = level.lock() {
                    *meter = meter_level(&pcm);
                }
                if let Ok(mut w) = writer.lock() {
                    if let Err(e) = w.append_at(&pcm, timestamp) {
                        if let Ok(mut slot) = errors.lock() {
                            *slot = Some(e);
                        }
                    }
                }
            },
            move |error| {
                if let Ok(mut slot) = error_slot.lock() {
                    *slot = Some(format!("Audio recording interrupted: {error}"));
                }
            },
            None,
        )
        .map_err(|e| e.to_string())
}
pub fn rms(samples: &[i16]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    (samples
        .iter()
        .map(|s| (*s as f32 / 32768.0).powi(2))
        .sum::<f32>()
        / samples.len() as f32)
        .sqrt()
        .clamp(0.0, 1.0)
}

/// The meter shown in the Flowbar: the macOS recorder's mapping, so ordinary speech fills the line.
pub fn meter_level(samples: &[i16]) -> f32 {
    ((rms(samples) - 0.003) * 18.0).clamp(0.0, 1.0)
}
pub fn part_directory(base: &Path) -> PathBuf {
    base.join(Id::default().to_string())
}

/// Splits a dictation into pieces of at most `seconds`, like the macOS chunk store, so each
/// provider request stays short. A recording that already fits is returned as-is; otherwise the
/// pieces are written beside it as `<name>-part<N>.wav` and the caller removes them.
pub fn split_wav(path: &Path, seconds: u32) -> Result<Vec<PathBuf>, String> {
    split_wav_with_gain(path, seconds, 1.0)
}

/// Speech peaks are lifted toward this level (about −6 dBFS).
const SPEECH_TARGET: f64 = 0.5;
/// At most +20 dB, so a quiet laptop array becomes clear speech without room noise becoming loud.
pub(crate) const MAX_SPEECH_GAIN: f64 = 10.0;
/// Below about −48 dBFS a take holds no speech worth lifting; amplifying it invites invented text.
const SILENCE_LEVEL: f64 = 0.004;

/// The gain that brings a quiet dictation's speech up to a level providers transcribe reliably.
/// Built-in Windows microphone arrays often deliver speech near −30 dBFS, where transcription
/// drops whole phrases. Never turns audio down.
pub fn speech_gain(path: &Path) -> Result<f64, String> {
    let mut reader = hound::WavReader::open(path).map_err(|e| e.to_string())?;
    let spec = reader.spec();
    if spec.sample_format != hound::SampleFormat::Int || spec.bits_per_sample == 0 {
        return Ok(1.0);
    }
    let scale = 2.0_f64.powi(i32::from(spec.bits_per_sample) - 1);
    const BINS: usize = 2048;
    let mut histogram = vec![0_u64; BINS];
    let mut total = 0_u64;
    for sample in reader.samples::<i32>() {
        let level = (f64::from(sample.map_err(|e| e.to_string())?).abs() / scale).min(1.0);
        histogram[((level * (BINS - 1) as f64) as usize).min(BINS - 1)] += 1;
        total += 1;
    }
    if total == 0 {
        return Ok(1.0);
    }
    // The 99.9th percentile follows speech peaks while ignoring the odd click or bump.
    let threshold = total - total / 1000;
    let mut seen = 0;
    let mut peak = 1.0;
    for (bin, count) in histogram.iter().enumerate() {
        seen += count;
        if seen >= threshold {
            peak = (bin + 1) as f64 / BINS as f64;
            break;
        }
    }
    Ok(gain_for_peak(peak))
}

pub(crate) fn gain_for_peak(peak: f64) -> f64 {
    if peak < SILENCE_LEVEL {
        1.0
    } else {
        (SPEECH_TARGET / peak).clamp(1.0, MAX_SPEECH_GAIN)
    }
}

/// Applies gain, rounding off anything near full scale instead of clipping it.
pub(crate) fn lift(sample: f64, gain: f64) -> f64 {
    let value = sample * gain;
    let knee = 0.9;
    if value.abs() <= knee {
        return value;
    }
    value.signum() * (knee + (1.0 - knee) * ((value.abs() - knee) / (1.0 - knee)).tanh())
}

/// As [`split_wav`], with `gain` applied to every piece. The original recording is never changed,
/// so a lifted take is always written as pieces even when it fits in one.
pub fn split_wav_with_gain(path: &Path, seconds: u32, gain: f64) -> Result<Vec<PathBuf>, String> {
    let mut reader = hound::WavReader::open(path).map_err(|e| e.to_string())?;
    let spec = reader.spec();
    let frames_per_part = u64::from(spec.sample_rate) * u64::from(seconds.max(1));
    let lifted = gain > 1.001;
    if spec.channels == 0
        || spec.sample_format != hound::SampleFormat::Int
        || (!lifted && u64::from(reader.duration()) <= frames_per_part)
    {
        return Ok(vec![path.to_path_buf()]);
    }
    let scale = 2.0_f64.powi(i32::from(spec.bits_per_sample) - 1);
    let per_part = (frames_per_part * u64::from(spec.channels)) as usize;
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("recording");
    let mut parts: Vec<PathBuf> = Vec::new();
    let mut writer: Option<hound::WavWriter<BufWriter<File>>> = None;
    let mut written = 0;
    let result = (|| {
        for sample in reader.samples::<i32>() {
            let sample = sample.map_err(|e| e.to_string())?;
            if written % per_part == 0 {
                if let Some(done) = writer.take() {
                    done.finalize().map_err(|e| e.to_string())?;
                }
                let part = path.with_file_name(format!("{stem}-part{}.wav", parts.len() + 1));
                writer = Some(hound::WavWriter::create(&part, spec).map_err(|e| e.to_string())?);
                parts.push(part);
            }
            let sample = if lifted {
                (lift(f64::from(sample) / scale, gain) * (scale - 1.0)).round() as i32
            } else {
                sample
            };
            if let Some(w) = writer.as_mut() {
                w.write_sample(sample).map_err(|e| e.to_string())?;
            }
            written += 1;
        }
        if let Some(done) = writer.take() {
            done.finalize().map_err(|e| e.to_string())?;
        }
        Ok(())
    })();
    match result {
        Ok(()) => Ok(parts),
        Err(error) => {
            for part in &parts {
                let _ = fs::remove_file(part);
            }
            Err(error)
        }
    }
}

/// Compact uploads in memory; preserve the original recording and use an anti-aliasing
/// windowed-sinc filter for downsampling instead of dropping samples.
pub fn upload_wav(path: &Path) -> Result<Vec<u8>, String> {
    let mut reader = hound::WavReader::open(path).map_err(|e| e.to_string())?;
    let spec = reader.spec();
    if spec.channels == 0 || spec.sample_rate == 0 {
        return Err("Unreadable audio format.".into());
    }
    if spec.channels == 1
        && spec.sample_rate <= 16000
        && spec.bits_per_sample == 16
        && spec.sample_format == hound::SampleFormat::Int
    {
        return fs::read(path).map_err(|e| e.to_string());
    }
    let samples: Vec<f64> = match spec.sample_format {
        hound::SampleFormat::Float => reader
            .samples::<f32>()
            .map(|s| s.map(|s| s as f64))
            .collect::<Result<_, _>>(),
        hound::SampleFormat::Int => {
            let scale = 2.0_f64.powi(spec.bits_per_sample as i32 - 1);
            reader
                .samples::<i32>()
                .map(|s| s.map(|s| s as f64 / scale))
                .collect::<Result<_, _>>()
        }
    }
    .map_err(|e| e.to_string())?;
    let mono: Vec<f64> = samples
        .chunks_exact(spec.channels as usize)
        .map(|frame| frame.iter().sum::<f64>() / spec.channels as f64)
        .collect();
    let count = (mono.len() as f64 * 16000.0 / spec.sample_rate as f64).ceil() as usize;
    let cutoff = (16000.0 / spec.sample_rate as f64).min(1.0);
    let mut cursor = std::io::Cursor::new(vec![]);
    {
        let mut writer = hound::WavWriter::new(
            &mut cursor,
            hound::WavSpec {
                channels: 1,
                sample_rate: 16000,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            },
        )
        .map_err(|e| e.to_string())?;
        for i in 0..count {
            let center = i as f64 * spec.sample_rate as f64 / 16000.0;
            let mut value = 0.0;
            let mut weight = 0.0;
            for k in (center.floor() as isize - 32)..=(center.floor() as isize + 32) {
                if k < 0 || k as usize >= mono.len() {
                    continue;
                }
                let distance = center - k as f64;
                if distance.abs() > 32.0 {
                    continue;
                }
                let x = std::f64::consts::PI * distance * cutoff;
                let sinc = if x.abs() < 1e-10 { 1.0 } else { x.sin() / x };
                let w =
                    cutoff * sinc * 0.5 * (1.0 + (std::f64::consts::PI * distance / 32.0).cos());
                value += mono[k as usize] * w;
                weight += w;
            }
            let sample = if weight.abs() > 1e-10 {
                value / weight
            } else {
                0.0
            };
            writer
                .write_sample((sample.clamp(-1.0, 1.0) * 32767.0) as i16)
                .map_err(|e| e.to_string())?;
        }
        writer.finalize().map_err(|e| e.to_string())?;
    }
    Ok(cursor.into_inner())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dictation_splits_into_fifteen_second_pieces_without_losing_samples() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("take.wav");
        let spec = hound::WavSpec {
            channels: 2,
            sample_rate: 100,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut writer = hound::WavWriter::create(&path, spec).unwrap();
        for i in 0..(100 * 2 * 32) {
            writer.write_sample((i % 1000) as i16).unwrap();
        }
        writer.finalize().unwrap();
        let parts = split_wav(&path, 15).unwrap();
        let lengths: Vec<u32> = parts
            .iter()
            .map(|p| hound::WavReader::open(p).unwrap().duration())
            .collect();
        assert_eq!(lengths, [1500, 1500, 200]);
        let joined: Vec<i16> = parts
            .iter()
            .flat_map(|p| {
                hound::WavReader::open(p)
                    .unwrap()
                    .samples::<i16>()
                    .map(Result::unwrap)
                    .collect::<Vec<_>>()
            })
            .collect();
        let original: Vec<i16> = hound::WavReader::open(&path)
            .unwrap()
            .samples::<i16>()
            .map(Result::unwrap)
            .collect();
        assert_eq!(joined, original);
        assert_eq!(split_wav(&path, 40).unwrap(), std::slice::from_ref(&path));
    }
    fn tone(path: &Path, amplitude: f64, seconds: u32) {
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 1000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut writer = hound::WavWriter::create(path, spec).unwrap();
        for i in 0..(1000 * seconds) {
            let value = (f64::from(i) * 0.3).sin() * amplitude * 32767.0;
            writer.write_sample(value as i16).unwrap();
        }
        writer.finalize().unwrap();
    }
    fn peak(path: &Path) -> f64 {
        hound::WavReader::open(path)
            .unwrap()
            .samples::<i16>()
            .map(|s| f64::from(s.unwrap()).abs() / 32767.0)
            .fold(0.0, f64::max)
    }
    #[test]
    fn quiet_dictation_is_lifted_without_touching_the_recording() {
        let dir = tempfile::tempdir().unwrap();
        let quiet = dir.path().join("quiet.wav");
        tone(&quiet, 0.037, 3); // The level a Windows laptop array delivered in testing.
        let gain = speech_gain(&quiet).unwrap();
        assert!(gain > 9.9 && gain <= MAX_SPEECH_GAIN, "{gain}");
        let parts = split_wav_with_gain(&quiet, 15, gain).unwrap();
        assert_eq!(parts.len(), 1);
        assert_ne!(parts[0], quiet, "the original is kept as recorded");
        assert!((peak(&quiet) - 0.037).abs() < 0.001);
        assert!((peak(&parts[0]) - 0.37).abs() < 0.01, "{}", peak(&parts[0]));

        let loud = dir.path().join("loud.wav");
        tone(&loud, 0.8, 3);
        assert_eq!(speech_gain(&loud).unwrap(), 1.0, "never turned down");
        assert_eq!(split_wav_with_gain(&loud, 15, 1.0).unwrap(), [loud]);

        let silent = dir.path().join("silent.wav");
        tone(&silent, 0.002, 3);
        assert_eq!(
            speech_gain(&silent).unwrap(),
            1.0,
            "silence is not amplified"
        );
    }
    #[test]
    fn lifting_rounds_off_peaks_instead_of_clipping() {
        assert_eq!(lift(0.05, 10.0), 0.5);
        let high = lift(0.2, 10.0);
        assert!(high > 0.9 && high < 1.0, "{high}");
        assert!(lift(-0.2, 10.0) < -0.9);
    }
    #[test]
    fn meter_level_lets_speech_fill_the_flowbar() {
        assert_eq!(meter_level(&[]), 0.0);
        assert_eq!(meter_level(&[50; 64]), 0.0); // Room noise stays flat.
        let speech = meter_level(&[1600; 64]); // About 0.05 RMS, ordinary speech.
        assert!(speech > 0.8 && speech <= 1.0, "{speech}");
        assert_eq!(meter_level(&[i16::MAX; 64]), 1.0);
    }
    #[test]
    fn timestamp_gaps_close_partial_chunks_on_the_meeting_timeline() {
        let dir = tempfile::tempdir().unwrap();
        let mut writer = ChunkWriter::new(dir.path().into(), 1, 10, 0.0).unwrap();
        writer.append_at(&[0; 10], 2.0).unwrap();
        writer.append_at(&[0; 10], 3.0).unwrap();
        writer.append_at(&[0; 10], 12.0).unwrap();
        writer.finish().unwrap();
        let first: AudioChunkDescriptor =
            read_json(&dir.path().join("chunk-00000.wav.json")).unwrap();
        let second: AudioChunkDescriptor =
            read_json(&dir.path().join("chunk-00001.wav.json")).unwrap();
        assert_eq!((first.start, first.duration), (2.0, 2.0));
        assert_eq!((second.start, second.duration), (12.0, 1.0));
    }
    #[test]
    fn descriptors_closed_chunks_recovery_and_upload() {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().join("meeting");
        let part = part_directory(&base);
        let track = part.join("microphone");
        let mut writer = ChunkWriter::new(track.clone(), 2, 48000, 2.5).unwrap();
        writer.append(&vec![1000; 48000 * 2]).unwrap();
        let path = track.join("chunk-00000.wav");
        let d: AudioChunkDescriptor = read_json(&descriptor_path(&path)).unwrap();
        assert_eq!(d.duration, 0.0);
        assert_eq!(d.start, 2.5);
        assert!(inventory(&base, true).unwrap().chunks.is_empty());
        writer.finish().unwrap();
        let inv = inventory(&base, true).unwrap();
        assert_eq!(inv.chunks.len(), 1);
        assert!(!inv.chunks[0].id.contains('\\'));
        assert_eq!(inv.chunks[0].duration, 1.0);
        let d: AudioChunkDescriptor = read_json(&descriptor_path(&path)).unwrap();
        assert_eq!(d.duration, 1.0);
        let bytes = upload_wav(&path).unwrap();
        let audio = hound::WavReader::new(std::io::Cursor::new(bytes)).unwrap();
        assert_eq!(audio.spec().sample_rate, 16000);
        assert_eq!(audio.spec().channels, 1);
        assert_eq!(audio.duration(), 16000);
        // Stale zero-duration descriptors are excluded live, but readable WAVs recover at stop/restart.
        atomic_json(
            &descriptor_path(&path),
            &AudioChunkDescriptor { duration: 0.0, ..d },
        )
        .unwrap();
        assert!(inventory(&base, true).unwrap().chunks.is_empty());
        assert_eq!(inventory(&base, false).unwrap().chunks.len(), 1);
        fs::write(track.join("chunk-00001.wav"), b"corrupt").unwrap();
        assert_eq!(inventory(&base, false).unwrap().unreadable, 1);
    }
    #[test]
    fn fifteen_second_boundary_and_final_partial() {
        let dir = tempfile::tempdir().unwrap();
        let mut writer = ChunkWriter::new(dir.path().into(), 1, 10, 0.0).unwrap();
        writer.append(&[0; 151]).unwrap();
        let d: AudioChunkDescriptor = read_json(&dir.path().join("chunk-00000.wav.json")).unwrap();
        assert_eq!(d.duration, 15.0);
        let d: AudioChunkDescriptor = read_json(&dir.path().join("chunk-00001.wav.json")).unwrap();
        assert_eq!(d.duration, 0.0);
        assert_eq!(d.start, 15.0);
        writer.finish().unwrap();
        let d: AudioChunkDescriptor = read_json(&dir.path().join("chunk-00001.wav.json")).unwrap();
        assert_eq!(d.duration, 0.1);
    }
    #[test]
    fn descriptor_matches_swift_json() {
        let d: AudioChunkDescriptor =
            serde_json::from_str(r#"{"filename":"chunk-00003.wav","start":45,"duration":15}"#)
                .unwrap();
        assert_eq!(d.filename, "chunk-00003.wav");
        assert_eq!(
            serde_json::to_value(d).unwrap(),
            serde_json::json!({"filename":"chunk-00003.wav","start":45.0,"duration":15.0})
        );
    }
}
