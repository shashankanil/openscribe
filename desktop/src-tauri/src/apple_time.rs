//! Date and UUID representations shared with Foundation's JSON encoders.
use chrono::{DateTime, Local, SecondsFormat, Utc};
use serde::{de::Error, Deserialize, Deserializer, Serialize, Serializer};
use std::fmt;

pub const APPLE_EPOCH: f64 = 978_307_200.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Id(pub uuid::Uuid);
impl Default for Id {
    fn default() -> Self {
        Self(uuid::Uuid::new_v4())
    }
}
impl fmt::Display for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0.hyphenated().to_string().to_uppercase())
    }
}
impl Serialize for Id {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_string())
    }
}
impl<'de> Deserialize<'de> for Id {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        uuid::Uuid::parse_str(&String::deserialize(d)?)
            .map(Self)
            .map_err(D::Error::custom)
    }
}
impl std::str::FromStr for Id {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, String> {
        uuid::Uuid::parse_str(s)
            .map(Self)
            .map_err(|_| "Invalid identifier.".into())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct NoteDate(pub i64);
impl Default for NoteDate {
    fn default() -> Self {
        Self(Utc::now().timestamp())
    }
}
impl NoteDate {
    pub fn datetime(self) -> DateTime<Utc> {
        DateTime::from_timestamp(self.0, 0).expect("validated note date")
    }
    pub fn local_day(self) -> chrono::NaiveDate {
        self.datetime().with_timezone(&Local).date_naive()
    }
    pub fn day_title(self) -> String {
        self.datetime()
            .with_timezone(&Local)
            .format("%B %-d, %Y")
            .to_string()
    }
    pub fn apple(self) -> f64 {
        self.0 as f64 - APPLE_EPOCH
    }
}
impl Serialize for NoteDate {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.datetime().to_rfc3339_opts(SecondsFormat::Secs, true))
    }
}
impl<'de> Deserialize<'de> for NoteDate {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(d)?;
        if raw.contains('.') {
            return Err(D::Error::custom(
                "ISO dates must not contain fractional seconds",
            ));
        }
        DateTime::parse_from_rfc3339(&raw)
            .map(|v| Self(v.timestamp()))
            .map_err(D::Error::custom)
    }
}
pub fn apple_now() -> f64 {
    Utc::now().timestamp_millis() as f64 / 1000.0 - APPLE_EPOCH
}

/// Date.formatted() uses the user's short date and time. Use the Windows locale for
/// the export header; the rest of markdown is byte-for-byte the Swift template.
pub fn formatted_local_date(date: chrono::DateTime<chrono::Local>) -> String {
    #[cfg(windows)]
    {
        use chrono::{Datelike, Timelike};
        #[repr(C)]
        struct SystemTime {
            year: u16,
            month: u16,
            weekday: u16,
            day: u16,
            hour: u16,
            minute: u16,
            second: u16,
            millis: u16,
        }
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn GetDateFormatEx(
                locale: *const u16,
                flags: u32,
                time: *const SystemTime,
                format: *const u16,
                buffer: *mut u16,
                len: i32,
                calendar: *const u16,
            ) -> i32;
            fn GetTimeFormatEx(
                locale: *const u16,
                flags: u32,
                time: *const SystemTime,
                format: *const u16,
                buffer: *mut u16,
                len: i32,
            ) -> i32;
        }
        let time = SystemTime {
            year: date.year() as u16,
            month: date.month() as u16,
            weekday: date.weekday().num_days_from_sunday() as u16,
            day: date.day() as u16,
            hour: date.hour() as u16,
            minute: date.minute() as u16,
            second: date.second() as u16,
            millis: 0,
        };
        let mut day = [0_u16; 128];
        let mut hour = [0_u16; 128];
        // SAFETY: SYSTEMTIME is repr(C), all optional pointers are null, and buffers
        // remain valid for the complete calls with their exact capacities.
        let (d, t) = unsafe {
            (
                GetDateFormatEx(
                    std::ptr::null(),
                    1,
                    &time,
                    std::ptr::null(),
                    day.as_mut_ptr(),
                    day.len() as i32,
                    std::ptr::null(),
                ),
                GetTimeFormatEx(
                    std::ptr::null(),
                    2,
                    &time,
                    std::ptr::null(),
                    hour.as_mut_ptr(),
                    hour.len() as i32,
                ),
            )
        };
        if d > 0 && t > 0 {
            return format!(
                "{}, {}",
                String::from_utf16_lossy(&day[..d as usize - 1]),
                String::from_utf16_lossy(&hour[..t as usize - 1])
            );
        }
    }
    date.format("%-m/%-d/%Y, %-I:%M %p").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn foundation_dates_and_uppercase_ids() {
        let date: NoteDate = serde_json::from_str("\"2026-10-19T10:58:15Z\"").unwrap();
        assert_eq!(
            serde_json::to_string(&date).unwrap(),
            "\"2026-10-19T10:58:15Z\""
        );
        assert!(serde_json::from_str::<NoteDate>("\"2026-10-19T10:58:15.000Z\"").is_err());
        assert_eq!(NoteDate(978307200).apple(), 0.0);
        let id: Id = serde_json::from_str("\"e621e1f8-c36c-495a-93fc-0c247a3e6e5f\"").unwrap();
        assert_eq!(
            serde_json::to_string(&id).unwrap(),
            "\"E621E1F8-C36C-495A-93FC-0C247A3E6E5F\""
        );
    }
}
