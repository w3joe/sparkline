use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tapo::{ApiClient, PlugEnergyMonitoringHandler};
use tokio::sync::Mutex;

use crate::protocol::{classify, ErrorKind, HelperError, PlugInfo, PlugReading};

pub enum Backend {
    Real(RealBackend),
    Simulated(SimBackend),
}

impl Backend {
    pub async fn configure(&self, username: String, password: String) {
        match self {
            Backend::Real(b) => b.configure(username, password).await,
            Backend::Simulated(b) => b.configure(username, password).await,
        }
    }

    pub async fn read(&self, plug: &str, ip: &str) -> Result<PlugReading, HelperError> {
        match self {
            Backend::Real(b) => b.read(plug, ip).await,
            Backend::Simulated(b) => b.read(plug, ip).await,
        }
    }

    pub async fn set(&self, plug: &str, ip: &str, on: bool) -> Result<PlugReading, HelperError> {
        match self {
            Backend::Real(b) => b.set(plug, ip, on).await,
            Backend::Simulated(b) => b.set(plug, ip, on).await,
        }
    }

    pub async fn info(&self, plug: &str, ip: &str) -> Result<PlugInfo, HelperError> {
        match self {
            Backend::Real(b) => b.info(plug, ip).await,
            Backend::Simulated(b) => b.info(plug, ip).await,
        }
    }

    pub async fn reset(&self) {
        match self {
            Backend::Real(b) => b.reset().await,
            Backend::Simulated(_) => {}
        }
    }

    pub async fn sim_set_power(&self, plug: &str, mw: Option<u64>) -> Result<(), HelperError> {
        match self {
            Backend::Real(_) => Err(HelperError::new(
                ErrorKind::BadRequest,
                "sim_set_power is only available with --simulate",
            )),
            Backend::Simulated(b) => {
                b.plugs.lock().await.entry(plug.to_string()).or_default().override_mw = mw;
                Ok(())
            }
        }
    }
}

struct Session {
    ip: String,
    handler: Arc<PlugEnergyMonitoringHandler>,
}

type Slot = Arc<Mutex<Option<Session>>>;

pub struct RealBackend {
    timeout: Duration,
    credentials: Mutex<Option<(String, String)>>,
    slots: Mutex<HashMap<String, Slot>>,
}

impl RealBackend {
    pub fn new(timeout: Duration) -> Self {
        Self { timeout, credentials: Mutex::new(None), slots: Mutex::new(HashMap::new()) }
    }

    async fn configure(&self, username: String, password: String) {
        *self.credentials.lock().await = Some((username, password));
        self.reset().await;
    }

    async fn reset(&self) {
        let slots: Vec<Slot> = self.slots.lock().await.values().cloned().collect();
        for slot in slots {
            *slot.lock().await = None;
        }
    }

    async fn slot(&self, plug: &str) -> Slot {
        self.slots.lock().await.entry(plug.to_string()).or_default().clone()
    }

    /// Runs `f` against an authenticated handler for `plug`. Calls for one plug are serialised so
    /// logins never race. A stale session is retried once with a fresh login; a failed fresh
    /// login is never retried, because P110s lock themselves after repeated bad logins.
    async fn with_handler<T, F, Fut>(&self, plug: &str, ip: &str, f: F) -> Result<T, HelperError>
    where
        F: Fn(Arc<PlugEnergyMonitoringHandler>) -> Fut,
        Fut: Future<Output = Result<T, tapo::Error>>,
    {
        let slot = self.slot(plug).await;
        let mut session = slot.lock().await;
        loop {
            let fresh = session.as_ref().is_none_or(|s| s.ip != ip);
            if fresh {
                *session = None;
                let (username, password) = self.credentials.lock().await.clone().ok_or_else(|| {
                    HelperError::new(ErrorKind::NotConfigured, "Tapo credentials have not been set")
                })?;
                let handler = ApiClient::new(username, password)
                    .with_timeout(self.timeout)
                    .p110(ip.to_string())
                    .await
                    .map_err(|e| classify(&e))?;
                *session = Some(Session { ip: ip.to_string(), handler: Arc::new(handler) });
            }
            let handler = session.as_ref().expect("session was just set").handler.clone();
            match f(handler).await {
                Ok(value) => return Ok(value),
                Err(e) => {
                    *session = None;
                    let error = classify(&e);
                    let network = matches!(error.kind, ErrorKind::Unreachable | ErrorKind::Timeout);
                    if fresh || network {
                        return Err(error);
                    }
                }
            }
        }
    }

    async fn read(&self, plug: &str, ip: &str) -> Result<PlugReading, HelperError> {
        self.with_handler(plug, ip, |h| async move {
            let info = h.get_device_info().await?;
            let usage = h.get_energy_usage().await?;
            let power_mw = match usage.current_power {
                Some(mw) => mw,
                None => h.get_current_power().await?.current_power * 1000,
            };
            Ok(PlugReading {
                device_on: info.device_on,
                power_mw,
                today_wh: usage.today_energy,
                month_wh: usage.month_energy,
            })
        })
        .await
    }

