//! Cursor API client for fetching usage information
//!
//! Uses browser cookies to authenticate with cursor.com API

use crate::browser::cookies::get_cookie_header;
use crate::core::{CostSnapshot, ProviderError, RateWindow};
use chrono::{DateTime, Utc};
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, de::DeserializeOwned};
use std::path::{Path, PathBuf};

const BASE_URL: &str = "https://cursor.com";
const DASHBOARD_BASE_URL: &str = "https://api2.cursor.sh/aiserver.v1.DashboardService";
const COOKIE_DOMAINS: [&str; 2] = ["cursor.com", "cursor.sh"];
const CURSOR_ACCESS_TOKEN_KEY: &str = "cursorAuth/accessToken";
const CURSOR_EMAIL_KEY: &str = "cursorAuth/cachedEmail";
const CURSOR_MEMBERSHIP_KEY: &str = "cursorAuth/stripeMembershipType";

pub(super) type CursorUsageResult = (
    RateWindow,
    Option<RateWindow>,
    Option<RateWindow>,
    Option<CostSnapshot>,
    Option<String>,
    Option<String>,
);

/// Cursor API client
pub struct CursorApi {
    client: reqwest::Client,
}

impl CursorApi {
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::new(),
        }
    }

    /// Fetch usage information from Cursor API
    /// Returns (primary, secondary, model_specific, cost, email, plan_type)
    pub async fn fetch_usage(&self) -> Result<CursorUsageResult, ProviderError> {
        match self.get_cookie_header() {
            Ok(cookie_header) => match self.fetch_usage_with_cookie_header(&cookie_header).await {
                Ok(result) => Ok(result),
                Err(web_error) => self
                    .fetch_usage_from_cursor_ide()
                    .await
                    .or(Err(web_error)),
            },
            Err(cookie_error) => self
                .fetch_usage_from_cursor_ide()
                .await
                .map_err(|ide_error| match cookie_error {
                    ProviderError::NoCookies => ProviderError::Other(format!(
                        "No Cursor browser cookies and Cursor IDE session fallback failed: {ide_error}"
                    )),
                    other => other,
                }),
        }
    }

    /// Fetch usage information with an already resolved Cookie header.
    pub async fn fetch_usage_with_cookie_header(
        &self,
        cookie_header: &str,
    ) -> Result<CursorUsageResult, ProviderError> {
        // Fetch usage summary and user info in parallel
        let (usage_result, user_result) = tokio::join!(
            self.fetch_usage_summary(cookie_header),
            self.fetch_user_info(cookie_header)
        );

        let usage_summary = usage_result?;
        let user_info = user_result.ok();

        self.build_result(usage_summary, user_info)
    }

    fn get_cookie_header(&self) -> Result<String, ProviderError> {
        for domain in COOKIE_DOMAINS {
            match get_cookie_header(domain) {
                Ok(header) if !header.is_empty() => {
                    tracing::debug!("Found Cursor cookies for {}", domain);
                    return Ok(header);
                }
                Ok(_) => {
                    tracing::debug!("No cookies for {}", domain);
                }
                Err(e) => {
                    tracing::debug!("Cookie error for {}: {}", domain, e);
                }
            }
        }

        Err(ProviderError::NoCookies)
    }

    async fn fetch_usage_summary(
        &self,
        cookie_header: &str,
    ) -> Result<UsageSummary, ProviderError> {
        let url = format!("{}/api/usage-summary", BASE_URL);

        let response = self
            .client
            .get(&url)
            .header("Cookie", cookie_header)
            .header("Accept", "application/json")
            .timeout(std::time::Duration::from_secs(15))
            .send()
            .await?;

        if response.status() == 401 || response.status() == 403 {
            return Err(ProviderError::AuthRequired);
        }

        if !response.status().is_success() {
            return Err(ProviderError::Other(format!(
                "Cursor API returned {}",
                response.status()
            )));
        }

        // Try structured deserialization first, fall back to raw JSON on failure
        let text = response
            .text()
            .await
            .map_err(|e| ProviderError::Parse(e.to_string()))?;
        serde_json::from_str::<UsageSummary>(&text).map_err(|e| {
            tracing::warn!(
                "Cursor usage-summary parse error: {e}; response length: {} bytes",
                text.len()
            );
            ProviderError::Parse(e.to_string())
        })
    }

    async fn fetch_user_info(&self, cookie_header: &str) -> Result<UserInfo, ProviderError> {
        let url = format!("{}/api/auth/me", BASE_URL);

        let response = self
            .client
            .get(&url)
            .header("Cookie", cookie_header)
            .header("Accept", "application/json")
            .timeout(std::time::Duration::from_secs(15))
            .send()
            .await?;

        if !response.status().is_success() {
            return Err(ProviderError::Other(
                "Failed to fetch user info".to_string(),
            ));
        }

        response
            .json()
            .await
            .map_err(|e| ProviderError::Parse(e.to_string()))
    }

    async fn fetch_usage_from_cursor_ide(&self) -> Result<CursorUsageResult, ProviderError> {
        let session = Self::read_cursor_ide_session()?;
        let (usage_result, me_result) = tokio::join!(
            self.fetch_dashboard_current_period_usage(&session.access_token),
            self.fetch_dashboard_me(&session.access_token)
        );

        self.build_dashboard_result(
            usage_result?,
            me_result.ok().and_then(|me| me.email).or(session.email),
            session.membership_type,
        )
    }

    async fn fetch_dashboard_current_period_usage(
        &self,
        access_token: &str,
    ) -> Result<DashboardCurrentPeriodUsage, ProviderError> {
        self.post_dashboard_json("GetCurrentPeriodUsage", access_token, serde_json::json!({}))
            .await
    }

    async fn fetch_dashboard_me(&self, access_token: &str) -> Result<DashboardMe, ProviderError> {
        self.post_dashboard_json("GetMe", access_token, serde_json::json!({}))
            .await
    }

    async fn post_dashboard_json<T: DeserializeOwned>(
        &self,
        method: &str,
        access_token: &str,
        body: serde_json::Value,
    ) -> Result<T, ProviderError> {
        let url = format!("{DASHBOARD_BASE_URL}/{method}");
        let response = self
            .client
            .post(&url)
            .bearer_auth(access_token)
            .header("Connect-Protocol-Version", "1")
            .header("Accept", "application/json")
            .json(&body)
            .timeout(std::time::Duration::from_secs(15))
            .send()
            .await?;

        if response.status() == 401 || response.status() == 403 {
            return Err(ProviderError::AuthRequired);
        }

        if !response.status().is_success() {
            return Err(ProviderError::Other(format!(
                "Cursor Dashboard API returned {}",
                response.status()
            )));
        }

        response
            .json()
            .await
            .map_err(|e| ProviderError::Parse(e.to_string()))
    }

    fn build_dashboard_result(
        &self,
        usage: DashboardCurrentPeriodUsage,
        email: Option<String>,
        membership_type: Option<String>,
    ) -> Result<CursorUsageResult, ProviderError> {
        let billing_end = usage
            .billing_cycle_end
            .as_deref()
            .and_then(parse_unix_millis)
            .or_else(|| usage.billing_cycle_end.as_deref().and_then(parse_iso_date));

        let plan = usage.plan_usage.unwrap_or_default();
        let primary = RateWindow::with_details(
            dashboard_percent(plan.total_percent_used).unwrap_or(0.0),
            None,
            billing_end,
            None,
        );
        let secondary = dashboard_percent(plan.auto_percent_used)
            .map(|percent| RateWindow::with_details(percent, None, billing_end, None));
        let model_specific = dashboard_percent(plan.api_percent_used)
            .map(|percent| RateWindow::with_details(percent, None, billing_end, None));

        let plan_type = membership_type
            .filter(|value| !value.trim().is_empty())
            .map(|value| format!("Cursor {}", capitalize(&value.to_lowercase())));

        Ok((primary, secondary, model_specific, None, email, plan_type))
    }

    fn read_cursor_ide_session() -> Result<CursorIdeSession, ProviderError> {
        let db_path = cursor_state_db_path().ok_or_else(|| {
            ProviderError::NotInstalled(
                "Could not resolve Cursor application data path.".to_string(),
            )
        })?;

        if !db_path.exists() {
            return Err(ProviderError::NotInstalled(format!(
                "Cursor IDE state database not found at {}. Open Cursor and sign in first.",
                db_path.display()
            )));
        }

        let temp_db = copy_state_db_to_temp(&db_path)?;
        let result = read_cursor_ide_session_from_db(&temp_db);
        let _ = std::fs::remove_file(&temp_db);
        result
    }

    fn build_result(
        &self,
        summary: UsageSummary,
        user_info: Option<UserInfo>,
    ) -> Result<CursorUsageResult, ProviderError> {
        let billing_end = summary
            .billing_cycle_end
            .as_ref()
            .and_then(|s| parse_iso_date(s));

        let (percent_used, secondary, model_specific, cost_snapshot) =
            if let Some(individual) = &summary.individual_usage {
                if let Some(plan) = &individual.plan {
                    let used_cents = plan.used.unwrap_or(0) as f64;
                    let limit_cents = plan
                        .breakdown
                        .as_ref()
                        .and_then(|b| b.total)
                        .or(plan.limit)
                        .unwrap_or(0) as f64;

                    let percent = if limit_cents > 0.0 {
                        (used_cents / limit_cents) * 100.0
                    } else {
                        plan.total_percent_used.unwrap_or(0.0) * 100.0
                    };

                    let secondary = plan
                        .auto_percent_used
                        .map(|v| RateWindow::with_details(v * 100.0, None, billing_end, None));

                    let model_specific = plan
                        .api_percent_used
                        .map(|v| RateWindow::with_details(v * 100.0, None, billing_end, None));

                    let cost = Self::on_demand_cost(individual.on_demand.as_ref(), billing_end)
                        .or_else(|| {
                            summary.team_usage.as_ref().and_then(|team| {
                                Self::on_demand_cost(team.on_demand.as_ref(), billing_end)
                            })
                        })
                        .unwrap_or_else(|| {
                            let mut cost = CostSnapshot::new(used_cents / 100.0, "USD", "Monthly");
                            if limit_cents > 0.0 {
                                cost = cost.with_limit(limit_cents / 100.0);
                            }
                            if let Some(reset) = billing_end {
                                cost = cost.with_resets_at(reset);
                            }
                            cost
                        });

                    (percent, secondary, model_specific, Some(cost))
                } else {
                    (0.0, None, None, None)
                }
            } else {
                (0.0, None, None, None)
            };

        let primary = RateWindow::with_details(percent_used, None, billing_end, None);

        let plan_type = summary
            .membership_type
            .as_ref()
            .map(|t| match t.to_lowercase().as_str() {
                "enterprise" => "Cursor Enterprise".to_string(),
                "pro" => "Cursor Pro".to_string(),
                "hobby" => "Cursor Hobby".to_string(),
                "team" => "Cursor Team".to_string(),
                other => format!("Cursor {}", capitalize(other)),
            });

        let email = user_info.as_ref().and_then(|u| u.email.clone());

        Ok((
            primary,
            secondary,
            model_specific,
            cost_snapshot,
            email,
            plan_type,
        ))
    }

    fn on_demand_cost(
        on_demand: Option<&OnDemandUsage>,
        billing_end: Option<DateTime<Utc>>,
    ) -> Option<CostSnapshot> {
        let usage = on_demand?;
        if usage.enabled == Some(false) {
            return None;
        }

        let used_cents = usage.used.unwrap_or(0) as f64;
        let limit_cents = usage
            .limit
            .or_else(|| {
                usage
                    .remaining
                    .map(|remaining| remaining + usage.used.unwrap_or(0))
            })
            .unwrap_or(0) as f64;

        if used_cents <= 0.0 && limit_cents <= 0.0 {
            return None;
        }

        let mut cost = CostSnapshot::new(used_cents / 100.0, "USD", "Monthly");
        if limit_cents > 0.0 {
            cost = cost.with_limit(limit_cents / 100.0);
        }
        if let Some(reset) = billing_end {
            cost = cost.with_resets_at(reset);
        }
        Some(cost)
    }
}

