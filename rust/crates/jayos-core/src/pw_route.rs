//! Which device an EasyEffects virtual device's sound actually reaches.
//!
//! EasyEffects 8 makes two virtual devices, `easyeffects_sink` and
//! `easyeffects_source`, and runs its effects between them and the hardware:
//! applications play into the sink, its filters read the sink's monitor and
//! write to the speakers; the microphone feeds its input filters, and they
//! write into the virtual source that applications record from. Both virtual
//! devices are PipeWire null sinks created with `monitor.channel-volumes`
//! false -- EasyEffects' own default for its activateMonitorChannelVolumes
//! setting (easyeffects_db.kcfg, READ) -- and a null sink's only output IS its
//! monitor. So their volume, and on the source side their mute, reach nothing
//! anyone hears. RUN against an EasyEffects-shaped graph on PipeWire 1.0.5 (a
//! pass-through pw_filter with no media.class between each virtual device and
//! a device): easyeffects_source muted, and a recorder of it still read
//! -15.3 dBFS; the microphone behind it muted, and the recorder read silence.
//! easyeffects_sink at 20%, and the speakers still read -15.3 dBFS. The
//! sink's MONITOR, which pactl lists as a source of its own, is another node
//! whose controls work -- see [`inert`].
//!
//! When one of them is the default, a volume slider or a microphone mute that
//! acts on "the default" acts on nothing. The volume popup (jayos-audio-state)
//! and the privacy page (jayos-privacy) ask this module for the device behind
//! it instead, and act on that. Two sources, in order:
//!
//!  - the link graph, from `pw-dump`: the one device reached from the virtual
//!    node through filters (nodes with no media.class, which is what a
//!    pw_filter is) -- downstream from the sink, upstream to the source;
//!  - EasyEffects' own record, [StreamOutputs] outputDevice or [StreamInputs]
//!    inputDevice in its rc file. It is needed because EasyEffects unlinks its
//!    filters when nothing has played or recorded for a while (its inactivity
//!    timer), and a mute set then must still land on the right device.
//!
//! Neither answering is an answer too: nothing to act on. The callers then
//! refuse rather than act on the virtual device, because a mute that reports
//! success and silences nothing is the one outcome worse than no mute.
//!
//! What has NOT been run: a real EasyEffects. Its graph was reproduced from its
//! source (stream_input_effects.cpp connect_filters, READ) with a stand-in
//! filter, and the property names below are the ones its pw_node_manager.cpp
//! sets (READ).

use serde_json::{Map, Value};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::PathBuf;

/// EasyEffects' application id, which it sets on both virtual devices.
pub const EASYEFFECTS_APP_ID: &str = "com.github.wwmm.easyeffects";

/// The fixed node names EasyEffects gives its virtual devices
/// (tags::pipewire::ee_sink_name / ee_source_name, READ).
pub const EASYEFFECTS_NODES: [&str; 2] = ["easyeffects_sink", "easyeffects_source"];

/// Which way from the virtual device the real one lies.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    /// A sink: follow the links out of it, to an `Audio/Sink`.
    Sink,
    /// A source: follow the links into it, back to an `Audio/Source`.
    Source,
}

/// How many nodes a walk may visit. EasyEffects' longest chain is its plugin
/// count plus three; this only stops a graph with a cycle in it.
const MAX_NODES: usize = 256;

fn prop<'a>(p: Option<&'a Map<String, Value>>, key: &str) -> &'a str {
    p.and_then(|m| m.get(key)).and_then(Value::as_str).unwrap_or("")
}

