// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! TSFN infrastructure for opener operations (open_with_system + reveal_in_dir).
//!
//! Two TSFNs are created during ability init (in `render/xcomponent.rs`):
//! - `OPENER_OPEN_WITH_SYSTEM_TSFN`: calls `helper.openWithSystem(uri)` → `Promise<void>`
//! - `OPENER_REVEAL_IN_DIR_TSFN`: calls `helper.revealInDir(dirUri)` → `Promise<void>`

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, RwLock};

use napi_ohos::{
    bindgen_prelude::{FnArgs, Function, JsObjectValue, Unknown},
    threadsafe_function::ThreadsafeFunction,
    Env, Error, Result, Status,
};

use crate::get_main_thread_env;

// ─── openWithSystem TSFN ───────────────────────────────────────────────────

type OpenWithSystemCall<'a> = Function<'a, String, Unknown<'a>>;

pub type OpenWithSystemTsfn =
    ThreadsafeFunction<FnArgs<(String,)>, Unknown<'static>, FnArgs<(String,)>, Status, false>;

type OpenWithSystemTsfnStore = LazyLock<RwLock<Option<Arc<OpenWithSystemTsfn>>>>;

pub(crate) static OPENER_OPEN_WITH_SYSTEM_TSFN: OpenWithSystemTsfnStore =
    LazyLock::new(|| RwLock::new(None));

static OPENER_OPEN_WITH_SYSTEM_INITIALIZED: AtomicBool = AtomicBool::new(false);

/// Create the TSFN that calls `helper.openWithSystem(uri)`.
/// Must be called after `set_main_thread_env`.
pub fn create_open_with_system_tsfn(env: &Env) -> Result<Arc<OpenWithSystemTsfn>> {
    if OPENER_OPEN_WITH_SYSTEM_INITIALIZED.load(Ordering::Acquire) {
        return get_open_with_system_tsfn().ok_or_else(|| {
            Error::from_reason("OPENER_OPEN_WITH_SYSTEM_TSFN flag set but TSFN is None")
        });
    }
    let callback: Function<'_, FnArgs<(String,)>, Unknown<'_>> =
        env.create_function_from_closure("opener_open_with_system_callback", move |ctx| {
            let uri = ctx.first_arg::<String>()?;
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let fn_ref = helper_obj
                        .get_named_property::<OpenWithSystemCall<'_>>("openWithSystem")?;
                    return fn_ref.call(uri);
                }
            }
            Err(Error::from_reason(
                "Failed to call helper.openWithSystem from main thread",
            ))
        })?;

    let tsfn = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);
    {
        let mut guard = (*OPENER_OPEN_WITH_SYSTEM_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write OPENER_OPEN_WITH_SYSTEM_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }
    OPENER_OPEN_WITH_SYSTEM_INITIALIZED.store(true, Ordering::Release);
    Ok(tsfn_arc)
}

pub fn get_open_with_system_tsfn() -> Option<Arc<OpenWithSystemTsfn>> {
    (*OPENER_OPEN_WITH_SYSTEM_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}

// ─── revealInDir TSFN ──────────────────────────────────────────────────────

type RevealInDirCall<'a> = Function<'a, String, Unknown<'a>>;

pub type RevealInDirTsfn =
    ThreadsafeFunction<FnArgs<(String,)>, Unknown<'static>, FnArgs<(String,)>, Status, false>;

type RevealInDirTsfnStore = LazyLock<RwLock<Option<Arc<RevealInDirTsfn>>>>;

pub(crate) static OPENER_REVEAL_IN_DIR_TSFN: RevealInDirTsfnStore =
    LazyLock::new(|| RwLock::new(None));

static OPENER_REVEAL_IN_DIR_INITIALIZED: AtomicBool = AtomicBool::new(false);

/// Create the TSFN that calls `helper.revealInDir(dirUri)`.
/// Must be called after `set_main_thread_env`.
pub fn create_reveal_in_dir_tsfn(env: &Env) -> Result<Arc<RevealInDirTsfn>> {
    if OPENER_REVEAL_IN_DIR_INITIALIZED.load(Ordering::Acquire) {
        return get_reveal_in_dir_tsfn()
            .ok_or_else(|| Error::from_reason("OPENER_REVEAL_IN_DIR_TSFN flag set but TSFN is None"));
    }
    let callback: Function<'_, FnArgs<(String,)>, Unknown<'_>> =
        env.create_function_from_closure("opener_reveal_in_dir_callback", move |ctx| {
            let dir_uri = ctx.first_arg::<String>()?;
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let fn_ref = helper_obj
                        .get_named_property::<RevealInDirCall<'_>>("revealInDir")?;
                    return fn_ref.call(dir_uri);
                }
            }
            Err(Error::from_reason(
                "Failed to call helper.revealInDir from main thread",
            ))
        })?;

    let tsfn = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);
    {
        let mut guard = (*OPENER_REVEAL_IN_DIR_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write OPENER_REVEAL_IN_DIR_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }
    OPENER_REVEAL_IN_DIR_INITIALIZED.store(true, Ordering::Release);
    Ok(tsfn_arc)
}

pub fn get_reveal_in_dir_tsfn() -> Option<Arc<RevealInDirTsfn>> {
    (*OPENER_REVEAL_IN_DIR_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}
