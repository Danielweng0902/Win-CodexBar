//! Antigravity provider implementation
//!
//! Fetches usage data from Antigravity's local language server probe
//! Uses Windows process detection to find CSRF token

use async_trait::async_trait;
use regex_lite::Regex;
use serde::Deserialize;
#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::process::Command;
use std::sync::OnceLock;

use crate::core::{
    FetchContext, Provider, ProviderError, ProviderFetchResult, ProviderId, ProviderMetadata,
    RateWindow, SourceMode, UsageSnapshot,
};

/// Antigravity provider
pub struct AntigravityProvider {
    metadata: ProviderMetadata,
}

impl AntigravityProvider {
    pub fn new() -> Self {
        Self {
            metadata: ProviderMetadata {
                id: ProviderId::Antigravity,
                display_name: "Antigravity",
                session_label: "Claude",
                weekly_label: "Gemini Pro",
                supports_opus: true,
                supports_credits: false,
                default_enabled: false,
                is_primary: false,
                dashboard_url: None,
                status_page_url: None,
            },
        }
    }

    /// Detect running Antigravity language servers and extract connection info.
    fn detect_process_infos() -> Result<Vec<ProcessInfo>, ProviderError> {
        // Use PowerShell to get process command lines
        #[cfg(windows)]
        const CREATE_NO_WINDOW: u32 = 0x08000000;

        let mut cmd = Command::new("powershell.exe");
        cmd.args([
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            "Get-CimInstance Win32_Process | Where-Object { $_.Name -like '*language_server_windows*' } | Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress",
        ]);
        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW);

        let output = cmd
            .output()
            .map_err(|e| ProviderError::Other(format!("Failed to run PowerShell: {}", e)))?;

