//! Pure daily-note operations. Keep these in step with Models.swift and AppStore.swift.
use crate::apple_time::{Id, NoteDate};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashSet};

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct NoteCapture {
    pub id: Id,
    pub created_at: NoteDate,
    pub title: String,
    pub raw_text: String,
    pub text: String,
    pub duration: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_application: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_bundle_identifier: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<CaptureKind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attachment: Option<String>,
    #[serde(rename = "meetingID", skip_serializing_if = "Option::is_none")]
    pub meeting_id: Option<Id>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recognized_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub superseded: Option<bool>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum CaptureKind {
    #[default]
    Dictation,
    Screenshot,
    Meeting,
    Text,
}
impl NoteCapture {
    pub fn entry_kind(&self) -> CaptureKind {
        self.kind.unwrap_or_default()
    }
    pub fn visible(&self) -> bool {
        self.superseded != Some(true)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct VoiceNote {
    pub id: Id,
    pub created_at: NoteDate,
    pub title: String,
    pub raw_text: String,
    pub cleaned_text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edited_text: Option<String>,
    pub duration: f64,
    pub is_pinned: bool,
    pub tags: Vec<String>,
    pub source: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_application: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_bundle_identifier: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub captures: Option<Vec<NoteCapture>>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}
impl Default for VoiceNote {
    fn default() -> Self {
        Self {
            id: Id::default(),
            created_at: NoteDate::default(),
            title: String::new(),
            raw_text: String::new(),
            cleaned_text: String::new(),
            edited_text: None,
            duration: 0.0,
            is_pinned: false,
            tags: vec![],
            source: "Dictation".into(),
            source_application: None,
            source_bundle_identifier: None,
            captures: None,
            extra: BTreeMap::new(),
        }
    }
}
fn join<'a>(texts: impl IntoIterator<Item = &'a str>) -> String {
    texts
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n")
}
impl VoiceNote {
    pub fn display_text(&self) -> &str {
        if self.captures.is_some() && self.edited_text.is_none() {
            return &self.cleaned_text;
        }
        self.edited_text
            .as_deref()
            .unwrap_or(if self.cleaned_text.is_empty() {
                &self.raw_text
            } else {
                &self.cleaned_text
            })
    }
    pub fn display_title(&self) -> String {
        let name = self.title.trim();
        if !name.is_empty() && name != "Untitled note" {
            return name.into();
        }
        let words = self
            .display_text()
            .lines()
            .find(|s| !s.is_empty())
            .unwrap_or_default()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        if words.is_empty() {
            "Untitled note".into()
        } else {
            words.chars().take(64).collect()
        }
    }
    pub fn latest_text(&self) -> &str {
        self.captures
            .as_ref()
            .and_then(|c| c.iter().rev().find(|c| c.visible() && !c.text.is_empty()))
            .map(|c| c.text.as_str())
            .unwrap_or_else(|| self.display_text())
    }
    pub fn last_captured_at(&self) -> NoteDate {
        self.captures
            .as_ref()
            .and_then(|c| c.last())
            .map(|c| c.created_at)
            .unwrap_or(self.created_at)
    }
    pub fn as_capture(&self) -> NoteCapture {
        NoteCapture {
            id: self.id,
            created_at: self.created_at,
            title: self.title.clone(),
            raw_text: self.raw_text.clone(),
            text: self.display_text().into(),
            duration: self.duration,
            source_application: self.source_application.clone(),
            source_bundle_identifier: self.source_bundle_identifier.clone(),
            extra: self.extra.clone(),
            ..NoteCapture::default()
        }
    }
    pub fn append_captures(&mut self, incoming: Vec<NoteCapture>) {
        let known: HashSet<_> = self.captures.iter().flatten().map(|c| c.id).collect();
        let added: Vec<_> = incoming
            .into_iter()
            .filter(|c| !known.contains(&c.id))
            .collect();
        if added.is_empty() {
            return;
        }
        if let Some(edited) = &self.edited_text {
            self.edited_text = Some(join(
                std::iter::once(edited.as_str()).chain(added.iter().map(|c| c.text.as_str())),
            ));
        }
        let captures = self.captures.get_or_insert_with(Vec::new);
        captures.extend(added);
        captures.sort_by_key(|c| c.created_at);
        self.recompute_from_captures();
    }
    pub fn update_capture(&mut self, mut capture: NoteCapture) {
        if let Some(old) = self
            .captures
            .iter_mut()
            .flatten()
            .find(|c| c.id == capture.id)
        {
            let mut extra = old.extra.clone();
            extra.extend(capture.extra);
            capture.extra = extra;
            *old = capture;
            self.recompute_from_captures();
        }
    }
    pub fn remove_capture(&mut self, id: Id) {
        if let Some(c) = &mut self.captures {
            c.retain(|c| c.id != id);
        }
        self.recompute_from_captures();
    }
    pub fn recompute_from_captures(&mut self) {
        let entries = self.captures.as_deref().unwrap_or_default();
        self.raw_text = join(
            entries
                .iter()
                .filter(|c| c.entry_kind() != CaptureKind::Text)
                .map(|c| c.raw_text.as_str()),
        );
        self.cleaned_text = join(
            entries
                .iter()
                .filter(|c| c.visible())
                .map(|c| c.text.as_str()),
        );
        self.duration = entries.iter().map(|c| c.duration).sum();
        self.created_at = entries
            .first()
            .map(|c| c.created_at)
            .unwrap_or(self.created_at);
        let apps: BTreeSet<_> = entries
            .iter()
            .filter_map(|c| c.source_application.clone())
            .collect();
        self.source_application = if apps.len() == 1 {
            apps.into_iter().next()
        } else {
            None
        };
        let bundles: BTreeSet<_> = entries
            .iter()
            .filter_map(|c| c.source_bundle_identifier.clone())
            .collect();
        self.source_bundle_identifier = if bundles.len() == 1 {
            bundles.into_iter().next()
        } else {
            None
        };
    }
    pub fn migrated_to_timeline(mut self) -> Self {
        if let (Some(edited), Some(entries)) = (self.edited_text.clone(), self.captures.as_mut()) {
            self.edited_text = None;
            let visible: Vec<_> = entries.iter().filter(|c| c.visible()).collect();
            let start = visible
                .first()
                .map(|c| c.created_at)
                .unwrap_or(self.created_at);
            if edited != join(visible.iter().map(|c| c.text.as_str())) {
                for entry in entries.iter_mut().filter(|c| {
                    c.visible()
                        && matches!(c.entry_kind(), CaptureKind::Dictation | CaptureKind::Text)
                }) {
                    entry.superseded = Some(true);
                }
                let originals = join(entries.iter().filter(|c| c.superseded == Some(true)).map(
                    |c| {
                        if c.raw_text.is_empty() {
                            c.text.as_str()
                        } else {
                            c.raw_text.as_str()
                        }
                    },
                ));
                entries.push(NoteCapture {
                    created_at: start,
                    raw_text: originals,
                    text: edited,
                    kind: Some(CaptureKind::Text),
                    ..NoteCapture::default()
                });
                entries.sort_by_key(|c| c.created_at);
            }
            self.recompute_from_captures();
        }
        self
    }
    pub fn merging_new_captures(mut self, stored: &Self) -> Self {
        let mut extra = stored.extra.clone();
        extra.extend(self.extra);
        self.extra = extra;
        // Editors from older versions may omit newer capture fields.
        for capture in self.captures.iter_mut().flatten() {
            if let Some(previous) = stored
                .captures
                .iter()
                .flatten()
                .find(|c| c.id == capture.id)
            {
                let mut extra = previous.extra.clone();
                extra.extend(std::mem::take(&mut capture.extra));
                capture.extra = extra;
            }
        }
        let known: HashSet<_> = self.captures.iter().flatten().map(|c| c.id).collect();
        let added: Vec<_> = stored
            .captures
            .iter()
            .flatten()
            .filter(|c| !known.contains(&c.id))
            .cloned()
            .collect();
        if added.is_empty() {
            return self;
        }
        let edited = self.edited_text.as_ref().map(|_| {
            join(std::iter::once(self.display_text()).chain(added.iter().map(|c| c.text.as_str())))
        });
        self.append_captures(added);
        if edited.is_some() {
            self.edited_text = edited;
        }
        self
    }
    pub fn has_content(&self) -> bool {
        !self.display_text().trim().is_empty()
            || (!self.title.trim().is_empty() && self.title != "Untitled note")
    }
}
pub fn sort_notes(notes: &mut [VoiceNote]) {
    notes.sort_by_key(|n| std::cmp::Reverse(n.last_captured_at()));
}
pub fn add_to_day(notes: &mut Vec<VoiceNote>, capture: NoteCapture) -> VoiceNote {
    if let Some(saved) = notes
        .iter()
        .find(|n| n.id == capture.id || n.captures.iter().flatten().any(|c| c.id == capture.id))
    {
        return saved.clone();
    }
    let index = if let Some(i) = notes.iter().position(|n| {
        n.captures.is_some() && n.created_at.local_day() == capture.created_at.local_day()
    }) {
        i
    } else {
        notes.push(VoiceNote {
            id: capture.id,
            created_at: capture.created_at,
            title: capture.created_at.day_title(),
            captures: Some(vec![]),
            ..VoiceNote::default()
        });
        notes.len() - 1
    };
    notes[index].append_captures(vec![capture]);
    let result = notes[index].clone();
    sort_notes(notes);
    result
}
pub fn group_existing_dictations(notes: Vec<VoiceNote>) -> Vec<VoiceNote> {
    let mut grouped: Vec<_> = notes
        .iter()
        .filter(|n| n.source != "Dictation" || n.captures.is_some())
        .cloned()
        .collect();
    let mut old: Vec<_> = notes
        .into_iter()
        .filter(|n| n.source == "Dictation" && n.captures.is_none())
        .collect();
    old.sort_by_key(|n| n.created_at);
    for original in old {
        if let Some(daily) = grouped.iter_mut().find(|n| {
            n.captures.is_some() && n.created_at.local_day() == original.created_at.local_day()
        }) {
            daily.append_captures(vec![original.as_capture()]);
            daily.is_pinned |= original.is_pinned;
            daily.tags = daily
                .tags
                .iter()
                .chain(&original.tags)
                .cloned()
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect();
        } else {
            let capture = original.as_capture();
            let mut daily = original;
            daily.title = daily.created_at.day_title();
            daily.cleaned_text = daily.display_text().into();
            daily.captures = Some(vec![capture]);
            grouped.push(daily);
        }
    }
    sort_notes(&mut grouped);
    grouped
}

#[cfg(test)]
mod tests {
    use super::*;
    fn capture(text: &str, offset: i64) -> NoteCapture {
        NoteCapture {
            created_at: NoteDate(1_792_400_000 + offset),
            raw_text: text.into(),
            text: text.into(),
            duration: 2.0,
            ..NoteCapture::default()
        }
    }
    #[test]
    fn swift_fixture_round_trip_and_unknown_keys() {
        let raw = r#"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","createdAt":"2026-10-19T10:58:15Z","title":"","rawText":"Raw","cleanedText":"Clean","duration":1.25,"isPinned":false,"tags":[],"source":"Dictation","future":{"x":1},"captures":[{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","createdAt":"2026-10-19T10:58:15Z","title":"","rawText":"Raw","text":"Clean","duration":1.25,"kind":"dictation","meetingID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"}]}"#;
        let note: VoiceNote = serde_json::from_str(raw).unwrap();
        assert_eq!(
            serde_json::to_value(note).unwrap(),
            serde_json::from_str::<Value>(raw).unwrap()
        );
    }
    #[test]
    fn append_update_remove_recompute() {
        let mut notes = vec![];
        let first = capture("First", 0);
        let mut daily = add_to_day(&mut notes, first.clone());
        let mut second = capture("Second", 60);
        daily.append_captures(vec![second.clone(), first]);
        assert_eq!(daily.display_text(), "First\n\nSecond");
        assert_eq!(daily.duration, 4.0);
        second.text = "Changed".into();
        daily.update_capture(second.clone());
        assert_eq!(daily.latest_text(), "Changed");
        daily.remove_capture(second.id);
        assert_eq!(daily.display_text(), "First");
    }
    #[test]
    fn pending_empty_edit_preserves_new_capture_and_timeline_raw_history() {
        let mut notes = vec![];
        let mut pending = add_to_day(&mut notes, capture("Old", 0));
        pending.edited_text = Some(String::new());
        let stored = add_to_day(&mut notes, capture("New", 60));
        let merged = pending.merging_new_captures(&stored).migrated_to_timeline();
        assert_eq!(merged.display_text(), "New");
        assert_eq!(merged.raw_text, "Old\n\nNew");
        assert_eq!(merged.duration, 4.0);
        assert!(merged.edited_text.is_none());
    }
    #[test]
    fn grouping_manual_notes_pins_tags_titles_and_order() {
        let first = VoiceNote {
            title: "Custom".into(),
            created_at: NoteDate(1_792_400_000),
            raw_text: "Raw".into(),
            edited_text: Some("Edited".into()),
            tags: vec!["work".into()],
            ..VoiceNote::default()
        };
        let next = VoiceNote {
            created_at: NoteDate(first.created_at.0 + 60),
            cleaned_text: "Second".into(),
            is_pinned: true,
            tags: vec!["personal".into()],
            ..VoiceNote::default()
        };
        let manual = VoiceNote {
            source: "Note".into(),
            ..VoiceNote::default()
        };
        let grouped = group_existing_dictations(vec![next, manual, first]);
        assert_eq!(grouped.len(), 2);
        let daily = grouped.iter().find(|n| n.captures.is_some()).unwrap();
        assert_eq!(daily.display_text(), "Edited\n\nSecond");
        assert_eq!(daily.captures.as_ref().unwrap()[0].title, "Custom");
        assert!(daily.is_pinned);
        assert_eq!(daily.tags, ["personal", "work"]);
        assert_eq!(group_existing_dictations(grouped.clone()), grouped);
    }
    #[test]
    fn empty_day_and_title_fallback() {
        let n = VoiceNote {
            raw_text: "Must not return".into(),
            captures: Some(vec![]),
            ..VoiceNote::default()
        };
        assert_eq!(n.display_text(), "");
        assert_eq!(n.display_title(), "Untitled note");
    }
    #[test]
    fn editor_updates_keep_unknown_note_and_capture_fields() {
        let mut stored = VoiceNote {
            captures: Some(vec![capture("Old", 0)]),
            ..VoiceNote::default()
        };
        stored.extra.insert("futureNote".into(), Value::Bool(true));
        stored.captures.as_mut().unwrap()[0]
            .extra
            .insert("futureCapture".into(), Value::Bool(true));
        let mut edit = stored.clone();
        edit.extra.clear();
        let capture = &mut edit.captures.as_mut().unwrap()[0];
        capture.extra.clear();
        capture.text = "Updated".into();
        let merged = edit.merging_new_captures(&stored);
        assert_eq!(merged.extra["futureNote"], true);
        assert_eq!(merged.captures.unwrap()[0].extra["futureCapture"], true);
    }
}
