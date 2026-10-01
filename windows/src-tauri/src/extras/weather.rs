// The Weather pill (WeatherMochi): Open-Meteo, free and keyless, for the city
// typed in Settings › Extras, every 15 minutes while the pill is on. Only that
// city's name (to look it up, from Settings) and coordinates go out.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager};

use super::Place;

pub const TASK_ID: &str = "integration_weather";
const EVERY: Duration = Duration::from_secs(15 * 60);

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WeatherNow {
    pub place: String,
    pub temperature: f64,
    pub code: i64,
    pub day: bool,
    /// Highest in the next two hours, %.
    pub rain_chance: i64,
    pub accessory: &'static str,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Update {
    weather: Option<WeatherNow>,
    error: Option<String>,
}

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap_or_default()
}

/// Settings → City → Set: the first place Open-Meteo knows by that name.
pub async fn geocode(city: &str, language: &str) -> Option<Place> {
    let city: String = city.trim().chars().take(80).collect();
    if city.is_empty() {
        return None;
    }
    let mut url = url::Url::parse("https://geocoding-api.open-meteo.com/v1/search").ok()?;
    url.query_pairs_mut().append_pair("name", &city).append_pair("count", "1").append_pair("language", language);
    let json: Value = client().get(url).send().await.ok()?.json().await.ok()?;
    let r = json.get("results")?.as_array()?.first()?;
    let (lat, lon) = (r.get("latitude")?.as_f64()?, r.get("longitude")?.as_f64()?);
    let name = [r.get("name").and_then(Value::as_str), r.get("country_code").and_then(Value::as_str)]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(", ");
    Some(Place { name, lat, lon })
}

/// Reads the forecast's answer (pure, for the test).
fn parse(place: &Place, json: &Value) -> Option<WeatherNow> {
    let cur = json.get("current")?;
    let temperature = cur.get("temperature_2m")?.as_f64()?;
    let code = cur.get("weather_code")?.as_i64()?;
    let day = cur.get("is_day").and_then(Value::as_i64) == Some(1);
    let rain_chance = json
        .get("hourly")
        .and_then(|h| h.get("precipitation_probability"))
        .and_then(Value::as_array)
        .map(|a| a.iter().take(3).filter_map(Value::as_i64).max().unwrap_or(0))
        .unwrap_or(0);
    Some(WeatherNow {
        place: place.name.clone(),
        temperature,
        code,
        day,
        rain_chance,
        accessory: super::weather_accessory(code, temperature, day, rain_chance),
    })
}

async fn fetch(place: &Place) -> Option<WeatherNow> {
    let mut url = url::Url::parse("https://api.open-meteo.com/v1/forecast").ok()?;
    url.query_pairs_mut()
        .append_pair("latitude", &format!("{:.3}", place.lat))
        .append_pair("longitude", &format!("{:.3}", place.lon))
        .append_pair("current", "temperature_2m,weather_code,is_day")
        .append_pair("hourly", "precipitation_probability")
        .append_pair("forecast_hours", "3")
        .append_pair("timezone", "auto");
    let json: Value = client().get(url).send().await.ok()?.json().await.ok()?;
    parse(place, &json)
}

static LAST: Mutex<Option<(Instant, Place)>> = Mutex::new(None);

fn place(app: &AppHandle) -> Option<Place> {
    app.try_state::<crate::Shared>()?.settings.lock().unwrap().weather_place.clone()
}

/// One tick: fetch when due, or at once after the city changed (`force`).
pub async fn tick(app: &AppHandle, force: bool) {
    if !force && !super::pill_on(app, TASK_ID) {
        return;
    }
    let Some(place) = place(app) else {
        let _ = app.emit("extras-weather", Update { weather: None, error: Some("Type your city in Settings › Extras.".into()) });
        return;
    };
    {
        let mut last = LAST.lock().unwrap();
        let due = force || last.as_ref().is_none_or(|(at, p)| at.elapsed() >= EVERY || *p != place);
        if !due {
            return;
        }
        *last = Some((Instant::now(), place.clone()));
    }
    let update = match fetch(&place).await {
        Some(w) => Update { weather: Some(w), error: None },
        None => Update { weather: None, error: Some("api.open-meteo.com can't be reached.".into()) },
    };
    let _ = app.emit("extras-weather", update);
}

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(4)).await;
        loop {
            tick(&app, false).await;
            tokio::time::sleep(Duration::from_secs(60)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_forecast_is_read_with_the_next_two_hours_of_rain() {
        let place = Place { name: "Bogotá, CO".into(), lat: 4.6, lon: -74.1 };
        let w = parse(&place, &json!({
            "current": { "temperature_2m": 14.2, "weather_code": 3, "is_day": 1 },
            "hourly": { "precipitation_probability": [10, 70, 20, 90] }
        })).unwrap();
        assert_eq!(w.rain_chance, 70, "three hourly values, the fourth is beyond");
        assert_eq!(w.accessory, "umbrella");
        assert!(w.day);
        assert!(parse(&place, &json!({ "current": {} })).is_none());
    }
}
