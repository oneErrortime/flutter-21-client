use axum::{http::StatusCode, response::IntoResponse};
use metrics_exporter_prometheus::{PrometheusBuilder, PrometheusHandle};
use once_cell::sync::OnceCell;

static PROMETHEUS: OnceCell<PrometheusHandle> = OnceCell::new();

pub fn install() -> PrometheusHandle {
    let handle = PrometheusBuilder::new()
        .install_recorder()
        .expect("Failed to install Prometheus recorder");

    // Register application metrics
    metrics::describe_counter!("auth.register.success", "Successful registrations");
    metrics::describe_counter!("auth.login.success", "Successful logins");
    metrics::describe_counter!("auth.login.failed", "Failed login attempts");
    metrics::describe_counter!("auth.refresh.reuse_detected", "Refresh token reuse attacks detected");
    metrics::describe_counter!("calls.initiated", "Calls initiated");
    metrics::describe_counter!("calls.ended", "Calls ended");
    metrics::describe_counter!("ws.auth.success", "WebSocket connections authenticated");
    metrics::describe_gauge!("ws.connected_clients", "Currently connected WebSocket clients");
    metrics::describe_counter!("http.requests", "HTTP requests");

    PROMETHEUS.set(handle.clone()).ok();
    handle
}

/// Prometheus scrape endpoint — no AppState needed; reads from global handle.
/// Protect this endpoint with a firewall rule or HTTP basic auth in production.
pub async fn metrics_handler() -> impl IntoResponse {
    match PROMETHEUS.get() {
        Some(handle) => (StatusCode::OK, handle.render()),
        None => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "Metrics recorder not initialised".to_string(),
        ),
    }
}
