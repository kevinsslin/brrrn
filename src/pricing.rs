use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;

use crate::agg::Usage;

/// Per-token USD prices for one model, from LiteLLM's pricing table.
#[derive(Clone, Copy, Debug)]
pub struct Price {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_w5m: f64,
    pub cache_w1h: f64,
}

impl Price {
    pub fn cost(&self, u: &Usage) -> f64 {
        u.input as f64 * self.input
            + u.cache_read as f64 * self.cache_read
            + u.cache_w5m as f64 * self.cache_w5m
            + u.cache_w1h as f64 * self.cache_w1h
            + u.output as f64 * self.output
    }
}

pub struct Pricing {
    map: HashMap<String, Price>,
    resolved: RefCell<HashMap<String, Option<Price>>>,
}

impl Pricing {
    pub fn load(path: &Path) -> Result<Self, String> {
        let raw = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read pricing file {}: {e}", path.display()))?;
        Self::from_json_str(&raw)
    }

    pub fn from_json_str(raw: &str) -> Result<Self, String> {
        let json: serde_json::Value =
            serde_json::from_str(raw).map_err(|e| format!("invalid pricing JSON: {e}"))?;
        let obj = json.as_object().ok_or("pricing JSON is not an object")?;

        let mut map = HashMap::new();
        for (name, v) in obj {
            let (Some(input), Some(output)) = (
                v.get("input_cost_per_token").and_then(|x| x.as_f64()),
                v.get("output_cost_per_token").and_then(|x| x.as_f64()),
            ) else {
                continue;
            };
            let cache_read = v
                .get("cache_read_input_token_cost")
                .and_then(|x| x.as_f64())
                .unwrap_or(input);
            let cache_w5m = v
                .get("cache_creation_input_token_cost")
                .and_then(|x| x.as_f64())
                .unwrap_or(input * 1.25);
            let cache_w1h = v
                .get("cache_creation_input_token_cost_above_1hr")
                .and_then(|x| x.as_f64())
                .unwrap_or(input * 2.0);
            map.insert(
                name.clone(),
                Price { input, output, cache_read, cache_w5m, cache_w1h },
            );
        }
        Ok(Self { map, resolved: RefCell::new(HashMap::new()) })
    }

    /// Resolve a model name as logged by the CLI to a price entry.
    pub fn resolve(&self, model: &str) -> Option<Price> {
        if let Some(hit) = self.resolved.borrow().get(model) {
            return *hit;
        }
        let base = model.trim_end_matches("[1m]");
        let candidates = [
            model.to_string(),
            base.to_string(),
            format!("anthropic/{base}"),
            format!("openai/{base}"),
        ];
        let found = candidates.iter().find_map(|c| self.map.get(c)).copied();
        self.resolved.borrow_mut().insert(model.to_string(), found);
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = r#"{
        "claude-test-5": {
            "input_cost_per_token": 1e-6,
            "output_cost_per_token": 5e-6,
            "cache_read_input_token_cost": 1e-7,
            "cache_creation_input_token_cost": 1.25e-6,
            "cache_creation_input_token_cost_above_1hr": 2e-6
        },
        "gpt-test": {
            "input_cost_per_token": 2e-6,
            "output_cost_per_token": 8e-6,
            "cache_read_input_token_cost": 2e-7
        },
        "no-output-price": { "input_cost_per_token": 1e-6 }
    }"#;

    #[test]
    fn resolves_exact_and_strips_1m_suffix() {
        let p = Pricing::from_json_str(FIXTURE).unwrap();
        assert!(p.resolve("claude-test-5").is_some());
        assert!(p.resolve("claude-test-5[1m]").is_some());
        assert!(p.resolve("unknown-model").is_none());
        // entries without both input and output prices are skipped
        assert!(p.resolve("no-output-price").is_none());
    }

    #[test]
    fn missing_cache_prices_fall_back_to_input_multiples() {
        let p = Pricing::from_json_str(FIXTURE).unwrap();
        let gpt = p.resolve("gpt-test").unwrap();
        assert!((gpt.cache_w5m - 2e-6 * 1.25).abs() < 1e-18);
        assert!((gpt.cache_w1h - 2e-6 * 2.0).abs() < 1e-18);
    }

    #[test]
    fn cost_weights_every_tier() {
        let p = Pricing::from_json_str(FIXTURE).unwrap();
        let price = p.resolve("claude-test-5").unwrap();
        let u = Usage {
            input: 1000,
            cache_read: 1000,
            cache_w5m: 1000,
            cache_w1h: 1000,
            output: 1000,
            reasoning: 0,
        };
        let expected = 1e-3 + 1e-4 + 1.25e-3 + 2e-3 + 5e-3;
        assert!((price.cost(&u) - expected).abs() < 1e-12);
    }
}
