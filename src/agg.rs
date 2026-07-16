use chrono::NaiveDate;
use std::collections::{BTreeMap, HashMap};

use crate::pricing::Price;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, PartialOrd, Ord)]
pub enum Source {
    Claude,
    Codex,
}

impl Source {
    pub fn label(&self) -> &'static str {
        match self {
            Source::Claude => "claude-code",
            Source::Codex => "codex",
        }
    }

    pub fn as_u8(&self) -> u8 {
        match self {
            Source::Claude => 0,
            Source::Codex => 1,
        }
    }

    pub fn from_u8(v: u8) -> Option<Source> {
        match v {
            0 => Some(Source::Claude),
            1 => Some(Source::Codex),
            _ => None,
        }
    }
}

#[derive(Default, Clone, Copy, PartialEq, Debug)]
pub struct Usage {
    pub input: u64, // non-cached input tokens
    pub cache_read: u64,
    pub cache_w5m: u64,
    pub cache_w1h: u64,
    pub output: u64,    // includes reasoning for codex
    pub reasoning: u64, // informational subset of output
}

impl Usage {
    pub fn total(&self) -> u64 {
        self.input + self.cache_read + self.cache_w5m + self.cache_w1h + self.output
    }

    pub fn is_zero(&self) -> bool {
        self.total() == 0
    }

    pub fn add(&mut self, o: &Usage) {
        self.input += o.input;
        self.cache_read += o.cache_read;
        self.cache_w5m += o.cache_w5m;
        self.cache_w1h += o.cache_w1h;
        self.output += o.output;
        self.reasoning += o.reasoning;
    }

    pub fn to_array(&self) -> [u64; 6] {
        [
            self.input,
            self.cache_read,
            self.cache_w5m,
            self.cache_w1h,
            self.output,
            self.reasoning,
        ]
    }

    pub fn from_array(a: [u64; 6]) -> Usage {
        Usage {
            input: a[0],
            cache_read: a[1],
            cache_w5m: a[2],
            cache_w1h: a[3],
            output: a[4],
            reasoning: a[5],
        }
    }
}

/// One priced-unit of scanned work: a single message (Claude) or turn delta
/// (Codex), already deduped, not yet priced or date-filtered.
#[derive(Clone, Debug)]
pub struct Entry {
    pub date: NaiveDate,
    pub hour: u8, // 0-23, same timezone as `date`
    pub source: Source,
    pub model: String,
    pub speed: String, // claude: speed field; codex: reasoning effort
    pub usage: Usage,
}

#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Key {
    pub source: Source,
    pub model: String,
    pub speed: String,
}

#[derive(Default)]
pub struct DayAgg {
    pub tokens: u64,
    pub cost: f64,
    pub unpriced_tokens: u64,
}

/// Per-day, per-model rollup that feeds pit submissions and hover detail.
#[derive(Default, Clone)]
pub struct DayModel {
    pub input: u64,
    pub output: u64,
    pub cost: f64,
    pub priced: bool,
}

/// Per-hour rollup that feeds the time-of-day rhythm view.
#[derive(Default, Clone, Copy)]
pub struct HourAgg {
    pub tokens: u64,
    pub cost: f64,
}

#[derive(Default)]
pub struct Agg {
    pub by_key: HashMap<Key, (Usage, Option<f64>)>,
    pub daily_by_key: BTreeMap<NaiveDate, HashMap<Key, (Usage, Option<f64>)>>,
    pub daily: BTreeMap<NaiveDate, BTreeMap<Source, DayAgg>>,
    pub hourly: BTreeMap<NaiveDate, [HourAgg; 24]>,
    pub daily_models: BTreeMap<NaiveDate, BTreeMap<String, DayModel>>,
    /// Always spans full history, even when the report itself is date-filtered.
    pub streak_daily_cost: BTreeMap<NaiveDate, f64>,
    pub records: u64,
}

impl Agg {
    /// Add to both the current report and full-history streak data.
    pub fn add_entry(&mut self, e: &Entry, price: Option<Price>) {
        self.add_streak_entry(e, price);
        self.add_report_entry(e, price);
    }

    pub fn add_streak_entry(&mut self, e: &Entry, price: Option<Price>) {
        *self.streak_daily_cost.entry(e.date).or_default() +=
            price.map(|p| p.cost(&e.usage)).unwrap_or(0.0);
    }

