//! Local addition (fs-portal): lightweight observability for the forwarding
//! paths — process-wide counters and an optional Prometheus text-exposition
//! endpoint. Zero new dependencies: std atomics + a std TCP listener thread,
//! so the vendored Cargo.lock stays untouched.
//!
//! Enabled by setting `DUMBPIPE_METRICS_ADDR` (e.g. `0.0.0.0:9103`); when the
//! variable is unset nothing listens and the counters are inert.

use std::{
    collections::BTreeMap,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
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
    render_labeled(None)
}

/// Keep only characters that are safe inside a Prometheus label value (the
/// instance names fs-portal generates are alphanumeric anyway).
fn sanitize_label(v: &str) -> String {
    v.chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
        .collect()
}

/// Like `render()`, but when `instance` is set every sample carries a
/// `proc="<instance>"` label so payloads from several processes can be told
/// apart after the central metrics server merges them onto one endpoint.
pub fn render_labeled(instance: Option<&str>) -> String {
    let label = match instance {
        Some(i) => format!("{{proc=\"{}\"}}", sanitize_label(i)),
        None => String::new(),
    };
    let mut out = String::with_capacity(1024);
    let mut metric = |name: &str, kind: &str, help: &str, value: u64| {
        out.push_str(&format!(
            "# HELP {name} {help}\n# TYPE {name} {kind}\n{name}{label} {value}\n"
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

// ---- central metrics server (push aggregation) ----------------------------
//
// With several forwarding processes (fs-portal FSP_PROCS > 1) a port per
// process is awkward to scrape. Instead every process pushes its labeled
// exposition to one `dumbpipe metrics-server`, which serves the merged result
// from a single port. Same zero-dependency constraints as above.

/// If `DUMBPIPE_METRICS_PUSH_ADDR` is set (host:port of a running
/// `dumbpipe metrics-server`), push labeled metrics there periodically from a
/// background thread — the multi-process alternative to serving a port of our
/// own. The sample label and storage key is `DUMBPIPE_METRICS_INSTANCE`
/// (default `pid<pid>`); the cadence is `DUMBPIPE_METRICS_PUSH_INTERVAL_SECS`
/// (default 5). Failed pushes are logged and retried on the next tick —
/// metrics must not take down the pipe.
pub fn spawn_push_from_env() {
    let Ok(addr) = std::env::var("DUMBPIPE_METRICS_PUSH_ADDR") else {
        return;
    };
    let instance = std::env::var("DUMBPIPE_METRICS_INSTANCE")
        .ok()
        .map(|v| sanitize_label(&v))
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| format!("pid{}", std::process::id()));
    let interval = std::env::var("DUMBPIPE_METRICS_PUSH_INTERVAL_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|v| *v >= 1)
        .unwrap_or(5);
    std::thread::Builder::new()
        .name("dumbpipe-metrics-push".into())
        .spawn(move || {
            tracing::info!(
                "metrics: pushing prometheus metrics to http://{addr}/push every {interval}s as proc=\"{instance}\""
            );
            loop {
                if let Err(e) = push_once(&addr, &instance) {
                    tracing::debug!("metrics: push to {addr} failed: {e}");
                }
                std::thread::sleep(Duration::from_secs(interval));
            }
        })
        .ok();
}

/// One HTTP POST of the current counters to the metrics server.
fn push_once(addr: &str, instance: &str) -> std::io::Result<()> {
    let body = render_labeled(Some(instance));
    let mut stream = TcpStream::connect(addr)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let request = format!(
        "POST /push?instance={instance} HTTP/1.1\r\nhost: dumbpipe-metrics\r\ncontent-type: text/plain\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(request.as_bytes())?;
    let mut ack = [0u8; 512];
    let _ = stream.read(&mut ack); // wait for the server's ack, best-effort
    Ok(())
}

/// Latest payload pushed by one process.
struct Pushed {
    body: String,
    at: Instant,
}

/// The central metrics server behind `dumbpipe metrics-server --addr ...`:
/// processes POST their labeled exposition to `/push?instance=NAME` and any
/// GET serves every payload merged per metric family, plus a
/// `dumbpipe_metrics_push_age_seconds` freshness gauge per process.
pub fn run_metrics_server(addr: &str) -> std::io::Result<()> {
    let listener = TcpListener::bind(addr)?;
    tracing::info!(
        "metrics-server: serving merged prometheus metrics on http://{addr}/metrics (push endpoint: POST /push?instance=NAME)"
    );
    serve_aggregator(listener)
}

fn serve_aggregator(listener: TcpListener) -> std::io::Result<()> {
    let store: Arc<Mutex<BTreeMap<String, Pushed>>> = Arc::default();
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let store = store.clone();
        std::thread::spawn(move || {
            let _ = handle_aggregator_conn(stream, &store);
        });
    }
    Ok(())
}

fn handle_aggregator_conn(
    mut stream: TcpStream,
    store: &Mutex<BTreeMap<String, Pushed>>,
) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let (method, target, body) = read_request(&mut stream)?;
    let (status, content_type, response_body) = if method == "POST" {
        let instance = target
            .split_once('?')
            .map(|(_, q)| q)
            .unwrap_or("")
            .split('&')
            .find_map(|kv| kv.strip_prefix("instance="))
            .map(sanitize_label)
            .unwrap_or_default();
        if instance.is_empty() {
            (
                "400 Bad Request",
                "text/plain",
                "missing instance= query parameter\n".to_string(),
            )
        } else {
            store
                .lock()
                .unwrap()
                .insert(instance, Pushed { body, at: Instant::now() });
            ("200 OK", "text/plain", "ok\n".to_string())
        }
    } else {
        (
            "200 OK",
            "text/plain; version=0.0.4; charset=utf-8",
            merge_payloads(&store.lock().unwrap()),
        )
    };
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: {content_type}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{response_body}",
        response_body.len()
    );
    stream.write_all(response.as_bytes())
}

/// Minimal HTTP/1.x request reader: returns (method, target, body). Headers
/// are capped at 64 KiB, the body at 4 MiB via content-length.
fn read_request(stream: &mut impl Read) -> std::io::Result<(String, String, String)> {
    let mut head = Vec::new();
    let mut buf = [0u8; 4096];
    let mut leftover = Vec::new();
    loop {
        let n = stream.read(&mut buf)?;
        if n == 0 {
            break;
        }
        head.extend_from_slice(&buf[..n]);
        if let Some(pos) = head.windows(4).position(|w| w == b"\r\n\r\n") {
            leftover = head.split_off(pos + 4);
            head.truncate(pos);
            break;
        }
        if head.len() > 64 * 1024 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "headers too large",
            ));
        }
    }
    let head = String::from_utf8_lossy(&head).into_owned();
    let mut lines = head.lines();
    let mut request_line = lines.next().unwrap_or("").split_whitespace();
    let method = request_line.next().unwrap_or("").to_string();
    let target = request_line.next().unwrap_or("").to_string();
    let content_length = lines
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.trim().parse::<usize>().ok())
        .unwrap_or(0)
        .min(4 * 1024 * 1024);
    let mut body = leftover;
    while body.len() < content_length {
        let n = stream.read(&mut buf)?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&buf[..n]);
    }
    body.truncate(content_length);
    Ok((method, target, String::from_utf8_lossy(&body).into_owned()))
}

