use chrono::{DateTime, Duration, NaiveDate, NaiveDateTime, TimeZone, Utc};
use ical::{parser::ical::component::IcalEvent, property::Property};
use rrule::{RRule, RRuleSet, Tz};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    io::BufReader,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use tauri::{Emitter, Manager};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CalendarSource {
    pub id: String,
    pub name: String,
    pub url: Option<String>,
    pub file: Option<String>,
}
#[derive(Clone, Debug, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct CalendarSettings {
    pub calendar_enabled: bool,
    pub calendar_sources: Vec<CalendarSource>,
    pub calendar_excluded_titles: Vec<String>,
    pub calendar_auto_start: bool,
    pub calendar_meetings_only: bool,
    pub calendar_summarize: bool,
    pub meeting_live_transcription: bool,
}
impl Default for CalendarSettings {
    fn default() -> Self {
        Self {
            calendar_enabled: false,
            calendar_sources: vec![],
            calendar_excluded_titles: vec![],
            calendar_auto_start: true,
            calendar_meetings_only: true,
            calendar_summarize: true,
            meeting_live_transcription: true,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEvent {
    pub id: String,
    pub title: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    #[serde(rename = "calendarID")]
    pub calendar_id: String,
    pub calendar_name: String,
    pub link: Option<String>,
    pub has_attendees: bool,
    pub excluded: bool,
    pub is_all_day: bool,
}
impl CalendarEvent {
    pub fn matches_exclusion(&self, phrases: &[String]) -> bool {
        phrases
            .iter()
            .map(|p| p.trim().to_lowercase())
            .any(|p| !p.is_empty() && self.title.to_lowercase().contains(&p))
    }
    pub fn is_due(
        &self,
        now: DateTime<Utc>,
        settings: &CalendarSettings,
        handled: &HashSet<String>,
    ) -> bool {
        !self.excluded
            && !self.is_all_day
            && !self.matches_exclusion(&settings.calendar_excluded_titles)
            && settings
                .calendar_sources
                .iter()
                .any(|s| s.id == self.calendar_id)
            && !handled.contains(&self.id)
            && self.start <= now
            && now - self.start <= Duration::seconds(120)
            && self.end > now
            && (!settings.calendar_meetings_only || self.link.is_some() || self.has_attendees)
    }
}
pub fn meeting_link(text: &str) -> Option<String> {
    static RE: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r#"(?i)https://[^\s<>"\x00-\x1f]+"#).unwrap()
    });
    RE.find_iter(text)
        .filter_map(|m| {
            reqwest::Url::parse(m.as_str().trim_end_matches([')', ',', '.', ';', '!', '?'])).ok()
        })
        .find(|url| {
            url.scheme() == "https"
                && url.host_str().is_some_and(|host| {
                    [
                        "meet.google.com",
                        "zoom.us",
                        "teams.microsoft.com",
                        "teams.live.com",
                        "webex.com",
                    ]
                    .iter()
                    .any(|h| host == *h || host.ends_with(&format!(".{h}")))
                })
        })
        .map(|u| u.to_string())
}
fn prop<'a>(event: &'a IcalEvent, name: &str) -> Option<&'a Property> {
    event.properties.iter().find(|p| p.name == name)
}
fn value<'a>(event: &'a IcalEvent, name: &str) -> Option<&'a str> {
    prop(event, name).and_then(|p| p.value.as_deref())
}
fn param<'a>(p: &'a Property, name: &str) -> Option<&'a str> {
    p.params
        .as_ref()?
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))?
        .1
        .first()
        .map(String::as_str)
}
fn unescape(text: &str) -> String {
    let mut out = String::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n' | 'N') => out.push('\n'),
                Some(c) => out.push(c),
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}
fn timezone(p: &Property, fallback: Option<&str>) -> Result<Tz, String> {
    let Some(zone) = param(p, "TZID").or(fallback) else {
        return Ok(Tz::LOCAL);
    };
    let zone = zone.trim_matches('"');
    // Some exporters prefix standard IANA names with a vendor namespace.
    zone.parse::<chrono_tz::Tz>()
        .or_else(|_| {
            zone.strip_prefix("/freeassociation.sourceforge.net/")
                .unwrap_or(zone)
                .parse::<chrono_tz::Tz>()
        })
        .or_else(|_| {
            zone.parse::<windows_timezones::WindowsTimezone>()
                .ok()
                .and_then(|tz| tz.tzdb_id().parse::<chrono_tz::Tz>().ok())
                .ok_or(())
        })
        .map(Tz::from)
        .map_err(|_| {
            format!("Unsupported calendar time zone: {zone}. Use an ICS feed with IANA or standard Windows time zones.")
        })
}
fn date(p: &Property, fallback: Option<&str>) -> Result<DateTime<Tz>, String> {
    let value = p.value.as_deref().ok_or("Calendar date is missing.")?;
    let all_day = value.len() == 8;
    let naive = if all_day {
        NaiveDate::parse_from_str(value, "%Y%m%d")
            .map_err(|_| "Invalid calendar date.")?
            .and_hms_opt(0, 0, 0)
            .unwrap()
    } else {
        NaiveDateTime::parse_from_str(value.trim_end_matches('Z'), "%Y%m%dT%H%M%S")
            .map_err(|_| "Invalid calendar date/time.")?
    };
    let tz = if value.ends_with('Z') {
        Tz::UTC
    } else {
        timezone(p, fallback)?
    };
    tz.from_local_datetime(&naive)
        .earliest()
        .ok_or_else(|| "Calendar time falls in a daylight-saving gap.".into())
}
fn duration(value: &str) -> Result<Duration, String> {
    let mut seconds = 0_i64;
    let mut digits = String::new();
    if !value.starts_with('P') {
        return Err("Invalid calendar duration.".into());
    }
    for c in value[1..].chars() {
        if c.is_ascii_digit() {
            digits.push(c);
            continue;
        }
        if c == 'T' && digits.is_empty() {
            continue;
        }
        let n: i64 = digits.parse().map_err(|_| "Invalid calendar duration.")?;
        digits.clear();
        let factor = match c {
            'W' => 604800,
            'D' => 86400,
            'H' => 3600,
            'M' => 60,
            'S' => 1,
            _ => return Err("Invalid calendar duration.".into()),
        };
        seconds = seconds
            .checked_add(
                n.checked_mul(factor)
                    .ok_or("Calendar duration is too long.")?,
            )
            .ok_or("Calendar duration is too long.")?;
    }
    if !digits.is_empty() {
        return Err("Invalid calendar duration.".into());
    }
    Duration::try_seconds(seconds).ok_or_else(|| "Calendar duration is too long.".into())
}
fn occurrence(
    source: &CalendarSource,
    event: &IcalEvent,
    master: Option<&IcalEvent>,
    owner: Option<&str>,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    identity: DateTime<Utc>,
) -> Result<CalendarEvent, String> {
    let mut effective = event.clone();
    if let Some(master) = master {
        for p in &master.properties {
            if !event.properties.iter().any(|own| own.name == p.name) {
                effective.properties.push(p.clone());
            }
        }
    }
    let event = &effective;
    let uid = value(event, "UID").ok_or("Calendar event has no UID.")?;
    let all_day = prop(event, "DTSTART").is_some_and(|p| {
        p.value.as_ref().is_some_and(|v| v.len() == 8) || param(p, "VALUE") == Some("DATE")
    });
    // ICS has no EventKit isCurrentUser. Match an exported owner when available;
    // without owner identity, conservatively exclude events with a declined attendee.
    let declined = event.properties.iter().any(|p| {
        p.name == "ATTENDEE"
            && param(p, "PARTSTAT").is_some_and(|s| s.eq_ignore_ascii_case("DECLINED"))
            && owner.is_none_or(|o| {
                p.value.as_deref().is_some_and(|v| {
                    v.trim_start_matches("mailto:")
                        .eq_ignore_ascii_case(o.trim_start_matches("mailto:"))
                })
            })
    });
    let text = event
        .properties
        .iter()
        .filter(|p| {
            ["URL", "LOCATION", "DESCRIPTION", "X-GOOGLE-CONFERENCE"].contains(&p.name.as_str())
        })
        .filter_map(|p| p.value.as_deref())
        .map(unescape)
        .collect::<Vec<_>>()
        .join("\n");
    Ok(CalendarEvent {
        id: format!("{}:{}:{}", source.id, uid, identity.timestamp()),
        title: unescape(value(event, "SUMMARY").unwrap_or("Meeting")),
        start,
        end,
        calendar_id: source.id.clone(),
        calendar_name: source.name.clone(),
        link: meeting_link(&text),
        has_attendees: event.properties.iter().any(|p| p.name == "ATTENDEE"),
        excluded: all_day
            || value(event, "STATUS").is_some_and(|s| s.eq_ignore_ascii_case("CANCELLED"))
            || declined,
        is_all_day: all_day,
    })
}
/// Parses folded/escaped RFC5545 properties with `ical`; `rrule` expands in the event's
/// timezone (including DST), bounded to the requested horizon and 4096 occurrences.
pub fn parse_ics(
    text: &str,
    source: &CalendarSource,
    from: DateTime<Utc>,
    to: DateTime<Utc>,
) -> Result<Vec<CalendarEvent>, String> {
    let mut result = BTreeMap::new();
    for calendar in ical::IcalParser::new(BufReader::new(text.as_bytes())) {
        let calendar = calendar.map_err(|_| "The calendar subscription is not valid ICS.")?;
        let fallback = calendar
            .properties
            .iter()
            .find(|p| p.name == "X-WR-TIMEZONE")
            .and_then(|p| p.value.as_deref());
        let owner = calendar
            .properties
            .iter()
            .filter(|p| ["X-WR-RELCALID", "X-WR-CALNAME"].contains(&p.name.as_str()))
            .filter_map(|p| p.value.as_deref())
            .find(|v| v.contains('@'));
        let mut overrides = HashSet::new();
        for event in &calendar.events {
            if let Some(id) = prop(event, "RECURRENCE-ID") {
                overrides.insert((
                    value(event, "UID").unwrap_or_default().to_owned(),
                    date(id, fallback)?.with_timezone(&Utc).timestamp(),
                ));
            }
        }
        for event in &calendar.events {
            if prop(event, "RECURRENCE-ID").is_some_and(|p| param(p, "RANGE").is_some()) {
                return Err("Calendar RANGE recurrence overrides are not supported.".into());
            }
            let recurrence_id = prop(event, "RECURRENCE-ID")
                .map(|p| date(p, fallback))
                .transpose()?;
            let master = recurrence_id.and_then(|_| {
                calendar.events.iter().find(|candidate| {
                    prop(candidate, "RECURRENCE-ID").is_none()
                        && value(candidate, "UID") == value(event, "UID")
                })
            });
            let start = match prop(event, "DTSTART") {
                Some(p) => date(p, fallback)?,
                None if value(event, "STATUS") == Some("CANCELLED") => continue,
                None => return Err("Calendar event has no start time.".into()),
            };
            let end = if let Some(p) = prop(event, "DTEND") {
                date(p, fallback)?
            } else if let Some(d) = value(event, "DURATION") {
                start
                    .checked_add_signed(duration(d)?)
                    .ok_or("Calendar end date is out of range.")?
            } else if let Some(master) = master {
                let master_start = date(
                    prop(master, "DTSTART").ok_or("Calendar series has no start time.")?,
                    fallback,
                )?;
                let length = if let Some(p) = prop(master, "DTEND") {
                    date(p, fallback)? - master_start
                } else if let Some(d) = value(master, "DURATION") {
                    duration(d)?
                } else {
                    Duration::zero()
                };
                start
                    .checked_add_signed(length)
                    .ok_or("Calendar end date is out of range.")?
            } else if prop(event, "DTSTART")
                .and_then(|p| p.value.as_ref())
                .is_some_and(|v| v.len() == 8)
            {
                start + Duration::days(1)
            } else {
                start
            };
            if end < start {
                return Err("Calendar event ends before it starts.".into());
            }
            let mut set = RRuleSet::new(start).rdate(start);
            for p in event.properties.iter().filter(|p| p.name == "RRULE") {
                let rule: RRule<rrule::Unvalidated> = p
                    .value
                    .as_deref()
                    .unwrap_or_default()
                    .parse()
                    .map_err(|_| "Invalid calendar recurrence rule.")?;
                set = set.rrule(
                    rule.validate(start)
                        .map_err(|_| "Unsupported calendar recurrence rule.")?,
                );
            }
            for p in event
                .properties
                .iter()
                .filter(|p| p.name == "EXDATE" || p.name == "RDATE")
            {
                for v in p.value.as_deref().unwrap_or_default().split(',') {
                    let mut p = p.clone();
                    p.value = Some(v.into());
                    let dt = date(&p, fallback)?;
                    set = if p.name == "EXDATE" {
                        set.exdate(dt)
                    } else {
                        set.rdate(dt)
                    };
                }
            }
            let dates = set
                .after((from - (end - start)).with_timezone(&Tz::UTC))
                .before(to.with_timezone(&Tz::UTC))
                .all(4096);
            if dates.limited {
                return Err("Calendar recurrence exceeded the safe expansion limit.".into());
            }
            for dt in dates.dates {
                let start_utc = dt.with_timezone(&Utc);
                let end_utc = start_utc + (end - start);
                let identity = recurrence_id.unwrap_or(dt).with_timezone(&Utc);
                if recurrence_id.is_none()
                    && overrides.contains(&(
                        value(event, "UID").unwrap_or_default().to_owned(),
                        identity.timestamp(),
                    ))
                {
                    continue;
                }
                if end_utc <= from || start_utc >= to {
                    continue;
                }
                let event = occurrence(source, event, master, owner, start_utc, end_utc, identity)?;
                result.insert(event.id.clone(), event);
            }
        }
    }
    let mut result: Vec<_> = result.into_values().collect();
    result.sort_by_key(|e| e.start);
    Ok(result)
}

