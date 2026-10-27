//! Explicit native smoke checks; never open devices during the ordinary test suite.
#![cfg(windows)]
use openscribe_desktop_lib::meeting_audio;
use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

#[test]
#[ignore = "opens the real microphone and WASAPI loopback for one second"]
fn microphone_and_wasapi_loopback_open_and_finalize() {
    let dir = tempfile::tempdir().unwrap();
    let meeting = dir.path().join("meeting");
    let part = meeting_audio::part_directory(&meeting);
    let failure = Arc::new(Mutex::new(None));
    let meter = Arc::new(Mutex::new([0.0; 2]));
    let origin = Instant::now();
    let system = meeting_audio::start_track(
        part.join("system"),
        true,
        String::new(),
        origin,
        failure.clone(),
        meter.clone(),
    )
    .expect("WASAPI loopback must open on the output endpoint");
    let microphone = meeting_audio::start_track(
        part.join("microphone"),
        false,
        String::new(),
        origin,
        failure.clone(),
        meter,
    )
    .expect("Microphone must open");
    std::thread::sleep(Duration::from_secs(1));
    microphone.stop().expect("Microphone must finalize");
    system.stop().expect("Loopback must finalize");
    let error = failure.lock().unwrap().clone();
    assert!(error.is_none(), "{error:?}");
    let inventory = meeting_audio::inventory(&meeting, true).unwrap();
    assert_eq!(inventory.unreadable, 0);
    println!("Native capture finalized {} audio sections; loopback can have no samples while the output is silent.", inventory.chunks.len());
    assert!(inventory
        .chunks
        .iter()
        .any(|chunk| chunk.track == "microphone"));
}
