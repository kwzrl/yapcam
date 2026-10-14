//! C ABI implementation matching the Lead-owned header. Reads share a lock;
//! edits serialize. Error handling contains panics at the foreign boundary.

use std::cell::RefCell;
use std::ffi::{c_char, CString};

pub const YC_ABI_VERSION: u32 = 2;

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

pub(crate) fn set_last_error(message: &str) {
    let text = CString::new(message.replace('\0', " ")).unwrap_or_default();
    LAST_ERROR.with(|e| *e.borrow_mut() = text);
}

#[no_mangle]
pub extern "C" fn yc_abi_version() -> u32 {
    YC_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn yc_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

/// # Safety
/// `s` must be a string returned by this library, or null.
#[no_mangle]
pub unsafe extern "C" fn yc_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

use crate::project::{Error, Project, Result};
use std::{ffi::CStr, path::Path, sync::RwLock};

/// All non-null C pointers must be live, correctly aligned, and have the stated
/// access for the call duration. Handle free must not race any other call. Returned
/// strings/handles have one owner, released by the corresponding free function.
pub struct YcProject {
    pub(crate) inner: RwLock<Project>,
}
fn boundary(f: impl FnOnce() -> Result<()> + std::panic::UnwindSafe) -> i32 {
    match std::panic::catch_unwind(f) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            set_last_error(&e.message);
            e.status
        }
        Err(_) => {
            set_last_error("Rust core panic");
            99
        }
    }
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
    output(
        out,
        Box::into_raw(Box::new(YcProject {
            inner: RwLock::new(p),
        })),
    )
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
        handle(p)?
            .inner
            .read()
            .map_err(|_| Error::new(99, "Poisoned project"))?
            .save(Path::new(utf8(path)?))
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
        output(
            out,
            Box::into_raw(Box::new(YcProject {
                inner: RwLock::new(copy),
            })),
        )
    })
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_project_free(p: *mut YcProject) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
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
        let cs = handle(p)?
            .inner
            .write()
            .map_err(|_| Error::new(99, "Poisoned project"))?
            .apply(&command)?;
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
    boundary(|| {
        if out.is_null() {
            return Err(Error::new(1, "Null undo output"));
        }
        output(
            out,
            handle(p)?
                .inner
                .write()
                .map_err(|_| Error::new(99, "Poisoned project"))?
                .undo()? as u8,
        )
    })
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_redo(p: *mut YcProject, out: *mut u8) -> i32 {
    boundary(|| {
        if out.is_null() {
            return Err(Error::new(1, "Null redo output"));
        }
        output(
            out,
            handle(p)?
                .inner
                .write()
                .map_err(|_| Error::new(99, "Poisoned project"))?
                .redo()? as u8,
        )
    })
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_can_undo(p: *const YcProject) -> u8 {
    handle(p)
        .ok()
        .and_then(|h| h.inner.read().ok())
        .is_some_and(|p| !p.undo.is_empty()) as u8
}
/// # Safety
/// Non-null arguments must be valid for the call, outputs writable, and strings
/// NUL-terminated UTF-8. Handles must belong to this library and must not race free.
/// Returned strings/handles transfer ownership; free them with this library.
#[no_mangle]
pub unsafe extern "C" fn yc_can_redo(p: *const YcProject) -> u8 {
    handle(p)
        .ok()
        .and_then(|h| h.inner.read().ok())
        .is_some_and(|p| !p.redo.is_empty()) as u8
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