/// Whether a node, by its properties and name, is one of EasyEffects' virtual
/// devices with its own level switched off.
///
/// Narrow on purpose: EasyEffects' id or one of its two node names. Other null
/// sinks can carry `monitor.channel-volumes` false too, but none has been seen
/// misleading anyone, and hiding a slider that works is its own defect. With
/// EasyEffects' "monitor channel volumes" switched on the property reads
/// "true", the node's own controls work, and it is not inert -- so a person who
/// turned that on keeps them. (EasyEffects can flip the setting at runtime
/// without changing the property pactl reports, READ in pw_node_manager.cpp;
/// that leaves this answer stale until it restarts.)
///
/// A MONITOR is never inert, not even the monitor of EasyEffects' sink.
/// pactl lists a sink's monitor as a source that carries the SINK's properties:
/// `easyeffects_sink.monitor` printed EasyEffects' application.id,
/// monitor.channel-volumes "false" and even node.name "easyeffects_sink", with
/// device.class "monitor" added (RUN, pactl 16.1 on PipeWire 1.0.5). Its own
/// mute and volume are the sink's monitorMute and monitorVolumes. They act on
/// the monitor ports whatever monitor.channel-volumes says (RUN, with a tone
/// in the sink: the monitor muted gave -inf at a recorder of it, and at 20% it
/// gave -57.0 dBFS; the sink muted, or at 20%, left the recorder at -15.1).
/// With the monitor as the default source, calling it inert sent the privacy
/// mute to the microphone named in EasyEffects' rc. `jayos-privacy mic off`
/// exited 0, status said micMuted true, and the recorder kept its -15.1 dBFS.
/// The popup's hero moved that microphone too. Muting this monitor also
/// silences what EasyEffects plays, because its filters read the same ports:
/// a native reader of them read -inf as well. That is the cost of muting the
/// default this configuration names.
pub fn inert(props: Option<&Map<String, Value>>, name: &str) -> bool {
    // Both tests, as jayos-audio-state's is_monitor has them: the class is what
    // PipeWire sets, and the suffix is what pactl names every monitor.
    if prop(props, "device.class") == "monitor" || name.ends_with(".monitor") {
        return false;
    }
    let easyeffects =
        prop(props, "application.id") == EASYEFFECTS_APP_ID || EASYEFFECTS_NODES.contains(&name);
    easyeffects && prop(props, "monitor.channel-volumes") != "true"
}

/// Whether a media class is the device a walk on this side ends at.
///
/// A source may be a virtual one (a remap, another DSP) as well as hardware:
/// muting whatever feeds EasyEffects silences what comes out of it. A sink
/// that a source walk reaches is NOT accepted, even through its monitor:
/// EasyEffects' echo canceller links the output device into its input chain
/// as a probe (stream_input_effects.cpp, READ), so every chain with one would
/// otherwise have two candidates and resolve to nothing.
fn ends_walk(class: &str, side: Side) -> bool {
    match side {
        Side::Sink => class == "Audio/Sink",
        Side::Source => class == "Audio/Source" || class == "Audio/Source/Virtual",
    }
}

/// What `pw-dump` printed, as the one array of objects [`device_behind`] and
/// the helpers' other readers walk.
///
/// pw-dump prints the graph as one JSON array -- and then, when an object is
/// added, changed or removed while it is still dumping, a further array saying
/// just that: `[{"id":110,"info":null}]` for a client that left (RUN on
/// PipeWire 1.0.5: 4 of 60 dumps taken while the volume popup polled). Read as
/// one document, that output is not JSON at all, so the graph read as empty
/// and the answer fell to EasyEffects' rc or to a refusal: the privacy switch
/// muted the microphone the rc named rather than the one behind the virtual
/// source (3 of 30), and a volume key moved another output (6 of 60).
///
/// Every array is applied in order: an entry whose `info` is null removes the
/// object with its id, and any other entry replaces that object or is added.
/// A document cut off part-way -- a dump the timeout ended -- stops the reading
/// there and keeps what came before it. `None` when the first document is not
/// an array.
pub fn parse_dump(text: &str) -> Option<Value> {
    let mut documents = serde_json::Deserializer::from_str(text).into_iter::<Value>();
    let Some(Ok(Value::Array(mut objects))) = documents.next() else {
        return None;
    };
    for document in documents {
        let Ok(Value::Array(changes)) = document else {
            break;
        };
        for change in changes {
            let id = change.get("id").and_then(Value::as_u64);
            let removed = change.get("info").is_some_and(Value::is_null);
            let at = id.and_then(|id| {
                objects.iter().position(|o| o.get("id").and_then(Value::as_u64) == Some(id))
            });
            match (at, removed) {
                (Some(i), true) => {
                    objects.remove(i);
                }
                (Some(i), false) => objects[i] = change,
                (None, true) => {}
                (None, false) => objects.push(change),
            }
        }
    }
    Some(Value::Array(objects))
}

