// Human labels for agent actions, ported field-for-field from the original
// bridge.mjs so the feed reads exactly the same.

use serde_json::Value;

const SHORT: usize = 40;

// String(value) for the JSON values that actually reach these labels.
fn stringify(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        other => other.to_string(),
    }
}

pub fn short_value(value: &Value) -> String {
    short(&stringify(value))
}

pub fn short(value: &str) -> String {
    let text = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.chars().count() > SHORT {
        let mut cut: String = text.chars().take(SHORT - 1).collect();
        cut.push('\u{2026}');
        cut
    } else {
        text
    }
}

fn quoted(value: &str) -> String {
    format!("\u{201c}{}\u{201d}", short(value))
}

fn quoted_value(value: &Value) -> String {
    quoted(&stringify(value))
}

fn strip_prefix_ci<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    // .get(), not a slice: selectors are arbitrary UTF-8, and an index that
    // lands inside a multi-byte character must mean "no match", not a panic.
    let head = text.get(..prefix.len())?;
    if head.eq_ignore_ascii_case(prefix) {
        Some(&text[prefix.len()..])
    } else {
        None
    }
}

// One optional leading and one optional trailing quote, the way the original
// regexes' `["']?(.+?)["']?` behaved.
fn unquote(text: &str) -> Option<&str> {
    let text = text.strip_prefix(['"', '\'']).unwrap_or(text);
    let text = text.strip_suffix(['"', '\'']).unwrap_or(text);
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

// Playwright-style selector engines carry human text inside the selector
// string itself, so a plain `click` command is often still describable
// without asking the page anything.
fn from_selector(selector: &Value, refs: &Value) -> String {
    let text = stringify(selector);

    for prefix in ["text=", ":has-text="] {
        if let Some(inner) = strip_prefix_ci(&text, prefix).and_then(unquote) {
            return quoted(inner);
        }
    }

    if let Some(rest) = strip_prefix_ci(&text, "role=") {
        if !rest.is_empty() && rest.chars().all(|c| c.is_ascii_alphabetic()) {
            return rest.to_string();
        }
        if let Some((role, tail)) = rest.split_once('[') {
            if !role.is_empty() && role.chars().all(|c| c.is_ascii_alphabetic()) {
                if let Some(name) = tail
                    .strip_suffix(']')
                    .and_then(|t| strip_prefix_ci(t, "name="))
                    .and_then(unquote)
                {
                    return format!("{} {}", role, quoted(name));
                }
            }
        }
    }

    // A snapshot ref means nothing to a reader on its own, but the snapshot
    // that minted it said what it was.
    if let Some(id) = text.strip_prefix('@') {
        if !id.is_empty() {
            let known = &refs[id];
            let name = known["name"].as_str().unwrap_or("");
            let role = known["role"].as_str().unwrap_or("");
            if !name.is_empty() {
                let head = if role.is_empty() {
                    String::new()
                } else {
                    short(role) + " "
                };
                return head + &quoted(name);
            }
            if !role.is_empty() {
                return short(role);
            }
            return "element".to_string();
        }
    }

    short(&text)
}

// What the agent aimed at, in the words a person would use. agent-browser's
// locator commands carry the text, role or label they searched by, which is
// most of what an agent actually clicks — bare CSS selectors and snapshot refs
// are the cases with nothing human in them.
fn target_of(action: &str, p: &Value, refs: &Value) -> String {
    match action {
        "getbytext" => quoted_value(&p["text"]),
        "getbyrole" => {
            let name = stringify(&p["name"]);
            if !name.is_empty() {
                format!("{} {}", short_value(&p["role"]), quoted(&name))
            } else {
                short_value(&p["role"])
            }
        }
        "getbylabel" => quoted_value(&p["label"]),
        "getbyplaceholder" => quoted_value(&p["placeholder"]),
        "getbyalt" => quoted_value(&p["alt"]),
        "getbytitle" => quoted_value(&p["title"]),
        "getbytestid" => short_value(&p["testId"]),
        _ => from_selector(&p["selector"], refs),
    }
}

fn verb_for(name: &str, fallback: &str) -> String {
    match name.to_ascii_lowercase().as_str() {
        "click" => "click",
        "dblclick" => "double-click",
        "hover" => "hover",
        "focus" => "focus",
        "check" => "check",
        "uncheck" => "uncheck",
        "select" => "select",
        "fill" => "type into",
        "type" => "type into",
        "upload" => "upload to",
        "drag" => "drag",
        "scrollintoview" => "scroll to",
        _ => fallback,
    }
    .to_string()
}

// Actions worth drawing a pointer for: things done *at* a place on the page.
pub fn pointed(action: &str) -> bool {
    matches!(
        action,
        "click"
            | "dblclick"
            | "hover"
            | "drag"
            | "check"
            | "uncheck"
            | "focus"
            | "select"
            | "fill"
            | "type"
    )
}

// A short human label for one agent action.
// fill and type carry the value being typed. It is never shown: this is where
// passwords and tokens go, and the panel sits on a desktop.
pub fn describe(action: &str, p: &Value, refs: &Value) -> String {
    // The locator family: the verb is in `subaction`, the target in the params.
    if action.starts_with("getby") {
        let sub = stringify(&p["subaction"]);
        let verb = if sub.is_empty() {
            "find".to_string()
        } else {
            verb_for(&sub, &sub)
        };
        return format!("{} {}", verb, target_of(action, p, refs));
    }

    match action {
        "navigate" => {
            let mut url = stringify(&p["url"]);
            for prefix in ["https://", "http://"] {
                if let Some(rest) = url.strip_prefix(prefix) {
                    url = rest.to_string();
                    break;
                }
            }
            let url = url.strip_suffix('/').unwrap_or(&url);
            format!("navigate {}", short(url))
        }
        "click" => format!("click {}", from_selector(&p["selector"], refs)),
        "dblclick" => format!("double-click {}", from_selector(&p["selector"], refs)),
        "hover" => format!("hover {}", from_selector(&p["selector"], refs)),
        "focus" => format!("focus {}", from_selector(&p["selector"], refs)),
        "check" => format!("check {}", from_selector(&p["selector"], refs)),
        "uncheck" => format!("uncheck {}", from_selector(&p["selector"], refs)),
        "select" => format!("select {}", from_selector(&p["selector"], refs)),
        "scrollintoview" => format!("scroll to {}", from_selector(&p["selector"], refs)),
        "drag" => format!("drag {}", from_selector(&p["selector"], refs)),
        "upload" => format!("upload to {}", from_selector(&p["selector"], refs)),
        // Deliberately no value: this is where credentials get typed.
        "type" => format!("type into {}", from_selector(&p["selector"], refs)),
        "fill" => format!("type into {}", from_selector(&p["selector"], refs)),
        "keyboard" => "type".to_string(),
        "press" => format!("press {}", short_value(&p["key"])),
        "scroll" => {
            let arrow = match stringify(&p["direction"]).to_ascii_lowercase().as_str() {
                "up" => "\u{2191}",
                "down" => "\u{2193}",
                "left" => "\u{2190}",
                "right" => "\u{2192}",
                _ => "",
            };
            let amount = if p["amount"].is_null() {
                String::new()
            } else {
                stringify(&p["amount"])
            };
            format!("scroll {}{}", arrow, amount)
        }
        "mousemove" => format!(
            "move {},{}",
            p["x"].as_f64().unwrap_or(0.0).round() as i64,
            p["y"].as_f64().unwrap_or(0.0).round() as i64
        ),
        "mousedown" => "mouse down".to_string(),
        "mouseup" => "mouse up".to_string(),
        "wheel" => "wheel".to_string(),
        "back" => "back".to_string(),
        "forward" => "forward".to_string(),
        "reload" => "reload".to_string(),
        "screenshot" => "screenshot".to_string(),
        "snapshot" => "snapshot".to_string(),
        "eval" => "eval".to_string(), // never the code itself
        "waitfor" | "wait" => {
            let has_selector = p["selector"]
                .as_str()
                .map(|s| !s.is_empty())
                .unwrap_or(!p["selector"].is_null());
            if has_selector {
                format!("wait {}", from_selector(&p["selector"], refs))
            } else {
                format!("wait {}", short_value(&p["ms"]))
            }
        }
        other => short(other),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    // Shared setup, inline assertions: one click label against the same ref
    // table every describe test uses.
    fn click_label(selector: &str) -> String {
        let refs = json!({ "e5": { "role": "link", "name": "The ISO" } });
        describe("click", &json!({ "selector": selector }), &refs)
    }

    mod describe_fn {
        use super::*;

        #[test]
        fn quotes_the_text_a_text_engine_searched_by() {
            assert_eq!(
                click_label("text=\"More information\""),
                "click \u{201c}More information\u{201d}"
            );
        }

        #[test]
        fn names_role_and_accessible_name_from_a_role_engine() {
            assert_eq!(
                click_label("role=button[name=\"Accedi\"]"),
                "click button \u{201c}Accedi\u{201d}"
            );
        }

        #[test]
        fn names_a_bare_role_engine_by_its_role() {
            assert_eq!(click_label("role=link"), "click link");
        }

        #[test]
        fn resolves_a_known_snapshot_ref_from_the_ref_table() {
            assert_eq!(click_label("@e5"), "click link \u{201c}The ISO\u{201d}");
        }

        #[test]
        fn calls_an_unknown_snapshot_ref_an_element() {
            assert_eq!(click_label("@e9"), "click element");
        }

        #[test]
        fn shows_a_bare_css_selector_verbatim() {
            assert_eq!(click_label("#login-button"), "click #login-button");
        }

        #[test]
        fn never_shows_the_value_being_typed() {
            let label = describe(
                "fill",
                &json!({ "selector": "#password", "value": "hunter2" }),
                &json!({}),
            );
            assert_eq!(label, "type into #password");
        }

        #[test]
        fn survives_multibyte_selectors_shorter_than_the_engine_prefixes() {
            // Byte lengths where a naive prefix slice would land inside a
            // character; the label content does not matter, not panicking does.
            for sel in [
                "\u{65e5}\u{672c}\u{8a9e}",
                "\u{e9}",
                "text=\u{65e5}\u{672c}",
                "role=\u{e9}",
            ] {
                let _ = describe("click", &json!({ "selector": sel }), &json!({}));
            }
        }
    }

    mod short_fn {
        use super::*;

        #[test]
        fn cuts_long_text_on_char_boundaries_to_forty_chars() {
            let cut = short(&"\u{65e5}".repeat(60));
            assert_eq!(cut.chars().count(), 40, "cut to {cut:?}");
        }

        #[test]
        fn ends_cut_text_with_an_ellipsis() {
            let cut = short(&"\u{65e5}".repeat(60));
            assert!(cut.ends_with('\u{2026}'), "cut to {cut:?}");
        }
    }
}
