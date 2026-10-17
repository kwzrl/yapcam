use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
};
use yapcam_core::project::Project;
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(yapcam_core::project::unique_id("yapcam-mcp-test"));
        fs::create_dir(&root).unwrap();
        let fixture = Self(root);
        copy(
            &Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../Tests/Fixtures/synthetic/basic.yapcam"),
            &fixture.0,
        );
        fixture
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn copy(src: &Path, dst: &Path) {
    for entry in fs::read_dir(src).unwrap() {
        let e = entry.unwrap();
        let target = dst.join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            fs::create_dir(&target).unwrap();
            copy(&e.path(), &target);
        } else {
            fs::copy(e.path(), target).unwrap();
        }
    }
}
fn tree(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    fn visit(root: &Path, p: &Path, out: &mut BTreeMap<PathBuf, Vec<u8>>) {
        for e in fs::read_dir(p).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                visit(root, &p, out);
            } else {
                out.insert(p.strip_prefix(root).unwrap().into(), fs::read(p).unwrap());
            }
        }
    }
    let mut result = BTreeMap::new();
    visit(root, root, &mut result);
    result
}
struct Client {
    child: Child,
    input: Option<ChildStdin>,
    output: BufReader<ChildStdout>,
    id: u64,
}
impl Client {
    fn new(root: &Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_yapcam-mcp"))
            .arg("--project")
            .arg(root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        Self {
            input: child.stdin.take(),
            output: BufReader::new(child.stdout.take().unwrap()),
            child,
            id: 0,
        }
    }
    fn raw(&mut self, text: &str) -> Value {
        writeln!(self.input.as_mut().unwrap(), "{text}").unwrap();
        let mut line = String::new();
        assert!(self.output.read_line(&mut line).unwrap() > 0);
        serde_json::from_str(&line).unwrap()
    }
    fn rpc(&mut self, method: &str, params: Value) -> Value {
        self.id += 1;
        let id = self.id;
        let r =
            self.raw(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}).to_string());
        assert_eq!(r["id"], id);
        r
    }
    fn init(&mut self) {
        let r=self.rpc("initialize",json!({"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}));
        assert_eq!(r["result"]["protocolVersion"], "2025-06-18");
        writeln!(
            self.input.as_mut().unwrap(),
            "{}",
            json!({"jsonrpc":"2.0","method":"notifications/initialized"})
        )
        .unwrap();
    }
    fn call(&mut self, name: &str, args: Value) -> Value {
        self.rpc("tools/call", json!({"name":name,"arguments":args}))["result"].clone()
    }
    fn ok(&mut self, name: &str, args: Value) -> Value {
        let r = self.call(name, args);
        assert_eq!(r["isError"], false, "{r}");
        serde_json::from_str(r["content"][0]["text"].as_str().unwrap()).unwrap()
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        self.input.take();
        if !std::thread::panicking() {
            assert!(self.child.wait().unwrap().success());
        } else {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}
fn transcript() -> Value {
    json!({"schema_version":1,"engine":"test","locale":"en-US","words":[{"text":"Hello","src_start_ns":100000000,"src_end_ns":400000000},{"text":"um","src_start_ns":1100000000,"src_end_ns":1400000000},{"text":"world","src_start_ns":2100000000_i64,"src_end_ns":2400000000_i64}]})
}
fn edit() -> Value {
    json!({"commands":[{"op":"delete_range","tl_start_ns":1000000000,"tl_end_ns":1500000000},{"op":"add_zoom","tl_start_ns":0,"tl_end_ns":1000000000,"mode":"manual","target":[0.5,0.5],"scale":2,"ease_in_ns":100000000,"ease_out_ns":100000000}]})
}
#[test]
fn end_to_end_backup_atomic_batch_and_history() {
    let f = Fixture::new();
    Project::create(&f.0).unwrap().save(&f.0).unwrap();
    fs::write(
        f.0.join("recording/transcript.json"),
        transcript().to_string(),
    )
    .unwrap();
    let before = tree(&f.0);
    let original = fs::read(f.0.join("project.json")).unwrap();
    let mut c = Client::new(&f.0);
    c.init();
    assert_eq!(
        c.rpc("tools/list", json!({}))["result"]["tools"]
            .as_array()
            .unwrap()
            .len(),
        9
    );
    assert_eq!(
        c.ok("read_transcript", json!({}))["words"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    let initial = c.ok("read_project", json!({}));
    assert_eq!(
        c.call(
            "batch",
            json!({"commands":[{"op":"split","at_tl_ns":500000000},{"op":"invalid"}]})
        )["isError"],
        true
    );
    assert_eq!(c.ok("read_project", json!({})), initial);
    c.ok("batch", edit());
    assert_eq!(
        c.ok("project_summary", json!({}))["duration_ns"],
        4500000000_i64
    );
    let words = c.ok("read_transcript", json!({}));
    assert_eq!(words["words"].as_array().unwrap().len(), 2);
    assert_eq!(words["words"][1]["tl_start_ns"], 1600000000);
    assert_eq!(tree(&f.0), before);
    c.ok("undo", json!({}));
    assert_eq!(c.ok("read_project", json!({})), initial);
    assert_eq!(c.ok("undo", json!({}))["changed"], false);
    c.ok("redo", json!({}));
    assert_eq!(tree(&f.0), before);
    c.ok("save", json!({}));
    assert_eq!(
        fs::read(f.0.join("project.json.pre-mcp")).unwrap(),
        original
    );
    c.ok(
        "apply",
        json!({"command":{"op":"set","path":"notes","value":"second save"}}),
    );
    c.ok("save", json!({}));
    assert_eq!(
        fs::read(f.0.join("project.json.pre-mcp")).unwrap(),
        original
    );
    let reopened = Project::open(&f.0).unwrap();
    assert_eq!(
        yapcam_core::time::duration(&reopened.data.timeline.clips),
        4500000000
    );
    assert_eq!(reopened.data.zooms.len(), 1);
    for (path, bytes) in before {
        if path.starts_with("recording") {
            assert_eq!(fs::read(f.0.join(path)).unwrap(), bytes);
        }
    }
}
#[test]
fn capture_only_caption_fallback_ranges_and_protocol_errors() {
    let f = Fixture::new();
    let before = tree(&f.0);
    let mut c = Client::new(&f.0);
    assert_eq!(c.raw("{")["error"]["code"], -32700);
    assert_eq!(c.raw("[]")["error"]["code"], -32600);
    assert_eq!(c.rpc("tools/list", json!({}))["error"]["code"], -32000);
    c.init();
    assert_eq!(c.rpc("bogus", json!({}))["error"]["code"], -32601);
    assert_eq!(c.ok("read_transcript", json!({}))["available"], false);
    c.ok(
        "apply",
        json!({"command":{"op":"import_transcript","transcript":transcript()}}),
    );
    assert_eq!(
        c.ok(
            "read_transcript",
            json!({"start_ns":1000000000,"end_ns":1500000000})
        )["words"][0]["text"],
        "um"
    );
    c.ok(
        "apply",
        json!({"command":{"op":"set","path":"autosave","value":true}}),
    );
    assert_eq!(tree(&f.0), before);
    let clicks = c.ok("read_events", json!({"type":"click"}));
    assert!(!clicks["events"].as_array().unwrap().is_empty());
    assert_eq!(
        c.call("read_events", json!({"start_ns":-1}))["isError"],
        true
    );
    assert_eq!(
        c.call("read_transcript", json!({"source":"typo"}))["isError"],
        true
    );
    c.ok("save", json!({}));
    assert!(!f.0.join("project.json.pre-mcp").exists());
}
#[test]
fn symlink_backup_cannot_escape_package() {
    use std::os::unix::fs::symlink;
    let f = Fixture::new();
    Project::create(&f.0).unwrap().save(&f.0).unwrap();
    let outside = Fixture::new();
    let target = outside.0.join("sentinel");
    fs::write(&target, "untouched").unwrap();
    symlink(&target, f.0.join("project.json.pre-mcp")).unwrap();
    let original = fs::read(f.0.join("project.json")).unwrap();
    let mut c = Client::new(&f.0);
    c.init();
    c.ok("batch", edit());
    assert_eq!(c.call("save", json!({}))["isError"], true);
    assert_eq!(fs::read(target).unwrap(), b"untouched");
    assert_eq!(fs::read(f.0.join("project.json")).unwrap(), original);
}

#[test]
fn transcript_speed_mapping_and_argument_validation() {
    let f = Fixture::new();
    fs::write(
        f.0.join("recording/transcript.json"),
        transcript().to_string(),
    )
    .unwrap();
    let mut c = Client::new(&f.0);
    c.init();
    let project = c.ok("read_project", json!({}));
    let id = &project["timeline"]["clips"][0]["id"];
    c.ok(
        "apply",
        json!({"command":{"op":"set_speed","clip_id":id,"speed":2}}),
    );
    let t = c.ok("read_transcript", json!({"source":"recording"}));
    assert_eq!(t["words"][0]["tl_start_ns"], 50000000);
    assert_eq!(t["words"][0]["tl_end_ns"], 200000000);
    assert_eq!(t["source_words"][0]["src_start_ns"], 100000000);
    assert_eq!(c.call("save", json!({"typo":true}))["isError"], true);
    let r = c.call("read_project", json!({"section":"zooms"}));
    assert!(r["structuredContent"].is_object());
    assert_eq!(
        c.call("read_transcript", json!({"start_ns":2,"end_ns":1}))["isError"],
        true
    );
    fs::write(f.0.join("recording/transcript.json"), "{}").unwrap();
    assert_eq!(c.call("read_transcript", json!({}))["isError"], true);
}
