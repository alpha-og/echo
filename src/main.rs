mod cli;
mod pairing;
mod protocol;
mod server;

use clap::Parser;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    let cli = cli::Cli::parse();
    use cli::Cmd::*;
    match cli.cmd {
        Serve { bind } => server::serve(&bind).await?,
        PairCode => pairing::pair_code().await?,
        Status { server, role } => cli::status(&server, &role).await?,
        Send { server, to, action } => cli::send(&server, &to, action).await?,
        Tail { server, role } => cli::tail(&server, &role).await?,
    }
    Ok(())
}
