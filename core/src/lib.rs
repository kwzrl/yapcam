//! Yapcam core: project model, time model, edits and frame evaluation.
//! The C ABI lives in `ffi.rs` and mirrors `include/yapcam_core.h`.

pub mod commands;
pub mod ffi;
pub mod frame;
pub mod layers;
pub mod model;
pub mod project;
pub mod query;
pub mod time;

#[cfg(test)]
pub(crate) mod allocation_test {
    use std::{
        alloc::{GlobalAlloc, Layout, System},
        cell::Cell,
    };
    thread_local! { static TRACK: Cell<bool> = const {Cell::new(false)}; static COUNT: Cell<usize> = const {Cell::new(0)}; }
    struct Counting;
    unsafe impl GlobalAlloc for Counting {
        unsafe fn alloc(&self, l: Layout) -> *mut u8 {
            let _ = TRACK.try_with(|t| {
                if t.get() {
                    let _ = COUNT.try_with(|c| c.set(c.get() + 1));
                }
            });
            System.alloc(l)
        }
        unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
            System.dealloc(p, l);
        }
        unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
            let _ = TRACK.try_with(|t| {
                if t.get() {
                    let _ = COUNT.try_with(|c| c.set(c.get() + 1));
                }
            });
            System.realloc(p, l, n)
        }
    }
    #[global_allocator]
    static ALLOCATOR: Counting = Counting;
    pub fn count(f: impl FnOnce()) -> usize {
        COUNT.with(|c| c.set(0));
        TRACK.with(|t| t.set(true));
        f();
        TRACK.with(|t| t.set(false));
        COUNT.with(Cell::get)
    }
}
pub mod auto;
pub mod input;
pub mod spring;

pub mod effects;

pub mod motion;
