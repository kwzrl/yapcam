//! The agent's handbook, compiled in so the app and the stdio server ship the same text for their version.
//! Served as MCP resources (`yapcam://<name>`) and prompts; the in-app chat uses `chat` as its system prompt.
use serde_json::{json, Value};

/// (name, title, description, text). The name is the resource path after `yapcam://`.
const DOCS: &[(&str, &str, &str, &str)] = &[
    (
        "playbook",
        "Yapcam playbook",
        "Read first: the editing workflow every agent follows.",
        include_str!("../agent-docs/playbook.md"),
    ),
    (
        "craft",
        "Craft rules",
        "Hard rules for cuts, zooms, text and captions in screen recordings.",
        include_str!("../agent-docs/craft.md"),
    ),
    (
        "tools",
        "Which tool when",
        "One line per tool: understand, see, judge, edit, raw.",
        include_str!("../agent-docs/tools.md"),
    ),
    (
        "examples/tighten",
        "Example: tighten a raw demo",
        "Worked example with tool calls: clean a raw demo.",
        include_str!("../agent-docs/examples/tighten.md"),
    ),
    (
        "examples/walkthrough",
        "Example: feature walkthrough",
        "Worked example with tool calls: zooms on the key clicks.",
        include_str!("../agent-docs/examples/walkthrough.md"),
    ),
    (
        "examples/changelog",
        "Example: what's-new clip",
        "Worked example with tool calls: a 30–45 s changelog clip.",
        include_str!("../agent-docs/examples/changelog.md"),
    ),
];
const CHAT: &str = include_str!("../agent-docs/chat.md");

/// Short `initialize.instructions`: points to the playbook and states the core loop.
pub const INSTRUCTIONS: &str = "Yapcam: you edit a screen recording in the Yapcam editor; changes land live on the user's timeline.
Read the resource yapcam://playbook first, and yapcam://craft before adding zooms, text or captions.
Loop: read `moments` → short brief → cuts → `check` → layers (zooms, text, captions last) → `check` + `capture` → fix the biggest viewer-facing problem → 1–3 line summary.
Intention tools take SECONDS on the current timeline; raw apply/batch take integer NANOSECONDS. Re-read after cuts.
Every mutating call is one undo step: put one logical step's raw commands in one `batch`.
Never export unless asked. Ask before destructive whole-video changes when the request is vague.";

/// A doc by name: `playbook`, `yapcam://craft`, `examples/tighten`, `chat` (system prompt template with `{document}`)
/// or `instructions`.
pub fn doc(name: &str) -> Option<&'static str> {
    let name = name.strip_prefix("yapcam://").unwrap_or(name);
    match name {
        "chat" => Some(CHAT),
        "instructions" => Some(INSTRUCTIONS),
        _ => DOCS.iter().find(|d| d.0 == name).map(|d| d.3),
    }
}

/// The in-app chat system prompt for one document.
pub fn chat_prompt(document: &str) -> String {
    CHAT.replace("{document}", document)
}

/// The line the in-app server appends to `INSTRUCTIONS`.
pub const APP_INSTRUCTIONS: &str = "The editor saves on its own: call `save` only when asked.";

/// Server capabilities for `initialize`, shared by both transports.
pub fn capabilities() -> Value {
    json!({"tools":{"listChanged":false},"resources":{"listChanged":false},"prompts":{"listChanged":false}})
}

/// (prompt name, description, example doc). Each prompt runs one workflow with its worked example attached.
const PROMPTS: &[(&str, &str, &str)] = &[
    ("tighten", "Clean up a raw demo: open on the first word, cut false starts, fillers, dead air and the tail.", "examples/tighten"),
    ("walkthrough", "Turn the recording into a feature walkthrough with zooms on the clicks that carry the story.", "examples/walkthrough"),
    ("changelog", "Cut a 30–45 s what's-new clip from a longer demo.", "examples/changelog"),
];

/// Methods this module answers.
pub fn handles(method: &str) -> bool {
    matches!(
        method,
        "resources/list"
            | "resources/templates/list"
            | "resources/read"
            | "prompts/list"
            | "prompts/get"
    )
}

