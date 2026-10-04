//! Local CLI: status / send / tail / pair-code display.
use clap::{Parser, Subcommand};
use std::time::Duration;
use crate::{protocol::{Command, DeviceRole, NowPlayingState, now_ms}, server::STALE_MS};

#[derive(Parser)]
#[command(name = "echo", about = "Apple Music sync relay: iPhone Now Playing <-> Mac")]
pub(crate) struct Cli {
    #[command(subcommand)]
    pub(crate) cmd: Cmd,
}
#[derive(Subcommand)]
pub(crate) enum Cmd {
    /// Run the relay server (runs on Mac). No flags needed for personal use.
    Serve {
        #[arg(long, default_value = "[::]:11447")]
        bind: String,
    },
    /// Print the current pairing code (run on the Mac, type it into the phone).
    PairCode,
    /// Print latest state of one side.
    Status {
        #[arg(long, default_value = "http://127.0.0.1:11447")]
        server: String,
        /// Which side: iphone|mac.
        #[arg(long, default_value = "iphone")]
        role: String,
    },
    /// Send a control command to one side.
    Send {
        #[arg(long, default_value = "http://127.0.0.1:11447")]
        server: String,
        /// Target side: iphone|mac.
        #[arg(long, default_value = "iphone")]
        to: String,
        #[command(subcommand)]
        action: SendAction,
    },
    /// Live-tail one side's states (polls GET /status).
    Tail {
        #[arg(long, default_value = "http://127.0.0.1:11447")]
        server: String,
        #[arg(long, default_value = "iphone")]
        role: String,
    },
}
#[derive(Subcommand)]
pub(crate) enum SendAction {
    Play,
    Pause,
    Toggle,
    Next,
    Previous,
    Seek { position: f64 },
    /// Exact handoff: tell iPhone to play catalog id at position.
    PlayId { store_id: String, #[arg(long, default_value_t = 0.0)] position: f64 },
}
fn http_client() -> anyhow::Result<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .map_err(anyhow::Error::from)
}
fn state_label(s: &NowPlayingState) -> String {
    format!("{:?}", s.state).to_lowercase()
}
async fn fetch_status(server: &str, role: &str) -> anyhow::Result<Option<NowPlayingState>> {
    let client = http_client()?;
    let resp = client.get(format!("{server}/status?role={role}")).send().await?;
    if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
        anyhow::bail!("401 unauthorized (run on the Mac itself, or pair first)");
    }
    if resp.status() == reqwest::StatusCode::NO_CONTENT {
        return Ok(None);
    }
    Ok(Some(resp.json::<NowPlayingState>().await?))
}
pub(crate) async fn status(server: &str, role: &str) -> anyhow::Result<()> {
    match fetch_status(server, role).await? {
        None => println!("no state yet (is the iPhone publisher connected?)"),
        Some(s) => {
            let now = now_ms();
            let pos = s.effective_elapsed(now).or(s.elapsed).unwrap_or(0.0);
            println!(
                "{} — {} [{}]",
                s.title.as_deref().unwrap_or("(no title)"),
                s.artist.as_deref().unwrap_or("(no artist)"),
                state_label(&s)
            );
            if let Some(id) = &s.store_id {
                println!("storeID: {id}");
            }
            let age = now - s.timestamp_ms;
            let stale = if age > STALE_MS { "  STALE" } else { "" };
            println!(
                "position: {:.1}s / {:.1}s  rate={}  updated={}ms ago{}",
                pos,
                s.duration.unwrap_or(0.0),
                s.rate,
                age,
                stale
            );
        }
    }
    Ok(())
}
pub(crate) async fn send(server: &str, to: &str, action: SendAction) -> anyhow::Result<()> {
    let cmd = match action {
        SendAction::Play => Command::play(),
        SendAction::Pause => Command::pause(),
        SendAction::Toggle => Command::toggle(),
        SendAction::Next => Command::next(),
        SendAction::Previous => Command::previous(),
        SendAction::Seek { position } => Command::seek(position),
        SendAction::PlayId { store_id, position } => Command::play_store_id(store_id, position),
    };
    let cmd = match to {
        "mac" => cmd.to(DeviceRole::Mac),
        "iphone" => cmd.to(DeviceRole::Iphone),
        _ => cmd,
    };
    if let Err(e) = cmd.validate() {
        anyhow::bail!("refusing to send invalid command: {e}");
    }
    let client = http_client()?;
    let req = client.post(format!("{server}/command")).json(&cmd);
    let resp = req.send().await?;
    if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
        anyhow::bail!("401 unauthorized (run on the Mac itself, or pair first)");
    }
    println!("{}", resp.text().await?);
    Ok(())
}
pub(crate) async fn tail(server: &str, role: &str) -> anyhow::Result<()> {
    let mut last = String::new();
    loop {
        match fetch_status(server, role).await? {
            None => println!("(waiting for iPhone…)"),
            Some(s) => {
                let pos = s.effective_elapsed(now_ms()).or(s.elapsed).unwrap_or(0.0);
                let line = format!(
                    "{} — {} [{:.0}s/{:.0}s {}]",
                    s.title.as_deref().unwrap_or("?"),
                    s.artist.as_deref().unwrap_or("?"),
                    pos,
                    s.duration.unwrap_or(0.0),
                    state_label(&s)
                );
                if line != last {
                    println!("{line}");
                    last = line;
                }
            }
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}
