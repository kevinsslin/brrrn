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
}

#[derive(Default, Clone, Copy)]
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
}

#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Key {
    pub source: Source,
    pub model: String,
    pub speed: String, // claude: speed field; codex: reasoning effort
}

#[derive(Default)]
pub struct DayAgg {
    pub tokens: u64,
    pub cost: f64,
    pub unpriced_tokens: u64,
}

#[derive(Default)]
pub struct Agg {
    pub by_key: HashMap<Key, (Usage, Option<f64>)>,
    pub daily: BTreeMap<NaiveDate, BTreeMap<Source, DayAgg>>,
    pub records: u64,
}

impl Agg {
    pub fn add(&mut self, date: NaiveDate, key: Key, u: Usage, price: Option<Price>) {
        self.records += 1;
        let cost = price.map(|p| p.cost(&u));

        let entry = self
            .by_key
            .entry(key.clone())
            .or_insert_with(|| (Usage::default(), cost.map(|_| 0.0)));
        entry.0.add(&u);
        if let (Some(c), Some(total)) = (cost, entry.1.as_mut()) {
            *total += c;
        }

        let day = self.daily.entry(date).or_default().entry(key.source).or_default();
        day.tokens += u.total();
        match cost {
            Some(c) => day.cost += c,
            None => day.unpriced_tokens += u.total(),
        }
    }
}