/// The node.name of the one device behind `name` in a `pw-dump` array.
///
/// Walks links in one direction only -- out of a sink, into a source -- and
/// only THROUGH nodes that have no media.class, which is what a filter is.
/// Any node with a class stops the walk there: an application stream, the
/// other EasyEffects device, a device of the wrong kind. (Its own device is
/// never reached again -- it is where the walk started -- and the callers
/// refuse an answer that is itself inert.) `None` when the node
/// is not in the dump, when nothing is linked (EasyEffects has unlinked its
/// filters), and when two different devices are reached, because acting on one
/// of two would be a guess.
pub fn device_behind(dump: &Value, name: &str, side: Side) -> Option<String> {
    let objects = dump.as_array()?;

    let mut class_of: HashMap<u64, (&str, &str)> = HashMap::new();
    let mut start = None;
    let mut next_of: HashMap<u64, Vec<u64>> = HashMap::new();

    for object in objects {
        let kind = object.get("type").and_then(Value::as_str).unwrap_or("");
        let Some(id) = object.get("id").and_then(Value::as_u64) else {
            continue;
        };
        let info = object.get("info");
        match kind {
            "PipeWire:Interface:Node" => {
                let props = info.and_then(|i| i.get("props")).and_then(Value::as_object);
                let node_name = prop(props, "node.name");
                class_of.insert(id, (node_name, prop(props, "media.class")));
                if node_name == name && start.is_none() {
                    start = Some(id);
                }
            }
            "PipeWire:Interface:Link" => {
                let end = |key: &str| info.and_then(|i| i.get(key)).and_then(Value::as_u64);
                let (Some(from), Some(to)) = (end("output-node-id"), end("input-node-id")) else {
                    continue;
                };
                let (here, there) = match side {
                    Side::Sink => (from, to),
                    Side::Source => (to, from),
                };
                next_of.entry(here).or_default().push(there);
            }
            _ => {}
        }
    }

    let start = start?;
    let mut seen: HashSet<u64> = HashSet::from([start]);
    let mut frontier = vec![start];
    let mut found: BTreeSet<&str> = BTreeSet::new();

    while let Some(node) = frontier.pop() {
        for &next in next_of.get(&node).into_iter().flatten() {
            if seen.len() >= MAX_NODES || !seen.insert(next) {
                continue;
            }
            let Some(&(next_name, class)) = class_of.get(&next) else {
                continue;
            };
            if class.is_empty() {
                frontier.push(next);
            } else if ends_walk(class, side) {
                found.insert(next_name);
            }
        }
    }

    match (found.len(), found.into_iter().next()) {
        (1, Some(device)) if !device.is_empty() => Some(device.to_string()),
        _ => None,
    }
}

/// EasyEffects' rc file: `$XDG_CONFIG_HOME/easyeffects/db/easyeffectsrc`, the
/// 8.x layout config/common/scripts/easyeffects-lib.sh reads as `EE_RC`.
pub fn easyeffects_rc() -> PathBuf {
    crate::paths::config_root().join("easyeffects/db/easyeffectsrc")
}

