// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! TSFN infrastructure for Huawei Account operations.
//!
//! Three TSFNs are created during ability init (in `render/xcomponent.rs`):
//! - `ACCOUNT_LOGIN_TSFN`: calls `helper.accountLogin()` → `Promise<AccountInfo>`
//! - `ACCOUNT_SILENT_LOGIN_TSFN`: calls `helper.accountSilentLogin()` → `Promise<AccountInfo>`
//! - `ACCOUNT_LOGOUT_TSFN`: calls `helper.accountLogout()` → `Promise<void>`

use std::sync::{Arc, LazyLock, RwLock};

use napi_ohos::{
    bindgen_prelude::{Function, JsObjectValue, Unknown},
    threadsafe_function::ThreadsafeFunction,
    Env, Error, Result, Status,
};

use crate::get_main_thread_env;

/// Shared TSFN type for all account operations: no input args, returns an
/// `Unknown<'static>` (the ArkTS Promise) which the caller resolves on the JS
/// thread via `call_with_return_value`.
pub type AccountTsfn = ThreadsafeFunction<(), Unknown<'static>, (), Status, false>;

type AccountTsfnStore = LazyLock<RwLock<Option<Arc<AccountTsfn>>>>;

// ─── accountLogin TSFN ─────────────────────────────────────────────────────

type AccountLoginCall<'a> = Function<'a, (), Unknown<'a>>;

pub(crate) static ACCOUNT_LOGIN_TSFN: AccountTsfnStore = LazyLock::new(|| RwLock::new(None));

/// Create the TSFN that calls `helper.accountLogin()`.
/// Must be called after `set_main_thread_env`.
pub fn create_account_login_tsfn(env: &Env) -> Result<Arc<AccountTsfn>> {
    let callback: Function<'_, (), Unknown<'_>> =
        env.create_function_from_closure("account_login_callback", move |_ctx| {
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let fn_ref =
                        helper_obj.get_named_property::<AccountLoginCall<'_>>("accountLogin")?;
                    return fn_ref.call(());
                }
            }
            Err(Error::from_reason(
                "Failed to call helper.accountLogin from main thread",
            ))
        })?;

    let tsfn = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);
    {
        let mut guard = (*ACCOUNT_LOGIN_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write ACCOUNT_LOGIN_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }
    Ok(tsfn_arc)
}

pub fn get_account_login_tsfn() -> Option<Arc<AccountTsfn>> {
    (*ACCOUNT_LOGIN_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}

// ─── accountSilentLogin TSFN ───────────────────────────────────────────────

type AccountSilentLoginCall<'a> = Function<'a, (), Unknown<'a>>;

pub(crate) static ACCOUNT_SILENT_LOGIN_TSFN: AccountTsfnStore = LazyLock::new(|| RwLock::new(None));

/// Create the TSFN that calls `helper.accountSilentLogin()`.
/// Must be called after `set_main_thread_env`.
pub fn create_account_silent_login_tsfn(env: &Env) -> Result<Arc<AccountTsfn>> {
    let callback: Function<'_, (), Unknown<'_>> =
        env.create_function_from_closure("account_silent_login_callback", move |_ctx| {
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let fn_ref = helper_obj
                        .get_named_property::<AccountSilentLoginCall<'_>>("accountSilentLogin")?;
                    return fn_ref.call(());
                }
            }
            Err(Error::from_reason(
                "Failed to call helper.accountSilentLogin from main thread",
            ))
        })?;

    let tsfn = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);
    {
        let mut guard = (*ACCOUNT_SILENT_LOGIN_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write ACCOUNT_SILENT_LOGIN_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }
    Ok(tsfn_arc)
}

pub fn get_account_silent_login_tsfn() -> Option<Arc<AccountTsfn>> {
    (*ACCOUNT_SILENT_LOGIN_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}

// ─── accountLogout TSFN ────────────────────────────────────────────────────

type AccountLogoutCall<'a> = Function<'a, (), Unknown<'a>>;

pub(crate) static ACCOUNT_LOGOUT_TSFN: AccountTsfnStore = LazyLock::new(|| RwLock::new(None));

/// Create the TSFN that calls `helper.accountLogout()`.
/// Must be called after `set_main_thread_env`.
pub fn create_account_logout_tsfn(env: &Env) -> Result<Arc<AccountTsfn>> {
    let callback: Function<'_, (), Unknown<'_>> =
        env.create_function_from_closure("account_logout_callback", move |_ctx| {
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let fn_ref =
                        helper_obj.get_named_property::<AccountLogoutCall<'_>>("accountLogout")?;
                    return fn_ref.call(());
                }
            }
            Err(Error::from_reason(
                "Failed to call helper.accountLogout from main thread",
            ))
        })?;

    let tsfn = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);
    {
        let mut guard = (*ACCOUNT_LOGOUT_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write ACCOUNT_LOGOUT_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }
    Ok(tsfn_arc)
}

pub fn get_account_logout_tsfn() -> Option<Arc<AccountTsfn>> {
    (*ACCOUNT_LOGOUT_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}