    async fn set(&self, plug: &str, ip: &str, on: bool) -> Result<PlugReading, HelperError> {
        self.with_handler(plug, ip, |h| async move {
            if on { h.on().await? } else { h.off().await? }
            Ok(())
        })
        .await?;
        self.read(plug, ip).await
    }

    async fn info(&self, plug: &str, ip: &str) -> Result<PlugInfo, HelperError> {
        self.with_handler(plug, ip, |h| async move {
            let info = h.get_device_info().await?;
            Ok(PlugInfo {
                model: info.model,
                nickname: info.nickname,
                fw_ver: info.fw_ver,
                mac: info.mac,
                device_on: info.device_on,
                rssi: info.rssi,
            })
        })
        .await
    }
}

#[derive(Default)]
pub struct SimPlug {
    pub on: bool,
    pub override_mw: Option<u64>,
}

/// Fake plugs for UI work and tests. An IP containing "unreachable" fails like an offline
/// plug, and the password "wrong" fails like bad credentials.
#[derive(Default)]
pub struct SimBackend {
    credentials: Mutex<Option<(String, String)>>,
    pub plugs: Mutex<HashMap<String, SimPlug>>,
}

impl SimBackend {
    async fn configure(&self, username: String, password: String) {
        *self.credentials.lock().await = Some((username, password));
    }

    async fn check(&self, ip: &str) -> Result<(), HelperError> {
        match self.credentials.lock().await.as_ref() {
            None => return Err(HelperError::new(ErrorKind::NotConfigured, "Tapo credentials have not been set")),
            Some((_, password)) if password == "wrong" => {
                return Err(HelperError::new(ErrorKind::AuthFailed, "Simulated invalid credentials"));
            }
            _ => {}
        }
        if ip.contains("unreachable") {
            tokio::time::sleep(Duration::from_millis(300)).await;
            return Err(HelperError::new(ErrorKind::Unreachable, format!("Simulated: {ip} is unreachable")));
        }
        Ok(())
    }

    async fn reading(&self, plug: &str) -> PlugReading {
        let mut plugs = self.plugs.lock().await;
        let state = plugs.entry(plug.to_string()).or_insert_with(|| SimPlug { on: true, override_mw: None });
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().subsec_nanos() as u64;
        let power_mw = if !state.on {
            0
        } else {
            state.override_mw.unwrap_or(45_000 + (nanos % 30_000))
        };
        PlugReading { device_on: state.on, power_mw, today_wh: 820, month_wh: 9_400 }
    }

    async fn read(&self, plug: &str, ip: &str) -> Result<PlugReading, HelperError> {
        self.check(ip).await?;
        Ok(self.reading(plug).await)
    }

    async fn set(&self, plug: &str, ip: &str, on: bool) -> Result<PlugReading, HelperError> {
        self.check(ip).await?;
        {
            let mut plugs = self.plugs.lock().await;
            let state = plugs.entry(plug.to_string()).or_default();
            state.on = on;
            if on {
                state.override_mw = None;
            }
        }
        Ok(self.reading(plug).await)
    }

    async fn info(&self, plug: &str, ip: &str) -> Result<PlugInfo, HelperError> {
        let reading = self.read(plug, ip).await?;
        Ok(PlugInfo {
            model: "P110".into(),
            nickname: format!("Simulated {plug}"),
            fw_ver: "1.0.0".into(),
            mac: "00-00-00-00-00-00".into(),
            device_on: reading.device_on,
            rssi: -50,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn simulated_plugs_switch_independently() {
        let backend = Backend::Simulated(SimBackend::default());
        backend.configure("u".into(), "pw".into()).await;
        let a = backend.set("a", "10.0.0.2", false).await.unwrap();
        assert!(!a.device_on);
        assert_eq!(a.power_mw, 0);
        let b = backend.read("b", "10.0.0.3").await.unwrap();
        assert!(b.device_on);
        assert!(b.power_mw > 0);
    }

    #[tokio::test]
    async fn simulated_failures_have_the_right_kinds() {
        let backend = Backend::Simulated(SimBackend::default());
        assert_eq!(backend.read("a", "1.2.3.4").await.unwrap_err().kind, ErrorKind::NotConfigured);
        backend.configure("u".into(), "pw".into()).await;
        assert_eq!(backend.read("a", "unreachable").await.unwrap_err().kind, ErrorKind::Unreachable);
        backend.configure("u".into(), "wrong".into()).await;
        assert_eq!(backend.read("a", "1.2.3.4").await.unwrap_err().kind, ErrorKind::AuthFailed);
    }

    #[tokio::test]
    async fn real_backend_requires_credentials() {
        let backend = Backend::Real(RealBackend::new(Duration::from_secs(1)));
        let err = backend.read("a", "127.0.0.1:9").await.unwrap_err();
        assert_eq!(err.kind, ErrorKind::NotConfigured);
    }
}
