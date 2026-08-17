//! Command line arguments.
use std::{
    io,
    net::{SocketAddr, SocketAddrV4, SocketAddrV6, ToSocketAddrs},
    str::FromStr,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

use clap::{Parser, Subcommand};
use dumbpipe::EndpointTicket;
use iroh::{
    endpoint::{presets, Accepting},
    Endpoint, EndpointAddr, SecretKey,
};
use n0_error::{bail_any, ensure_any, AnyError, Result, StdResultExt};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    select,
    sync::{OwnedSemaphorePermit, Semaphore},
    time::timeout,
};

// Local addition (fs-portal): forwarding metrics + optional Prometheus endpoint.
mod metrics;
use tokio_util::sync::CancellationToken;
#[cfg(unix)]
use {
    std::path::PathBuf,
    tokio::net::{UnixListener, UnixStream},
};

const ONLINE_TIMEOUT: Duration = Duration::from_secs(5);

/// Create a dumb pipe between two machines, using an iroh endpoint.
///
/// One side listens, the other side connects. Both sides are identified by a
/// 32 byte endpoint id.
///
/// Connecting to a endpoint id is independent of its IP address. Dumbpipe will try
/// to establish a direct connection even through NATs and firewalls. If that
/// fails, it will fall back to using a relay server.
///
/// For all subcommands, you can specify a secret key using the IROH_SECRET
/// environment variable. If you don't, a random one will be generated.
///
/// You can also specify a port for the endpoint. If you don't, a random one
/// will be chosen.
#[derive(Parser, Debug)]
pub struct Args {
    #[clap(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand, Debug)]
pub enum Commands {
    /// Generate a short endpoint ticket. This ticket can be used to later connect to a
    /// listener that is using the same secret key again.
    ///
    /// This command only really makes sense when you are providing dumbpipe with a
    /// secret key.
    GenerateTicket,

    /// Listen on an endpoint and forward stdin/stdout to the first incoming
    /// bidi stream.
    ///
    /// Will print a endpoint ticket on stderr that can be used to connect.
    Listen(ListenArgs),

    /// Listen on an endpoint and forward incoming connections to the specified
    /// host and port. Every incoming bidi stream is forwarded to a new connection.
    ///
    /// Will print a endpoint ticket on stderr that can be used to connect.
    ///
    /// As far as the endpoint is concerned, this is listening. But it is
    /// connecting to a TCP socket for which you have to specify the host and port.
    ListenTcp(ListenTcpArgs),

    /// Connect to an endpoint, open a bidi stream, and forward stdin/stdout.
    ///
    /// A endpoint ticket is required to connect.
    Connect(ConnectArgs),

    /// Connect to an endpoint, open a bidi stream, and forward stdin/stdout
    /// to it.
    ///
    /// A endpoint ticket is required to connect.
    ///
    /// As far as the endpoint is concerned, this is connecting. But it is
    /// listening on a TCP socket for which you have to specify the interface and port.
    ConnectTcp(ConnectTcpArgs),

    #[cfg(unix)]
    /// Listen on an endpoint and forward incoming connections to the specified
    /// Unix socket path. Every incoming bidi stream is forwarded to a new connection.
    ///
    /// Will print a endpoint ticket on stderr that can be used to connect.
    ///
    /// As far as the endpoint is concerned, this is listening. But it is
    /// connecting to a Unix socket for which you have to specify the path.
    ListenUnix(ListenUnixArgs),

    #[cfg(unix)]
    /// Connect to an endpoint, open a bidi stream, and forward connections
    /// from the specified Unix socket path.
    ///
    /// A endpoint ticket is required to connect.
    ///
    /// As far as the endpoint is concerned, this is connecting. But it is
    /// listening on a Unix socket for which you have to specify the path.
    ConnectUnix(ConnectUnixArgs),

    /// Local addition (fs-portal): central Prometheus metrics server.
    ///
    /// Forwarding processes push their labeled metrics here (enable with
    /// DUMBPIPE_METRICS_PUSH_ADDR + DUMBPIPE_METRICS_INSTANCE; POST
    /// /push?instance=NAME) and a single port serves the merged families to
    /// Prometheus (any GET path answers, so /metrics works).
    MetricsServer(MetricsServerArgs),
}

#[derive(Parser, Debug)]
pub struct MetricsServerArgs {
    /// The address to serve the merged metrics endpoint on, e.g. 0.0.0.0:9104.
    #[clap(long)]
    pub addr: String,
}

#[derive(Parser, Debug)]
pub struct CommonArgs {
    /// The IPv4 address that the endpoint will listen on.
    ///
    /// If None, defaults to a random free port, but it can be useful to specify a fixed
    /// port, e.g. to configure a firewall rule.
    #[clap(long, default_value = None)]
    pub ipv4_addr: Option<SocketAddrV4>,

    /// The IPv6 address that the endpoint will listen on.
    ///
    /// If None, defaults to a random free port, but it can be useful to specify a fixed
    /// port, e.g. to configure a firewall rule.
    #[clap(long, default_value = None)]
    pub ipv6_addr: Option<SocketAddrV6>,