/// Merge pushed payloads into one exposition. Lines are regrouped per metric
/// family (HELP/TYPE once, then every process's samples) because Prometheus
/// requires a family's lines to be contiguous; a freshness gauge is appended
/// so a stale payload from a dead process is detectable.
fn merge_payloads(store: &BTreeMap<String, Pushed>) -> String {
    let mut order: Vec<String> = Vec::new();
    let mut headers: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut samples: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for pushed in store.values() {
        for line in pushed.body.lines() {
            if line.is_empty() {
                continue;
            }
            let (family, is_header) = match line.strip_prefix("# ") {
                Some(rest) => (rest.split_whitespace().nth(1).unwrap_or(""), true),
                None => (
                    line.split(|c| c == '{' || c == ' ').next().unwrap_or(""),
                    false,
                ),
            };
            if family.is_empty() {
                continue;
            }
            if !headers.contains_key(family) && !samples.contains_key(family) {
                order.push(family.to_string());
            }
            let bucket = if is_header {
                headers.entry(family.to_string()).or_default()
            } else {
                samples.entry(family.to_string()).or_default()
            };
            if !is_header || !bucket.iter().any(|l| l == line) {
                bucket.push(line.to_string());
            }
        }
    }
    let mut out = String::new();
    for family in &order {
        for line in headers.get(family).into_iter().flatten() {
            out.push_str(line);
            out.push('\n');
        }
        for line in samples.get(family).into_iter().flatten() {
            out.push_str(line);
            out.push('\n');
        }
    }
    if !store.is_empty() {
        out.push_str(
            "# HELP dumbpipe_metrics_push_age_seconds Seconds since this process last pushed its metrics\n# TYPE dumbpipe_metrics_push_age_seconds gauge\n",
        );
        for (instance, pushed) in store {
            out.push_str(&format!(
                "dumbpipe_metrics_push_age_seconds{{proc=\"{instance}\"}} {}\n",
                pushed.at.elapsed().as_secs()
            ));
        }
    }
    out
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
    fn labeled_render_carries_proc_label() {
        let text = render_labeled(Some("dp2"));
        assert!(text
            .lines()
            .any(|l| l.starts_with("dumbpipe_connections_total{proc=\"dp2\"} ")));
        // HELP/TYPE lines stay unlabeled
        assert!(text.contains("# HELP dumbpipe_connections_total "));
        assert!(text.contains("# TYPE dumbpipe_connections_total counter"));
    }

    #[test]
    fn sanitize_label_strips_quotes_and_escapes() {
        assert_eq!(sanitize_label("dp1"), "dp1");
        assert_eq!(sanitize_label("a\"b\\c{d}e f\n"), "abcdef");
    }

    #[test]
    fn merge_groups_families_and_appends_age_gauge() {
        let mut store = BTreeMap::new();
        for name in ["dp1", "dp2"] {
            store.insert(
                name.to_string(),
                Pushed {
                    body: render_labeled(Some(name)),
                    at: Instant::now(),
                },
            );
        }
        let merged = merge_payloads(&store);
        // exactly one HELP and one TYPE per family, one sample per process
        let helps = merged
            .lines()
            .filter(|l| l.starts_with("# HELP dumbpipe_connections_total "))
            .count();
        let types = merged
            .lines()
            .filter(|l| l.starts_with("# TYPE dumbpipe_connections_total "))
            .count();
        assert_eq!((helps, types), (1, 1));
        assert!(merged.contains("dumbpipe_connections_total{proc=\"dp1\"} "));
        assert!(merged.contains("dumbpipe_connections_total{proc=\"dp2\"} "));
        // a family's lines are contiguous: dp2's sample directly follows dp1's
        let lines: Vec<_> = merged.lines().collect();
        let i = lines
            .iter()
            .position(|l| l.starts_with("dumbpipe_connections_total{proc=\"dp1\"}"))
            .unwrap();
        assert!(lines[i + 1].starts_with("dumbpipe_connections_total{proc=\"dp2\"}"));
        assert!(merged.contains("dumbpipe_metrics_push_age_seconds{proc=\"dp1\"} "));
        assert!(merged.contains("dumbpipe_metrics_push_age_seconds{proc=\"dp2\"} "));
    }

    #[test]
    fn read_request_parses_post_with_body() {
        let raw: &[u8] =
            b"POST /push?instance=dp1 HTTP/1.1\r\nhost: x\r\ncontent-length: 5\r\n\r\nhello";
        let (method, target, body) = read_request(&mut &raw[..]).unwrap();
        assert_eq!(method, "POST");
        assert_eq!(target, "/push?instance=dp1");
        assert_eq!(body, "hello");
    }

    #[test]
    fn aggregator_end_to_end_push_then_scrape() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || serve_aggregator(listener));
        for name in ["dp1", "dp2"] {
            push_once(&addr.to_string(), name).unwrap();
        }
        let mut stream = TcpStream::connect(addr).unwrap();
        stream
            .write_all(b"GET /metrics HTTP/1.1\r\nhost: x\r\n\r\n")
            .unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 200 OK"));
        assert!(response.contains("dumbpipe_connections_total{proc=\"dp1\"} "));
        assert!(response.contains("dumbpipe_connections_total{proc=\"dp2\"} "));
        assert!(response.contains("dumbpipe_metrics_push_age_seconds{proc=\"dp2\"} "));
    }

    #[test]
    fn aggregator_rejects_push_without_instance() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || serve_aggregator(listener));
        let mut stream = TcpStream::connect(addr).unwrap();
        stream
            .write_all(b"POST /push HTTP/1.1\r\nhost: x\r\ncontent-length: 2\r\n\r\nhi")
            .unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 400 "));
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
