use serde_json::{json, Value};
use std::{
    fs,
    io::{self, BufRead, Write},
    path::PathBuf,
};
use yapcam_core::{
    mcp::Server,
    project::{Error, Project, Result},
};
fn bad(message: &str) -> Error {
    Error::new(1, message)
}
fn open(path: PathBuf) -> Result<Project> {
    let path = fs::canonicalize(path)?;
    let mut project = if ["project.json", "project.json.prev", "autosave/project.json"]
        .iter()
        .any(|p| path.join(p).exists())
    {
        Project::open(&path)?
    } else {
        Project::create(&path)?
    };
    project.snapshot = true; // Also survives set autosave=true and history operations.
    Ok(project)
}

fn main() {
    if let Err(e) = run() {
        eprintln!("yapcam-mcp: {}", e.message);
        std::process::exit(1);
    }
}
fn run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 2 || args[0] != "--project" {
        return Err(bad("Usage: yapcam-mcp --project <closed-package.yapcam>"));
    }
    let mut project = open(PathBuf::from(&args[1]))?;
    let mut server = Server {
        project: &mut project,
        initialized: false,
    };
    let mut out = io::stdout().lock();
    for line in io::stdin().lock().lines() {
        let response = match serde_json::from_str::<Value>(&line?) {
            Ok(v) => server.rpc(v),
            Err(_) => Some(
                json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}),
            ),
        };
        if let Some(v) = response {
            serde_json::to_writer(&mut out, &v)?;
            writeln!(out)?;
            out.flush()?;
        }
    }
    Ok(())
}
