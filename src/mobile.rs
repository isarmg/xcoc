//! Native mobile control plane; FFmpeg is never required on Android or iOS.
use crate::{
    device::{CapabilityStatus, DeviceCapabilities, DeviceIdentity, StreamDescriptor},
    rtsp_publish::{self, Publisher},
};
use anyhow::{Context, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::sync::mpsc;
use tokio_rustls::rustls;
use url::Url;
use uuid::Uuid;

pub const PROTOCOL: &str = env!("XCOC_EDGE_PROTOCOL");
const API_PREFIX: &str = env!("XCOC_API_PREFIX");

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Pairing {
    pub server: String,
    pub installation_id: Uuid,
    pub instance_id: Uuid,
    pub access_token: String,
    pub name: String,
}
impl Pairing {
    pub fn validate(&self) -> anyhow::Result<()> {
        server_origin(&self.server)?;
        validate_name(&self.name)?;
        ensure!(
            !self.instance_id.is_nil()
                && !self.installation_id.is_nil()
                && self.access_token.len() == 43
                && self
                    .access_token
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b)),
            "invalid mobile pairing"
        );
        Ok(())
    }
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureMetadata {
    pub platform: MobilePlatform,
    pub model: String,
    pub width: u32,
    pub height: u32,
    pub frame_rate: u32,
    pub active: bool,
}
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MobilePlatform {
    Android,
    Ios,
}
impl CaptureMetadata {
    fn validate(&self) -> anyhow::Result<()> {
        ensure!(
            !self.model.is_empty()
                && self.model.chars().count() <= 128
                && !self.model.chars().any(char::is_control)
                && (16..=7680).contains(&self.width)
                && (16..=4320).contains(&self.height)
                && (1..=60).contains(&self.frame_rate),
            "invalid mobile capture metadata"
        );
        Ok(())
    }
}

fn validate_name(value: &str) -> anyhow::Result<()> {
    ensure!(
        !value.trim().is_empty()
            && value.chars().count() <= 64
            && !value.chars().any(char::is_control),
        "invalid mobile camera name"
    );
    Ok(())
}
fn server_origin(value: &str) -> anyhow::Result<Url> {
    ensure!(value.len() <= 4096, "invalid Server origin");
    let url = Url::parse(value)?;
    ensure!(
        url.scheme() == "https"
            && url.host_str().is_some()
            && url.path() == "/"
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none(),
        "mobile Server requires an HTTPS origin"
    );
    Ok(url)
}
fn http_client() -> anyhow::Result<reqwest::Client> {
    // The same public CA trust bundle is used for HTTPS and RTSPS on both mobile platforms.
    let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(reqwest::Client::builder()
        .tls_backend_preconfigured(config)
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(12))
        .build()?)
}
async fn response_json<T: for<'de> Deserialize<'de>>(
    response: reqwest::Response,
    limit: usize,
) -> anyhow::Result<T> {
    let mut response = response
        .error_for_status()
        .context("Server rejected mobile request")?;
    ensure!(
        response.status().is_success(),
        "Server rejected mobile request"
    );
    ensure!(
        response
            .content_length()
            .is_none_or(|length| length <= limit as u64),
        "Server response too large"
    );
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        ensure!(
            chunk.len() <= limit.saturating_sub(bytes.len()),
            "Server response too large"
        );
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).context("invalid Server response")
}

pub async fn pair(
    server: &str,
    code: &str,
    name: &str,
    installation_id: Uuid,
) -> anyhow::Result<Pairing> {
    let origin = server_origin(server)?;
    validate_name(name)?;
    ensure!(
        !installation_id.is_nil()
            && code.len() == 36
            && code
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit()),
        "invalid mobile authorization code"
    );
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Response {
        protocol: String,
        client_id: Uuid,
        access_token: String,
    }
    let response = http_client()?.post(origin.join(&format!("{API_PREFIX}/client/pair"))?).json(&json!({"protocol": PROTOCOL, "product": "xcos", "installation_id": installation_id, "name": name.trim(), "client_version": env!("CARGO_PKG_VERSION"), "authorization_code": code})).send().await?;
    let response: Response = response_json(response, 16384).await?;
    ensure!(
        response.protocol == PROTOCOL,
        "incompatible mobile pairing protocol"
    );
    let pairing = Pairing {
        server: origin.into(),
        installation_id,
        instance_id: response.client_id,
        access_token: response.access_token,
        name: name.trim().into(),
    };
    pairing.validate()?;
    Ok(pairing)
}