#[derive(Clone, Debug, Default)]
pub struct CaptureStatus {
    pub active_id: Option<String>,
    pub dictation_busy: bool,
    pub meeting_busy: bool,
    pub unattended_ready: bool,
    pub session_active: bool,
}
#[derive(Clone, Debug)]
pub struct CalendarStart {
    pub title: String,
    pub microphone: bool,
    pub system_audio: bool,
    pub summarize_on_stop: bool,
    pub live_transcription: bool,
}
/// Codex-A/integrator installs this adapter. Calendar never guesses microphone permissions,
/// active capture IDs or processing state and cannot record without a configured adapter.
pub trait CalendarCapture: Send + Sync {
    fn status(&self) -> CaptureStatus;
    fn start(&self, request: CalendarStart) -> Result<String, String>;
    fn finish(&self, summarize: Option<bool>) -> Result<(), String>;
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarPrompt {
    pub event: CalendarEvent,
    pub kind: String,
    pub deadline: DateTime<Utc>,
    pub automatic: bool,
    pub message: String,
}
impl CalendarPrompt {
    fn new(event: CalendarEvent, kind: &str, now: DateTime<Utc>, automatic: bool) -> Self {
        Self {
            event,
            kind: kind.into(),
            deadline: now + Duration::seconds(60),
            automatic,
            message: if kind == "start" {
                "Do you want to record this meeting?"
            } else {
                "Still in this meeting?"
            }
            .into(),
        }
    }
}
#[derive(Clone, Debug)]
struct Tracked {
    event: CalendarEvent,
    id: String,
    end: DateTime<Utc>,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(default)]
struct Decisions {
    handled: BTreeMap<String, i64>,
    skipped: BTreeMap<String, i64>,
}
impl Decisions {
    fn prune(&mut self, now: DateTime<Utc>) {
        let cutoff = (now - Duration::days(7)).timestamp();
        self.handled.retain(|_, v| *v > cutoff);
        self.skipped.retain(|_, v| *v > cutoff);
    }
    fn allow(&mut self, id: &str) {
        if self.skipped.remove(id).is_some() {
            self.handled.remove(id);
        }
    }
}
#[derive(Default)]
struct Runtime {
    events: Vec<CalendarEvent>,
    decisions: Decisions,
    prompt: Option<CalendarPrompt>,
    tracked: Option<Tracked>,
    last_tick: Option<DateTime<Utc>>,
    pending_stop: Option<Option<bool>>,
    bridge: Option<Arc<dyn CalendarCapture>>,
    error: Option<String>,
    suspended: bool,
    published_prompt: Option<(String, String, DateTime<Utc>, bool)>,
}
fn publish_prompt(app: &tauri::AppHandle, rt: &mut Runtime) -> Result<(), String> {
    let current = rt
        .prompt
        .as_ref()
        .map(|p| (p.event.id.clone(), p.kind.clone(), p.deadline, p.automatic));
    if current == rt.published_prompt {
        return Ok(());
    }
    if let Some((id, kind, _, _)) = &rt.published_prompt {
        app.emit(
            "calendar://prompt-closed",
            serde_json::json!({"occurrenceId": id, "kind": kind}),
        )
        .map_err(|_| "Could not dismiss the calendar prompt.")?;
    }
    if let Some(prompt) = &rt.prompt {
        app.emit(
            if prompt.kind == "start" {
                "calendar://prompt-start"
            } else {
                "calendar://prompt-end"
            },
            prompt,
        )
        .map_err(|_| "Could not show the calendar prompt.")?;
    }
    rt.published_prompt = current;
    Ok(())
}
#[derive(Default)]
pub struct CalendarState(Mutex<Runtime>);
pub fn set_capture_adapter(
    app: &tauri::AppHandle,
    adapter: Arc<dyn CalendarCapture>,
) -> Result<(), String> {
    app.state::<CalendarState>()
        .0
        .lock()
        .map_err(|_| "Calendar is busy.")?
        .bridge = Some(adapter);
    Ok(())
}
fn root(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_data_dir()
        .map_err(|_| "Could not locate the calendar profile.".into())
}
fn settings(app: &tauri::AppHandle) -> Result<CalendarSettings, String> {
    let path = root(app)?.join("settings.json");
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|_| {
            "Calendar settings could not be read. Fix Settings before calendar automation can run."
                .into()
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(CalendarSettings::default()),
        Err(_) => Err("Could not read calendar settings.".into()),
    }
}
fn save_decisions(path: &Path, decisions: &Decisions) -> Result<(), String> {
    let bytes =
        serde_json::to_vec_pretty(decisions).map_err(|_| "Could not encode calendar decisions.")?;
    let parent = path.parent().ok_or("Invalid calendar profile path.")?;
    std::fs::create_dir_all(parent).map_err(|_| "Could not create the calendar profile.")?;
    let temp = parent.join(format!("calendar-decisions-{}.tmp", uuid::Uuid::new_v4()));
    let write = || -> std::io::Result<()> {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        std::fs::rename(&temp, path)
    };
    if write().is_err() {
        let _ = std::fs::remove_file(temp);
        return Err("Could not save calendar decisions. Calendar automation is blocked to avoid duplicate recordings.".into());
    }
    Ok(())
}
fn load_decisions(path: &Path) -> Result<Decisions, String> {
    match std::fs::read(path) {
        Ok(bytes) => match serde_json::from_slice(&bytes) {
            Ok(d) => Ok(d),
            Err(_) => {
                let backup = path.with_file_name(format!(
                    "calendar-decisions-unreadable-{}.json",
                    uuid::Uuid::new_v4().to_string().to_uppercase()
                ));
                std::fs::copy(path,backup).map_err(|_| "Could not back up unreadable calendar decisions. Calendar automation is blocked.")?;
                // A damaged consent history must not silently replay today's meetings.
                Err("Calendar decisions were unreadable and backed up. Review calendar automation before enabling it again.".into())
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Decisions::default()),
        Err(_) => Err("Could not read calendar decisions. Calendar automation is blocked.".into()),
    }
}
async fn read_source(source: &CalendarSource) -> Result<String, String> {
    const LIMIT: usize = 8 * 1024 * 1024;
    match (&source.url, &source.file) {
        (Some(url), None) => {
            let url =
                reqwest::Url::parse(url).map_err(|_| "Enter a valid calendar subscription URL.")?;
            if !matches!(url.scheme(), "https" | "http") {
                return Err("Calendar subscription URLs must use HTTP or HTTPS.".into());
            }
            let client = reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(20))
                .build()
                .map_err(|_| "Could not connect to the calendar service.")?;
            let mut response = client
                .get(url)
                .send()
                .await
                .map_err(|_| "Could not download the calendar subscription.")?
                .error_for_status()
                .map_err(|_| {
                    "The calendar subscription returned an error. Check its URL in Settings."
                })?;
            if response.content_length().is_some_and(|n| n > LIMIT as u64) {
                return Err("Calendar subscription is too large (8 MB limit).".into());
            }
            let mut bytes = vec![];
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|_| "Could not finish downloading the calendar subscription.")?
            {
                if bytes.len() + chunk.len() > LIMIT {
                    return Err("Calendar subscription is too large (8 MB limit).".into());
                }
                bytes.extend_from_slice(&chunk);
            }
            String::from_utf8(bytes).map_err(|_| "Calendar subscription is not UTF-8 text.".into())
        }
        (None, Some(file)) => {
            let meta = tokio::fs::metadata(file)
                .await
                .map_err(|_| "Could not open the calendar file.")?;
            if !meta.is_file() || meta.len() > LIMIT as u64 {
                return Err("Choose an ICS file smaller than 8 MB.".into());
            }
            tokio::fs::read_to_string(file)
                .await
                .map_err(|_| "Could not read the calendar file as UTF-8 text.".into())
        }
        _ => Err("Each calendar source must specify either a URL or a file.".into()),
    }
}
async fn fetch_events(
    settings: &CalendarSettings,
    now: DateTime<Utc>,
) -> Result<Vec<CalendarEvent>, String> {
    let mut events = vec![];
    let mut ids = HashSet::new();
    for source in &settings.calendar_sources {
        if source.id.trim().is_empty() || !ids.insert(&source.id) {
            return Err("Calendar sources must have distinct, nonempty IDs.".into());
        }
        let text = read_source(source).await?;
        events.extend(parse_ics(
            &text,
            source,
            now - Duration::seconds(120),
            now + Duration::days(1),
        )?);
    }
    events.sort_by_key(|e| e.start);
    Ok(events)
}
fn update_events(
    runtime: &mut Runtime,
    events: Result<Vec<CalendarEvent>, String>,
) -> Result<Vec<CalendarEvent>, String> {
    let events = match events {
        Ok(events) => events,
        Err(error) => {
            runtime.events.clear();
            if runtime.prompt.as_ref().is_some_and(|p| p.kind == "start") {
                runtime.prompt = None;
            }
            return Err(error);
        }
    };
    if runtime.prompt.as_ref().is_some_and(|p| {
        p.kind == "start" && !events.iter().any(|e| e.id == p.event.id && !e.excluded)
    }) {
        runtime.prompt = None;
    }
    runtime.events = events.clone();
    Ok(events)
}
#[tauri::command]
pub async fn calendar_refresh(
    app: tauri::AppHandle,
    state: tauri::State<'_, CalendarState>,
) -> Result<Vec<CalendarEvent>, String> {
    let events = match settings(&app) {
        Ok(settings) => fetch_events(&settings, Utc::now()).await,
        Err(error) => Err(error),
    };
    let mut runtime = state.0.lock().map_err(|_| "Calendar is busy.")?;
    let result = update_events(&mut runtime, events);
    publish_prompt(&app, &mut runtime)?;
    result
}
fn close_start_if_invalid(runtime: &mut Runtime, settings: &CalendarSettings) {
    if runtime.prompt.as_ref().is_some_and(|p| {
        p.kind == "start"
            && (!settings.calendar_enabled
                || !settings
                    .calendar_sources
                    .iter()
                    .any(|s| s.id == p.event.calendar_id)
                || p.event
                    .matches_exclusion(&settings.calendar_excluded_titles)
                || runtime.decisions.skipped.contains_key(&p.event.id))
    }) {
        runtime.prompt = None;
    }
}
fn record(
    runtime: &mut Runtime,
    settings: &CalendarSettings,
    now: DateTime<Utc>,
    automatic: bool,
) -> Result<(), String> {
    let prompt = runtime
        .prompt
        .take()
        .filter(|p| p.kind == "start")
        .ok_or("This calendar start prompt is no longer available.")?;
    let event = prompt.event;
    let bridge = runtime
        .bridge
        .as_ref()
        .ok_or("Calendar recording is waiting for the meeting capture adapter.")?;
    let status = bridge.status();
    if event.excluded
        || runtime.decisions.skipped.contains_key(&event.id)
        || event.matches_exclusion(&settings.calendar_excluded_titles)
        || !settings.calendar_enabled
        || !settings
            .calendar_sources
            .iter()
            .any(|s| s.id == event.calendar_id)
        || event.end <= now
        || status.dictation_busy
        || status.meeting_busy
        || status.active_id.is_some()
        || !status.session_active
    {
        return Err(
            "Calendar recording skipped: capture is busy or this event is no longer available."
                .into(),
        );
    }
    if automatic && !status.unattended_ready {
        return Err("Automatic recording skipped. Enable microphone and system audio access before the next meeting.".into());
    }
    let id = bridge.start(CalendarStart {
        title: event.title.clone(),
        microphone: true,
        system_audio: true,
        summarize_on_stop: settings.calendar_summarize,
        live_transcription: !automatic && settings.meeting_live_transcription,
    })?;
    let end = event.end;
    runtime.tracked = Some(Tracked { event, id, end });
    Ok(())
}
#[tauri::command]
pub fn calendar_decision(
    app: tauri::AppHandle,
    state: tauri::State<CalendarState>,
    occurrence_id: String,
    decision: String,
) -> Result<(), String> {
    let settings = settings(&app)?;
    let mut rt = state.0.lock().map_err(|_| "Calendar is busy.")?;
    if let Some(error) = &rt.error {
        return Err(error.clone());
    }
    let now = Utc::now();
    let result = (|| -> Result<(), String> {
        match decision.as_str() {
            "skip" | "decline" | "notHappening" => {
                let event = rt
                    .events
                    .iter()
                    .find(|e| e.id == occurrence_id)
                    .cloned()
                    .or_else(|| {
                        rt.tracked
                            .as_ref()
                            .filter(|t| t.event.id == occurrence_id)
                            .map(|t| t.event.clone())
                    })
                    .ok_or("This calendar occurrence is no longer available.")?;
                let mut decisions = rt.decisions.clone();
                decisions.skipped.insert(event.id, event.end.timestamp());
                save_decisions(&root(&app)?.join("calendar-decisions.json"), &decisions)?;
                rt.decisions = decisions;
                if rt
                    .prompt
                    .as_ref()
                    .is_some_and(|p| p.event.id == occurrence_id)
                {
                    rt.prompt = None;
                }
                if rt
                    .tracked
                    .as_ref()
                    .is_some_and(|t| t.event.id == occurrence_id)
                {
                    rt.pending_stop = Some(Some(false));
                }
            }
            "allow" => {
                let mut decisions = rt.decisions.clone();
                decisions.allow(&occurrence_id);
                save_decisions(&root(&app)?.join("calendar-decisions.json"), &decisions)?;
                rt.decisions = decisions;
            }
            "start" => {
                if !rt
                    .prompt
                    .as_ref()
                    .is_some_and(|p| p.event.id == occurrence_id && p.kind == "start")
                {
                    return Err("This calendar start prompt is no longer available.".into());
                }
                record(&mut rt, &settings, now, false)?;
            }
            "extend" | "finish" => {
                let tracked = rt
                    .tracked
                    .as_mut()
                    .filter(|t| t.event.id == occurrence_id)
                    .ok_or("This calendar recording is no longer active.")?;
                if decision == "extend" {
                    tracked.end = tracked.end.max(now) + Duration::minutes(15);
                } else {
                    rt.pending_stop = Some(None);
                }
                rt.prompt = None;
            }
            _ => return Err("Unknown calendar decision.".into()),
        }
        Ok(())
    })();
    publish_prompt(&app, &mut rt)?;
    result
}
#[derive(Debug, PartialEq)]
enum TickAction {
    None,
    Start,
    Finish(Option<bool>),
    Due(CalendarEvent),
}
fn advance(
    rt: &mut Runtime,
    settings: &CalendarSettings,
    status: &CaptureStatus,
    now: DateTime<Utc>,
) -> TickAction {
    let gap = rt
        .last_tick
        .is_some_and(|last| now - last > Duration::seconds(10));
    rt.last_tick = Some(now);
    if gap || !status.session_active {
        rt.prompt = None;
    }
    rt.suspended = !status.session_active;
    close_start_if_invalid(rt, settings);
    if let Some(tracked) = rt.tracked.clone() {
        if !settings.calendar_enabled
            || !settings
                .calendar_sources
                .iter()
                .any(|s| s.id == tracked.event.calendar_id)
            || tracked
                .event
                .matches_exclusion(&settings.calendar_excluded_titles)
        {
            rt.pending_stop = Some(Some(false));
            rt.prompt = None;
        }
        if status.active_id.as_ref() != Some(&tracked.id) {
            rt.tracked = None;
            rt.prompt = None;
            rt.pending_stop = None;
        } else if !status.meeting_busy {
            if let Some(summarize) = rt.pending_stop.take() {
                return TickAction::Finish(summarize);
            }
            if !rt.suspended && rt.prompt.is_none() && now >= tracked.end {
                rt.prompt = Some(CalendarPrompt::new(tracked.event, "end", now, true));
            }
        }
    }
    if rt.suspended {
        return TickAction::None;
    }
    if let Some(prompt) = rt.prompt.as_mut() {
        if prompt.kind == "start" && prompt.automatic && !settings.calendar_auto_start {
            prompt.automatic = false;
        } else if prompt.automatic && now >= prompt.deadline {
            if prompt.kind == "start" {
                return TickAction::Start;
            }
            rt.prompt = None;
            rt.pending_stop = Some(None);
        }
    } else if settings.calendar_enabled
        && !status.dictation_busy
        && !status.meeting_busy
        && status.active_id.is_none()
    {
        let handled = rt
            .decisions
            .handled
            .keys()
            .chain(rt.decisions.skipped.keys())
            .cloned()
            .collect();
        if let Some(event) = rt.events.iter().find(|e| e.is_due(now, settings, &handled)) {
            return TickAction::Due(event.clone());
        }
    }
    TickAction::None
}
fn tick(app: &tauri::AppHandle) -> Result<(), String> {
    let settings = settings(app)?;
    let state = app.state::<CalendarState>();
    let mut rt = state.0.lock().map_err(|_| "Calendar is busy.")?;
    if let Some(error) = &rt.error {
        return Err(error.clone());
    }
    let now = Utc::now();
    let bridge = rt.bridge.clone();
    let status = bridge.as_ref().map(|b| b.status()).unwrap_or_default();
    let result = (|| -> Result<(), String> {
        match advance(&mut rt, &settings, &status, now) {
            TickAction::None => {}
            TickAction::Start => record(&mut rt, &settings, now, true)?,
            TickAction::Finish(summarize) => {
                if let Err(error) = bridge
                    .as_ref()
                    .ok_or("Calendar capture is unavailable.")?
                    .finish(summarize)
                {
                    rt.pending_stop = Some(summarize);
                    return Err(error);
                }
            }
            TickAction::Due(event) => {
                let mut decisions = rt.decisions.clone();
                decisions.prune(now);
                decisions.handled.insert(event.id.clone(), now.timestamp());
                save_decisions(&root(app)?.join("calendar-decisions.json"), &decisions)?;
                rt.decisions = decisions;
                rt.prompt = Some(CalendarPrompt::new(
                    event,
                    "start",
                    now,
                    settings.calendar_auto_start,
                ));
            }
        }
        Ok(())
    })();
    publish_prompt(app, &mut rt)?;
    result
}
/// Poll feeds every five minutes; a one-second policy tick catches starts between polls.
pub fn boot(app: tauri::AppHandle) {
    let state = app.state::<CalendarState>();
    if let Ok(mut runtime) = state.0.lock() {
        match root(&app).and_then(|p| load_decisions(&p.join("calendar-decisions.json"))) {
            Ok(d) => runtime.decisions = d,
            Err(e) => runtime.error = Some(e),
        }
    }
    let feeds_app = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            if let Err(error) = calendar_refresh(feeds_app.clone(), feeds_app.state()).await {
                let _ = feeds_app.emit("calendar://error", error);
            }
            tokio::time::sleep(std::time::Duration::from_secs(300)).await;
        }
    });
    tauri::async_runtime::spawn(async move {
        loop {
            if let Err(error) = tick(&app) {
                let _ = app.emit("calendar://error", error);
            }
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
    });
}
#[cfg(test)]
mod tests {
    use super::*;
    fn source() -> CalendarSource {
        CalendarSource {
            id: "work".into(),
            name: "Work".into(),
            url: None,
            file: None,
        }
    }
    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 19, 10, 0, 0).unwrap()
    }
    fn settings() -> CalendarSettings {
        CalendarSettings {
            calendar_enabled: true,
            calendar_sources: vec![source()],
            ..Default::default()
        }
    }
    fn event() -> CalendarEvent {
        CalendarEvent {
            id: "event:occurrence".into(),
            title: "Weekly sync".into(),
            start: now(),
            end: now() + Duration::hours(1),
            calendar_id: "work".into(),
            calendar_name: "Work".into(),
            link: None,
            has_attendees: true,
            excluded: false,
            is_all_day: false,
        }
    }
    fn parse(body: &str) -> Result<Vec<CalendarEvent>, String> {
        parse_ics(
            &format!("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n{body}\r\nEND:VCALENDAR\r\n"),
            &source(),
            now() - Duration::days(2),
            now() + Duration::days(10),
        )
    }
    #[test]
    fn swift_due_timing_scope_and_exclusion_cases() {
        let mut e = event();
        let mut s = settings();
        let mut handled = HashSet::new();
        assert!(e.is_due(now(), &s, &handled));
        handled.insert(e.id.clone());
        assert!(!e.is_due(now(), &s, &handled));
        handled.clear();
        s.calendar_sources.clear();
        assert!(!e.is_due(now(), &s, &handled));
        s = settings();
        e.start = now() + Duration::seconds(30);
        assert!(!e.is_due(now(), &s, &handled));
        e.start = now() - Duration::seconds(121);
        assert!(!e.is_due(now(), &s, &handled));
        e.start = now() - Duration::seconds(120);
        assert!(e.is_due(now(), &s, &handled));
        e.end = now();
        assert!(!e.is_due(now(), &s, &handled));
        e = event();
        e.excluded = true;
        assert!(!e.is_due(now(), &s, &handled));
        e.excluded = false;
        e.has_attendees = false;
        assert!(!e.is_due(now(), &s, &handled));
        s.calendar_meetings_only = false;
        assert!(e.is_due(now(), &s, &handled));
        assert!(e.matches_exclusion(&[" SYNC ".into()]));
        assert!(!e.matches_exclusion(&["".into(), "   ".into(), "personal".into()]));
        s.calendar_excluded_titles = vec!["weekly".into()];
        assert!(!e.is_due(now(), &s, &handled));
    }
    #[test]
    fn swift_meeting_links_reject_spoofed_hosts() {
        for host in [
            "meet.google.com",
            "us02web.zoom.us",
            "teams.microsoft.com",
            "teams.live.com",
            "company.webex.com",
        ] {
            assert!(meeting_link(&format!("Join https://{host}/meeting")).is_some());
        }
        for text in [
            "https://zoom.us.evil.example/j/123",
            "https://example.com/meet.google.com",
            "file:///tmp/meeting",
            "http://zoom.us/j/123",
            "https://zoom.us@evil.example/path",
        ] {
            assert!(meeting_link(text).is_none(), "{text}");
        }
    }
    #[test]
    fn parses_folded_escaped_text_duration_and_filters() {
        let events=parse("BEGIN:VEVENT\r\nUID:one\r\nDTSTART:20261019T100000Z\r\nDURATION:PT1H\r\nSUMMARY:Weekly\\, sync\r\nDESCRIPTION:Join https://meet.google.com/abc-\r\n defg-hij\\nBring notes\r\nATTENDEE:mailto:guest@example.com\r\nEND:VEVENT").unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].title, "Weekly, sync");
        assert_eq!(events[0].end - events[0].start, Duration::hours(1));
        assert_eq!(
            events[0].link.as_deref(),
            Some("https://meet.google.com/abc-defg-hij")
        );
        assert!(events[0].has_attendees);
        let events=parse("BEGIN:VEVENT\r\nUID:all\r\nDTSTART;VALUE=DATE:20261019\r\nDTEND;VALUE=DATE:20261020\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:cancel\r\nDTSTART:20261019T100000Z\r\nDTEND:20261019T110000Z\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:decline\r\nDTSTART:20261019T100000Z\r\nDTEND:20261019T110000Z\r\nATTENDEE;PARTSTAT=DECLINED;X-OPENSCRIBE-SELF=TRUE:mailto:me@example.com\r\nEND:VEVENT").unwrap();
        assert_eq!(events.len(), 3);
        assert!(events.iter().all(|e| e.excluded));
    }
    #[test]
    fn recurrence_exdate_and_moved_or_cancelled_overrides_preserve_occurrence_identity() {
        let events=parse("BEGIN:VEVENT\r\nUID:repeat\r\nDTSTART;TZID=Asia/Kolkata:20261019T153000\r\nDTEND;TZID=Asia/Kolkata:20261019T163000\r\nRRULE:FREQ=DAILY;COUNT=5\r\nEXDATE;TZID=Asia/Kolkata:20261020T153000\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:repeat\r\nRECURRENCE-ID;TZID=Asia/Kolkata:20261021T153000\r\nDTSTART;TZID=Asia/Kolkata:20261021T173000\r\nDTEND;TZID=Asia/Kolkata:20261021T183000\r\nSUMMARY:Moved\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:repeat\r\nRECURRENCE-ID;TZID=Asia/Kolkata:20261022T153000\r\nSTATUS:CANCELLED\r\nEND:VEVENT").unwrap();
        assert_eq!(events.len(), 3);
        assert_eq!(events[0].start, now());
        let moved = events.iter().find(|e| e.title == "Moved").unwrap();
        assert_eq!(moved.start, now() + Duration::days(2) + Duration::hours(2));
        assert!(moved
            .id
            .ends_with(&(now() + Duration::days(2)).timestamp().to_string()));
        assert!(events
            .iter()
            .all(|e| e.start != now() + Duration::days(1) && e.start != now() + Duration::days(3)));
    }
    #[test]
    fn timezone_recurrence_tracks_dst_and_rejects_unknown_zones() {
        let text="BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:dst\r\nDTSTART;TZID=America/New_York:20261031T100000\r\nDTEND;TZID=America/New_York:20261031T110000\r\nRRULE:FREQ=DAILY;COUNT=3\r\nEND:VEVENT\r\nEND:VCALENDAR";
        let events = parse_ics(text, &source(), now(), now() + Duration::days(20)).unwrap();
        assert_eq!(events.len(), 3);
        assert_eq!(events[1].start - events[0].start, Duration::hours(25));
        assert!(parse(&text.replace("America/New_York", "Unknown/Zone")).is_err());
    }
    #[test]
    fn outlook_windows_timezone_ids_map_through_cldr_and_keep_dst() {
        let india = parse(concat!(
            "BEGIN:VEVENT\r\nUID:outlook\r\nDTSTART;TZID=India Standard Time:20261019T153000\r\n",
            "DTEND;TZID=India Standard Time:20261019T163000\r\nEND:VEVENT"
        ))
        .unwrap();
        assert_eq!(india[0].start, now());
        let text = concat!(
            "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:outlook-dst\r\n",
            "DTSTART;TZID=Eastern Standard Time:20261031T100000\r\n",
            "DTEND;TZID=Eastern Standard Time:20261031T110000\r\n",
            "RRULE:FREQ=DAILY;COUNT=3\r\nEND:VEVENT\r\nEND:VCALENDAR"
        );
        let events = parse_ics(text, &source(), now(), now() + Duration::days(20)).unwrap();
        assert_eq!(events.len(), 3);
        assert_eq!(events[1].start - events[0].start, Duration::hours(25));
    }
    #[test]
    fn moved_override_inherits_series_duration_and_metadata() {
        let events = parse(concat!(
            "BEGIN:VEVENT\r\nUID:series\r\nDTSTART:20261019T100000Z\r\nDURATION:PT1H\r\n",
            "SUMMARY:Team sync\r\nLOCATION:https://zoom.us/j/123\r\nRRULE:FREQ=DAILY;COUNT=2\r\nEND:VEVENT\r\n",
            "BEGIN:VEVENT\r\nUID:series\r\nRECURRENCE-ID:20261020T100000Z\r\n",
            "DTSTART:20261020T120000Z\r\nEND:VEVENT"
        )).unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[1].end - events[1].start, Duration::hours(1));
        assert_eq!(events[1].title, "Team sync");
        assert_eq!(events[1].link.as_deref(), Some("https://zoom.us/j/123"));
    }
    #[test]
    fn rdates_exdates_and_calendar_timezone_are_respected() {
        let events = parse(concat!(
            "X-WR-TIMEZONE:Asia/Kolkata\r\nBEGIN:VEVENT\r\nUID:dates\r\n",
            "DTSTART:20261019T153000\r\nDTEND:20261019T163000\r\n",
            "RDATE:20261020T153000,20261021T153000\r\nEXDATE:20261020T153000\r\nEND:VEVENT"
        ))
        .unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].start, now());
        assert_eq!(events[1].start, now() + Duration::days(2));
    }
    #[test]
    fn malformed_dates_rules_and_expansion_are_errors_not_silent_omissions() {
        for body in ["BEGIN:VEVENT\r\nUID:x\r\nDTSTART:bad\r\nEND:VEVENT","BEGIN:VEVENT\r\nUID:x\r\nDTSTART:20261019T100000Z\r\nRRULE:FREQ=BAD\r\nEND:VEVENT","BEGIN:VEVENT\r\nUID:x\r\nDTSTART:20261019T100000Z\r\nDTEND:20261019T090000Z\r\nEND:VEVENT"] { assert!(parse(body).is_err()); }
        assert!(duration("P1DT2H3M4S").is_ok());
        assert!(duration("P999999999999999999999999999D").is_err());
    }
    #[test]
    fn decisions_survive_restart_and_allow_affects_only_one_occurrence() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("calendar-test-{}", uuid::Uuid::new_v4()));
        let path = dir.join("calendar-decisions.json");
        let mut d = Decisions::default();
        d.handled.insert("one".into(), now().timestamp());
        d.skipped.insert("one".into(), event().end.timestamp());
        save_decisions(&path, &d).unwrap();
        let mut restored = load_decisions(&path).unwrap();
        assert_eq!(d, restored);
        restored.allow("next");
        assert_eq!(d, restored);
        restored.allow("one");
        assert!(restored.skipped.is_empty() && restored.handled.is_empty());
        save_decisions(&path, &restored).unwrap();
        assert_eq!(load_decisions(&path).unwrap(), restored);
        d.handled
            .insert("old".into(), (now() - Duration::days(8)).timestamp());
        d.prune(now());
        assert!(!d.handled.contains_key("old"));
        std::fs::write(&path, "bad json").unwrap();
        assert!(load_decisions(&path).is_err());
        assert!(std::fs::read_dir(&dir).unwrap().any(|p| p
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains("unreadable")));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[tokio::test]
    async fn subscriptions_read_local_ics_and_reject_invalid_source_configuration() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("calendar-source-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("calendar.ics");
        let text = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:local\r\nDTSTART:20261019T100000Z\r\nDTEND:20261019T110000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        std::fs::write(&path, text).unwrap();
        let mut source = source();
        source.file = Some(path.to_string_lossy().into_owned());
        assert_eq!(read_source(&source).await.unwrap(), text);
        let settings = CalendarSettings {
            calendar_sources: vec![source.clone()],
            ..settings()
        };
        assert_eq!(fetch_events(&settings, now()).await.unwrap().len(), 1);
        let mut duplicate = settings.clone();
        duplicate.calendar_sources.push(source.clone());
        assert!(fetch_events(&duplicate, now()).await.is_err());
        source.url = Some("https://example.invalid/calendar.ics".into());
        assert!(read_source(&source).await.is_err());
        source.file = None;
        source.url = Some("file:///calendar.ics".into());
        assert!(read_source(&source).await.is_err());
        source.url = None;
        assert!(read_source(&source).await.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[derive(Default)]
    struct MockCapture {
        status: CaptureStatus,
        starts: Mutex<Vec<CalendarStart>>,
    }
    impl CalendarCapture for MockCapture {
        fn status(&self) -> CaptureStatus {
            self.status.clone()
        }
        fn start(&self, request: CalendarStart) -> Result<String, String> {
            self.starts.lock().unwrap().push(request);
            Ok("meeting-id".into())
        }
        fn finish(&self, _: Option<bool>) -> Result<(), String> {
            Ok(())
        }
    }
    fn runtime(bridge: Arc<MockCapture>) -> Runtime {
        Runtime {
            bridge: Some(bridge),
            prompt: Some(CalendarPrompt::new(event(), "start", now(), true)),
            ..Default::default()
        }
    }
    #[test]
    fn automatic_starts_are_local_only_and_permission_gated() {
        let bridge = Arc::new(MockCapture {
            status: CaptureStatus {
                session_active: true,
                unattended_ready: true,
                ..Default::default()
            },
            ..Default::default()
        });
        let mut rt = runtime(bridge.clone());
        record(&mut rt, &settings(), now(), true).unwrap();
        assert!(!bridge.starts.lock().unwrap()[0].live_transcription);
        assert!(bridge.starts.lock().unwrap()[0].summarize_on_stop);
        assert_eq!(rt.tracked.as_ref().unwrap().end, event().end);
        let mut rt = runtime(bridge.clone());
        record(&mut rt, &settings(), now(), false).unwrap();
        assert!(bridge.starts.lock().unwrap()[1].live_transcription);
        for status in [
            CaptureStatus {
                session_active: true,
                ..Default::default()
            },
            CaptureStatus {
                session_active: true,
                unattended_ready: true,
                dictation_busy: true,
                ..Default::default()
            },
            CaptureStatus {
                session_active: true,
                unattended_ready: true,
                active_id: Some("manual".into()),
                ..Default::default()
            },
        ] {
            let bridge = Arc::new(MockCapture {
                status,
                ..Default::default()
            });
            let mut rt = runtime(bridge.clone());
            assert!(record(&mut rt, &settings(), now(), true).is_err());
            assert!(bridge.starts.lock().unwrap().is_empty());
        }
    }
    #[test]
    fn prompt_policy_deadlines_and_settings_changes() {
        let prompt = CalendarPrompt::new(event(), "start", now(), true);
        assert_eq!(prompt.deadline, now() + Duration::seconds(60));
        assert_eq!(prompt.message, "Do you want to record this meeting?");
        let mut rt = Runtime {
            prompt: Some(prompt),
            ..Default::default()
        };
        let mut settings = settings();
        settings.calendar_excluded_titles = vec!["weekly".into()];
        close_start_if_invalid(&mut rt, &settings);
        assert!(rt.prompt.is_none());
        let mut d = Decisions::default();
        d.skipped.insert(event().id, event().end.timestamp());
        assert!(!event().is_due(
            now(),
            &super::tests::settings(),
            &d.skipped.keys().cloned().collect()
        ));
    }
}

#[cfg(test)]
mod transition_tests {
    use super::*;
    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 19, 10, 0, 0).unwrap()
    }
    fn event() -> CalendarEvent {
        CalendarEvent {
            id: "occurrence".into(),
            title: "Weekly sync".into(),
            start: now(),
            end: now() + Duration::hours(1),
            calendar_id: "work".into(),
            calendar_name: "Work".into(),
            link: None,
            has_attendees: true,
            excluded: false,
            is_all_day: false,
        }
    }
    fn settings() -> CalendarSettings {
        CalendarSettings {
            calendar_enabled: true,
            calendar_sources: vec![CalendarSource {
                id: "work".into(),
                name: "Work".into(),
                url: None,
                file: None,
            }],
            ..Default::default()
        }
    }
    fn status() -> CaptureStatus {
        CaptureStatus {
            session_active: true,
            unattended_ready: true,
            ..Default::default()
        }
    }
    fn pending() -> Runtime {
        let mut rt = Runtime {
            prompt: Some(CalendarPrompt::new(event(), "start", now(), true)),
            last_tick: Some(now()),
            events: vec![event()],
            ..Default::default()
        };
        rt.decisions.handled.insert(event().id, now().timestamp());
        rt
    }
    #[test]
    fn stalled_or_inactive_session_never_executes_expired_start() {
        let mut rt = pending();
        assert_eq!(
            advance(
                &mut rt,
                &settings(),
                &status(),
                now() + Duration::seconds(61)
            ),
            TickAction::None
        );
        assert!(rt.prompt.is_none());
        let mut rt = pending();
        let mut inactive = status();
        inactive.session_active = false;
        assert_eq!(
            advance(
                &mut rt,
                &settings(),
                &inactive,
                now() + Duration::seconds(1)
            ),
            TickAction::None
        );
        assert!(rt.prompt.is_none());
        assert_eq!(
            advance(
                &mut rt,
                &settings(),
                &status(),
                now() + Duration::seconds(2)
            ),
            TickAction::None
        );
    }
    #[test]
    fn automatic_countdown_runs_only_when_enabled_and_ticking() {
        let mut rt = pending();
        rt.last_tick = Some(now() + Duration::seconds(59));
        assert_eq!(
            advance(
                &mut rt,
                &settings(),
                &status(),
                now() + Duration::seconds(60)
            ),
            TickAction::Start
        );
        let mut rt = pending();
        let mut settings = settings();
        settings.calendar_auto_start = false;
        advance(&mut rt, &settings, &status(), now() + Duration::seconds(1));
        assert!(!rt.prompt.as_ref().unwrap().automatic);
        rt.last_tick = Some(now() + Duration::seconds(59));
        assert_eq!(
            advance(&mut rt, &settings, &status(), now() + Duration::seconds(60)),
            TickAction::None
        );
    }
    #[test]
    fn busy_capture_blocks_due_events_and_handled_prevents_restart_duplicates() {
        let mut rt = Runtime {
            events: vec![event()],
            ..Default::default()
        };
        let mut busy = status();
        busy.dictation_busy = true;
        assert_eq!(
            advance(&mut rt, &settings(), &busy, now()),
            TickAction::None
        );
        assert_eq!(
            advance(&mut rt, &settings(), &status(), now()),
            TickAction::Due(event())
        );
        rt.decisions.handled.insert(event().id, now().timestamp());
        assert_eq!(
            advance(&mut rt, &settings(), &status(), now()),
            TickAction::None
        );
    }
    fn tracked() -> Runtime {
        Runtime {
            tracked: Some(Tracked {
                event: event(),
                id: "active".into(),
                end: event().end,
            }),
            last_tick: Some(event().end),
            ..Default::default()
        }
    }
    #[test]
    fn end_prompt_automatically_finishes_after_60_seconds_and_defers_while_busy() {
        let mut rt = tracked();
        let mut status = status();
        status.active_id = Some("active".into());
        assert_eq!(
            advance(&mut rt, &settings(), &status, event().end),
            TickAction::None
        );
        let prompt = rt.prompt.as_ref().unwrap();
        assert_eq!(prompt.kind, "end");
        assert!(prompt.automatic);
        assert_eq!(prompt.deadline, event().end + Duration::seconds(60));
        rt.last_tick = Some(event().end + Duration::seconds(59));
        advance(
            &mut rt,
            &settings(),
            &status,
            event().end + Duration::seconds(60),
        );
        assert_eq!(rt.pending_stop, Some(None));
        status.meeting_busy = true;
        assert_eq!(
            advance(
                &mut rt,
                &settings(),
                &status,
                event().end + Duration::seconds(61)
            ),
            TickAction::None
        );
        status.meeting_busy = false;
        assert_eq!(
            advance(
                &mut rt,
                &settings(),
                &status,
                event().end + Duration::seconds(62)
            ),
            TickAction::Finish(None)
        );
    }
    #[test]
    fn disabling_watching_deselecting_or_excluding_stops_without_processing() {
        for settings in [
            CalendarSettings {
                calendar_enabled: false,
                ..settings()
            },
            CalendarSettings {
                calendar_sources: vec![],
                ..settings()
            },
            CalendarSettings {
                calendar_excluded_titles: vec!["weekly".into()],
                ..settings()
            },
        ] {
            let mut rt = tracked();
            let mut status = status();
            status.active_id = Some("active".into());
            assert_eq!(
                advance(&mut rt, &settings, &status, now()),
                TickAction::Finish(Some(false))
            );
        }
    }
    #[test]
    fn manual_stop_or_different_active_meeting_clears_tracking() {
        let mut rt = tracked();
        let mut status = status();
        status.active_id = Some("other".into());
        assert_eq!(
            advance(&mut rt, &settings(), &status, now()),
            TickAction::None
        );
        assert!(rt.tracked.is_none());
        assert!(rt.prompt.is_none());
    }
    #[test]
    fn known_owner_decline_does_not_confuse_guest_decline() {
        let text="BEGIN:VCALENDAR\r\nX-WR-RELCALID:opaque-id\r\nX-WR-CALNAME:me@example.com\r\nBEGIN:VEVENT\r\nUID:one\r\nDTSTART:20261019T100000Z\r\nDTEND:20261019T110000Z\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:me@example.com\r\nATTENDEE;PARTSTAT=DECLINED:mailto:guest@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR";
        let source = settings().calendar_sources.remove(0);
        let events = parse_ics(
            text,
            &source,
            now() - Duration::days(1),
            now() + Duration::days(1),
        )
        .unwrap();
        assert!(!events[0].excluded);
        let events = parse_ics(
            &text.replace("PARTSTAT=ACCEPTED:mailto:me", "PARTSTAT=DECLINED:mailto:me"),
            &source,
            now() - Duration::days(1),
            now() + Duration::days(1),
        )
        .unwrap();
        assert!(events[0].excluded);
    }
    #[test]
    fn failed_refresh_cancels_start_without_stopping_a_tracked_recording() {
        let mut rt = pending();
        assert!(update_events(&mut rt, Err("Subscription unavailable".into())).is_err());
        assert!(rt.events.is_empty());
        assert!(rt.prompt.is_none());
        let mut rt = tracked();
        rt.prompt = Some(CalendarPrompt::new(event(), "end", now(), true));
        assert!(update_events(&mut rt, Err("Subscription unavailable".into())).is_err());
        assert_eq!(rt.prompt.as_ref().unwrap().kind, "end");
        assert!(rt.tracked.is_some());
        assert!(rt.pending_stop.is_none());
    }
    #[test]
    fn cancelled_occurrence_cancels_start_prompt_on_refresh() {
        let mut rt = pending();
        let mut cancelled = event();
        cancelled.excluded = true;
        update_events(&mut rt, Ok(vec![cancelled])).unwrap();
        assert!(rt.prompt.is_none());
    }
    #[test]
    fn stop_without_processing_waits_for_busy_capture_and_survives_session_inactivity() {
        let mut rt = tracked();
        let mut status = status();
        status.active_id = Some("active".into());
        status.meeting_busy = true;
        status.session_active = false;
        let settings = CalendarSettings {
            calendar_enabled: false,
            ..settings()
        };
        assert_eq!(
            advance(&mut rt, &settings, &status, now()),
            TickAction::None
        );
        assert_eq!(rt.pending_stop, Some(Some(false)));
        status.meeting_busy = false;
        assert_eq!(
            advance(&mut rt, &settings, &status, now() + Duration::seconds(1)),
            TickAction::Finish(Some(false))
        );
    }
}
