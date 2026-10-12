use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Deserialize, PartialEq)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Op {
    Configure { username: String, password: String },
    Read { plug: String, ip: String },
    Set { plug: String, ip: String, on: bool },
    Info { plug: String, ip: String },
    /// Drops every cached session so the next call logs in again.
    Reset,
    Ping,
    /// Only honoured by the simulated backend.
    SimSetPower { plug: String, mw: Option<u64> },
}

#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: u64,
    #[serde(flatten)]
    pub op: Op,
}

#[derive(Debug, Serialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    Unreachable,
    Timeout,
    AuthFailed,
    Protocol,
    NotConfigured,
    BadRequest,
}

#[derive(Debug, Serialize, Clone, PartialEq)]
pub struct HelperError {
    pub kind: ErrorKind,
    pub message: String,
}

impl HelperError {
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self { kind, message: message.into() }
    }
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub id: u64,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<HelperError>,
}

impl Response {
    pub fn success(id: u64, result: Value) -> Self {
        Self { id, ok: true, result: Some(result), error: None }
    }

    pub fn failure(id: u64, error: HelperError) -> Self {
        Self { id, ok: false, result: None, error: Some(error) }
    }
}

#[derive(Debug, Serialize, Clone, PartialEq)]
pub struct PlugReading {
    pub device_on: bool,
    pub power_mw: u64,
    pub today_wh: u64,
    pub month_wh: u64,
}

#[derive(Debug, Serialize, Clone, PartialEq)]
pub struct PlugInfo {
    pub model: String,
    pub nickname: String,
    pub fw_ver: String,
    pub mac: String,
    pub device_on: bool,
    pub rssi: i16,
}

/// Parses one request line. Returns the request id (0 when it can't be read) with the error.
pub fn parse_request(line: &str) -> Result<Request, (u64, HelperError)> {
    serde_json::from_str::<Request>(line).map_err(|e| {
        let id = serde_json::from_str::<Value>(line)
            .ok()
            .and_then(|v| v.get("id").and_then(Value::as_u64))
            .unwrap_or(0);
        (id, HelperError::new(ErrorKind::BadRequest, e.to_string()))
    })
}

pub fn classify(error: &tapo::Error) -> HelperError {
    use tapo::{Error, TapoResponseError};
    let message = error.to_string();
    let kind = match error {
        Error::Http(e) if e.is_timeout() => ErrorKind::Timeout,
        Error::Http(_) => ErrorKind::Unreachable,
        Error::Tapo(TapoResponseError::Unauthorized { .. }) => ErrorKind::AuthFailed,
        Error::Tapo(TapoResponseError::DeviceError { kind, .. }) if *kind == "LOGIN" => {
            ErrorKind::AuthFailed
        }
        Error::Tapo(TapoResponseError::HttpError { status_code, .. })
            if *status_code == 401 || *status_code == 403 =>
        {
            ErrorKind::AuthFailed
        }
        _ => ErrorKind::Protocol,
    };
    HelperError::new(kind, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tapo::{Error, TapoResponseError};

    #[test]
    fn parses_every_op() {
        let r = parse_request(r#"{"id":1,"op":"configure","username":"a@b.c","password":"pw"}"#).unwrap();
        assert_eq!(r.id, 1);
        assert_eq!(r.op, Op::Configure { username: "a@b.c".into(), password: "pw".into() });

        let r = parse_request(r#"{"id":2,"op":"read","plug":"a","ip":"10.0.0.2"}"#).unwrap();
        assert_eq!(r.op, Op::Read { plug: "a".into(), ip: "10.0.0.2".into() });

        let r = parse_request(r#"{"id":3,"op":"set","plug":"b","ip":"10.0.0.3","on":false}"#).unwrap();
        assert_eq!(r.op, Op::Set { plug: "b".into(), ip: "10.0.0.3".into(), on: false });

        let r = parse_request(r#"{"id":4,"op":"info","plug":"b","ip":"10.0.0.3"}"#).unwrap();
        assert_eq!(r.op, Op::Info { plug: "b".into(), ip: "10.0.0.3".into() });

        assert_eq!(parse_request(r#"{"id":5,"op":"reset"}"#).unwrap().op, Op::Reset);
        assert_eq!(parse_request(r#"{"id":6,"op":"ping"}"#).unwrap().op, Op::Ping);
        assert_eq!(
            parse_request(r#"{"id":7,"op":"sim_set_power","plug":"a","mw":null}"#).unwrap().op,
            Op::SimSetPower { plug: "a".into(), mw: None }
        );
    }

    #[test]
    fn bad_request_keeps_id_when_possible() {
        let (id, err) = parse_request(r#"{"id":9,"op":"explode"}"#).unwrap_err();
        assert_eq!(id, 9);
        assert_eq!(err.kind, ErrorKind::BadRequest);

        let (id, _) = parse_request("not json").unwrap_err();
        assert_eq!(id, 0);
    }

    #[test]
    fn response_serialization_omits_empty_fields() {
        let ok = serde_json::to_string(&Response::success(1, serde_json::json!({"x":1}))).unwrap();
        assert_eq!(ok, r#"{"id":1,"ok":true,"result":{"x":1}}"#);
        let err = serde_json::to_string(&Response::failure(
            2,
            HelperError::new(ErrorKind::AuthFailed, "nope"),
        ))
        .unwrap();
        assert_eq!(err, r#"{"id":2,"ok":false,"error":{"kind":"auth_failed","message":"nope"}}"#);
    }

    #[test]
    fn classifies_auth_errors() {
        let e = Error::Tapo(TapoResponseError::Unauthorized {
            kind: "HASH_MISMATCH",
            description: "bad".into(),
        });
        assert_eq!(classify(&e).kind, ErrorKind::AuthFailed);

        let e = Error::Tapo(TapoResponseError::DeviceError { code: -1501, kind: "LOGIN" });
        assert_eq!(classify(&e).kind, ErrorKind::AuthFailed);

        let e = Error::Tapo(TapoResponseError::HttpError { status_code: 403, description: "x".into() });
        assert_eq!(classify(&e).kind, ErrorKind::AuthFailed);
    }

    #[test]
    fn classifies_other_errors_as_protocol() {
        let e = Error::Tapo(TapoResponseError::EmptyResult);
        assert_eq!(classify(&e).kind, ErrorKind::Protocol);
        let e = Error::DeviceNotFound;
        assert_eq!(classify(&e).kind, ErrorKind::Protocol);
    }

    #[tokio::test]
    async fn classifies_connection_failures_as_unreachable() {
        let client = tapo::ApiClient::new("user@example.com", "pw")
            .with_timeout(std::time::Duration::from_secs(2));
        // Port 9 on localhost is closed, so the connection is refused straight away.
        let err = client.p110("127.0.0.1:9").await.err().expect("must fail");
        let kind = classify(&err).kind;
        assert!(
            kind == ErrorKind::Unreachable || kind == ErrorKind::Timeout,
            "unexpected kind {kind:?}: {err}"
        );
    }
}