        if !output.status.success() {
            return Err(ProviderError::NotInstalled(
                "Failed to detect Antigravity process".to_string(),
            ));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let rows = parse_detected_processes(stdout.trim())?;

        // Parse command line for CSRF token and port — compiled once
        static CSRF_RE: OnceLock<Regex> = OnceLock::new();
        static EXT_CSRF_RE: OnceLock<Regex> = OnceLock::new();
        static PORT_RE: OnceLock<Regex> = OnceLock::new();
        let csrf_regex = CSRF_RE
            .get_or_init(|| Regex::new(r"--csrf_token\s+([a-f0-9-]+)").expect("valid regex"));
        let ext_csrf_regex = EXT_CSRF_RE.get_or_init(|| {
            Regex::new(r"--extension_server_csrf_token\s+([a-f0-9-]+)").expect("valid regex")
        });
        let port_regex = PORT_RE
            .get_or_init(|| Regex::new(r"--extension_server_port\s+(\d+)").expect("valid regex"));

        let mut infos = Vec::new();
        for row in rows {
            let Some(line) = row.command_line.as_deref() else {
                continue;
            };
            if line.contains("language_server_windows") && line.contains("--csrf_token") {
                let csrf_token = csrf_regex
                    .captures(line)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().to_string());

                let ext_csrf_token = ext_csrf_regex
                    .captures(line)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().to_string());

                let port = port_regex
                    .captures(line)
                    .and_then(|c| c.get(1))
                    .and_then(|m| m.as_str().parse::<u16>().ok());

                if let (Some(token), Some(p)) = (csrf_token, port) {
                    infos.push(ProcessInfo {
                        process_id: row.process_id,
                        csrf_token: token,
                        extension_server_csrf_token: ext_csrf_token,
                        extension_port: p,
                    });
                }
            }
        }

        if infos.is_empty() {
            Err(ProviderError::NotInstalled(
                "Antigravity language server not running".to_string(),
            ))
        } else {
            Ok(infos)
        }
    }

    /// Fetch user status from Antigravity API
    async fn fetch_user_status(&self) -> Result<UsageSnapshot, ProviderError> {
        let process_infos = Self::detect_process_infos()?;
        let mut failures = Vec::new();

        for process_info in process_infos {
            match self.fetch_user_status_for_process(&process_info).await {
                Ok(snapshot) => return Ok(snapshot),
                Err(error) => failures.push(format!(
                    "pid {}: {}",
                    process_info
                        .process_id
                        .map(|pid| pid.to_string())
                        .unwrap_or_else(|| "unknown".to_string()),
                    error
                )),
            }
        }

        Err(ProviderError::Other(format!(
            "Antigravity probe failed from all detected language servers. {}",
            failures.join("; ")
        )))
    }

    async fn fetch_user_status_for_process(
        &self,
        process_info: &ProcessInfo,
    ) -> Result<UsageSnapshot, ProviderError> {
        // SECURITY: TLS verification disabled for the local language server.
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_millis(1500))
            .danger_accept_invalid_certs(true)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|e| ProviderError::Other(e.to_string()))?;

        let body = serde_json::json!({
            "metadata": {
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "en"
            }
        });

        let mut failures = Vec::new();
        for port in candidate_api_ports(process_info) {
            for scheme in ["https", "http"] {
                let url = format!(
                    "{}://127.0.0.1:{}/exa.language_server_pb.LanguageServerService/GetUserStatus",
                    scheme, port
                );

                for (token_kind, csrf_token) in csrf_token_candidates(process_info) {
                    let resp = client
                        .post(&url)
                        .header("Content-Type", "application/json")
                        .header("Connect-Protocol-Version", "1")
                        .header("X-Codeium-Csrf-Token", csrf_token)
                        .json(&body)
                        .send()
                        .await;

                    match resp {
                        Ok(resp) if resp.status().is_success() => {
                            let json: UserStatusResponse = resp
                                .json()
                                .await
                                .map_err(|e| ProviderError::Parse(e.to_string()))?;
                            return self.parse_user_status(json);
                        }
                        Ok(resp) => {
                            let status = resp.status();
                            let text = resp.text().await.unwrap_or_default();
                            push_probe_failure(
                                &mut failures,
                                format!("{scheme}:{port} {token_kind} -> {status}: {text}"),
                            );
                        }
                        Err(error) => {
                            push_probe_failure(
                                &mut failures,
                                format!("{scheme}:{port} {token_kind} -> {error}"),
                            );
                        }
                    }
                }
            }
        }

        Err(ProviderError::Other(format!(
            "Could not fetch Antigravity user status from detected language server. {}",
            failures.join("; ")
        )))
    }

    fn parse_user_status(
        &self,
        response: UserStatusResponse,
    ) -> Result<UsageSnapshot, ProviderError> {
        let user_status = response
            .user_status
            .ok_or_else(|| ProviderError::Other("Missing userStatus".to_string()))?;

        let model_configs = user_status
            .cascade_model_config_data
            .and_then(|d| d.client_model_configs)
            .unwrap_or_default();

        let mut primary: Option<RateWindow> = None;
        let mut secondary: Option<RateWindow> = None;
        let mut tertiary: Option<RateWindow> = None;

        for config in &model_configs {
            let family = classify_model(&config.label);
            match family {
                ModelFamily::Claude if primary.is_none() => {
                    if let Some(quota) = &config.quota_info {
                        primary = Some(rate_window_from_quota(quota));
                    }
                }
                ModelFamily::GeminiProLow if secondary.is_none() => {
                    if let Some(quota) = &config.quota_info {
                        secondary = Some(rate_window_from_quota(quota));
                    }
                }
                ModelFamily::GeminiFlash if tertiary.is_none() => {
                    if let Some(quota) = &config.quota_info {
                        tertiary = Some(rate_window_from_quota(quota));
                    }
                }
                _ => {}
            }
        }

        if primary.is_none()
            && let Some(first) = model_configs.first()
            && let Some(quota) = &first.quota_info
        {
            primary = Some(rate_window_from_quota(quota));
        }

        let primary = primary.unwrap_or_else(|| RateWindow::new(0.0));
        let mut snapshot = UsageSnapshot::new(primary);

        if let Some(sec) = secondary {
            snapshot = snapshot.with_secondary(sec);
        }
        if let Some(ter) = tertiary {
            snapshot = snapshot.with_model_specific(ter);
        }

        // Add plan info
        let plan_name = user_status
            .plan_status
            .and_then(|ps| ps.plan_info)
            .and_then(|pi| pi.plan_display_name.or(pi.plan_name));

        if let Some(plan) = plan_name {
            snapshot = snapshot.with_login_method(&plan);
        }

        Ok(snapshot)
    }
}

impl Default for AntigravityProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Provider for AntigravityProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Antigravity
    }

    fn metadata(&self) -> &ProviderMetadata {
        &self.metadata
    }

    async fn fetch_usage(&self, _ctx: &FetchContext) -> Result<ProviderFetchResult, ProviderError> {
        tracing::debug!("Fetching Antigravity usage via local probe");

        match self.fetch_user_status().await {
            Ok(usage) => Ok(ProviderFetchResult::new(usage, "local")),
            Err(e) => {
                tracing::warn!("Antigravity probe failed: {}", e);
                Err(e)
            }
        }
    }

    fn available_sources(&self) -> Vec<SourceMode> {
        vec![SourceMode::Auto, SourceMode::Cli]
    }

    fn supports_cli(&self) -> bool {
        true
    }
}