/// Answers resources/* and prompts/* requests. Err is a JSON-RPC (code, message).
pub fn handle(method: &str, params: &Value) -> Result<Value, (i64, String)> {
    let invalid = |m: &str| Err((-32602, m.to_string()));
    match method {
        "resources/list" => Ok(
            json!({"resources": DOCS.iter().map(|(name, title, description, text)| json!({
            "uri": format!("yapcam://{name}"), "name": name, "title": title, "description": description,
            "mimeType": "text/markdown", "size": text.len()})).collect::<Vec<_>>()}),
        ),
        "resources/templates/list" => Ok(json!({"resourceTemplates": []})),
        "resources/read" => {
            let Some(uri) = params["uri"].as_str() else {
                return invalid("uri required");
            };
            match uri
                .strip_prefix("yapcam://")
                .and_then(|n| DOCS.iter().find(|d| d.0 == n))
            {
                Some(d) => {
                    Ok(json!({"contents":[{"uri":uri,"mimeType":"text/markdown","text":d.3}]}))
                }
                None => Err((-32002, format!("Resource not found: {uri}"))),
            }
        }
        "prompts/list" => Ok(
            json!({"prompts": PROMPTS.iter().map(|(name, description, _)| json!({
            "name": name, "description": description,
            "arguments": [{"name":"goal","description":"Anything specific: target length, features to keep, what to drop.","required":false}]
        })).collect::<Vec<_>>()}),
        ),
        "prompts/get" => {
            let Some(name) = params["name"].as_str() else {
                return invalid("name required");
            };
            let Some((name, description, example)) = PROMPTS.iter().find(|p| p.0 == name) else {
                return invalid(&format!("Unknown prompt: {name}"));
            };
            let goal = match &params["arguments"]["goal"] {
                Value::String(g) if !g.trim().is_empty() => format!("\n\nMy goal: {}", g.trim()),
                Value::Null => String::new(),
                Value::String(_) => String::new(),
                _ => return invalid("goal must be a string"),
            };
            let text = format!("{description} Follow yapcam://playbook and yapcam://craft; the worked example below shows the calls.{goal}");
            let resource = |n: &str| json!({"type":"resource","resource":{"uri":format!("yapcam://{n}"),"mimeType":"text/markdown","text":doc(n).unwrap()}});
            Ok(json!({"description": description, "messages": [
                {"role":"user","content":{"type":"text","text":text}},
                {"role":"user","content":resource("playbook")},
                {"role":"user","content":resource("craft")},
                {"role":"user","content":resource(example)},
            ], "_meta": {"prompt": name}}))
        }
        _ => Err((-32601, "Method not found".into())),
    }
}

/// A full JSON-RPC response for a resources/prompts request, or None when `request` is another method.
pub fn rpc(request: &Value) -> Option<Value> {
    let method = request["method"].as_str().filter(|m| handles(m))?;
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let params = request.get("params").cloned().unwrap_or(json!({}));
    Some(match handle(method, &params) {
        Ok(result) => json!({"jsonrpc":"2.0","id":id,"result":result}),
        Err((code, message)) => {
            json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn docs_resolve_by_name_and_uri() {
        for name in [
            "playbook",
            "craft",
            "tools",
            "examples/tighten",
            "examples/walkthrough",
            "examples/changelog",
        ] {
            let text = doc(name).unwrap();
            assert!(text.starts_with("# "), "{name}");
            assert_eq!(doc(&format!("yapcam://{name}")), Some(text));
        }
        assert!(doc("chat").unwrap().contains("{document}"));
        assert!(chat_prompt("Demo").contains("\"Demo\""));
        assert!(INSTRUCTIONS.contains("yapcam://playbook") && INSTRUCTIONS.lines().count() <= 8);
        assert_eq!(doc("missing"), None);
        assert_eq!(doc("yapcam://chat/../playbook"), None);
    }
    #[test]
    fn docs_name_only_contract_tools() {
        let all: String = DOCS
            .iter()
            .map(|d| d.3)
            .chain([CHAT, INSTRUCTIONS])
            .collect();
        for tool in [
            "moments",
            "check",
            "capture",
            "grab",
            "filmstrip",
            "waveform",
            "cut_words",
            "tighten_pauses",
            "remove_fillers",
            "trim_start_to_first_word",
            "zoom_on_click",
            "batch",
        ] {
            assert!(
                all.contains(&format!("`{tool}")) || all.contains(&format!("\"{tool}\"")),
                "{tool} undocumented"
            );
        }
    }
    #[test]
    fn resources_and_prompts() {
        let list = handle("resources/list", &json!({})).unwrap();
        assert_eq!(list["resources"].as_array().unwrap().len(), DOCS.len());
        assert_eq!(list["resources"][0]["uri"], "yapcam://playbook");
        let read = handle("resources/read", &json!({"uri":"yapcam://craft"})).unwrap();
        assert!(read["contents"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Visual budget 0"));
        assert_eq!(
            handle("resources/read", &json!({"uri":"yapcam://nope"}))
                .unwrap_err()
                .0,
            -32002
        );
        assert_eq!(handle("resources/read", &json!({})).unwrap_err().0, -32602);
        let prompts = handle("prompts/list", &json!({})).unwrap();
        let names: Vec<_> = prompts["prompts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| p["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["tighten", "walkthrough", "changelog"]);
        let get = handle(
            "prompts/get",
            &json!({"name":"changelog","arguments":{"goal":"40 s"}}),
        )
        .unwrap();
        assert!(get["messages"][0]["content"]["text"]
            .as_str()
            .unwrap()
            .ends_with("My goal: 40 s"));
        assert_eq!(
            get["messages"][3]["content"]["resource"]["uri"],
            "yapcam://examples/changelog"
        );
        assert!(handle("prompts/get", &json!({"name":"x"})).is_err());
        assert!(handle(
            "prompts/get",
            &json!({"name":"tighten","arguments":{"goal":3}})
        )
        .is_err());
        assert!(rpc(&json!({"jsonrpc":"2.0","id":1,"method":"tools/list"})).is_none());
        let r = rpc(&json!({"jsonrpc":"2.0","id":7,"method":"resources/read","params":{"uri":"yapcam://playbook"}})).unwrap();
        assert_eq!(r["id"], 7);
        assert!(r["result"]["contents"][0]["text"]
            .as_str()
            .unwrap()
            .starts_with("# Yapcam playbook"));
    }
}
