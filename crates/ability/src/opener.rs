// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! Opener functionality for OpenHarmony.
//!
//! The ArkTS side (`ArkHelper.ets`) provides:
//! - `openWithSystem(uri)` — starts an ability with `ohos.want.action.viewData`
//!   to open a URI with the system-default handler.
//! - `revealInDir(dirUri)` — starts an ability with `ohos.want.action.viewData`
//!   for a directory URI to reveal it in the file manager.
//!
//! The TSFN infrastructure (in `helper/opener.rs`) bridges ArkTS Promises to Rust Futures.
//!
//! OHOS platform constraints:
//! - `open_with_system` / `reveal_in_dir` rely on `context.startAbility` with a viewData Want.
//! - The ArkTS methods intentionally do NOT catch — rejections propagate to Rust's
//!   `promise.catch` so the error message is surfaced to the caller.

use std::{cell::Cell, rc::Rc};

use futures_channel::oneshot;
use napi_ohos::{
    bindgen_prelude::{CallbackContext, FnArgs, PromiseRaw, Unknown},
    threadsafe_function::ThreadsafeFunctionCallMode,
    Error, JsValue, Result, Status, ValueType,
};
use tokio::time::{timeout, Duration};

use crate::helper::{get_open_with_system_tsfn, get_reveal_in_dir_tsfn};

/// Open a URI with the system-default handler.
///
/// Bridges to ArkTS `helper.openWithSystem(uri)` which calls
/// `context.startAbility({ action: 'ohos.want.action.viewData', uri,
/// entities: ['entity.system.browsable'] })`.
pub async fn open_with_system(uri: String) -> Result<()> {
    let tsfn = get_open_with_system_tsfn()
        .ok_or_else(|| Error::from_reason("opener open_with_system TSFN not initialized"))?;

    let (tx, rx) = oneshot::channel::<std::result::Result<(), String>>();
    let tx_cell = Rc::new(Cell::new(Some(tx)));

    let status = tsfn.call_with_return_value(
        FnArgs { data: (uri,) },
        ThreadsafeFunctionCallMode::NonBlocking,
        move |result, _env| {
            match result {
                Ok(value) => { handle_void_promise(value, tx_cell.clone()); }
                Err(err) => { send_once(&tx_cell, Err(err.to_string())); }
            }
            Ok(())
        },
    );

    if status != Status::Ok {
        return Err(Error::from_reason(format!(
            "call openWithSystem TSFN failed: {:?}",
            status
        )));
    }

    // Timeout: 10s for open_with_system (ability launch may take time)
    let result = timeout(Duration::from_secs(10), rx)
        .await
        .map_err(|_| Error::from_reason("opener open_with_system timed out"))?
        .map_err(|_| Error::from_reason("opener open_with_system receiver dropped"))?;
    result.map_err(|msg| Error::from_reason(msg))
}

/// Reveal a directory URI in the system file manager.
///
/// Bridges to ArkTS `helper.revealInDir(dirUri)` which calls
/// `context.startAbility({ action: 'ohos.want.action.viewData', uri: dirUri })`.
pub async fn reveal_in_dir(dir_uri: String) -> Result<()> {
    let tsfn = get_reveal_in_dir_tsfn()
        .ok_or_else(|| Error::from_reason("opener reveal_in_dir TSFN not initialized"))?;

    let (tx, rx) = oneshot::channel::<std::result::Result<(), String>>();
    let tx_cell = Rc::new(Cell::new(Some(tx)));

    let status = tsfn.call_with_return_value(
        FnArgs { data: (dir_uri,) },
        ThreadsafeFunctionCallMode::NonBlocking,
        move |result, _env| {
            match result {
                Ok(value) => { handle_void_promise(value, tx_cell.clone()); }
                Err(err) => { send_once(&tx_cell, Err(err.to_string())); }
            }
            Ok(())
        },
    );

    if status != Status::Ok {
        return Err(Error::from_reason(format!(
            "call revealInDir TSFN failed: {:?}",
            status
        )));
    }

    // Timeout: 10s for reveal_in_dir (ability launch may take time)
    let result = timeout(Duration::from_secs(10), rx)
        .await
        .map_err(|_| Error::from_reason("opener reveal_in_dir timed out"))?
        .map_err(|_| Error::from_reason("opener reveal_in_dir receiver dropped"))?;
    result.map_err(|msg| Error::from_reason(msg))
}

// ── Helpers ──────────────────────────────────────────────────────────

fn send_once<T>(cell: &Rc<Cell<Option<oneshot::Sender<T>>>>, value: T) {
    if let Some(sender) = cell.replace(None) {
        let _ = sender.send(value);
    }
}

fn handle_void_promise(
    value: Unknown<'static>,
    tx: Rc<Cell<Option<oneshot::Sender<std::result::Result<(), String>>>>>,
) {
    // Validate type before unsafe cast (prevent UB on non-Promise values)
    let type_check = value.get_type();
    if !matches!(type_check, Ok(ValueType::Object)) {
        send_once(&tx, Err("expected Promise from ArkTS".to_string()));
        return;
    }

    let promise: PromiseRaw<'static, ()> = unsafe { value.cast().unwrap_unchecked() };

    let tx_catch = tx.clone();
    let _ = promise
        .then(move |_ctx: CallbackContext<()>| {
            send_once(&tx, Ok(()));
            Ok(())
        })
        .and_then(|p| {
            p.catch(move |ctx: CallbackContext<Unknown>| {
                let msg: String = ctx.value.coerce_to_string()
                    .and_then(|s| s.into_utf8().and_then(|u| u.into_owned()))
                    .unwrap_or_else(|_| "unknown rejection".to_string());
                send_once(&tx_catch, Err(format!("rejected: {}", msg)));
                Ok(())
            })
        });
}