impl Default for CursorApi {
    fn default() -> Self {
        Self::new()
    }
}

// --- API Response Types ---

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageSummary {
    billing_cycle_start: Option<String>,
    billing_cycle_end: Option<String>,
    membership_type: Option<String>,
    limit_type: Option<String>,
    is_unlimited: Option<bool>,
    individual_usage: Option<IndividualUsage>,
    team_usage: Option<TeamUsage>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IndividualUsage {
    plan: Option<PlanUsage>,
    on_demand: Option<OnDemandUsage>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanUsage {
    enabled: Option<bool>,
    used: Option<i64>,
    limit: Option<i64>,
    remaining: Option<i64>,
    breakdown: Option<PlanBreakdown>,
    auto_percent_used: Option<f64>,
    api_percent_used: Option<f64>,
    total_percent_used: Option<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanBreakdown {
    included: Option<i64>,
    bonus: Option<i64>,
    total: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OnDemandUsage {
    enabled: Option<bool>,
    used: Option<i64>,
    limit: Option<i64>,
    remaining: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TeamUsage {
    on_demand: Option<OnDemandUsage>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UserInfo {
    email: Option<String>,
    email_verified: Option<bool>,
    name: Option<String>,
    sub: Option<String>,
    created_at: Option<String>,
    updated_at: Option<String>,
    picture: Option<String>,
}

#[derive(Debug)]
struct CursorIdeSession {
    access_token: String,
    email: Option<String>,
    membership_type: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DashboardCurrentPeriodUsage {
    billing_cycle_end: Option<String>,
    plan_usage: Option<DashboardPlanUsage>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DashboardPlanUsage {
    auto_percent_used: Option<f64>,
    api_percent_used: Option<f64>,
    total_percent_used: Option<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DashboardMe {
    email: Option<String>,
}

// --- Helper functions ---

fn cursor_state_db_path() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("CURSOR_STATE_DB")
        && !path.trim().is_empty()
    {
        return Some(PathBuf::from(path));
    }

    dirs::data_dir().map(|base| {
        base.join("Cursor")
            .join("User")
            .join("globalStorage")
            .join("state.vscdb")
    })
}

fn copy_state_db_to_temp(path: &Path) -> Result<PathBuf, ProviderError> {
    let temp_path = std::env::temp_dir().join(format!(
        "codexbar-cursor-state-{}.vscdb",
        uuid::Uuid::new_v4()
    ));
    std::fs::copy(path, &temp_path).map_err(|e| {
        ProviderError::Other(format!(
            "Failed to copy Cursor IDE state database for reading: {e}"
        ))
    })?;
    Ok(temp_path)
}

fn read_cursor_ide_session_from_db(db_path: &Path) -> Result<CursorIdeSession, ProviderError> {
    let conn = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| ProviderError::Other(format!("Failed to open Cursor IDE state: {e}")))?;
    conn.busy_timeout(std::time::Duration::from_millis(250))
        .map_err(|e| ProviderError::Other(format!("Failed to configure SQLite timeout: {e}")))?;

    let access_token = read_state_value(&conn, CURSOR_ACCESS_TOKEN_KEY)?
        .filter(|value| !value.trim().is_empty())
        .ok_or(ProviderError::AuthRequired)?;

    Ok(CursorIdeSession {
        access_token,
        email: read_state_value(&conn, CURSOR_EMAIL_KEY)?,
        membership_type: read_state_value(&conn, CURSOR_MEMBERSHIP_KEY)?,
    })
}

fn read_state_value(conn: &Connection, key: &str) -> Result<Option<String>, ProviderError> {
    conn.query_row(
        "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1",
        [key],
        |row| row.get::<_, String>(0),
    )
    .optional()
    .map_err(|e| ProviderError::Other(format!("Failed to read Cursor IDE state: {e}")))
}

fn parse_iso_date(s: &str) -> Option<DateTime<Utc>> {
    // Try with fractional seconds
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Some(dt.with_timezone(&Utc));
    }

    // Try without fractional seconds
    if let Ok(dt) = chrono::DateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%SZ") {
        return Some(dt.with_timezone(&Utc));
    }

    None
}

fn parse_unix_millis(s: &str) -> Option<DateTime<Utc>> {
    s.parse::<i64>()
        .ok()
        .and_then(DateTime::<Utc>::from_timestamp_millis)
}

fn dashboard_percent(value: Option<f64>) -> Option<f64> {
    value.map(|percent| {
        if percent <= 1.0 {
            percent * 100.0
        } else {
            percent
        }
        .clamp(0.0, 100.0)
    })
}

fn capitalize(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        None => String::new(),
        Some(first) => first.to_uppercase().chain(chars).collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn api() -> CursorApi {
        CursorApi::new()
    }

    fn parse_summary(json: &str) -> UsageSummary {
        serde_json::from_str(json).expect("fixture should parse")
    }

    #[test]
    fn test_cursor_build_result_with_lanes() {
        let json = r#"{
            "billingCycleStart": "2026-03-01T00:00:00Z",
            "billingCycleEnd": "2026-04-01T00:00:00Z",
            "membershipType": "pro",
            "individualUsage": {
                "plan": {
                    "used": 1500,
                    "limit": 5000,
                    "totalPercentUsed": 0.30,
                    "autoPercentUsed": 0.20,
                    "apiPercentUsed": 0.10
                }
            }
        }"#;

        let summary = parse_summary(json);
        let (primary, secondary, model_specific, cost, _email, plan_type) =
            api().build_result(summary, None).unwrap();

        assert!((primary.used_percent - 30.0).abs() < 0.01);

        let sec = secondary.expect("secondary should be present");
        assert!((sec.used_percent - 20.0).abs() < 0.01);
        assert!(sec.resets_at.is_some());

        let ms = model_specific.expect("model_specific should be present");
        assert!((ms.used_percent - 10.0).abs() < 0.01);
        assert!(ms.resets_at.is_some());

        assert!(cost.is_some());
        assert_eq!(plan_type.as_deref(), Some("Cursor Pro"));
    }

    #[test]
    fn test_cursor_build_result_cents_only() {
        let json = r#"{
            "billingCycleEnd": "2026-04-01T00:00:00Z",
            "membershipType": "pro",
            "individualUsage": {
                "plan": {
                    "used": 2500,
                    "limit": 5000
                }
            }
        }"#;

        let summary = parse_summary(json);
        let (primary, secondary, model_specific, cost, _, _) =
            api().build_result(summary, None).unwrap();

        assert!((primary.used_percent - 50.0).abs() < 0.01);
        assert!(secondary.is_none(), "no autoPercentUsed in payload");
        assert!(model_specific.is_none(), "no apiPercentUsed in payload");
        assert!(cost.is_some());
    }

    #[test]
    fn test_cursor_build_result_missing_plan() {
        let json = r#"{
            "membershipType": "hobby",
            "individualUsage": {}
        }"#;

        let summary = parse_summary(json);
        let (primary, secondary, model_specific, cost, _, _) =
            api().build_result(summary, None).unwrap();

        assert!((primary.used_percent).abs() < 0.01);
        assert!(secondary.is_none());
        assert!(model_specific.is_none());
        assert!(cost.is_none());
    }

    #[test]
    fn test_cursor_dashboard_result_from_ide_payload() {
        let usage = DashboardCurrentPeriodUsage {
            billing_cycle_end: Some("1781084981975".into()),
            plan_usage: Some(DashboardPlanUsage {
                total_percent_used: Some(42.0),
                auto_percent_used: Some(0.25),
                api_percent_used: Some(12.0),
            }),
        };

        let (primary, secondary, model_specific, cost, email, plan_type) = api()
            .build_dashboard_result(usage, Some("user@example.com".into()), Some("pro".into()))
            .unwrap();

        assert!((primary.used_percent - 42.0).abs() < 0.01);
        assert!(primary.resets_at.is_some());
        assert!((secondary.unwrap().used_percent - 25.0).abs() < 0.01);
        assert!((model_specific.unwrap().used_percent - 12.0).abs() < 0.01);
        assert!(cost.is_none());
        assert_eq!(email.as_deref(), Some("user@example.com"));
        assert_eq!(plan_type.as_deref(), Some("Cursor Pro"));
    }

    #[test]
    fn test_reads_cursor_ide_session_from_state_db() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        let conn = rusqlite::Connection::open(temp.path()).unwrap();
        conn.execute(
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
            [CURSOR_ACCESS_TOKEN_KEY, "access-token"],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
            [CURSOR_EMAIL_KEY, "user@example.com"],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
            [CURSOR_MEMBERSHIP_KEY, "pro"],
        )
        .unwrap();
        drop(conn);

        let session = read_cursor_ide_session_from_db(temp.path()).unwrap();
        assert_eq!(session.access_token, "access-token");
        assert_eq!(session.email.as_deref(), Some("user@example.com"));
        assert_eq!(session.membership_type.as_deref(), Some("pro"));
    }

    #[test]
    fn test_cursor_on_demand_as_cost() {
        let json = r#"{
            "billingCycleEnd": "2026-04-01T00:00:00Z",
            "membershipType": "pro",
            "individualUsage": {
                "plan": {
                    "used": 800,
                    "limit": 5000,
                    "totalPercentUsed": 0.16
                },
                "onDemand": {
                    "enabled": true,
                    "used": 350,
                    "limit": 1000
                }
            }
        }"#;

        let summary = parse_summary(json);
        let (primary, _, _, cost, _, _) = api().build_result(summary, None).unwrap();

        assert!((primary.used_percent - 16.0).abs() < 0.01);
        let cost = cost.expect("cost should exist from on-demand usage");
        assert!((cost.used - 3.5).abs() < 0.01);
        assert_eq!(cost.limit, Some(10.0));
        assert_eq!(cost.period, "Monthly");
    }
}
