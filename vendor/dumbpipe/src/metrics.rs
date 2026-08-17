//! Local addition (fs-portal): lightweight observability for the forwarding
//! paths — process-wide counters and an optional Prometheus text-exposition
//! endpoint. Zero new dependencies: std atomics + a std TCP listener thread,
//! so the vendored Cargo.lock stays untouched.
//!
//! Enabled by setting `DUMBPIPE_METRICS_ADDR` (e.g. `0.0.0.0:9103`); when the
//! variable is unset nothing listens and the counters are inert.

use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};

/// Total connections ever handed to the forwarder.
pub static CONNECTIONS_TOTAL: AtomicU64 = AtomicU64::new(0);
/// Connections currently being forwarded.
pub static CONNECTIONS_ACTIVE: AtomicU64 = AtomicU64::new(0);
/// Connections that finished forwarding (cleanly or not).
pub static CONNECTIONS_CLOSED_TOTAL: AtomicU64 = AtomicU64::new(0);
/// Bytes sent towards the iroh peer (local reader -> noq send stream).
pub static BYTES_TO_PEER_TOTAL: AtomicU64 = AtomicU64::new(0);
/// Bytes received from the iroh peer (noq recv stream -> local writer).
pub static BYTES_FROM_PEER_TOTAL: AtomicU64 = AtomicU64::new(0);
/// Errors while establishing or forwarding a connection.
pub static CONNECTION_ERRORS_TOTAL: AtomicU64 = AtomicU64::new(0);
/// Times a connection had to queue because --max-connections was reached.
pub static QUEUE_WAITS_TOTAL: AtomicU64 = AtomicU64::new(0);
/// Sum of completed-stream durations, in milliseconds (Prometheus-side:
/// divide by 1000 and by closed_total for the average stream lifetime).
pub static STREAM_DURATION_MS_TOTAL: AtomicU64 = AtomicU64::new(0);

fn get(counter: &AtomicU64) -> u64 {
    counter.load(Ordering::Relaxed)
}

/// Render the Prometheus text exposition format (version 0.0.4).
pub fn render() -> String {
    let mut out = String::with_capacity(1024);
    let mut metric = |name: &str, kind: &str, help: &str, value: u64| {
        out.push_str(&format!(
            "# HELP {name} {help}\n# TYPE {name} {kind}\n{name} {value}\n"
        ));
    };
    metric(
        "dumbpipe_connections_total",
        "counter",
        "Connections handed to the forwarder",
        get(&CONNECTIONS_TOTAL),
    );
    metric(
        "dumbpipe_connections_active",
        "gauge",
        "Connections currently being forwarded",
        get(&CONNECTIONS_ACTIVE),
    );
    metric(
        "dumbpipe_connections_closed_total",
        "counter",
        "Connections that finished forwarding",
        get(&CONNECTIONS_CLOSED_TOTAL),
    );
    metric(
        "dumbpipe_bytes_to_peer_total",
        "counter",
        "Bytes sent towards the iroh peer",
        get(&BYTES_TO_PEER_TOTAL),
    );
    metric(
        "dumbpipe_bytes_from_peer_total",
        "counter",
        "Bytes received from the iroh peer",
        get(&BYTES_FROM_PEER_TOTAL),
    );
    metric(
        "dumbpipe_connection_errors_total",
        "counter",
        "Errors establishing or forwarding a connection",
        get(&CONNECTION_ERRORS_TOTAL),
    );
    metric(
        "dumbpipe_queue_waits_total",
        "counter",
        "Connections that queued on --max-connections",
        get(&QUEUE_WAITS_TOTAL),
    );
    metric(
        "dumbpipe_stream_duration_ms_total",
        "counter",
        "Sum of completed stream durations in milliseconds",
        get(&STREAM_DURATION_MS_TOTAL),
    );
    out
}

/// If `DUMBPIPE_METRICS_ADDR` is set, serve `render()` over HTTP on it from a
/// background thread. Any GET path answers, so `/metrics` works. Errors are
/// logged, never fatal — metrics must not take down the pipe.
pub fn spawn_server_from_env() {
    let Ok(addr) = std::env::var("DUMBPIPE_METRICS_ADDR") else {
        return;
    };
    std::thread::Builder::new()
        .name("dumbpipe-metrics".into())
        .spawn(move || {
            let listener = match TcpListener::bind(&addr) {
                Ok(l) => {
                    tracing::info!("metrics: serving prometheus metrics on http://{addr}/metrics");
                    l
                }
                Err(e) => {
                    tracing::warn!("metrics: failed to bind {addr}: {e}");
                    return;
                }
            };
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                // drain the request line + headers best-effort; we answer
                // identically regardless of path or method
                let mut buf = [0u8; 4096];
                let _ = stream.read(&mut buf);
                let body = render();
                let response = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: text/plain; version=0.0.4; charset=utf-8\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(response.as_bytes());
            }
        })
        .ok();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_lists_every_metric_with_help_and_type() {
        let text = render();
        for name in [
            "dumbpipe_connections_total",
            "dumbpipe_connections_active",
            "dumbpipe_connections_closed_total",
            "dumbpipe_bytes_to_peer_total",
            "dumbpipe_bytes_from_peer_total",
            "dumbpipe_connection_errors_total",
            "dumbpipe_queue_waits_total",
            "dumbpipe_stream_duration_ms_total",
        ] {
            assert!(text.contains(&format!("# HELP {name} ")), "missing HELP for {name}");
            assert!(text.contains(&format!("# TYPE {name} ")), "missing TYPE for {name}");
            assert!(
                text.lines().any(|l| l.starts_with(&format!("{name} "))),
                "missing sample for {name}"
            );
        }
    }

    #[test]
    fn counters_show_up_in_rendered_values() {
        BYTES_TO_PEER_TOTAL.fetch_add(12345, Ordering::Relaxed);
        let text = render();
        let line = text
            .lines()
            .find(|l| l.starts_with("dumbpipe_bytes_to_peer_total "))
            .expect("sample line");
        let value: u64 = line.split_whitespace().nth(1).unwrap().parse().unwrap();
        assert!(value >= 12345);
    }

    #[test]
    fn http_endpoint_serves_metrics() {
        // bind on an ephemeral port directly (not via env) to avoid
        // cross-test env races
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);
            let body = render();
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: text/plain; version=0.0.4; charset=utf-8\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = stream.write_all(response.as_bytes());
        });
        let mut stream = std::net::TcpStream::connect(addr).unwrap();
        stream
            .write_all(b"GET /metrics HTTP/1.1\r\nhost: x\r\n\r\n")
            .unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 200 OK"));
        assert!(response.contains("dumbpipe_connections_total"));
    }
}
