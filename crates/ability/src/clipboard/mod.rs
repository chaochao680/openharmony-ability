//! OHOS Clipboard module
//!
//! This module provides:
//! - Rust API: clipboard_write_image() for clipboard-manager to write images
//! - TSFN-based cross-thread call to ArkTS writeImageToClipboard
//!
//! Uses async await + oneshot channel to properly wait for the ArkTS Promise result,
//! matching the Desktop (arboard) synchronous behavior.

use futures_channel::oneshot;
use napi_ohos::bindgen_prelude::{CallbackContext, Error, FnArgs, Function, JsObjectValue, JsValue, Result, Status, Uint8Array, Unknown};
use napi_ohos::threadsafe_function::{ThreadsafeCallContext, ThreadsafeFunction, ThreadsafeFunctionCallMode};
use napi_ohos::bindgen_prelude::PromiseRaw;
use napi_ohos::Env;
use std::cell::Cell;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use tokio::time::{timeout, Duration};

use crate::get_helper;

use ohos_hilog_binding::{hilog_error, LogOptions, set_global_options};

// ─── Data struct for cross-thread transfer via TSFN ───

struct ClipboardImageData {
    rgba: Vec<u8>,
    width: u32,
    height: u32,
}

// ─── TSFN type alias ───
// Output type is Unknown<'static> to capture the Promise<void> returned by writeImageToClipboard

type ClipboardTsfn = ThreadsafeFunction<
    ClipboardImageData,
    Unknown<'static>,
    FnArgs<(Uint8Array, u32, u32)>,
    Status,
    false,
>;

static TSFN_WRITE_IMAGE: Mutex<Option<ClipboardTsfn>> = Mutex::new(None);
static TSFN_INITIALIZED: AtomicBool = AtomicBool::new(false);

/// Initialize clipboard ThreadsafeFunction. Must be called on ArkTS main thread.
/// Idempotent: subsequent calls after the first successful init are no-ops.
pub fn init_clipboard_tsfn(env: &Env) -> Result<()> {
    if TSFN_INITIALIZED.load(Ordering::Acquire) {
        return Ok(());
    }

    set_global_options(LogOptions { domain: 0x0011, tag: "Clipboard" });

    let helper_obj = {
        let helper_rc = unsafe { get_helper() };
        let helper_guard = helper_rc.borrow();
        let helper_ref = helper_guard
            .as_ref()
            .ok_or_else(|| {
                hilog_error!("init_clipboard_tsfn: ArkHelper not initialized");
                Error::from_reason("ArkHelper not initialized")
            })?;
        helper_ref.get_value(env)?
    };

    let write_fn: Function<'_, (Uint8Array, u32, u32), Unknown<'_>> = helper_obj
        .get_named_property("writeImageToClipboard")
        .map_err(|e| {
            hilog_error!("init_clipboard_tsfn: writeImageToClipboard not found: {}", e);
            Error::from_reason(format!("writeImageToClipboard not found: {}", e))
        })?;

    let tsfn = write_fn
        .build_threadsafe_function::<ClipboardImageData>()
        .callee_handled::<false>()
        .build_callback(move |ctx: ThreadsafeCallContext<ClipboardImageData>| {
            Ok(FnArgs {
                data: (Uint8Array::new(ctx.value.rgba), ctx.value.width, ctx.value.height),
            })
        })?;

    *TSFN_WRITE_IMAGE.lock().unwrap() = Some(tsfn);
    TSFN_INITIALIZED.store(true, Ordering::Release);
    Ok(())
}

/// Write RGBA image data to the system clipboard (async, awaits ArkTS Promise result).
pub async fn clipboard_write_image(rgba: &[u8], width: u32, height: u32) -> Result<()> {
    // Validate rgba dimensions: must equal width * height * 4
    let expected = (width as usize).checked_mul(height as usize)
        .and_then(|v| v.checked_mul(4))
        .ok_or_else(|| Error::from_reason("dimensions overflow"))?;
    if rgba.len() != expected {
        hilog_error!("clipboard_write_image: rgba len {} != expected {} ({}x{}x4)", rgba.len(), expected, width, height);
        return Err(Error::from_reason(format!(
            "rgba len {} != expected {} ({}x{}x4)",
            rgba.len(), expected, width, height)));
    }

    let (tx, rx) = oneshot::channel::<Result<()>>();

    // Dispatch the TSFN call inside a block so MutexGuard is dropped before .await
    {
        let tsfn = TSFN_WRITE_IMAGE.lock().unwrap();
        let tsfn = tsfn
            .as_ref()
            .ok_or_else(|| {
                hilog_error!("clipboard_write_image: TSFN not initialized!");
                Error::from_reason("clipboard TSFN not initialized")
            })?;

        let data = ClipboardImageData {
            rgba: rgba.to_vec(),
            width,
            height,
        };

        let call_status = tsfn.call_with_return_value(
            data,
            ThreadsafeFunctionCallMode::NonBlocking,
            move |result, _env| {
                match result {
                    Ok(value) => {
                        // Validate ArkTS return type before unsafe cast to PromiseRaw.
                        // If writeImageToClipboard returns non-Promise, .then()/.catch() is UB.
                        let value_type = value.get_type()?;
                        if value_type != napi_ohos::ValueType::Object {
                            let _ = tx.send(Err(Error::from_reason(
                                "writeImageToClipboard did not return a Promise"
                            )));
                            return Ok(());
                        }

                        let tx_cell = Rc::new(Cell::new(Some(tx)));
                        let tx_in_catch = tx_cell.clone();
                        let promise: PromiseRaw<'static, Unknown<'static>> = unsafe { value.cast()? };
                        promise
                            .then(move |_ctx| {
                                if let Some(sender) = tx_cell.replace(None) {
                                    let _ = sender.send(Ok(()));
                                }
                                Ok(())
                            })?
                            .catch(move |ctx: CallbackContext<Unknown>| {
                                if let Some(sender) = tx_in_catch.replace(None) {
                                    // Extract error details from ArkTS rejection value.
                                    // OHOS BusinessError has .code and .message; coerce_to_string
                                    // converts the Error object to its string representation.
                                    let reason: String = ctx.value.coerce_to_string()
                                        .and_then(|s| s.into_utf8().and_then(|u| u.into_owned()))
                                        .unwrap_or_else(|_| "unknown rejection".to_string());
                                    let _ = sender.send(Err(Error::from_reason(format!("rejected: {}", reason))));
                                }
                                Ok(())
                            })?;
                    }
                    Err(err) => {
                        let _ = tx.send(Err(err));
                    }
                }
                Ok(())
            },
        );
        if call_status != Status::Ok {
            hilog_error!("clipboard_write_image: TSFN call failed: {:?}", call_status);
            return Err(Error::from_reason(format!("TSFN call failed: {:?}", call_status)));
        }
    } // MutexGuard dropped here

    // Add timeout to rx.await — if ArkTS Promise never resolves/rejects,
    // oneshot Receiver waits forever → UI freeze.
    timeout(Duration::from_secs(10), rx)
        .await
        .map_err(|_| Error::from_reason("clipboard write timed out"))?
        .map_err(|_| Error::from_reason("clipboard write cancelled"))?
}
