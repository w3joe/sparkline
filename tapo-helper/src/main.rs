//! Local control helper for GB10 Power Monitor.
//!
//! Speaks newline-delimited JSON on stdin/stdout. Plug requests are handled concurrently and
//! responses carry the request `id`; `configure` and `reset` complete before any later request
//! starts. The process exits when stdin closes, so it never outlives the app. Credentials only
//! ever arrive through a `configure` request.

mod backend;
mod protocol;

use std::sync::Arc;
use std::time::Duration;

use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use backend::{Backend, RealBackend, SimBackend};
use protocol::{parse_request, Op, Request, Response};

async fn handle(backend: &Backend, request: Request) -> Response {
    let id = request.id;
    let result = match request.op {
        Op::Configure { username, password } => {
            backend.configure(username, password).await;
            Ok(json!({}))
        }
        Op::Read { plug, ip } => backend.read(&plug, &ip).await.map(|r| json!(r)),
        Op::Set { plug, ip, on } => backend.set(&plug, &ip, on).await.map(|r| json!(r)),
        Op::Info { plug, ip } => backend.info(&plug, &ip).await.map(|r| json!(r)),
        Op::Reset => {
            backend.reset().await;
            Ok(json!({}))
        }
        Op::Ping => Ok(json!({ "version": env!("CARGO_PKG_VERSION"), "tapo": "0.11.1" })),
        Op::SimSetPower { plug, mw } => backend.sim_set_power(&plug, mw).await.map(|_| json!({})),
    };
    match result {
        Ok(value) => Response::success(id, value),
        Err(error) => Response::failure(id, error),
    }
}

fn encode(response: &Response) -> String {
    serde_json::to_string(response).expect("responses always serialize")
}

#[tokio::main]
async fn main() {
    let simulate = std::env::args().any(|a| a == "--simulate");
    let backend = Arc::new(if simulate {
        Backend::Simulated(SimBackend::default())
    } else {
        Backend::Real(RealBackend::new(Duration::from_secs(6)))
    });

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let writer = tokio::spawn(async move {
        let mut out = tokio::io::stdout();
        while let Some(line) = rx.recv().await {
            if out.write_all(line.as_bytes()).await.is_err()
                || out.write_all(b"\n").await.is_err()
                || out.flush().await.is_err()
            {
                std::process::exit(0);
            }
        }
    });

    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        let request = match parse_request(&line) {
            Ok(request) => request,
            Err((id, error)) => {
                let _ = tx.send(encode(&Response::failure(id, error)));
                continue;
            }
        };
        if matches!(request.op, Op::Configure { .. } | Op::Reset) {
            let response = handle(&backend, request).await;
            let _ = tx.send(encode(&response));
            continue;
        }
        let backend = backend.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            let response = handle(&backend, request).await;
            let _ = tx.send(encode(&response));
        });
    }
    // Requests still in flight hold sender clones; the writer finishes once they have replied.
    drop(tx);
    let _ = tokio::time::timeout(Duration::from_secs(15), writer).await;
    std::process::exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn run(backend: &Backend, line: &str) -> Response {
        handle(backend, parse_request(line).unwrap()).await
    }

    #[tokio::test]
    async fn round_trip_through_simulated_backend() {
        let backend = Backend::Simulated(SimBackend::default());
        let r = run(&backend, r#"{"id":1,"op":"read","plug":"a","ip":"x"}"#).await;
        assert!(!r.ok);
        let r = run(&backend, r#"{"id":2,"op":"configure","username":"u","password":"p"}"#).await;
        assert!(r.ok);
        let r = run(&backend, r#"{"id":3,"op":"set","plug":"a","ip":"x","on":false}"#).await;
        assert!(r.ok);
        assert_eq!(r.result.unwrap()["device_on"], json!(false));
        let r = run(&backend, r#"{"id":4,"op":"ping"}"#).await;
        assert_eq!(r.id, 4);
        assert!(r.ok);
    }
}