pub fn snapshot_document(pairing: &Pairing, metadata: &CaptureMetadata) -> anyhow::Result<Value> {
    metadata.validate()?;
    let confirmed = if metadata.active {
        CapabilityStatus::Supported
    } else {
        CapabilityStatus::Unknown
    };
    let capabilities = DeviceCapabilities {
        video: confirmed,
        main_stream: confirmed,
        sub_stream: CapabilityStatus::Unsupported,
        local_recording: CapabilityStatus::Unsupported,
        server_recording: CapabilityStatus::Supported,
        ptz: CapabilityStatus::Unsupported,
        events: CapabilityStatus::Unsupported,
        audio_input: CapabilityStatus::Unsupported,
        audio_output: CapabilityStatus::Unsupported,
    };
    let (adapter, manufacturer) = match metadata.platform {
        MobilePlatform::Android => ("rtsp", "Android"),
        MobilePlatform::Ios => ("rtsp", "Apple"),
    };
    let streams = if metadata.active {
        vec![StreamDescriptor {
            profile: "main".into(),
            video_codec: Some("h264".into()),
            audio_codec: None,
            width: Some(metadata.width),
            height: Some(metadata.height),
            frame_rate: Some(f64::from(metadata.frame_rate)),
        }]
    } else {
        Vec::new()
    };
    Ok(
        json!({ "protocol": PROTOCOL, "command_capacity": 0, "command_results": [], "cameras": [{ "id": pairing.instance_id, "name": pairing.name, "location": "", "adapter_kind": adapter, "identity": DeviceIdentity { manufacturer: Some(manufacturer.into()), model: Some(metadata.model.clone()), ..DeviceIdentity::default() }, "capabilities": capabilities, "streams": streams, "has_sub_stream": false, "enabled": metadata.active, "storage_mode": "server", "status": if metadata.active { "online" } else { "disabled" }, "health_message": null }] }),
    )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SnapshotResponse {
    protocol: String,
    accepted_at: String,
    publish: Vec<PublishGrant>,
    commands: Vec<Value>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PublishGrant {
    camera_id: Uuid,
    profile: String,
    publish_url: String,
}

pub struct MobileClient {
    pub pairing: Pairing,
    client: reqwest::Client,
    publisher: Mutex<Option<PublisherWorker>>,
    poll_revision: AtomicU64,
    closed: AtomicBool,
    authorization_rejected: AtomicBool,
}
impl MobileClient {
    pub fn open(pairing: Pairing) -> anyhow::Result<Self> {
        pairing.validate()?;
        Ok(Self {
            pairing,
            client: http_client()?,
            publisher: Mutex::new(None),
            poll_revision: AtomicU64::new(0),
            closed: AtomicBool::new(false),
            authorization_rejected: AtomicBool::new(false),
        })
    }
    /// Send current evidence and reconcile a scoped grant without exposing the URL to native UI.
    pub async fn poll(
        &self,
        metadata: &CaptureMetadata,
        sps: &[u8],
        pps: &[u8],
    ) -> anyhow::Result<Value> {
        let origin = server_origin(&self.pairing.server)?;
        let request = snapshot_document(&self.pairing, metadata)?;
        let revision = self.begin_poll()?;
        let response = self
            .client
            .put(origin.join(&format!("{API_PREFIX}/client/snapshot"))?)
            .bearer_auth(&self.pairing.access_token)
            .json(&request)
            .send()
            .await?;
        let response = self.receive_snapshot(revision, response).await?;
        ensure!(
            response.protocol == PROTOCOL
                && chrono::DateTime::parse_from_rfc3339(&response.accepted_at).is_ok()
                && response.commands.is_empty()
                && response.publish.len() <= 1,
            "incompatible mobile snapshot response"
        );
        let grant = response.publish.first();
        if let Some(grant) = grant {
            ensure!(
                grant.camera_id == self.pairing.instance_id && grant.profile == "main",
                "Server returned another camera grant"
            );
            rtsp_publish::validate_publish_url(&grant.publish_url)?;
        }
        self.reconcile_snapshot(revision, response, metadata, sps, pps)
    }

    fn begin_poll(&self) -> anyhow::Result<u64> {
        let _publisher = self
            .publisher
            .lock()
            .map_err(|_| anyhow::anyhow!("mobile publisher unavailable"))?;
        ensure!(
            !self.authorization_rejected.load(Ordering::Acquire),
            "mobile pairing was rejected; pair again before reconnecting"
        );
        ensure!(
            !self.closed.load(Ordering::Acquire),
            "mobile client is closed"
        );
        Ok(self
            .poll_revision
            .fetch_add(1, Ordering::AcqRel)
            .wrapping_add(1))
    }

    async fn receive_snapshot(
        &self,
        revision: u64,
        response: reqwest::Response,
    ) -> anyhow::Result<SnapshotResponse> {
        let result = response_json(response, 65536).await;
        if result
            .as_ref()
            .err()
            .is_some_and(crate::snapshot_authorization_rejected)
        {
            let mut publisher = self
                .publisher
                .lock()
                .map_err(|_| anyhow::anyhow!("mobile publisher unavailable"))?;
            // A rejected old request cannot invalidate a newer stop/poll intent.
            if self.poll_revision.load(Ordering::Acquire) == revision {
                self.authorization_rejected.store(true, Ordering::Release);
                self.poll_revision.fetch_add(1, Ordering::AcqRel);
                publisher.take();
            }
        }
        result
    }

    fn reconcile_snapshot(
        &self,
        revision: u64,
        response: SnapshotResponse,
        metadata: &CaptureMetadata,
        sps: &[u8],
        pps: &[u8],
    ) -> anyhow::Result<Value> {
        let grant = response.publish.first();
        let mut publisher = self
            .publisher
            .lock()
            .map_err(|_| anyhow::anyhow!("mobile publisher unavailable"))?;
        // stop/close and newer polls invalidate in-flight responses. Check while
        // holding the same lock as stop so an old grant cannot revive publishing.
        ensure!(
            !self.closed.load(Ordering::Acquire)
                && self.poll_revision.load(Ordering::Acquire) == revision,
            "mobile snapshot was superseded"
        );
        match grant.filter(|_| metadata.active) {
            None => {
                publisher.take();
            }
            Some(grant) if publisher.as_ref().is_none_or(|p| p.task.is_finished()) => {
                publisher.take();
                *publisher = Some(PublisherWorker::start(&grant.publish_url, sps, pps));
            }
            Some(_) => {}
        }
        Ok(
            json!({"publishing": publisher.as_ref().is_some_and(|p| p.connected.load(Ordering::Acquire)), "active": metadata.active}),
        )
    }
    pub fn frame(&self, bytes: &[u8], timestamp_us: u64) -> anyhow::Result<bool> {
        let units = rtsp_publish::annex_b_units(bytes)?;
        let keyframe = units.iter().any(|unit| unit[0] & 31 == 5);
        let publisher = self
            .publisher
            .lock()
            .map_err(|_| anyhow::anyhow!("mobile publisher unavailable"))?;
        let Some(publisher) = publisher.as_ref() else {
            return Ok(false);
        };
        if publisher.task.is_finished() || !publisher.connected.load(Ordering::Acquire) {
            return Ok(false);
        }
        if publisher.needs_keyframe.load(Ordering::Acquire) && !keyframe {
            return Ok(false);
        }
        match publisher.frames.try_send(Frame {
            bytes: bytes.to_vec(),
            timestamp_us,
        }) {
            Ok(()) => {
                if keyframe {
                    publisher.needs_keyframe.store(false, Ordering::Release);
                }
                Ok(true)
            }
            Err(_) => {
                publisher.needs_keyframe.store(true, Ordering::Release);
                Ok(false)
            }
        }
    }
    pub fn stop(&self) {
        if let Ok(mut publisher) = self.publisher.lock() {
            self.poll_revision.fetch_add(1, Ordering::AcqRel);
            publisher.take();
        }
    }
    /// Permanently invalidate this session, including FFI calls already holding an Arc.
    pub fn close(&self) {
        if let Ok(mut publisher) = self.publisher.lock() {
            self.closed.store(true, Ordering::Release);
            self.poll_revision.fetch_add(1, Ordering::AcqRel);
            publisher.take();
        }
    }
}
struct Frame {
    bytes: Vec<u8>,
    timestamp_us: u64,
}
struct PublisherWorker {
    frames: mpsc::Sender<Frame>,
    task: tokio::task::AbortHandle,
    connected: Arc<AtomicBool>,
    needs_keyframe: Arc<AtomicBool>,
}
impl Drop for PublisherWorker {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl PublisherWorker {
    fn start(url: &str, sps: &[u8], pps: &[u8]) -> Self {
        let (frames, mut receiver) = mpsc::channel::<Frame>(4);
        let connected = Arc::new(AtomicBool::new(false));
        let state = connected.clone();
        let needs_keyframe = Arc::new(AtomicBool::new(true));
        let url = url.to_owned();
        let sps = sps.to_vec();
        let pps = pps.to_vec();
        let task = tokio::spawn(async move {
            let Ok(mut publisher) = Publisher::connect(&url, &sps, &pps).await else {
                return;
            };
            state.store(true, Ordering::Release);
            let mut last_timestamp = None;
            while let Some(frame) = receiver.recv().await {
                if last_timestamp.is_some_and(|last| frame.timestamp_us <= last) {
                    continue;
                }
                last_timestamp = Some(frame.timestamp_us);
                if publisher
                    .frame(&frame.bytes, frame.timestamp_us)
                    .await
                    .is_err()
                {
                    break;
                }
            }
            state.store(false, Ordering::Release);
            publisher.close().await;
        });
        Self {
            frames,
            task: task.abort_handle(),
            connected,
            needs_keyframe,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn stopped_mobile_client_ignores_inflight_snapshot_completion() {
        let client = MobileClient::open(Pairing {
            server: "https://localhost".into(),
            installation_id: Uuid::new_v4(),
            instance_id: Uuid::new_v4(),
            access_token: "a".repeat(43),
            name: "phone".into(),
        })
        .unwrap();
        let metadata = CaptureMetadata {
            platform: MobilePlatform::Ios,
            model: "synthetic".into(),
            width: 1280,
            height: 720,
            frame_rate: 30,
            active: true,
        };
        // The response belongs to a poll that began before stop/close.
        let response = SnapshotResponse {
            protocol: PROTOCOL.into(),
            accepted_at: chrono::Utc::now().to_rfc3339(),
            commands: Vec::new(),
            publish: vec![PublishGrant {
                camera_id: client.pairing.instance_id,
                profile: "main".into(),
                publish_url: "rtsps://127.0.0.1:9/camera?jwt=synthetic".into(),
            }],
        };
        let revision = client.begin_poll().unwrap();
        client.stop();
        assert!(
            client
                .reconcile_snapshot(revision, response, &metadata, &[0x67, 1, 2, 3], &[0x68])
                .is_err()
        );
        assert!(
            client.publisher.lock().unwrap().is_none(),
            "late response recreated a stopped publisher"
        );
    }

    #[tokio::test]
    async fn older_mobile_snapshot_cannot_remove_newer_publisher() {
        let client = MobileClient::open(Pairing {
            server: "https://localhost".into(),
            installation_id: Uuid::new_v4(),
            instance_id: Uuid::new_v4(),
            access_token: "a".repeat(43),
            name: "phone".into(),
        })
        .unwrap();
        let metadata = CaptureMetadata {
            platform: MobilePlatform::Ios,
            model: "synthetic".into(),
            width: 1280,
            height: 720,
            frame_rate: 30,
            active: true,
        };
        let older_revision = client.begin_poll().unwrap();
        let newer_revision = client.begin_poll().unwrap();
        let (frames, _receiver) = mpsc::channel(4);
        let task = tokio::spawn(std::future::pending::<()>());
        *client.publisher.lock().unwrap() = Some(PublisherWorker {
            frames,
            task: task.abort_handle(),
            connected: Arc::new(AtomicBool::new(true)),
            needs_keyframe: Arc::new(AtomicBool::new(true)),
        });
        let empty_response = || SnapshotResponse {
            protocol: PROTOCOL.into(),
            accepted_at: chrono::Utc::now().to_rfc3339(),
            commands: Vec::new(),
            publish: Vec::new(),
        };
        assert!(
            client
                .reconcile_snapshot(older_revision, empty_response(), &metadata, &[], &[])
                .is_err()
        );
        assert!(client.publisher.lock().unwrap().is_some());
        assert!(!task.is_finished());
        // The newest intent still has authority to stop its own publisher.
        client
            .reconcile_snapshot(newer_revision, empty_response(), &metadata, &[], &[])
            .unwrap();
        assert!(client.publisher.lock().unwrap().is_none());
        assert!(task.await.unwrap_err().is_cancelled());
    }

    async fn http_response(status: u16) -> reqwest::Response {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0; 8192];
            assert!(socket.read(&mut request).await.unwrap() > 0);
            socket.write_all(format!("HTTP/1.1 {status} Fixture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
        });
        let response = reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap()
            .get(format!("http://{address}/"))
            .send()
            .await
            .unwrap();
        server.await.unwrap();
        response
    }

    #[tokio::test]
    async fn mobile_authorization_rejection_stops_retry_but_transient_errors_do_not() {
        for status in [401, 403, 503] {
            let client = MobileClient::open(Pairing {
                server: "https://localhost".into(),
                installation_id: Uuid::new_v4(),
                instance_id: Uuid::new_v4(),
                access_token: "a".repeat(43),
                name: "phone".into(),
            })
            .unwrap();
            let revision = client.begin_poll().unwrap();
            let (frames, _receiver) = mpsc::channel(4);
            let task = tokio::spawn(std::future::pending::<()>());
            *client.publisher.lock().unwrap() = Some(PublisherWorker {
                frames,
                task: task.abort_handle(),
                connected: Arc::new(AtomicBool::new(true)),
                needs_keyframe: Arc::new(AtomicBool::new(true)),
            });
            assert!(
                client
                    .receive_snapshot(revision, http_response(status).await)
                    .await
                    .is_err()
            );
            assert_eq!(client.begin_poll().is_err(), status == 401);
            assert_eq!(client.publisher.lock().unwrap().is_none(), status == 401);
            client.close();
            assert!(task.await.unwrap_err().is_cancelled());
        }
    }

    #[tokio::test]
    async fn stale_mobile_401_cannot_invalidate_newer_intent() {
        let client = MobileClient::open(Pairing {
            server: "https://localhost".into(),
            installation_id: Uuid::new_v4(),
            instance_id: Uuid::new_v4(),
            access_token: "a".repeat(43),
            name: "phone".into(),
        })
        .unwrap();
        let old_revision = client.begin_poll().unwrap();
        client.stop();
        let new_revision = client.begin_poll().unwrap();
        assert!(
            client
                .receive_snapshot(old_revision, http_response(401).await)
                .await
                .is_err()
        );
        assert_eq!(client.poll_revision.load(Ordering::Acquire), new_revision);
        assert!(client.begin_poll().is_ok());
    }

    #[test]
    fn mobile_snapshot_matches_edge_v1_and_never_contains_credentials() {
        let pairing = Pairing {
            server: "https://xcos.example.com".into(),
            installation_id: Uuid::new_v4(),
            instance_id: Uuid::new_v4(),
            access_token: "a".repeat(43),
            name: "phone".into(),
        };
        let mut metadata = CaptureMetadata {
            platform: MobilePlatform::Ios,
            model: "iPhone".into(),
            width: 1280,
            height: 720,
            frame_rate: 30,
            active: true,
        };
        let document = snapshot_document(&pairing, &metadata).unwrap();
        assert_eq!(document["command_capacity"], 0);
        assert_eq!(document["cameras"][0]["adapter_kind"], "rtsp");
        assert_eq!(document["cameras"][0]["capabilities"]["ptz"], "unsupported");
        assert!(!document.to_string().contains(&pairing.access_token));
        metadata.active = false;
        let document = snapshot_document(&pairing, &metadata).unwrap();
        assert_eq!(document["cameras"][0]["status"], "disabled");
        assert_eq!(document["cameras"][0]["streams"], json!([]));
    }
    #[test]
    fn mobile_origin_and_pairing_are_strict() {
        for origin in [
            "http://example.com",
            "https://example.com/api",
            "https://u:p@example.com",
            "https://example.com/?token=x",
        ] {
            assert!(server_origin(origin).is_err());
        }
        assert!(server_origin("https://example.com:8443").is_ok());
    }
}