/// The device EasyEffects last linked this side to, from its rc text.
///
/// KConfig writes a key only when it differs from the default, and the
/// default here is empty, so an absent key is `None`, as is an empty value.
/// The same reading as `ee_rc_get` in easyeffects-lib.sh: the group header
/// alone on its line, then `key=value` up to the next header.
pub fn easyeffects_device(rc: &str, side: Side) -> Option<String> {
    let (group, key) = match side {
        Side::Sink => ("[StreamOutputs]", "outputDevice="),
        Side::Source => ("[StreamInputs]", "inputDevice="),
    };
    let mut inside = false;
    for line in rc.lines() {
        let line = line.trim_end();
        if line.starts_with('[') {
            inside = line == group;
            continue;
        }
        if inside {
            if let Some(value) = line.strip_prefix(key) {
                let value = value.trim();
                return (!value.is_empty()).then(|| value.to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn node(id: u64, name: &str, class: Option<&str>) -> Value {
        let mut props = json!({ "node.name": name, "object.serial": id + 100 });
        if let Some(class) = class {
            props["media.class"] = json!(class);
        }
        json!({ "id": id, "type": "PipeWire:Interface:Node", "info": { "props": props } })
    }

    fn link(id: u64, from: u64, to: u64) -> Value {
        json!({ "id": id, "type": "PipeWire:Interface:Link",
                "info": { "output-node-id": from, "input-node-id": to, "state": "active" } })
    }

    /// The graph EasyEffects 8 builds, in pw-dump's shape: two stereo links
    /// per hop, as the stand-in graph printed them on PipeWire 1.0.5.
    fn easyeffects_graph() -> Vec<Value> {
        vec![
            node(40, "alsa_output.speakers", Some("Audio/Sink")),
            node(49, "alsa_output.headphones", Some("Audio/Sink")),
            node(60, "alsa_input.usb-mic", Some("Audio/Source")),
            node(66, "easyeffects_sink", Some("Audio/Sink")),
            node(72, "easyeffects_source", Some("Audio/Source/Virtual")),
            node(80, "ee_soe_equalizer", None),
            node(81, "ee_soe_output_level", None),
            node(90, "ee_sie_deepfilternet", None),
            node(91, "ee_sie_output_level", None),
            node(95, "Firefox", Some("Stream/Output/Audio")),
            node(96, "Zoom", Some("Stream/Input/Audio")),
            // an application into the sink, the sink's monitor into the chain,
            // the chain into the speakers
            link(200, 95, 66),
            link(201, 95, 66),
            link(202, 66, 80),
            link(203, 66, 80),
            link(204, 80, 81),
            link(205, 80, 81),
            link(206, 81, 40),
            link(207, 81, 40),
            // the microphone into the input chain, into the virtual source,
            // which an application records
            link(210, 60, 90),
            link(211, 60, 90),
            link(212, 90, 91),
            link(213, 90, 91),
            link(214, 91, 72),
            link(215, 91, 72),
            link(216, 72, 96),
            link(217, 72, 96),
        ]
    }

    #[test]
    fn the_sink_resolves_downstream_to_the_speakers() {
        let dump = Value::Array(easyeffects_graph());
        assert_eq!(
            device_behind(&dump, "easyeffects_sink", Side::Sink).as_deref(),
            Some("alsa_output.speakers")
        );
    }

    #[test]
    fn the_source_resolves_upstream_to_the_microphone() {
        let dump = Value::Array(easyeffects_graph());
        assert_eq!(
            device_behind(&dump, "easyeffects_source", Side::Source).as_deref(),
            Some("alsa_input.usb-mic")
        );
    }

    #[test]
    fn the_walk_goes_one_way_only() {
        // Upstream of the sink is Firefox, a stream; downstream of the source
        // is Zoom. Neither is a device, so a walk the wrong way finds nothing
        // -- and must never cross over to the other chain's device.
        let dump = Value::Array(easyeffects_graph());
        assert_eq!(device_behind(&dump, "easyeffects_sink", Side::Source), None);
        assert_eq!(device_behind(&dump, "easyeffects_source", Side::Sink), None);
    }

    #[test]
    fn the_echo_cancellers_probe_does_not_make_the_source_ambiguous() {
        // EasyEffects links the OUTPUT device into its echo canceller as a
        // probe. Walking back from the source reaches the speakers that way,
        // and a sink is not a source.
        let mut graph = easyeffects_graph();
        graph.push(link(220, 40, 90));
        let dump = Value::Array(graph);
        assert_eq!(
            device_behind(&dump, "easyeffects_source", Side::Source).as_deref(),
            Some("alsa_input.usb-mic")
        );
    }

    #[test]
    fn a_link_into_the_other_virtual_device_is_a_dead_end() {
        // The output chain's level meter can also feed easyeffects_source; a
        // sink walk must not treat that as a device, and a source walk must
        // not follow it back into the OUTPUT chain's sink.
        let mut graph = easyeffects_graph();
        graph.push(link(221, 81, 72));
        let dump = Value::Array(graph);
        assert_eq!(
            device_behind(&dump, "easyeffects_sink", Side::Sink).as_deref(),
            Some("alsa_output.speakers")
        );
        assert_eq!(
            device_behind(&dump, "easyeffects_source", Side::Source).as_deref(),
            Some("alsa_input.usb-mic")
        );
    }

    #[test]
    fn a_device_on_the_far_side_of_the_virtual_one_is_not_behind_it() {
        // Direction is what makes the answer: a virtual source someone chains
        // AFTER easyeffects_source, through a filter of its own, is fed by it,
        // and a sink that feeds easyeffects_sink through a filter plays into
        // it. Walked both ways, each would be a second candidate and resolve
        // nothing.
        let mut graph = easyeffects_graph();
        graph.push(node(97, "downstream_denoise", None));
        graph.push(node(98, "virtual_mic_after_ee", Some("Audio/Source/Virtual")));
        graph.push(link(230, 72, 97));
        graph.push(link(231, 97, 98));
        graph.push(node(99, "hdmi_monitor_loop", None));
        graph.push(link(232, 49, 99));
        graph.push(link(233, 99, 66));
        let dump = Value::Array(graph);
        assert_eq!(
            device_behind(&dump, "easyeffects_source", Side::Source).as_deref(),
            Some("alsa_input.usb-mic")
        );
        assert_eq!(
            device_behind(&dump, "easyeffects_sink", Side::Sink).as_deref(),
            Some("alsa_output.speakers")
        );
    }

    #[test]
    fn a_walk_does_not_pass_through_a_node_with_a_class() {
        // EasyEffects' "listen to mic" links easyeffects_source straight to
        // an output device (stream_input_effects.cpp, READ), and its output
        // level meter can feed easyeffects_source. A sink walk that carried on
        // through the virtual source would reach the headphones as a second
        // sink; only filters -- nodes with no class -- are walked through.
        let mut graph = easyeffects_graph();
        graph.push(link(240, 81, 72));
        graph.push(link(241, 72, 49));
        let dump = Value::Array(graph);
        assert_eq!(
            device_behind(&dump, "easyeffects_sink", Side::Sink).as_deref(),
            Some("alsa_output.speakers")
        );
    }

    #[test]
    fn two_devices_behind_it_is_no_answer() {
        let mut graph = easyeffects_graph();
        graph.push(link(222, 81, 49));
        let dump = Value::Array(graph);
        assert_eq!(device_behind(&dump, "easyeffects_sink", Side::Sink), None);
    }

    #[test]
    fn an_unlinked_chain_is_no_answer() {
        // What EasyEffects' inactivity timer leaves: the nodes, no links.
        let graph: Vec<Value> = easyeffects_graph()
            .into_iter()
            .filter(|o| o["type"] != "PipeWire:Interface:Link")
            .collect();
        let dump = Value::Array(graph);
        assert_eq!(device_behind(&dump, "easyeffects_sink", Side::Sink), None);
        assert_eq!(device_behind(&dump, "easyeffects_source", Side::Source), None);
    }

    #[test]
    fn a_cycle_between_filters_ends() {
        let mut graph = easyeffects_graph();
        graph.push(link(223, 81, 80));
        let dump = Value::Array(graph);
        assert_eq!(
            device_behind(&dump, "easyeffects_sink", Side::Sink).as_deref(),
            Some("alsa_output.speakers")
        );
    }

    #[test]
    fn a_node_not_in_the_dump_or_a_dump_that_is_not_a_list_is_no_answer() {
        let dump = Value::Array(easyeffects_graph());
        assert_eq!(device_behind(&dump, "easyeffects_elsewhere", Side::Sink), None);
        assert_eq!(device_behind(&json!({}), "easyeffects_sink", Side::Sink), None);
        assert_eq!(device_behind(&json!([]), "easyeffects_sink", Side::Sink), None);
    }

    #[test]
    fn easyeffects_devices_with_their_level_off_are_inert() {
        let props = |cv: &str| {
            json!({ "application.id": EASYEFFECTS_APP_ID, "monitor.channel-volumes": cv })
                .as_object()
                .cloned()
        };
        assert!(inert(props("false").as_ref(), "easyeffects_sink"));
        // Unset is EasyEffects' default too.
        let bare = json!({ "application.id": EASYEFFECTS_APP_ID }).as_object().cloned();
        assert!(inert(bare.as_ref(), "easyeffects_source"));
        // "Monitor channel volumes" switched on: the node's own controls work.
        assert!(!inert(props("true").as_ref(), "easyeffects_sink"));
        // Known by its name when the id is missing.
        assert!(inert(None, "easyeffects_source"));
        // Any other null sink with its level off is left alone.
        let other = json!({ "monitor.channel-volumes": "false", "factory.name": "support.null-audio-sink" });
        assert!(!inert(other.as_object(), "my_null_sink"));
        assert!(!inert(None, "alsa_output.speakers"));
    }

    #[test]
    fn the_monitor_of_easyeffects_sink_is_not_inert() {
        // What pactl 16.1 listed for it on PipeWire 1.0.5: the sink's own
        // properties, node.name included, plus device.class "monitor". Its
        // mute and volume are the monitor's own and they work, so treating it
        // as inert sent the privacy mute to the microphone instead.
        let monitor = json!({
            "application.id": EASYEFFECTS_APP_ID,
            "monitor.channel-volumes": "false",
            "node.virtual": "true",
            "node.name": "easyeffects_sink",
            "device.class": "monitor",
        });
        assert!(!inert(monitor.as_object(), "easyeffects_sink.monitor"));
        // Known as a monitor by its name alone, for a node with no class.
        let classless =
            json!({ "application.id": EASYEFFECTS_APP_ID, "monitor.channel-volumes": "false" });
        assert!(!inert(classless.as_object(), "easyeffects_sink.monitor"));
        // And by its class alone, whatever it is called.
        assert!(!inert(monitor.as_object(), "easyeffects_sink"));
        // The sink itself, with the same properties less the class, still is.
        let sink =
            json!({ "application.id": EASYEFFECTS_APP_ID, "monitor.channel-volumes": "false" });
        assert!(inert(sink.as_object(), "easyeffects_sink"));
    }

    #[test]
    fn the_rc_names_the_device_on_each_side() {
        let rc = "\
[Presets]
lastLoadedInputPreset=denoise

[StreamInputs]
inputDevice=alsa_input.usb-mic
useDefaultInputDevice=true

[StreamOutputs]
outputDevice=alsa_output.speakers
";
        assert_eq!(easyeffects_device(rc, Side::Source).as_deref(), Some("alsa_input.usb-mic"));
        assert_eq!(easyeffects_device(rc, Side::Sink).as_deref(), Some("alsa_output.speakers"));
    }

    #[test]
    fn a_key_outside_its_group_or_empty_is_no_answer() {
        let rc = "[Other]\ninputDevice=wrong\n[StreamInputs]\ninputDevice=\n";
        assert_eq!(easyeffects_device(rc, Side::Source), None);
        assert_eq!(easyeffects_device("", Side::Sink), None);
        assert_eq!(
            easyeffects_device("[StreamOutputs]\nuseDefaultOutputDevice=true\n", Side::Sink),
            None
        );
    }

    /// The dump as PipeWire 1.0.5 printed it with a client leaving part-way:
    /// the whole graph, then a second array removing the client.
    fn two_documents(graph: &[Value], then: &Value) -> String {
        format!("{}\n{}\n", Value::Array(graph.to_vec()), then)
    }

    #[test]
    fn a_dump_with_a_second_array_still_resolves_through_the_graph() {
        let text = two_documents(&easyeffects_graph(), &json!([{ "id": 110, "info": null }]));
        assert!(serde_json::from_str::<Value>(&text).is_err(), "the shape one document refuses");
        let dump = parse_dump(&text).expect("the graph");
        assert_eq!(
            device_behind(&dump, "easyeffects_sink", Side::Sink).as_deref(),
            Some("alsa_output.speakers")
        );
        assert_eq!(
            device_behind(&dump, "easyeffects_source", Side::Source).as_deref(),
            Some("alsa_input.usb-mic")
        );
    }

    #[test]
    fn a_later_array_removes_and_replaces_objects() {
        // The link from the output chain to the speakers goes, and a new one
        // to the headphones arrives: the sink now resolves to the headphones.
        let text = two_documents(
            &easyeffects_graph(),
            &json!([
                { "id": 206, "info": null },
                { "id": 207, "info": null },
                link(208, 81, 49),
            ]),
        );
        let dump = parse_dump(&text).expect("the graph");
        assert_eq!(
            device_behind(&dump, "easyeffects_sink", Side::Sink).as_deref(),
            Some("alsa_output.headphones")
        );
        // A change to a node replaces it rather than adding a second one.
        let renamed = two_documents(
            &easyeffects_graph(),
            &json!([node(40, "alsa_output.renamed", Some("Audio/Sink"))]),
        );
        let dump = parse_dump(&renamed).expect("the graph");
        let ids = dump.as_array().unwrap().iter().filter(|o| o["id"] == 40).count();
        assert_eq!(ids, 1);
        assert_eq!(
            device_behind(&dump, "easyeffects_sink", Side::Sink).as_deref(),
            Some("alsa_output.renamed")
        );
    }

    #[test]
    fn one_document_is_read_as_it_was_and_garbage_is_no_dump() {
        let text = Value::Array(easyeffects_graph()).to_string();
        assert_eq!(parse_dump(&text), Some(Value::Array(easyeffects_graph())));
        assert_eq!(parse_dump(""), None);
        assert_eq!(parse_dump("Failure: Connection refused"), None);
        assert_eq!(parse_dump("{\"not\": \"a list\"}"), None);
        // A second document cut off by the timeout keeps the first.
        let cut = format!("{}\n[{{\"id\": 110, \"in", Value::Array(easyeffects_graph()));
        assert_eq!(parse_dump(&cut), Some(Value::Array(easyeffects_graph())));
    }
}