    /// A custom ALPN to use for the endpoint.
    ///
    /// This is an expert feature that allows dumbpipe to be used to interact
    /// with existing iroh protocols.
    ///
    /// When using this option, the connect side must also specify the same ALPN.
    /// The listen side will not expect a handshake, and the connect side will
    /// not send one.
    ///
    /// Alpns are byte strings. To specify an utf8 string, prefix it with `utf8:`.
    /// Otherwise, it will be parsed as a hex string.
    #[clap(long)]
    pub custom_alpn: Option<String>,

    /// The verbosity level. Repeat to increase verbosity.
    #[clap(short = 'v', long, action = clap::ArgAction::Count)]
    pub verbose: u8,
}

impl CommonArgs {
    fn alpn(&self) -> Result<Vec<u8>> {
        Ok(match &self.custom_alpn {
            Some(alpn) => parse_alpn(alpn)?,
            None => dumbpipe::ALPN.to_vec(),
        })
    }

    fn is_custom_alpn(&self) -> bool {
        self.custom_alpn.is_some()
    }
}

fn parse_alpn(alpn: &str) -> Result<Vec<u8>> {
    Ok(if let Some(text) = alpn.strip_prefix("utf8:") {
        text.as_bytes().to_vec()
    } else {
        hex::decode(alpn).anyerr()?
    })
}

#[derive(Parser, Debug)]
pub struct ListenArgs {
    /// Immediately close our sending side, indicating that we will not transmit any data
    #[clap(long)]
    pub recv_only: bool,

    #[clap(flatten)]
    pub common: CommonArgs,
}

#[derive(Parser, Debug)]
pub struct ListenTcpArgs {
    #[clap(long)]
    pub host: String,

    /// Maximum number of connections to forward concurrently.
    ///
    /// Additional incoming connections are queued until a slot frees up.
    /// 0 means unlimited.
    #[clap(long, default_value_t = 0)]
    pub max_connections: usize,

    #[clap(flatten)]
    pub common: CommonArgs,
}

#[derive(Parser, Debug)]
pub struct ConnectTcpArgs {
    /// The addresses to listen on for incoming tcp connections.
    ///
    /// To listen on all network interfaces, use 0.0.0.0:12345
    #[clap(long)]
    pub addr: String,

    /// Maximum number of connections to forward concurrently.
    ///
    /// Additional incoming connections are queued until a slot frees up.
    /// 0 means unlimited.
    #[clap(long, default_value_t = 0)]
    pub max_connections: usize,

    /// The endpoint to connect to
    pub ticket: EndpointTicket,

    #[clap(flatten)]
    pub common: CommonArgs,
}

#[derive(Parser, Debug)]
pub struct ConnectArgs {
    /// The endpoint to connect to
    pub ticket: EndpointTicket,

    /// Immediately close our sending side, indicating that we will not transmit any data
    #[clap(long)]
    pub recv_only: bool,

    #[clap(flatten)]
    pub common: CommonArgs,
}

#[cfg(unix)]
#[derive(Parser, Debug)]
pub struct ListenUnixArgs {
    /// Path to the Unix socket to connect to
    #[clap(long)]
    pub socket_path: PathBuf,

    #[clap(flatten)]
    pub common: CommonArgs,
}

#[cfg(unix)]
#[derive(Parser, Debug)]
pub struct ConnectUnixArgs {
    /// Path to the Unix socket to listen on
    #[clap(long)]
    pub socket_path: PathBuf,

    /// The endpoint to connect to
    pub ticket: EndpointTicket,