struct ProcessInfo {
    process_id: Option<u32>,
    csrf_token: String,
    extension_server_csrf_token: Option<String>,
    extension_port: u16,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct DetectedProcess {
    process_id: Option<u32>,
    command_line: Option<String>,
}

fn parse_detected_processes(stdout: &str) -> Result<Vec<DetectedProcess>, ProviderError> {
    if stdout.trim().is_empty() {
        return Ok(Vec::new());
    }

    let value: serde_json::Value = serde_json::from_str(stdout)
        .map_err(|e| ProviderError::Parse(format!("Invalid Antigravity process list: {e}")))?;

    match value {
        serde_json::Value::Array(_) => serde_json::from_value(value)
            .map_err(|e| ProviderError::Parse(format!("Invalid Antigravity process row: {e}"))),
        serde_json::Value::Object(_) => {
            let row = serde_json::from_value(value).map_err(|e| {
                ProviderError::Parse(format!("Invalid Antigravity process row: {e}"))
            })?;
            Ok(vec![row])
        }
        _ => Ok(Vec::new()),
    }
}

fn candidate_api_ports(process_info: &ProcessInfo) -> Vec<u16> {
    let mut ports = Vec::new();
    if let Some(process_id) = process_info.process_id {
        ports.extend(listening_ports_for_process(process_id));
    }
    for offset in 0..20 {
        ports.push(process_info.extension_port.saturating_add(offset));
    }
    ports.extend([53835, 53836, 53837, 53838, 53845, 53849]);
    dedup_ports(ports)
}

fn dedup_ports(ports: Vec<u16>) -> Vec<u16> {
    let mut out = Vec::new();
    for port in ports {
        if port != 0 && !out.contains(&port) {
            out.push(port);
        }
    }
    out
}

fn csrf_token_candidates(process_info: &ProcessInfo) -> Vec<(&'static str, &str)> {
    let mut tokens = vec![("language", process_info.csrf_token.as_str())];
    if let Some(extension) = process_info.extension_server_csrf_token.as_deref()
        && extension != process_info.csrf_token
    {
        tokens.push(("extension", extension));
    }
    tokens
}

fn push_probe_failure(failures: &mut Vec<String>, failure: String) {
    const MAX_FAILURES: usize = 8;
    if failures.len() < MAX_FAILURES {
        failures.push(failure);
    }
}

#[cfg(windows)]
fn listening_ports_for_process(process_id: u32) -> Vec<u16> {
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    let mut cmd = Command::new("powershell.exe");
    cmd.args([
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        &format!(
            "Get-NetTCPConnection -State Listen -OwningProcess {} -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort",
            process_id
        ),
    ]);
    cmd.creation_flags(CREATE_NO_WINDOW);

    let Ok(output) = cmd.output() else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }

    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.trim().parse::<u16>().ok())
        .collect()
}

#[cfg(not(windows))]
fn listening_ports_for_process(_process_id: u32) -> Vec<u16> {
    Vec::new()
}

