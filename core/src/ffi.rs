//! C ABI implementation matching the Lead-owned header. Reads share a lock;
//! edits serialize. Error handling contains panics at the foreign boundary.

use std::cell::RefCell;
use std::ffi::{c_char, CString};

pub const YC_ABI_VERSION: u32 = 3;

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

pub(crate) fn set_last_error(message: &str) {
    let text = CString::new(message.replace('\0', " ")).unwrap_or_default();
    LAST_ERROR.with(|e| *e.borrow_mut() = text);
}

#[no_mangle]
pub extern "C" fn yc_abi_version() -> u32 {
    guarded(0, || YC_ABI_VERSION)
}

#[no_mangle]
pub extern "C" fn yc_last_error() -> *const c_char {
    guarded(c"Rust core panic".as_ptr(), || {
        LAST_ERROR.with(|e| e.borrow().as_ptr())
    })
}

/// # Safety
/// `s` must be a string returned by this library, or null.
#[no_mangle]
pub unsafe extern "C" fn yc_string_free(s: *mut c_char) {
    guarded((), || {
        if !s.is_null() {
            drop(CString::from_raw(s));
        }
    });
}

use crate::project::{Error, Project, Result};
use std::{
    ffi::CStr,
    path::Path,
    sync::{Mutex, RwLock},
};

