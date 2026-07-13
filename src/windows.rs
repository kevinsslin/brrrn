use chrono::{DateTime, Datelike, Duration, Local, NaiveDate};
use std::collections::BTreeMap;

/// Streak: consecutive UTC days with burn at or above this floor. $10 punishes
/// normal light days; $5 means "actually used it today". Mirrored in the hub.
pub const STREAK_THRESHOLD_USD: f64 = 5.0;

/// ISO week: Monday 00:00 of the week containing `d`.
pub fn week_start(d: NaiveDate) -> NaiveDate {
    d - Duration::days(d.weekday().num_days_from_monday() as i64)
}

pub fn month_start(d: NaiveDate) -> NaiveDate {
    d.with_day(1).expect("day 1 always valid")
}

/// Consecutive days at or above `threshold` counting back from `today`.
/// An incomplete today below the threshold does not break the streak (the
/// day is not over); it just doesn't count yet.
pub fn streak_days(daily_cost: &BTreeMap<NaiveDate, f64>, today: NaiveDate, threshold: f64) -> u32 {
    let at = |d: NaiveDate| daily_cost.get(&d).copied().unwrap_or(0.0) >= threshold;
    let mut d = if at(today) { today } else { today.pred_opt().expect("date range") };
    let mut n = 0;
    while at(d) {
        n += 1;
        d = d.pred_opt().expect("date range");
    }
    n
}

/// Bucket a timestamp into a calendar day, in UTC (leaderboard-comparable)
/// or the machine's local timezone.
pub fn parse_date(ts: Option<&str>, utc: bool) -> Option<NaiveDate> {
    let dt = DateTime::parse_from_rfc3339(ts?).ok()?;
    Some(if utc {
        dt.naive_utc().date()
    } else {
        dt.with_timezone(&Local).date_naive()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        s.parse().unwrap()
    }

    #[test]
    fn week_starts_monday() {
        assert_eq!(week_start(d("2026-07-14")), d("2026-07-13")); // Tuesday
        assert_eq!(week_start(d("2026-07-13")), d("2026-07-13")); // Monday itself
        assert_eq!(week_start(d("2026-07-19")), d("2026-07-13")); // Sunday
        assert_eq!(week_start(d("2026-08-01")), d("2026-07-27")); // crosses month
    }

    #[test]
    fn month_starts_first() {
        assert_eq!(month_start(d("2026-07-14")), d("2026-07-01"));
        assert_eq!(month_start(d("2026-02-28")), d("2026-02-01"));
    }

    #[test]
    fn streak_counts_back_from_today() {
        let mut m = BTreeMap::new();
        m.insert(d("2026-07-12"), 6.0);
        m.insert(d("2026-07-13"), 5.0);
        m.insert(d("2026-07-14"), 12.0);
        assert_eq!(streak_days(&m, d("2026-07-14"), 5.0), 3);
    }

    #[test]
    fn incomplete_today_does_not_break_streak() {
        let mut m = BTreeMap::new();
        m.insert(d("2026-07-12"), 6.0);
        m.insert(d("2026-07-13"), 9.0);
        m.insert(d("2026-07-14"), 1.5); // today, below floor, day not over
        assert_eq!(streak_days(&m, d("2026-07-14"), 5.0), 2);
    }

    #[test]
    fn gap_breaks_streak() {
        let mut m = BTreeMap::new();
        m.insert(d("2026-07-10"), 20.0);
        m.insert(d("2026-07-12"), 20.0); // 07-11 missing
        m.insert(d("2026-07-13"), 20.0);
        assert_eq!(streak_days(&m, d("2026-07-13"), 5.0), 2);
    }

    #[test]
    fn empty_history_is_zero() {
        assert_eq!(streak_days(&BTreeMap::new(), d("2026-07-14"), 5.0), 0);
    }

    #[test]
    fn parse_date_utc_vs_boundary() {
        // 23:30 UTC stays on the 13th in UTC regardless of local zone.
        assert_eq!(parse_date(Some("2026-07-13T23:30:00.000Z"), true), Some(d("2026-07-13")));
        assert_eq!(parse_date(Some("not a date"), true), None);
        assert_eq!(parse_date(None, true), None);
    }
}
