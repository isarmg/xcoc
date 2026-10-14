//! Camera adapters and mobile publishing share the existing Xcoc edge contract.
pub mod camera_presets;
pub mod device;
pub mod local_camera;
pub mod media_worker;
pub mod mobile;
pub mod onvif;
pub mod rtsp_publish;

/// The snapshot contract uses 401 for an invalid Server credential. Other HTTP errors stay retryable.
pub fn snapshot_authorization_rejected(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<reqwest::Error>()
        .and_then(reqwest::Error::status)
        .is_some_and(|status| status == reqwest::StatusCode::UNAUTHORIZED)
}
