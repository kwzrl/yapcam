//! C ABI scaffold. Functions not yet implemented return YC_ERR_STATE with an
//! explicit error; see docs/STATUS.md for ownership (Media/Timeline team).

use std::cell::RefCell;
use std::ffi::{c_char, CString};

pub const YC_ABI_VERSION: u32 = 1;

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