/// All non-null C pointers must be live, correctly aligned, and have the stated
/// access for the call duration. Handle free must not race any other call. Returned
/// strings/handles have one owner, released by the corresponding free function.
pub struct YcProject {
    pub(crate) inner: RwLock<Project>,
    writer: Mutex<()>,
}
impl YcProject {
    pub(crate) fn new(project: Project) -> Self {
        Self {
            inner: RwLock::new(project),
            writer: Mutex::new(()),
        }
    }
}
#[cfg(test)]
thread_local! { static INJECT_PANIC: std::cell::Cell<bool> = const { std::cell::Cell::new(false) }; }
fn guarded<T>(fallback: T, f: impl FnOnce() -> T + std::panic::UnwindSafe) -> T {
    match std::panic::catch_unwind(|| {
        #[cfg(test)]
        INJECT_PANIC.with(|flag| {
            if flag.replace(false) {
                panic!("injected FFI panic");
            }
        });
        f()
    }) {
        Ok(result) => result,
        Err(_) => {
            // Error reporting itself must not unwind through an extern C frame.
            let _ = std::panic::catch_unwind(|| set_last_error("Rust core panic"));
            fallback
        }
    }
}
fn boundary(f: impl FnOnce() -> Result<()> + std::panic::UnwindSafe) -> i32 {
    guarded(99, || match f() {
        Ok(()) => 0,
        Err(e) => {
            set_last_error(&e.message);
            e.status
        }
    })
}
unsafe fn utf8<'a>(s: *const c_char) -> Result<&'a str> {
    if s.is_null() {
        return Err(Error::new(1, "Null string argument"));
    }
    CStr::from_ptr(s)
        .to_str()
        .map_err(|_| Error::new(1, "Invalid UTF-8"))
}
unsafe fn handle<'a>(p: *const YcProject) -> Result<&'a YcProject> {
    p.as_ref()
        .ok_or_else(|| Error::new(1, "Null project handle"))
}
unsafe fn output<T>(out: *mut T, value: T) -> Result<()> {
    if out.is_null() {
        return Err(Error::new(1, "Null output argument"));
    }
    out.write(value);
    Ok(())
}
unsafe fn json_output(out: *mut *mut c_char, value: &impl serde::Serialize) -> Result<()> {
    if out.is_null() {
        return Err(Error::new(1, "Null JSON output"));
    }
    let s = CString::new(serde_json::to_string(value)?)
        .map_err(|_| Error::new(99, "Invalid JSON string"))?;
    out.write(s.into_raw());
    Ok(())
}
unsafe fn open_project(path: *const c_char, out: *mut *mut YcProject, create: bool) -> Result<()> {
    output(out, std::ptr::null_mut())?;
    let package = Path::new(utf8(path)?);
    let p = if create {
        Project::create(package)?
    } else {
        Project::open(package)?
    };
    output(out, Box::into_raw(Box::new(YcProject::new(p))))
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_project_create(path: *const c_char, out: *mut *mut YcProject) -> i32 {
    boundary(|| open_project(path, out, true))
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_project_open(path: *const c_char, out: *mut *mut YcProject) -> i32 {
    boundary(|| open_project(path, out, false))
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_project_save(p: *mut YcProject, path: *const c_char) -> i32 {
    boundary(|| {
        let h = handle(p)?;
        let _writer = h
            .writer
            .lock()
            .map_err(|_| Error::new(99, "Poisoned writer"))?;
        let data = h
            .inner
            .read()
            .map_err(|_| Error::new(99, "Poisoned project"))?
            .data
            .clone();
        crate::project::save_data(&data, Path::new(utf8(path)?))
    })
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_project_to_json(p: *const YcProject, out: *mut *mut c_char) -> i32 {
    boundary(|| {
        output(out, std::ptr::null_mut())?;
        json_output(
            out,
            &handle(p)?
                .inner
                .read()
                .map_err(|_| Error::new(99, "Poisoned project"))?
                .data,
        )
    })
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_project_clone(p: *const YcProject, out: *mut *mut YcProject) -> i32 {
    boundary(|| {
        output(out, std::ptr::null_mut())?;
        let mut copy = handle(p)?
            .inner
            .read()
            .map_err(|_| Error::new(99, "Poisoned project"))?
            .clone();
        copy.undo.clear();
        copy.redo.clear();
        copy.snapshot = true;
        output(out, Box::into_raw(Box::new(YcProject::new(copy))))
    })
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_project_free(p: *mut YcProject) {
    guarded((), || {
        if !p.is_null() {
            drop(Box::from_raw(p));
        }
    });
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_apply(
    p: *mut YcProject,
    command: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    boundary(|| {
        if !out.is_null() {
            output(out, std::ptr::null_mut())?;
        }
        let command = serde_json::from_str(utf8(command)?)?;
        let h = handle(p)?;
        let _writer = h
            .writer
            .lock()
            .map_err(|_| Error::new(99, "Poisoned writer"))?;
        let (staged, cs) = {
            let project = h
                .inner
                .read()
                .map_err(|_| Error::new(99, "Poisoned project"))?;
            let prepared = project.prepare_apply(&command)?;
            let staged = prepared.next.map(|next| {
                (
                    project.journal_target(&next),
                    next,
                    prepared.keys,
                    prepared.input,
                    prepared.group,
                )
            });
            (staged, prepared.changes)
        };
        if let Some((journal, next, keys, input, group)) = staged {
            journal.write(&next)?; // No state/read/frame lock is held during disk IO.
            let obsolete = h
                .inner
                .write()
                .map_err(|_| Error::new(99, "Poisoned project"))?
                .commit_apply(next, keys, input, group);
            drop(obsolete);
        }
        if !out.is_null() {
            json_output(out, &cs)?;
        }
        Ok(())
    })
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_undo(p: *mut YcProject, out: *mut u8) -> i32 {
    boundary(|| history(p, out, false))
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_redo(p: *mut YcProject, out: *mut u8) -> i32 {
    boundary(|| history(p, out, true))
}
unsafe fn history(p: *mut YcProject, out: *mut u8, redo: bool) -> Result<()> {
    if out.is_null() {
        return Err(Error::new(1, "Null history output"));
    }
    let h = handle(p)?;
    let _writer = h
        .writer
        .lock()
        .map_err(|_| Error::new(99, "Poisoned writer"))?;
    let staged = {
        let project = h
            .inner
            .read()
            .map_err(|_| Error::new(99, "Poisoned project"))?;
        let stack = if redo { &project.redo } else { &project.undo };
        stack.last().cloned().map(|next| {
            let keys = project.key_overlay_index.for_clips(&next.timeline.clips);
            let input = project.input_for(&next);
            (project.journal_target(&next), next, keys, input)
        })
    };
    let Some((journal, next, keys, input)) = staged else {
        return output(out, 0);
    };
    journal.write(&next)?;
    let (did, obsolete) = {
        let mut project = h
            .inner
            .write()
            .map_err(|_| Error::new(99, "Poisoned project"))?;
        if redo {
            project.commit_redo(keys, input)
        } else {
            project.commit_undo(keys, input)
        }
    };
    drop(obsolete); // Release retired positional indexes outside the project lock.
    output(out, did as u8)
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_can_undo(p: *const YcProject) -> u8 {
    guarded(0, || {
        handle(p)
            .ok()
            .and_then(|h| h.inner.read().ok())
            .is_some_and(|p| !p.undo.is_empty()) as u8
    })
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_can_redo(p: *const YcProject) -> u8 {
    guarded(0, || {
        handle(p)
            .ok()
            .and_then(|h| h.inner.read().ok())
            .is_some_and(|p| !p.redo.is_empty()) as u8
    })
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_timeline_duration(p: *const YcProject, out: *mut i64) -> i32 {
    boundary(|| {
        output(
            out,
            crate::time::duration(
                &handle(p)?
                    .inner
                    .read()
                    .map_err(|_| Error::new(99, "Poisoned project"))?
                    .data
                    .timeline
                    .clips,
            ),
        )
    })
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_frame_at(
    p: *const YcProject,
    tl_ns: i64,
    out: *mut crate::frame::Frame,
) -> i32 {
    boundary(|| {
        output(
            out,
            handle(p)?
                .inner
                .read()
                .map_err(|_| Error::new(99, "Poisoned project"))?
                .frame(tl_ns)?,
        )
    })
}
/// # Safety
/// `p` must be a live handle and `out` writable and aligned for FrameExtras.
/// The handle must not race free. Null pointers return an argument error.
#[no_mangle]
pub unsafe extern "C" fn yc_frame_extras_at(
    p: *const YcProject,
    tl_ns: i64,
    out: *mut crate::layers::FrameExtras,
) -> i32 {
    boundary(|| {
        output(
            out,
            handle(p)?
                .inner
                .read()
                .map_err(|_| Error::new(99, "Poisoned project"))?
                .frame_extras(tl_ns)?,
        )
    })
}
/// # Safety
/// `p` must be live and `out` writable/aligned for FrameMaskEffects, without a
/// racing free. Null pointers return an argument error; errors preserve output.
#[no_mangle]
pub unsafe extern "C" fn yc_frame_mask_effects_at(
    p: *const YcProject,
    tl_ns: i64,
    out: *mut crate::layers::FrameMaskEffects,
) -> i32 {
    boundary(|| {
        output(
            out,
            handle(p)?
                .inner
                .read()
                .map_err(|_| Error::new(99, "Poisoned project"))?
                .frame_mask_effects(tl_ns)?,
        )
    })
}
/// # Safety
/// `p` must be live and `out` writable/aligned for FrameMotion, without a racing
/// free. Null pointers return an argument error. Errors do not touch the output.
#[no_mangle]
pub unsafe extern "C" fn yc_frame_motion_at(
    p: *const YcProject,
    tl_ns: i64,
    out: *mut crate::motion::FrameMotion,
) -> i32 {
    boundary(|| {
        output(
            out,
            handle(p)?
                .inner
                .read()
                .map_err(|_| Error::new(99, "Poisoned project"))?
                .frame_motion(tl_ns)?,
        )
    })
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_query(
    p: *const YcProject,
    query: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    boundary(|| {
        output(out, std::ptr::null_mut())?;
        let value = handle(p)?
            .inner
            .read()
            .map_err(|_| Error::new(99, "Poisoned project"))?
            .query(&serde_json::from_str(utf8(query)?)?)?;
        json_output(out, &value)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        model::Zoom,
        project::{journal_test_hook, tests::Fixture},
    };
    use std::{
        collections::BTreeSet,
        sync::{mpsc, Arc},
        thread,
        time::Duration,
    };

    #[test]
    fn every_ffi_entry_point_contains_a_top_level_panic() {
        let fixture = Fixture::new();
        let p = Box::into_raw(Box::new(YcProject::new(
            Project::create(&fixture.0).unwrap(),
        )));
        let path = CString::new(fixture.0.to_str().unwrap()).unwrap();
        let command = CString::new(r#"{"op":"set","path":"notes","value":"test"}"#).unwrap();
        let query = CString::new(r#"{"q":"duration"}"#).unwrap();
        let mut text = std::ptr::null_mut();
        let mut copy = std::ptr::null_mut();
        let mut did = 0;
        let mut duration = 0;
        let mut frame = crate::frame::Frame::default();
        let mut extras = crate::layers::FrameExtras::default();
        let mut masks = crate::layers::FrameMaskEffects::default();
        let mut motion = crate::motion::FrameMotion::default();
        let mut covered = BTreeSet::new();
        macro_rules! probe {
            ($name:ident, $call:expr, $expected:expr) => {{
                INJECT_PANIC.with(|f| f.set(true));
                assert_eq!($call, $expected, stringify!($name));
                assert!(
                    !INJECT_PANIC.with(|f| f.get()),
                    "Missing boundary: {}",
                    stringify!($name)
                );
                covered.insert(stringify!($name));
            }};
        }
        macro_rules! probe_void {
            ($name:ident, $call:expr) => {{
                INJECT_PANIC.with(|f| f.set(true));
                $call;
                assert!(
                    !INJECT_PANIC.with(|f| f.get()),
                    "Missing boundary: {}",
                    stringify!($name)
                );
                covered.insert(stringify!($name));
            }};
        }
        unsafe {
            probe!(yc_abi_version, yc_abi_version(), 0);
            INJECT_PANIC.with(|f| f.set(true));
            assert_eq!(
                CStr::from_ptr(yc_last_error()).to_bytes(),
                b"Rust core panic"
            );
            assert!(!INJECT_PANIC.with(|f| f.get()));
            covered.insert("yc_last_error");
            probe!(
                yc_project_create,
                yc_project_create(path.as_ptr(), &mut copy),
                99
            );
            probe!(
                yc_project_open,
                yc_project_open(path.as_ptr(), &mut copy),
                99
            );
            probe!(yc_project_save, yc_project_save(p, path.as_ptr()), 99);
            probe!(yc_project_to_json, yc_project_to_json(p, &mut text), 99);
            probe!(yc_project_clone, yc_project_clone(p, &mut copy), 99);
            probe!(
                yc_mcp_handle,
                yc_mcp_handle(p, command.as_ptr(), &mut text),
                99
            );
            probe!(yc_mcp_catalog, yc_mcp_catalog(&mut text), 99);
            probe!(
                yc_agent_doc,
                yc_agent_doc(c"playbook".as_ptr(), &mut text),
                99
            );
            probe!(
                yc_agent_docs_rpc,
                yc_agent_docs_rpc(command.as_ptr(), &mut text),
                99
            );
            probe!(yc_apply, yc_apply(p, command.as_ptr(), &mut text), 99);
            probe!(yc_undo, yc_undo(p, &mut did), 99);
            probe!(yc_redo, yc_redo(p, &mut did), 99);
            probe!(yc_can_undo, yc_can_undo(p), 0);
            probe!(yc_can_redo, yc_can_redo(p), 0);
            probe!(
                yc_timeline_duration,
                yc_timeline_duration(p, &mut duration),
                99
            );
            probe!(yc_frame_at, yc_frame_at(p, 0, &mut frame), 99);
            probe!(
                yc_frame_extras_at,
                yc_frame_extras_at(p, 0, &mut extras),
                99
            );
            probe!(
                yc_frame_mask_effects_at,
                yc_frame_mask_effects_at(p, 0, &mut masks),
                99
            );
            probe!(
                yc_frame_motion_at,
                yc_frame_motion_at(p, 0, &mut motion),
                99
            );
            probe!(yc_query, yc_query(p, query.as_ptr(), &mut text), 99);
            let owned = CString::new("owned result").unwrap().into_raw();
            probe_void!(yc_string_free, yc_string_free(owned));
            yc_string_free(owned); // injection happens before ownership is consumed
            probe_void!(yc_project_free, yc_project_free(p));
            assert_eq!(
                CStr::from_ptr(yc_last_error()).to_bytes(),
                b"Rust core panic"
            );
            yc_project_free(p);
        }
        let declared: BTreeSet<_> = include_str!("../include/yapcam_core.h")
            .lines()
            .filter(|line| !line.trim_start().starts_with("//"))
            .filter_map(|line| line.split_once("yc_").map(|(_, tail)| tail))
            .filter_map(|tail| tail.split_once('(').map(|(name, _)| format!("yc_{name}")))
            .collect();
        let covered: BTreeSet<_> = covered.into_iter().map(str::to_owned).collect();
        assert!(declared.is_subset(&covered));
        // Lead owns the header declaration for the additive mask companion.
        // Still require panic coverage for every Rust export below.
        assert!(covered
            .difference(&declared)
            .all(|name| name == "yc_frame_mask_effects_at"));
        let exported: BTreeSet<_> = include_str!("ffi.rs")
            .lines()
            .filter(|line| line.trim_start().starts_with("pub "))
            .filter_map(|line| line.split_once("extern \"C\" fn ").map(|(_, tail)| tail))
            .filter_map(|tail| tail.split_once('(').map(|(name, _)| name.to_owned()))
            .collect();
        assert_eq!(
            covered, exported,
            "Every Rust C export requires the panic regression"
        );
    }

    #[test]
    fn frames_continue_while_apply_undo_redo_and_save_are_paused_on_disk() {
        let fixture = Fixture::new();
        let mut project = Project::create(&fixture.0).unwrap();
        project.data.canvas.crop = [0.1, 0.1, 0.7, 0.7];
        project.data.zooms.push(Zoom {
            style: "classic".into(),
            lens: Default::default(),
            id: "crop".into(),
            tl_start_ns: 0,
            tl_end_ns: 1_000_000_000,
            mode: "auto".into(),
            target: [0.5, 0.5],
            scale: 2.0,
            ease_in_ns: 300_000_000,
            ease_out_ns: 300_000_000,
            enabled: true,
        });
        let h = Arc::new(YcProject::new(project));
        for operation in ["apply", "undo", "redo", "save"] {
            let before = h.inner.read().unwrap().data.clone();
            let (entered_tx, entered_rx) = mpsc::channel();
            let (release_tx, release_rx) = mpsc::channel();
            let writer_h = h.clone();
            let package = fixture.0.clone();
            let writer = thread::spawn(move || {
                journal_test_hook::set(move || {
                    entered_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                });
                let p = Arc::as_ptr(&writer_h).cast_mut();
                let mut did = 0;
                unsafe {
                    match operation {
                        "apply" => {
                            let cmd = CString::new(
                                r#"{"op":"set","path":"notes","value":"durable edit"}"#,
                            )
                            .unwrap();
                            yc_apply(p, cmd.as_ptr(), std::ptr::null_mut())
                        }
                        "undo" => yc_undo(p, &mut did),
                        "redo" => yc_redo(p, &mut did),
                        _ => yc_project_save(
                            p,
                            CString::new(package.to_str().unwrap()).unwrap().as_ptr(),
                        ),
                    }
                }
            });
            let entered = entered_rx.recv_timeout(Duration::from_secs(2));
            let reader_h = h.clone();
            let (frames_tx, frames_rx) = mpsc::channel();
            let reader = thread::spawn(move || {
                let mut f = crate::frame::Frame::default();
                let mut extras = crate::layers::FrameExtras::default();
                let mut motion = crate::motion::FrameMotion::default();
                let allocations = crate::allocation_test::count(|| {
                    for _ in 0..100 {
                        assert_eq!(unsafe { yc_frame_at(Arc::as_ptr(&reader_h), 0, &mut f) }, 0);
                        assert_eq!(
                            unsafe { yc_frame_extras_at(Arc::as_ptr(&reader_h), 0, &mut extras) },
                            0
                        );
                        assert_eq!(
                            unsafe { yc_frame_motion_at(Arc::as_ptr(&reader_h), 1, &mut motion) },
                            0
                        );
                    }
                });
                frames_tx.send((allocations, f.screen_crop)).unwrap();
            });
            let frames = frames_rx.recv_timeout(Duration::from_secs(2));
            let unchanged = h
                .inner
                .try_read()
                .map(|state| state.data == before)
                .unwrap_or(false);
            let gated = matches!(
                h.writer.try_lock(),
                Err(std::sync::TryLockError::WouldBlock)
            );
            // Always release/join before asserting, so a failing regression never
            // strands a paused disk writer or a reader blocked by the old design.
            let _ = release_tx.send(());
            let status = writer.join().unwrap();
            reader.join().unwrap();
            assert!(entered.is_ok(), "{operation} did not reach disk stage");
            let (allocations, crop) = frames.expect("frame_at waited for journal/save IO");
            assert_eq!(allocations, 0);
            assert_eq!((crop.x, crop.y), (0.1, 0.1));
            assert!(unchanged, "uncommitted edit became visible during IO");
            assert!(gated, "disk work was not protected from concurrent writers");
            assert_eq!(status, 0);
        }
        assert_eq!(h.inner.read().unwrap().data.notes, "durable edit");
        assert_eq!(
            Project::open(&fixture.0).unwrap().data.notes,
            "durable edit"
        );
    }

    #[test]
    fn failed_ffi_journal_leaves_apply_undo_redo_state_and_history_untouched() {
        let fixture = Fixture::new();
        let h = YcProject::new(Project::create(&fixture.0).unwrap());
        let p = (&h as *const YcProject).cast_mut();
        let cmd = CString::new(r#"{"op":"set","path":"notes","value":"committed"}"#).unwrap();
        let autosave = fixture.0.join("autosave");
        std::fs::write(&autosave, "not a directory").unwrap();
        let before = h.inner.read().unwrap().data.clone();
        assert_eq!(
            unsafe { yc_apply(p, cmd.as_ptr(), std::ptr::null_mut()) },
            4
        );
        assert_eq!(h.inner.read().unwrap().data, before);
        assert_eq!(unsafe { yc_can_undo(p) }, 0);
        std::fs::remove_file(&autosave).unwrap();
        assert_eq!(
            unsafe { yc_apply(p, cmd.as_ptr(), std::ptr::null_mut()) },
            0
        );
        for redo in [false, true] {
            std::fs::remove_dir_all(&autosave).unwrap();
            std::fs::write(&autosave, "not a directory").unwrap();
            let before = h.inner.read().unwrap().data.clone();
            let mut did = 42;
            let call = |did| unsafe {
                if redo {
                    yc_redo(p, did)
                } else {
                    yc_undo(p, did)
                }
            };
            assert_eq!(call(&mut did), 4);
            assert_eq!(did, 42);
            assert_eq!(h.inner.read().unwrap().data, before);
            assert_eq!(
                unsafe {
                    if redo {
                        yc_can_redo(p)
                    } else {
                        yc_can_undo(p)
                    }
                },
                1
            );
            std::fs::remove_file(&autosave).unwrap();
            assert_eq!(call(&mut did), 0);
            assert_eq!(did, 1);
        }
    }
    #[test]
    fn concurrent_writers_keep_durable_order_and_complete_undo_redo_history() {
        let fixture = Fixture::new();
        let h = Arc::new(YcProject::new(Project::create(&fixture.0).unwrap()));
        let before = h.inner.read().unwrap().data.clone();
        let start = Arc::new(std::sync::Barrier::new(5));
        let writers: Vec<_> = (0..4)
            .map(|worker| {
                let h = h.clone();
                let start = start.clone();
                thread::spawn(move || {
                    start.wait();
                    for edit in 0..8 {
                        let cmd = CString::new(format!(
                            r#"{{"op":"set","path":"notes","value":"writer-{worker}-{edit}"}}"#
                        ))
                        .unwrap();
                        assert_eq!(
                            unsafe {
                                yc_apply(
                                    Arc::as_ptr(&h).cast_mut(),
                                    cmd.as_ptr(),
                                    std::ptr::null_mut(),
                                )
                            },
                            0
                        );
                    }
                })
            })
            .collect();
        start.wait();
        let mut frame = crate::frame::Frame::default();
        for _ in 0..1000 {
            assert_eq!(unsafe { yc_frame_at(Arc::as_ptr(&h), 0, &mut frame) }, 0);
        }
        for writer in writers {
            writer.join().unwrap();
        }
        let after = h.inner.read().unwrap().data.clone();
        assert_eq!(h.inner.read().unwrap().undo.len(), 32);
        assert_eq!(Project::open(&fixture.0).unwrap().data, after);
        let mut did = 0;
        for _ in 0..32 {
            assert_eq!(unsafe { yc_undo(Arc::as_ptr(&h).cast_mut(), &mut did) }, 0);
            assert_eq!(did, 1);
        }
        assert_eq!(h.inner.read().unwrap().data, before);
        assert_eq!(Project::open(&fixture.0).unwrap().data, before);
        for _ in 0..32 {
            assert_eq!(unsafe { yc_redo(Arc::as_ptr(&h).cast_mut(), &mut did) }, 0);
            assert_eq!(did, 1);
        }
        assert_eq!(h.inner.read().unwrap().data, after);
        assert_eq!(Project::open(&fixture.0).unwrap().data, after);
    }
    #[test]
    fn panic_during_unlocked_journal_io_does_not_poison_frame_reads() {
        let fixture = Fixture::new();
        let h = YcProject::new(Project::create(&fixture.0).unwrap());
        let before = h.inner.read().unwrap().data.clone();
        journal_test_hook::set(|| panic!("disk-stage panic"));
        let cmd = CString::new(r#"{"op":"set","path":"notes","value":"not published"}"#).unwrap();
        assert_eq!(
            unsafe {
                yc_apply(
                    (&h as *const YcProject).cast_mut(),
                    cmd.as_ptr(),
                    std::ptr::null_mut(),
                )
            },
            99
        );
        assert_eq!(h.inner.read().unwrap().data, before);
        let mut f = crate::frame::Frame::default();
        assert_eq!(unsafe { yc_frame_at(&h, 0, &mut f) }, 0);
        assert_eq!(unsafe { yc_can_undo(&h) }, 0);
    }
}

/// Dispatch one MCP request against the live project. Transport owns initialization state.
/// # Safety
/// Same pointer and ownership requirements as yc_apply. Free output with yc_string_free.
#[no_mangle]
pub unsafe extern "C" fn yc_mcp_handle(
    p: *mut YcProject,
    request: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    boundary(|| {
        output(out, std::ptr::null_mut())?;
        let request = serde_json::from_str(utf8(request)?).unwrap_or(serde_json::Value::Null);
        let h = handle(p)?;
        let _writer = h
            .writer
            .lock()
            .map_err(|_| Error::new(99, "Poisoned writer"))?;
        let mut project = h
            .inner
            .write()
            .map_err(|_| Error::new(99, "Poisoned project"))?;
        let response = crate::mcp::Server {
            project: &mut project,
            initialized: true,
        }
        .rpc(request);
        json_output(out, &response)
    })
}

/// # Safety
/// Output must be writable; free the returned string with yc_string_free.
#[no_mangle]
pub unsafe extern "C" fn yc_mcp_catalog(out: *mut *mut c_char) -> i32 {
    boundary(|| {
        output(out, std::ptr::null_mut())?;
        json_output(out, &crate::mcp::catalog())
    })
}

/// One agent doc by name (`playbook`, `yapcam://craft`, `examples/tighten`, `chat`, `instructions`, `app_instructions`)
/// as markdown text. Unknown names return status 1.
/// # Safety
/// `name` must be a valid C string; free the output with yc_string_free.
#[no_mangle]
pub unsafe extern "C" fn yc_agent_doc(name: *const c_char, out: *mut *mut c_char) -> i32 {
    boundary(|| {
        output(out, std::ptr::null_mut())?;
        let name = utf8(name)?;
        let text = if name == "app_instructions" {
            format!(
                "{}\n{}",
                crate::agent_docs::INSTRUCTIONS,
                crate::agent_docs::APP_INSTRUCTIONS
            )
        } else {
            crate::agent_docs::doc(name)
                .ok_or_else(|| Error::new(1, "Unknown agent doc"))?
                .to_string()
        };
        let s = CString::new(text).map_err(|_| Error::new(99, "Invalid doc string"))?;
        out.write(s.into_raw());
        Ok(())
    })
}

/// Answer an MCP resources/* or prompts/* request (the agent docs). Writes the JSON-RPC response, or `null` when
/// the method is not one of those.
/// # Safety
/// `request` must be a valid C string; free the output with yc_string_free.
#[no_mangle]
pub unsafe extern "C" fn yc_agent_docs_rpc(request: *const c_char, out: *mut *mut c_char) -> i32 {
    boundary(|| {
        output(out, std::ptr::null_mut())?;
        let request = serde_json::from_str(utf8(request)?).unwrap_or(serde_json::Value::Null);
        json_output(out, &crate::agent_docs::rpc(&request))
    })
}