    #[clap(flatten)]
    pub common: CommonArgs,
}

/// Copy from a reader to a noq stream.
///
/// Will send a reset to the other side if the operation is cancelled, and fail
/// with an error.
///
/// Returns the number of bytes copied in case of success.
async fn copy_to_noq(
    from: impl AsyncRead + Unpin,
    mut send: noq::SendStream,
    token: CancellationToken,
    conn_id: u64,
) -> io::Result<u64> {
    tracing::trace!("copying to noq");
    tokio::select! {
        res = instrumented_copy(from, &mut send, conn_id, "to_peer", &metrics::BYTES_TO_PEER_TOTAL) => {
            let size = res?;
            send.finish()?;
            Ok(size)
        }
        _ = token.cancelled() => {
            // send a reset to the other side immediately
            send.reset(0u8.into()).ok();
            Err(io::Error::other("cancelled"))
        }
    }
}

/// Copy from a noq stream to a writer.
///
/// Will send stop to the other side if the operation is cancelled, and fail
/// with an error.
///
/// Returns the number of bytes copied in case of success.
async fn copy_from_noq(
    mut recv: noq::RecvStream,
    mut to: impl AsyncWrite + Unpin,
    token: CancellationToken,
    conn_id: u64,
) -> io::Result<u64> {
    tokio::select! {
        res = instrumented_copy(&mut recv, &mut to, conn_id, "from_peer", &metrics::BYTES_FROM_PEER_TOTAL) => {
            Ok(res?)
        },
        _ = token.cancelled() => {
            recv.stop(0u8.into()).ok();
            Err(io::Error::other("cancelled"))
        }
    }
}

/// How many forwarded bytes between per-chunk speed log lines.
const CHUNK_LOG_BYTES: u64 = 32 * 1024 * 1024;

/// Copy `from` into `to` while feeding the byte counter and emitting a speed
/// log line every [`CHUNK_LOG_BYTES`] per direction. Local addition
/// (fs-portal): replaces `tokio::io::copy` so per-stream throughput is
/// observable in logs and metrics.
async fn instrumented_copy(
    mut from: impl AsyncRead + Unpin,
    to: &mut (impl AsyncWrite + Unpin),
    conn_id: u64,
    direction: &'static str,
    counter: &'static AtomicU64,
) -> io::Result<u64> {
    let mut buf = vec![0u8; 64 * 1024];
    let mut total: u64 = 0;
    let mut chunk_bytes: u64 = 0;
    let mut chunk_started = Instant::now();
    loop {
        let n = from.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        to.write_all(&buf[..n]).await?;
        total += n as u64;
        chunk_bytes += n as u64;
        counter.fetch_add(n as u64, Ordering::Relaxed);
        if chunk_bytes >= CHUNK_LOG_BYTES {
            let secs = chunk_started.elapsed().as_secs_f64().max(1e-9);
            tracing::info!(
                conn = conn_id,
                direction,
                chunk_mib = format_args!("{:.1}", chunk_bytes as f64 / 1_048_576.0),
                speed_mib_s = format_args!("{:.1}", chunk_bytes as f64 / 1_048_576.0 / secs),
                total_mib = format_args!("{:.1}", total as f64 / 1_048_576.0),
                "chunk forwarded"
            );
            chunk_bytes = 0;
            chunk_started = Instant::now();
        }
    }
    to.flush().await?;
    Ok(total)
}

/// Get the secret key or generate a new one.
///
/// Print the secret key to stderr if it was generated, so the user can save it.
fn get_or_create_secret() -> Result<SecretKey> {
    match std::env::var("IROH_SECRET") {
        Ok(secret) => SecretKey::from_str(&secret).std_context("invalid secret"),
        Err(_) => {
            let key = SecretKey::generate();
            eprintln!(
                "using secret key {}",
                data_encoding::HEXLOWER.encode(&key.to_bytes())
            );
            Ok(key)
        }
    }
}

/// Create a new iroh endpoint.
async fn create_endpoint(
    secret_key: SecretKey,
    common: &CommonArgs,
    alpns: Vec<Vec<u8>>,
) -> Result<Endpoint> {
    let mut builder = Endpoint::builder(presets::N0)
        .secret_key(secret_key)
        .alpns(alpns);
    if let Some(addr) = common.ipv4_addr {
        builder = builder.bind_addr(addr)?;
    }
    if let Some(addr) = common.ipv6_addr {
        builder = builder.bind_addr(addr)?;
    }
    let endpoint = builder.bind().await.anyerr()?;
    Ok(endpoint)
}

fn cancel_token<T>(token: CancellationToken) -> impl Fn(T) -> T {
    move |x| {
        token.cancel();
        x
    }
}

/// Concurrency limiter for the tcp forwarding modes: `Some` semaphore with
/// `max` permits, or `None` when `max` is 0 (unlimited).
fn connection_limiter(max: usize) -> Option<Arc<Semaphore>> {
    (max > 0).then(|| Arc::new(Semaphore::new(max)))
}

/// Wait for a free forwarding slot. Returns a permit to hold for the lifetime
/// of the connection, or `None` when no limit is configured. Errors only if
/// the semaphore is closed, which never happens here.
async fn acquire_slot(limiter: &Option<Arc<Semaphore>>) -> Result<Option<OwnedSemaphorePermit>> {
    match limiter {
        Some(semaphore) => {
            if semaphore.available_permits() == 0 {
                metrics::QUEUE_WAITS_TOTAL.fetch_add(1, Ordering::Relaxed);
                tracing::info!("max connections reached, queueing until a slot frees up");
            }
            let permit = semaphore
                .clone()
                .acquire_owned()
                .await
                .std_context("connection limiter closed")?;
            Ok(Some(permit))
        }
        None => Ok(None),
    }
}

/// Bidirectionally forward data from a noq stream and an arbitrary tokio
/// reader/writer pair, aborting both sides when either one forwarder is done,
/// or when control-c is pressed.
async fn forward_bidi(
    from1: impl AsyncRead + Send + Sync + Unpin + 'static,
    to1: impl AsyncWrite + Send + Sync + Unpin + 'static,
    from2: noq::RecvStream,
    to2: noq::SendStream,
) -> Result<()> {
    static NEXT_CONN_ID: AtomicU64 = AtomicU64::new(1);
    let conn_id = NEXT_CONN_ID.fetch_add(1, Ordering::Relaxed);
    metrics::CONNECTIONS_TOTAL.fetch_add(1, Ordering::Relaxed);
    let active = metrics::CONNECTIONS_ACTIVE.fetch_add(1, Ordering::Relaxed) + 1;
    let started = Instant::now();
    tracing::info!(conn = conn_id, active, "stream start");

    let token1 = CancellationToken::new();
    let token2 = token1.clone();
    let token3 = token1.clone();
    let forward_from_stdin = tokio::spawn(async move {
        copy_to_noq(from1, to2, token1.clone(), conn_id)
            .await
            .map_err(cancel_token(token1))
    });
    let forward_to_stdout = tokio::spawn(async move {
        copy_from_noq(from2, to1, token2.clone(), conn_id)
            .await
            .map_err(cancel_token(token2))
    });
    let _control_c = tokio::spawn(async move {
        tokio::signal::ctrl_c().await?;
        token3.cancel();
        io::Result::Ok(())
    });
    let res_from_peer = forward_to_stdout.await.anyerr().and_then(|r| r.anyerr());
    let res_to_peer = forward_from_stdin.await.anyerr().and_then(|r| r.anyerr());

    let elapsed = started.elapsed();
    metrics::CONNECTIONS_ACTIVE.fetch_sub(1, Ordering::Relaxed);
    metrics::CONNECTIONS_CLOSED_TOTAL.fetch_add(1, Ordering::Relaxed);
    metrics::STREAM_DURATION_MS_TOTAL.fetch_add(elapsed.as_millis() as u64, Ordering::Relaxed);
    let secs = elapsed.as_secs_f64().max(1e-9);
    let mib = |b: &u64| *b as f64 / 1_048_576.0;
    match (&res_from_peer, &res_to_peer) {
        (Ok(from_peer), Ok(to_peer)) => {
            tracing::info!(
                conn = conn_id,
                duration_s = format_args!("{:.2}", secs),
                from_peer_mib = format_args!("{:.2}", mib(from_peer)),
                to_peer_mib = format_args!("{:.2}", mib(to_peer)),
                avg_from_peer_mib_s = format_args!("{:.2}", mib(from_peer) / secs),
                avg_to_peer_mib_s = format_args!("{:.2}", mib(to_peer) / secs),
                "stream closed"
            );
        }
        (from_peer, to_peer) => {
            tracing::warn!(
                conn = conn_id,
                duration_s = format_args!("{:.2}", secs),
                from_peer = ?from_peer.as_ref().map(mib),
                to_peer = ?to_peer.as_ref().map(mib),
                "stream closed with error"
            );
        }
    }
    res_from_peer?;
    res_to_peer?;
    Ok(())
}

async fn listen_stdio(args: ListenArgs) -> Result<()> {
    let secret_key = get_or_create_secret()?;
    let endpoint = create_endpoint(secret_key, &args.common, vec![args.common.alpn()?]).await?;
    // wait for the endpoint to figure out its home relay and addresses before making a ticket
    if (timeout(ONLINE_TIMEOUT, endpoint.online()).await).is_err() {
        eprintln!("Warning: Failed to connect to the home relay");
    }
    let addr = endpoint.addr();
    let short = create_short_ticket(&addr);
    let ticket = EndpointTicket::new(addr);

    // print the ticket on stderr so it doesn't interfere with the data itself
    //
    // note that the tests rely on the ticket being the last thing printed
    eprintln!("Listening. To connect, use:\ndumbpipe connect {ticket}");
    if args.common.verbose > 0 {
        eprintln!("or:\ndumbpipe connect {short}");
    }

    loop {
        let Some(connecting) = endpoint.accept().await else {
            break;
        };
        let connection = match connecting.await {
            Ok(connection) => connection,
            Err(cause) => {
                tracing::warn!("error accepting connection: {}", cause);
                // if accept fails, we want to continue accepting connections
                continue;
            }
        };
        let remote_endpoint_id = &connection.remote_id();
        tracing::info!("got connection from {}", remote_endpoint_id);
        let (s, mut r) = match connection.accept_bi().await {
            Ok(x) => x,
            Err(cause) => {
                tracing::warn!("error accepting stream: {}", cause);
                // if accept_bi fails, we want to continue accepting connections
                continue;
            }
        };
        tracing::info!("accepted bidi stream from {}", remote_endpoint_id);
        if !args.common.is_custom_alpn() {
            // read the handshake and verify it
            let mut buf = [0u8; dumbpipe::HANDSHAKE.len()];
            r.read_exact(&mut buf).await.anyerr()?;
            ensure_any!(buf == dumbpipe::HANDSHAKE, "invalid handshake");
        }
        if args.recv_only {
            tracing::info!(
                "forwarding stdout to {} (ignoring stdin)",
                remote_endpoint_id
            );
            forward_bidi(tokio::io::empty(), tokio::io::stdout(), r, s).await?;
        } else {
            tracing::info!("forwarding stdin/stdout to {}", remote_endpoint_id);
            forward_bidi(tokio::io::stdin(), tokio::io::stdout(), r, s).await?;
        }
        // stop accepting connections after the first successful one
        break;
    }
    Ok(())
}

async fn connect_stdio(args: ConnectArgs) -> Result<()> {
    let secret_key = get_or_create_secret()?;
    let endpoint = create_endpoint(secret_key, &args.common, vec![]).await?;
    let addr = args.ticket.endpoint_addr();
    let remote_endpoint_id = addr.id;
    // connect to the remote, try only once
    let connection = endpoint
        .connect(addr.clone(), &args.common.alpn()?)
        .await
        .anyerr()?;
    tracing::info!("connected to {}", remote_endpoint_id);
    // open a bidi stream, try only once
    let (mut s, r) = connection.open_bi().await.anyerr()?;
    tracing::info!("opened bidi stream to {}", remote_endpoint_id);
    // send the handshake unless we are using a custom alpn
    // when using a custom alpn, everything is up to the user
    if !args.common.is_custom_alpn() {
        // the connecting side must write first. we don't know if there will be something
        // on stdin, so just write a handshake.
        s.write_all(&dumbpipe::HANDSHAKE).await.anyerr()?;
    }
    if args.recv_only {
        tracing::info!(
            "forwarding stdout to {} (ignoring stdin)",
            remote_endpoint_id
        );
        forward_bidi(tokio::io::empty(), tokio::io::stdout(), r, s).await?;
    } else {
        tracing::info!("forwarding stdin/stdout to {}", remote_endpoint_id);
        forward_bidi(tokio::io::stdin(), tokio::io::stdout(), r, s).await?;
    }
    tokio::io::stdout().flush().await.anyerr()?;
    Ok(())
}

/// Listen on a tcp port and forward incoming connections to an endpoint.
async fn connect_tcp(args: ConnectTcpArgs) -> Result<()> {
    let addrs = args
        .addr
        .to_socket_addrs()
        .std_context(format!("invalid host string {}", args.addr))?;
    let secret_key = get_or_create_secret()?;
    let endpoint = create_endpoint(secret_key, &args.common, vec![])
        .await
        .std_context("unable to bind endpoint")?;
    tracing::info!("tcp listening on {:?}", addrs);

    // Wait for our own endpoint to be ready before trying to connect.
    if (timeout(ONLINE_TIMEOUT, endpoint.online()).await).is_err() {
        eprintln!("Warning: Failed to connect to the home relay");
    }

    let tcp_listener = match tokio::net::TcpListener::bind(addrs.as_slice()).await {
        Ok(tcp_listener) => tcp_listener,
        Err(cause) => {
            tracing::error!("error binding tcp socket to {:?}: {}", addrs, cause);
            return Ok(());
        }
    };
    async fn handle_tcp_accept(
        next: io::Result<(tokio::net::TcpStream, SocketAddr)>,
        addr: EndpointAddr,
        endpoint: Endpoint,
        handshake: bool,
        alpn: &[u8],
        limiter: Option<Arc<Semaphore>>,
    ) -> Result<()> {
        let (tcp_stream, tcp_addr) = next.std_context("error accepting tcp connection")?;
        let (tcp_recv, tcp_send) = tcp_stream.into_split();
        tracing::info!("got tcp connection from {}", tcp_addr);
        // hold a forwarding slot for the lifetime of this connection; the tcp
        // connection is already accepted, so its data just queues until we
        // dial the peer
        let _slot = acquire_slot(&limiter).await?;
        let remote_endpoint_id = addr.id;
        let connection = endpoint
            .connect(addr, alpn)
            .await
            .std_context(format!("error connecting to {remote_endpoint_id}"))?;
        let (mut endpoint_send, endpoint_recv) = connection
            .open_bi()
            .await
            .std_context(format!("error opening bidi stream to {remote_endpoint_id}"))?;
        // send the handshake unless we are using a custom alpn
        // when using a custom alpn, everything is up to the user
        if handshake {
            // the connecting side must write first. we don't know if there will be something
            // on stdin, so just write a handshake.
            endpoint_send
                .write_all(&dumbpipe::HANDSHAKE)
                .await
                .anyerr()?;
        }
        forward_bidi(tcp_recv, tcp_send, endpoint_recv, endpoint_send).await?;
        Ok::<_, AnyError>(())
    }
    let addr = apply_addr_hints(
        args.ticket.endpoint_addr().clone(),
        std::env::var("DUMBPIPE_ADDR_HINTS").ok().as_deref(),
    );
    let limiter = connection_limiter(args.max_connections);
    loop {
        // also wait for ctrl-c here so we can use it before accepting a connection
        let next = tokio::select! {
            stream = tcp_listener.accept() => stream,
            _ = tokio::signal::ctrl_c() => {
                eprintln!("got ctrl-c, exiting");
                break;
            }
        };
        let endpoint = endpoint.clone();
        let addr = addr.clone();
        let handshake = !args.common.is_custom_alpn();
        let alpn = args.common.alpn()?;
        let limiter = limiter.clone();
        tokio::spawn(async move {
            if let Err(cause) =
                handle_tcp_accept(next, addr, endpoint, handshake, &alpn, limiter).await
            {
                // log error at warn level
                //
                // we should know about it, but it's not fatal
                metrics::CONNECTION_ERRORS_TOTAL.fetch_add(1, Ordering::Relaxed);
                tracing::warn!("error handling connection: {}", cause);
            }
        });
    }
    Ok(())
}

/// Listen on an endpoint and forward incoming connections to a tcp socket.
async fn listen_tcp(args: ListenTcpArgs) -> Result<()> {
    let addrs = match args.host.to_socket_addrs() {
        Ok(addrs) => addrs.collect::<Vec<_>>(),
        Err(e) => bail_any!("invalid host string {}: {}", args.host, e),
    };
    let secret_key = get_or_create_secret()?;
    let endpoint = create_endpoint(secret_key, &args.common, vec![args.common.alpn()?]).await?;
    // wait for the endpoint to figure out its address before making a ticket
    if (timeout(ONLINE_TIMEOUT, endpoint.online()).await).is_err() {
        eprintln!("Warning: Failed to connect to the home relay");
    }
    let addr = endpoint.addr();
    let short = create_short_ticket(&addr);
    // Local addition (fs-portal): with DUMBPIPE_STABLE_TICKET=1 the primary
    // ticket is the short one (endpoint id + relay only). The full ticket
    // embeds this boot's ephemeral direct addresses, so its string changes on
    // every restart; the short ticket is a stable function of the secret and
    // relay config — the "fixed receiver" ticket fs-portal persists and the
    // user hands out once. Connecting works the same: iroh dials via the
    // relay and hole-punches the current direct path.
    let ticket = if std::env::var("DUMBPIPE_STABLE_TICKET").as_deref() == Ok("1") {
        short.clone()
    } else {
        EndpointTicket::new(addr)
    };

    // print the ticket on stderr so it doesn't interfere with the data itself
    //
    // note that the tests rely on the ticket being the last thing printed
    eprintln!("Forwarding incoming requests to '{}'.", args.host);
    eprintln!("To connect, use e.g.:");
    eprintln!("dumbpipe connect-tcp {ticket}");
    if args.common.verbose > 0 {
        eprintln!("or:\ndumbpipe connect-tcp {short}");
    }
    tracing::info!("endpoint id is {}", ticket.endpoint_addr().id);
    tracing::info!(
        "relay url is {:?}",
        ticket
            .endpoint_addr()
            .relay_urls()
            .next()
            .map_or("None".to_string(), |url| url.to_string())
    );

    // handle a new incoming connection on the endpoint
    async fn handle_endpoint_accept(
        accepting: Accepting,
        addrs: Vec<std::net::SocketAddr>,
        handshake: bool,
        limiter: Option<Arc<Semaphore>>,
    ) -> Result<()> {
        let connection = accepting.await.std_context("error accepting connection")?;
        let remote_endpoint_id = &connection.remote_id();
        tracing::info!("got connection from {}", remote_endpoint_id);
        let (s, mut r) = connection
            .accept_bi()
            .await
            .std_context("error accepting stream")?;
        tracing::info!("accepted bidi stream from {}", remote_endpoint_id);
        if handshake {
            // read the handshake and verify it
            let mut buf = [0u8; dumbpipe::HANDSHAKE.len()];
            r.read_exact(&mut buf).await.anyerr()?;
            ensure_any!(buf == dumbpipe::HANDSHAKE, "invalid handshake");
        }
        // hold a forwarding slot for the lifetime of this connection; the
        // stream stays open (peer sees a stall, not an error) until a slot
        // frees up and we dial the local backend
        let _slot = acquire_slot(&limiter).await?;
        let connection = tokio::net::TcpStream::connect(addrs.as_slice())
            .await
            .std_context(format!("error connecting to {addrs:?}"))?;
        let (read, write) = connection.into_split();
        forward_bidi(read, write, r, s).await?;
        Ok(())
    }

    let limiter = connection_limiter(args.max_connections);
    loop {
        let incoming = select! {
            incoming = endpoint.accept() => incoming,
            _ = tokio::signal::ctrl_c() => {
                eprintln!("got ctrl-c, exiting");
                break;
            }
        };
        let Some(incoming) = incoming else {
            break;
        };
        let Ok(connecting) = incoming.accept() else {
            break;
        };
        let addrs = addrs.clone();
        let handshake = !args.common.is_custom_alpn();
        let limiter = limiter.clone();
        tokio::spawn(async move {
            if let Err(cause) = handle_endpoint_accept(connecting, addrs, handshake, limiter).await
            {
                // log error at warn level
                //
                // we should know about it, but it's not fatal
                metrics::CONNECTION_ERRORS_TOTAL.fetch_add(1, Ordering::Relaxed);
                tracing::warn!("error handling connection: {}", cause);
            }
        });
    }
    Ok(())
}

/// Local addition (fs-portal): merge extra direct socket addresses from
/// `DUMBPIPE_ADDR_HINTS` (comma-separated `ip:port`) into the address we
/// dial. Stable tickets (DUMBPIPE_STABLE_TICKET) carry identity + relay
/// only, so a peer that is actually on the local network can be reached
/// instantly by handing its fresh direct address to the connect side
/// out-of-band — without freezing ephemeral addresses into the ticket
/// string. Invalid entries are logged and skipped.
fn apply_addr_hints(mut addr: EndpointAddr, hints: Option<&str>) -> EndpointAddr {
    for hint in hints
        .unwrap_or("")
        .split(',')
        .map(str::trim)
        .filter(|h| !h.is_empty())
    {
        match hint.parse::<SocketAddr>() {
            Ok(sa) => addr = addr.with_ip_addr(sa),
            Err(e) => {
                tracing::warn!("ignoring invalid DUMBPIPE_ADDR_HINTS entry {hint:?}: {e}")
            }
        }
    }
    addr
}

/// Creates a ticket that only includes the id and any relay urls
fn create_short_ticket(addr: &EndpointAddr) -> EndpointTicket {
    let mut short = EndpointAddr::new(addr.id);
    for relay_url in addr.relay_urls() {
        short = short.with_relay_url(relay_url.clone());
    }
    short.into()
}

#[cfg(unix)]
/// Listen on an endpoint and forward incoming connections to a Unix socket.
async fn listen_unix(args: ListenUnixArgs) -> Result<()> {
    let socket_path = args.socket_path.clone();
    let secret_key = get_or_create_secret()?;
    let endpoint = create_endpoint(secret_key, &args.common, vec![args.common.alpn()?]).await?;
    // wait for the endpoint to figure out its address before making a ticket
    if (timeout(ONLINE_TIMEOUT, endpoint.online()).await).is_err() {
        eprintln!("Warning: Failed to connect to the home relay");
    }
    let addr = endpoint.addr();
    let short = create_short_ticket(&addr);
    let ticket = EndpointTicket::new(addr);

    // print the ticket on stderr so it doesn't interfere with the data itself
    //
    // note that the tests rely on the ticket being the last thing printed
    eprintln!(
        "Forwarding incoming requests to '{}'.",
        socket_path.display()
    );
    eprintln!("To connect, use e.g.:");
    eprintln!("dumbpipe connect-unix --socket-path /path/to/client.sock {ticket}");
    eprintln!("dumbpipe connect-tcp --addr 127.0.0.1:8080 {ticket}");
    if args.common.verbose > 0 {
        eprintln!("or:\ndumbpipe connect-unix --socket-path /path/to/client.sock {short}");
        eprintln!("dumbpipe connect-tcp --addr 127.0.0.1:8080 {short}");
    }
    tracing::info!("endpoint id is {}", ticket.endpoint_addr().id);
    tracing::info!(
        "relay url is {:?}",
        ticket
            .endpoint_addr()
            .relay_urls()
            .next()
            .map_or("None".to_string(), |url| url.to_string())
    );

    // handle a new incoming connection on the endpoint
    async fn handle_endpoint_accept(
        accepting: Accepting,
        socket_path: PathBuf,
        handshake: bool,
    ) -> Result<()> {
        tracing::trace!("accepting connection");
        let connection = accepting.await.std_context("error accepting connection")?;
        let remote_endpoint_id = &connection.remote_id();
        tracing::info!("got connection from {}", remote_endpoint_id);
        let (s, mut r) = connection
            .accept_bi()
            .await
            .std_context("error accepting stream")?;
        tracing::info!("accepted bidi stream from {}", remote_endpoint_id);
        if handshake {
            // read the handshake and verify it
            tracing::trace!("reading handshake");
            let mut buf = [0u8; dumbpipe::HANDSHAKE.len()];
            r.read_exact(&mut buf).await.anyerr()?;
            ensure_any!(buf == dumbpipe::HANDSHAKE, "invalid handshake");
            tracing::trace!("handshake verified");
        }
        tracing::trace!("connecting to backend socket {:?}", socket_path);
        let connection = UnixStream::connect(&socket_path)
            .await
            .std_context(format!("error connecting to {socket_path:?}"))?;
        tracing::trace!("connected to backend socket");
        let (read, write) = connection.into_split();
        tracing::trace!("starting forward_bidi");
        forward_bidi(read, write, r, s).await?;
        tracing::trace!("forward_bidi finished");
        Ok(())
    }

    loop {
        let incoming = select! {
            incoming = endpoint.accept() => incoming,
            _ = tokio::signal::ctrl_c() => {
                eprintln!("got ctrl-c, exiting");
                break;
            }
        };
        let Some(incoming) = incoming else {
            break;
        };
        let Ok(connecting) = incoming.accept() else {
            break;
        };
        let socket_path = socket_path.clone();
        let handshake = !args.common.is_custom_alpn();
        tokio::spawn(async move {
            if let Err(cause) = handle_endpoint_accept(connecting, socket_path, handshake).await {
                // log error at warn level
                //
                // we should know about it, but it's not fatal
                metrics::CONNECTION_ERRORS_TOTAL.fetch_add(1, Ordering::Relaxed);
                tracing::warn!("error handling connection: {}", cause);
            }
        });
    }
    Ok(())
}

#[cfg(unix)]
/// A RAII guard to clean up a Unix socket file.
struct UnixSocketGuard {
    path: PathBuf,
}

#[cfg(unix)]
impl Drop for UnixSocketGuard {
    fn drop(&mut self) {
        if let Err(e) = std::fs::remove_file(&self.path) {
            if e.kind() != std::io::ErrorKind::NotFound {
                tracing::error!("failed to remove socket file {:?}: {}", self.path, e);
            }
        }
    }
}

#[cfg(unix)]
/// Listen on a Unix socket and forward connections to an endpoint.
async fn connect_unix(args: ConnectUnixArgs) -> Result<()> {
    let socket_path = args.socket_path.clone();
    let secret_key = get_or_create_secret()?;
    let endpoint = create_endpoint(secret_key, &args.common, vec![])
        .await
        .std_context("unable to bind endpoint")?;
    tracing::info!("unix listening on {:?}", socket_path);

    // Wait for our own endpoint to be ready before trying to connect.
    if (timeout(ONLINE_TIMEOUT, endpoint.online()).await).is_err() {
        eprintln!("Warning: Failed to connect to the home relay");
    }

    // Remove existing socket file if it exists
    if let Err(e) = tokio::fs::remove_file(&socket_path).await {
        if e.kind() != io::ErrorKind::NotFound {
            bail_any!("failed to remove existing socket file: {}", e);
        }
    }

    let addr = args.ticket.endpoint_addr();
    tracing::info!("connecting to remote endpoint: {:?}", addr);
    let connection = endpoint
        .connect(addr.clone(), &args.common.alpn()?)
        .await
        .std_context("failed to connect to remote endpoint")?;
    tracing::info!("connected to remote endpoint successfully");

    let unix_listener = UnixListener::bind(&socket_path)
        .with_std_context(|_| format!("failed to bind Unix socket at {socket_path:?}"))?;
    tracing::info!("bound local unix socket: {:?}", socket_path);

    let _guard = UnixSocketGuard {
        path: socket_path.clone(),
    };

    async fn handle_unix_accept(
        next: io::Result<(UnixStream, tokio::net::unix::SocketAddr)>,
        connection: iroh::endpoint::Connection,
        handshake: bool,
    ) -> Result<()> {
        tracing::trace!("handling new local connection");
        let (unix_stream, unix_addr) = next.std_context("error accepting unix connection")?;
        let (unix_recv, unix_send) = unix_stream.into_split();
        tracing::trace!("got unix connection from {:?}", unix_addr);

        tracing::trace!("opening bidi stream");
        let (mut endpoint_send, endpoint_recv) = connection
            .open_bi()
            .await
            .std_context("error opening bidi stream")?;
        tracing::trace!("bidi stream opened");

        // send the handshake unless we are using a custom alpn
        // when using a custom alpn, everything is up to the user
        if handshake {
            tracing::trace!("sending handshake");
            // the connecting side must write first. we don't know if there will be something
            // on stdin, so just write a handshake.
            endpoint_send
                .write_all(&dumbpipe::HANDSHAKE)
                .await
                .anyerr()?;
            tracing::trace!("handshake sent");
        }

        tracing::trace!("starting forward_bidi");
        forward_bidi(unix_recv, unix_send, endpoint_recv, endpoint_send).await?;
        tracing::trace!("forward_bidi finished");
        Ok(())
    }

    tracing::info!("entering accept loop");
    loop {
        // also wait for ctrl-c here so we can use it before accepting a connection
        let next = tokio::select! {
            stream = unix_listener.accept() => stream,
            _ = tokio::signal::ctrl_c() => {
                eprintln!("got ctrl-c, exiting");
                break;
            }
        };
        tracing::trace!("accepted a local connection");
        let connection = connection.clone();
        let handshake = !args.common.is_custom_alpn();
        tokio::spawn(async move {
            tracing::trace!("spawning handler task");
            if let Err(cause) = handle_unix_accept(next, connection, handshake).await {
                // log error at warn level
                //
                // we should know about it, but it's not fatal
                metrics::CONNECTION_ERRORS_TOTAL.fetch_add(1, Ordering::Relaxed);
                tracing::warn!("error handling connection: {}", cause);
            }
            tracing::trace!("handler task finished");
        });
    }

    Ok(())
}

async fn generate_ticket() -> Result<()> {
    let secret_key = get_or_create_secret()?;
    let public_key = secret_key.public();
    let addr = EndpointAddr::new(public_key);
    let ticket = EndpointTicket::new(addr);
    println!("{}", ticket);
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    // Local addition (fs-portal): serve Prometheus metrics when
    // DUMBPIPE_METRICS_ADDR is set, or push them to a central
    // `dumbpipe metrics-server` when DUMBPIPE_METRICS_PUSH_ADDR is set.
    metrics::spawn_server_from_env();
    metrics::spawn_push_from_env();
    let args = Args::parse();
    let res = match args.command {
        Commands::GenerateTicket => generate_ticket().await,
        Commands::Listen(args) => listen_stdio(args).await,
        Commands::ListenTcp(args) => listen_tcp(args).await,
        Commands::Connect(args) => connect_stdio(args).await,
        Commands::ConnectTcp(args) => connect_tcp(args).await,

        #[cfg(unix)]
        Commands::ListenUnix(args) => listen_unix(args).await,

        #[cfg(unix)]
        Commands::ConnectUnix(args) => connect_unix(args).await,

        Commands::MetricsServer(args) => metrics::run_metrics_server(&args.addr).anyerr(),
    };
    match res {
        Ok(()) => std::process::exit(0),
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1)
        }
    }
}

#[cfg(test)]
mod addr_hint_tests {
    use super::*;

    fn test_addr() -> EndpointAddr {
        EndpointAddr::new(SecretKey::from_bytes(&[7u8; 32]).public())
    }

    #[test]
    fn no_hints_leaves_addr_unchanged() {
        let addr = test_addr();
        assert_eq!(apply_addr_hints(addr.clone(), None), addr);
        assert_eq!(apply_addr_hints(addr.clone(), Some("")), addr);
    }

    #[test]
    fn hints_merge_and_junk_is_skipped() {
        let out = apply_addr_hints(test_addr(), Some(" 10.0.0.5:4919, junk , 10.0.0.6:1 "));
        let ips: Vec<String> = out.ip_addrs().map(|a| a.to_string()).collect();
        assert_eq!(ips.len(), 2);
        assert!(ips.contains(&"10.0.0.5:4919".to_string()));
        assert!(ips.contains(&"10.0.0.6:1".to_string()));
    }
}
