use crate::project::{relative_path, Error, Project, Result};
use serde_json::{json, Value};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Write},
};
fn bad(message: &str) -> Error {
    Error::new(1, message)
}
pub struct Server<'a> {
    pub project: &'a mut Project,
    pub initialized: bool,
}
impl Server<'_> {
    pub(crate) fn transcript(&self, source: &str) -> Result<Value> {
        let captions = &self.project.data.canvas.captions;
        if source == "captions" || (source == "auto" && !captions.is_empty()) {
            let words: Vec<Value> = captions.iter().flat_map(|c| {
                if c.words.is_empty() { vec![json!({"text":c.text,"tl_start_ns":c.tl_start_ns,"tl_end_ns":c.tl_end_ns,"caption_id":c.id})] }
                else { c.words.iter().map(|w| json!({"text":w.text,"tl_start_ns":w.tl_start_ns,"tl_end_ns":w.tl_end_ns,"caption_id":c.id})).collect() }
            }).collect();
            return Ok(json!({"source":"captions","available":!captions.is_empty(),"words":words}));
        }
        if source != "auto" && source != "recording" {
            return Err(bad("source must be auto, captions or recording"));
        }
        let path = relative_path(&self.project.package, "recording/transcript.json")?;
        let bytes = match fs::read(path) {
            Ok(b) => b,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                return Ok(json!({"source":"recording","available":false,"words":[]}))
            }
            Err(e) => return Err(e.into()),
        };
        let transcript: Value = serde_json::from_slice(&bytes)?;
        // Reuse core validation and exact cut/speed/repeated-clip mapping on a disposable snapshot.
        let mut mapped = self.project.clone();
        mapped.snapshot = true; // Read-only mapping must never journal into the live package.
        mapped.apply(&json!({"op":"import_transcript","transcript":transcript}))?;
        let words: Vec<_> = mapped
            .data
            .canvas
            .captions
            .iter()
            .map(|c| json!({"text":c.text,"tl_start_ns":c.tl_start_ns,"tl_end_ns":c.tl_end_ns}))
            .collect();
        Ok(
            json!({"source":"recording","available":true,"locale":transcript["locale"],"warnings":transcript["warnings"],"source_words":transcript["words"],"words":words}),
        )
    }
    fn call(&mut self, name: &str, a: &Value) -> Result<Value> {
        if !a.is_object() {
            return Err(bad("arguments must be an object"));
        }
        let definition = catalog()
            .into_iter()
            .find(|t| t["name"] == name)
            .ok_or_else(|| bad("Unknown tool"))?;
        let properties = definition["inputSchema"]["properties"].as_object().unwrap();
        if a.as_object()
            .unwrap()
            .keys()
            .any(|k| !properties.contains_key(k))
        {
            return Err(bad("Unknown argument; consult tool inputSchema"));
        }
        match name {
            "moments" | "check" | "cut_words" | "tighten_pauses" | "remove_fillers" | "trim_start_to_first_word" | "zoom_on_click" => self.craft(name, a),
            "read_project" => {
                let data = self.project.query(&json!({"q":"project"}))?;
                match a.get("section") { None => Ok(data), Some(Value::String(s)) => data.get(s).cloned().ok_or_else(|| bad("Unknown top-level section")), _ => Err(bad("section must be a string")) }
            }
            "read_transcript" => {
                let mut data = self.transcript(a.get("source").map(|v| v.as_str().ok_or_else(|| bad("source must be a string"))).transpose()?.unwrap_or("auto"))?;
                filter(&mut data["words"], a, true)?;
                Ok(data)
            }
            "read_events" => {
                let kind = a.get("type").map(|v| v.as_str().ok_or_else(|| bad("type must be a string"))).transpose()?.unwrap_or("all");
                if !["all","click","key"].contains(&kind) { return Err(bad("type must be all, click or key")); }
                let mut rows = self.project.query(&json!({"q":"events"}))?;
                rows.as_array_mut().unwrap().retain(|r| match kind { "click" => r["type"] == "down", "key" => r["type"] == "key", _ => r["type"] == "down" || r["type"] == "key" });
                filter(&mut rows, a, false)?;
                Ok(json!({"events":rows}))
            }
            "project_summary" => {
                let p = &self.project;
                let events = p.query(&json!({"q":"events"}))?;
                let clicks = events.as_array().unwrap().iter().filter(|e| e["type"] == "down").count();
                let keys = events.as_array().unwrap().iter().filter(|e| e["type"] == "key").count();
                let session = serde_json::to_value(&p.session)?;
                Ok(json!({"duration_ns":crate::time::duration(&p.data.timeline.clips),"clips":p.query(&json!({"q":"clips"}))?,"segments":session["segments"],"zooms":p.data.zooms,"captions":p.data.canvas.captions.len(),"signals":{"transcript":self.transcript("auto")?["available"],"clicks":clicks,"keys":keys,"camera":!session["tracks"]["camera"].is_null(),"mic":!session["tracks"]["mic"].is_null()},"undo_steps":p.undo.len(),"redo_steps":p.redo.len()}))
            }
            "apply" => Ok(serde_json::to_value(self.project.apply(&json!({"op":"batch","commands":[a.get("command").ok_or_else(|| bad("Missing command"))?]}))?)?),
            "batch" => Ok(serde_json::to_value(self.project.apply(&json!({"op":"batch","commands":a.get("commands").ok_or_else(|| bad("Missing commands"))?}))?)?),
            "undo" => Ok(json!({"changed":self.project.undo()?})),
            "redo" => Ok(json!({"changed":self.project.redo()?})),
            "save" => {
                let root = &self.project.package;
                let primary = relative_path(root, "project.json")?;
                let backup = relative_path(root, "project.json.pre-mcp")?;
                if primary.exists() && !backup.exists() {
                    let bytes = fs::read(primary)?;
                    let mut file = OpenOptions::new().write(true).create_new(true).open(&backup)?;
                    if let Err(e) = file.write_all(&bytes).and_then(|_| file.sync_all()) { let _ = fs::remove_file(backup); return Err(e.into()); }
                    File::open(root)?.sync_all()?;
                }
                self.project.save(root)?;
                Ok(json!({"saved":true,"backup_exists":backup.exists()}))
            }
            _ => Err(bad("Unknown tool")),
        }
    }
    pub fn rpc(&mut self, request: Value) -> Option<Value> {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let error = |code, message: &str| json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}});
        if !request.is_object()
            || request["jsonrpc"] != "2.0"
            || !request["method"].is_string()
            || !(id.is_null() || id.is_string() || id.is_i64() || id.is_u64())
        {
            return Some(error(-32600, "Invalid Request"));
        }
        request.get("id")?; // Notifications never receive responses or execute tools.
        let method = request["method"].as_str().unwrap();
        let p = request.get("params").cloned().unwrap_or(json!({}));
        if !p.is_object() {
            return Some(error(-32602, "params must be an object"));
        }
        let result = match method {
            "initialize" => {
                if !p["protocolVersion"].is_string()
                    || !p["capabilities"].is_object()
                    || !p["clientInfo"].is_object()
                {
                    return Some(error(-32602, "Invalid initialize params"));
                }
                self.initialized = true;
                json!({"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"yapcam-mcp","version":env!("CARGO_PKG_VERSION")},"instructions":"Edits target this project. Save to persist. Use the stdio transport only on CLOSED projects. All edit times are current timeline integer nanoseconds. Read tool descriptions before editing."})
            }
            "ping" => json!({}),
            _ if !self.initialized => return Some(error(-32000, "Initialize first")),
            "tools/list" => json!({"tools":catalog()}),
            "tools/call" => {
                let Some(name) = p["name"].as_str() else {
                    return Some(error(-32602, "Missing tool name"));
                };
                if !catalog().iter().any(|t| t["name"] == name) {
                    return Some(error(-32602, "Unknown tool"));
                }
                match self.call(name, p.get("arguments").unwrap_or(&json!({}))) {
                    Ok(v) => {
                        json!({"content":[{"type":"text","text":v.to_string()}],"structuredContent":if v.is_object() {v.clone()} else {json!({"data":v})},"isError":false})
                    }
                    Err(e) => json!({"content":[{"type":"text","text":e.message}],"isError":true}),
                }
            }
            _ => return Some(error(-32601, "Method not found")),
        };
        Some(json!({"jsonrpc":"2.0","id":id,"result":result}))
    }
}
fn filter(rows: &mut Value, a: &Value, words: bool) -> Result<()> {
    let bound = |key| -> Result<Option<i64>> {
        a.get(key)
            .map(|v| {
                v.as_i64()
                    .filter(|n| *n >= 0)
                    .ok_or_else(|| bad("Range bounds must be nonnegative integer nanoseconds"))
            })
            .transpose()
    };
    let start = bound("start_ns")?.unwrap_or(0);
    let end = bound("end_ns")?.unwrap_or(i64::MAX);
    if end < start {
        return Err(bad("end_ns precedes start_ns"));
    }
    rows.as_array_mut().unwrap().retain(|r| {
        let t = r[if words { "tl_start_ns" } else { "tl_ns" }]
            .as_i64()
            .unwrap();
        t < end
            && if words {
                r["tl_end_ns"].as_i64().unwrap() > start
            } else {
                t >= start
            }
    });
    rows.as_array_mut()
        .unwrap()
        .sort_by_key(|r| r[if words { "tl_start_ns" } else { "tl_ns" }].as_i64());
    Ok(())
}
pub fn catalog() -> Vec<Value> {
    let range =
        json!({"start_ns":{"type":"integer","minimum":0},"end_ns":{"type":"integer","minimum":0}});
    let mut transcript = range.clone();
    transcript["source"] = json!({"type":"string","enum":["auto","captions","recording"]});
    let mut events = range;
    events["type"] = json!({"type":"string","enum":["all","click","key"]});
    let command = format!(
        "Fallback for operations without a dedicated intention tool (style, captions, existing zoom updates). Prefer moments, cut_words, tighten_pauses, remove_fillers, trim_start_to_first_word and zoom_on_click. Apply one existing core command; returns ChangeSet. Uses the project persistence policy. {}",
        include_str!("commands.md")
    );
    let specs = vec![
        ("project_summary", "Current duration, clips, recording segments, zooms, caption count, available signals and history counts.".to_string(),json!({}),vec![]),
        ("read_project","Current project JSON; optional top-level section (timeline, canvas, audio, zooms, etc.).".into(),json!({"section":{"type":"string"}}),vec![]),
        ("read_transcript","Words in current timeline ns; range is half-open and selects overlapping words. auto prefers imported captions (including corrections), then recording/transcript.json. recording also returns original source_words (unfiltered source ns), locale and recognition warnings. Cuts/speeds map via core. Captions without word timing return their whole text span; do not invent word timings. available=false means no transcript; this server does not recognize speech.".into(),transcript,vec![]),
        ("read_events","Captured mouse-down clicks and key presses mapped to current timeline tl_ns, with src_ns, segment and original event fields. x/y positions where captured; keys may have no position. type=all|click|key. Optional half-open timeline range in ns; removed events disappear.".into(),events,vec![]),
        ("apply",command.clone(),json!({"command":{"type":"object","required":["op"],"properties":{"op":{"type":"string"}}}}),vec!["command"]),
        ("batch",format!("Atomically apply commands sequentially; one undo step, failure rolls back everything. Each command sees prior edits. {}",command),json!({"commands":{"type":"array","items":{"type":"object"}}}),vec!["commands"]),
        ("undo","Undo one in-memory edit/batch; returns changed=false at history boundary. Save separately to persist.".into(),json!({}),vec![]),
        ("redo","Redo one in-memory edit/batch. New edits clear redo. Save separately to persist.".into(),json!({}),vec![]),
        ("save","Persist current project atomically via core. First save preserves existing project.json as project.json.pre-mcp without overwriting an existing backup. A capture without project.json has nothing to back up. Core also maintains .prev and clears autosave journal. With stdio, close the editor before use.".into(),json!({}),vec![]),
    ];
    crate::mcp_craft::catalog().into_iter().chain(specs.into_iter().map(|(name,desc,props,required)| json!({"name":name,"description":desc,"inputSchema":{"type":"object","properties":props,"required":required,"additionalProperties":false},"annotations":{"readOnlyHint":name.starts_with("read_") || name == "project_summary","openWorldHint":false}}))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shared_dispatch_atomic_history_and_protocol() {
        let root = std::env::temp_dir().join(crate::project::unique_id("mcp-core"));
        fn copy(from: &std::path::Path, to: &std::path::Path) {
            fs::create_dir_all(to).unwrap();
            for entry in fs::read_dir(from).unwrap() {
                let entry = entry.unwrap();
                if entry.path().is_dir() {
                    copy(&entry.path(), &to.join(entry.file_name()));
                } else {
                    fs::copy(entry.path(), to.join(entry.file_name())).unwrap();
                }
            }
        }
        copy(
            &std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../Tests/Fixtures/synthetic/basic.yapcam"),
            &root,
        );
        let mut project = Project::create(&root).unwrap();
        project.snapshot = true;
        let before = serde_json::to_value(&project.data).unwrap();
        let mut server = Server {
            project: &mut project,
            initialized: false,
        };
        let call = |name: &str, args: Value| json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":name,"arguments":args}});
        assert!(server.rpc(call("project_summary", json!({}))).unwrap()["error"].is_object());
        server.rpc(json!({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test"}}}));
        assert!(server
            .rpc(json!({"jsonrpc":"2.0","method":"tools/call","params":{"name":"undo"}}))
            .is_none());
        let batch = json!({"commands":[{"op":"set","path":"canvas.padding","value":30},{"op":"set","path":"canvas.radius","value":12}]});
        assert_eq!(
            server.rpc(call("batch", batch)).unwrap()["result"]["isError"],
            false
        );
        assert_eq!(server.project.undo.len(), 1);
        assert_eq!(
            server.rpc(call("undo", json!({}))).unwrap()["result"]["isError"],
            false
        );
        assert_eq!(serde_json::to_value(&server.project.data).unwrap(), before);
        let invalid = json!({"commands":[{"op":"set","path":"canvas.padding","value":30},{"op":"not_a_command"}]});
        assert_eq!(
            server.rpc(call("batch", invalid)).unwrap()["result"]["isError"],
            true
        );
        assert_eq!(serde_json::to_value(&server.project.data).unwrap(), before);
        for value in ["first", "second"] {
            let grouped = json!({"command":{"op":"coalesced_edit","key":"agent","command":{"op":"set","path":"notes","value":value}}});
            assert_eq!(
                server.rpc(call("apply", grouped)).unwrap()["result"]["isError"],
                false
            );
        }
        assert_eq!(
            server.project.undo.len(),
            2,
            "Separate MCP calls never coalesce"
        );
        fs::remove_dir_all(root).unwrap();
    }
}