    /// Add to report windows and model tables without touching streak data.
    pub fn add_report_entry(&mut self, e: &Entry, price: Option<Price>) {
        self.records += 1;
        let cost = price.map(|p| p.cost(&e.usage));

        let key = Key {
            source: e.source,
            model: e.model.clone(),
            speed: e.speed.clone(),
        };
        add_key_usage(&mut self.by_key, key.clone(), &e.usage, cost);
        add_key_usage(
            self.daily_by_key.entry(e.date).or_default(),
            key,
            &e.usage,
            cost,
        );

        let day = self
            .daily
            .entry(e.date)
            .or_default()
            .entry(e.source)
            .or_default();
        day.tokens += e.usage.total();
        match cost {
            Some(c) => day.cost += c,
            None => day.unpriced_tokens += e.usage.total(),
        }

        let hour = &mut self
            .hourly
            .entry(e.date)
            .or_insert_with(|| [HourAgg::default(); 24])[usize::from(e.hour.min(23))];
        hour.tokens += e.usage.total();
        hour.cost += cost.unwrap_or(0.0);

        let dm = self
            .daily_models
            .entry(e.date)
            .or_default()
            .entry(e.model.clone())
            .or_default();
        // Model-level input for display purposes includes cache traffic; it is
        // the "what went in" number, while cost already weights each tier.
        dm.input += e.usage.input + e.usage.cache_read + e.usage.cache_w5m + e.usage.cache_w1h;
        dm.output += e.usage.output;
        dm.cost += cost.unwrap_or(0.0);
        dm.priced = cost.is_some();
    }

    /// Full-history daily cost used as streak input.
    pub fn daily_cost(&self) -> &BTreeMap<NaiveDate, f64> {
        &self.streak_daily_cost
    }
}

fn add_key_usage(
    totals: &mut HashMap<Key, (Usage, Option<f64>)>,
    key: Key,
    usage: &Usage,
    cost: Option<f64>,
) {
    let slot = totals
        .entry(key)
        .or_insert_with(|| (Usage::default(), cost.map(|_| 0.0)));
    slot.0.add(usage);
    if let (Some(cost), Some(total)) = (cost, slot.1.as_mut()) {
        *total += cost;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pricing::Price;

    fn entry(date: &str, model: &str, usage: Usage) -> Entry {
        Entry {
            date: date.parse().unwrap(),
            hour: 0,
            source: Source::Claude,
            model: model.to_string(),
            speed: "standard".to_string(),
            usage,
        }
    }

    #[test]
    fn add_entry_rolls_up_key_day_and_model() {
        let mut agg = Agg::default();
        let p = Price {
            input: 1e-6,
            output: 5e-6,
            cache_read: 1e-7,
            cache_w5m: 1.25e-6,
            cache_w1h: 2e-6,
        };
        let u = Usage {
            input: 1000,
            cache_read: 2000,
            cache_w5m: 0,
            cache_w1h: 0,
            output: 100,
            reasoning: 0,
        };
        agg.add_entry(&entry("2026-07-13", "m", u), Some(p));
        agg.add_entry(&entry("2026-07-13", "m", u), Some(p));

        let key = Key {
            source: Source::Claude,
            model: "m".into(),
            speed: "standard".into(),
        };
        let (total, cost) = &agg.by_key[&key];
        assert_eq!(total.input, 2000);
        let expected = 2.0 * (1000.0 * 1e-6 + 2000.0 * 1e-7 + 100.0 * 5e-6);
        assert!((cost.unwrap() - expected).abs() < 1e-12);

        let dm = &agg.daily_models[&"2026-07-13".parse().unwrap()]["m"];
        assert_eq!(dm.input, 2 * 3000); // input + cache tiers
        assert_eq!(dm.output, 200);
        assert!(dm.priced);
    }

    #[test]
    fn hourly_rollup_buckets_cost_and_tokens_by_hour() {
        let mut agg = Agg::default();
        let p = Price {
            input: 1e-6,
            output: 5e-6,
            cache_read: 1e-7,
            cache_w5m: 1.25e-6,
            cache_w1h: 2e-6,
        };
        let u = Usage {
            input: 1000,
            output: 100,
            ..Default::default()
        };
        let mut early = entry("2026-07-13", "m", u);
        early.hour = 9;
        let mut late = entry("2026-07-13", "m", u);
        late.hour = 23;
        agg.add_entry(&early, Some(p));
        agg.add_entry(&early, Some(p));
        agg.add_entry(&late, Some(p));

        let hours = &agg.hourly[&"2026-07-13".parse().unwrap()];
        let per_entry = 1000.0 * 1e-6 + 100.0 * 5e-6;
        assert_eq!(hours[9].tokens, 2200);
        assert!((hours[9].cost - 2.0 * per_entry).abs() < 1e-12);
        assert_eq!(hours[23].tokens, 1100);
        assert!((hours[23].cost - per_entry).abs() < 1e-12);
        assert_eq!(hours[0].tokens, 0);
        assert_eq!(hours[0].cost, 0.0);
    }

    #[test]
    fn unpriced_entries_tracked_separately() {
        let mut agg = Agg::default();
        let u = Usage {
            input: 10,
            output: 5,
            ..Default::default()
        };
        agg.add_entry(&entry("2026-07-13", "mystery", u), None);
        let day = &agg.daily[&"2026-07-13".parse().unwrap()][&Source::Claude];
        assert_eq!(day.unpriced_tokens, 15);
        assert_eq!(day.cost, 0.0);
        let key = Key {
            source: Source::Claude,
            model: "mystery".into(),
            speed: "standard".into(),
        };
        assert!(agg.by_key[&key].1.is_none());
    }
}