// API Response types

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UserStatusResponse {
    user_status: Option<UserStatus>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UserStatus {
    #[allow(dead_code)]
    email: Option<String>,
    plan_status: Option<PlanStatus>,
    cascade_model_config_data: Option<ModelConfigData>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanStatus {
    plan_info: Option<PlanInfo>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanInfo {
    plan_name: Option<String>,
    plan_display_name: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ModelConfigData {
    client_model_configs: Option<Vec<ModelConfig>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ModelConfig {
    label: String,
    quota_info: Option<QuotaInfo>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct QuotaInfo {
    remaining_fraction: Option<f64>,
    reset_time: Option<String>,
}

// ── Model-family classification ──────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
enum ModelFamily {
    Claude,
    ClaudeThinking,
    GeminiProLow,
    GeminiFlash,
    Other,
}

fn classify_model(label: &str) -> ModelFamily {
    let lower = label.to_lowercase();
    if lower.contains("claude") {
        if lower.contains("thinking") {
            ModelFamily::ClaudeThinking
        } else {
            ModelFamily::Claude
        }
    } else if lower.contains("gemini") && lower.contains("pro") && lower.contains("low") {
        ModelFamily::GeminiProLow
    } else if lower.contains("gemini") && lower.contains("flash") {
        ModelFamily::GeminiFlash
    } else if lower.contains("pro") && lower.contains("low") {
        ModelFamily::GeminiProLow
    } else if lower.contains("flash") {
        ModelFamily::GeminiFlash
    } else {
        ModelFamily::Other
    }
}

fn rate_window_from_quota(quota: &QuotaInfo) -> RateWindow {
    let remaining = quota.remaining_fraction.unwrap_or(1.0);
    let used_percent = (1.0 - remaining) * 100.0;
    RateWindow::with_details(used_percent, None, None, quota.reset_time.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_classify_model_families() {
        assert_eq!(classify_model("Claude 3.5 Sonnet"), ModelFamily::Claude);
        assert_eq!(classify_model("claude-4-opus"), ModelFamily::Claude);
        assert_eq!(
            classify_model("Claude Thinking"),
            ModelFamily::ClaudeThinking
        );
        assert_eq!(
            classify_model("claude-3.5-sonnet-thinking"),
            ModelFamily::ClaudeThinking
        );
        assert_eq!(
            classify_model("Gemini 2.5 Pro Low"),
            ModelFamily::GeminiProLow
        );
        assert_eq!(classify_model("gemini-pro-low"), ModelFamily::GeminiProLow);
        assert_eq!(classify_model("Pro Low Latency"), ModelFamily::GeminiProLow);
        assert_eq!(classify_model("Gemini 2.5 Flash"), ModelFamily::GeminiFlash);
        assert_eq!(classify_model("gemini-flash"), ModelFamily::GeminiFlash);
        assert_eq!(classify_model("Flash Model"), ModelFamily::GeminiFlash);
        assert_eq!(classify_model("GPT-4o"), ModelFamily::Other);
        assert_eq!(classify_model("unknown-model"), ModelFamily::Other);
    }

    #[test]
    fn parse_detected_processes_accepts_single_object() {
        let rows = parse_detected_processes(
            r#"{"ProcessId":123,"CommandLine":"language_server_windows_x64.exe --csrf_token abc --extension_server_port 49152"}"#,
        )
        .unwrap();

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].process_id, Some(123));
    }

    #[test]
    fn candidate_api_ports_includes_extension_range_and_dedups() {
        let info = ProcessInfo {
            process_id: None,
            csrf_token: "abc".into(),
            extension_server_csrf_token: None,
            extension_port: 49152,
        };

        let ports = candidate_api_ports(&info);
        assert!(ports.contains(&49152));
        assert!(ports.contains(&49171));
        assert!(ports.contains(&53835));
        assert_eq!(ports.iter().filter(|&&port| port == 49152).count(), 1);
    }

    fn make_response(models: Vec<(&str, f64)>) -> UserStatusResponse {
        let json = serde_json::json!({
            "userStatus": {
                "cascadeModelConfigData": {
                    "clientModelConfigs": models.iter().map(|(label, remaining)| {
                        serde_json::json!({
                            "label": label,
                            "quotaInfo": {
                                "remainingFraction": remaining
                            }
                        })
                    }).collect::<Vec<_>>()
                }
            }
        });
        serde_json::from_value(json).unwrap()
    }

    #[test]
    fn test_parse_user_status_standard() {
        let resp = make_response(vec![
            ("Claude 3.5 Sonnet", 0.8),
            ("Gemini 2.5 Pro Low", 0.5),
            ("Gemini 2.5 Flash", 0.9),
        ]);
        let provider = AntigravityProvider::new();
        let snap = provider.parse_user_status(resp).unwrap();

        assert!((snap.primary.used_percent - 20.0).abs() < 0.1);
        let sec = snap.secondary.unwrap();
        assert!((sec.used_percent - 50.0).abs() < 0.1);
        let ter = snap.model_specific.unwrap();
        assert!((ter.used_percent - 10.0).abs() < 0.1);
    }

    #[test]
    fn test_parse_user_status_thinking_skipped() {
        let resp = make_response(vec![
            ("Claude Thinking", 0.6),
            ("Claude 3.5 Sonnet", 0.7),
            ("Gemini 2.5 Flash", 0.5),
        ]);
        let provider = AntigravityProvider::new();
        let snap = provider.parse_user_status(resp).unwrap();

        assert!((snap.primary.used_percent - 30.0).abs() < 0.1);
    }

    #[test]
    fn test_parse_user_status_fallback_first() {
        let resp = make_response(vec![("GPT-4o", 0.4), ("Mistral Large", 0.6)]);
        let provider = AntigravityProvider::new();
        let snap = provider.parse_user_status(resp).unwrap();

        assert!((snap.primary.used_percent - 60.0).abs() < 0.1);
        assert!(snap.secondary.is_none());
        assert!(snap.model_specific.is_none());
    }
}
