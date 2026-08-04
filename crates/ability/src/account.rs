// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! Huawei Account one-tap login for OpenHarmony via Account Kit.
//!
//! The ArkTS side (`helper/account.ets`) wraps `@kit.AccountKit`'s
//! `authentication` service (HuaweiIDProvider / AuthenticationController). The
//! TSFN infrastructure (in `helper/account.rs`) bridges ArkTS Promises to Rust
//! Futures.
//!
//! `login` / `silent_login` return a structured `AccountInfo`; `logout` maps to
//! Account Kit's "cancel authorization" (`createCancelAuthorizationRequest`),
//! see design D8.

use std::{cell::Cell, rc::Rc, sync::Arc};

use futures_channel::oneshot;
use napi_ohos::{
    bindgen_prelude::{CallbackContext, JsObjectValue, Object, PromiseRaw, Unknown},
    threadsafe_function::ThreadsafeFunctionCallMode,
    Error, JsValue, Result, Status,
};
use serde::{Deserialize, Serialize};

use crate::helper::{
    get_account_login_tsfn, get_account_logout_tsfn, get_account_silent_login_tsfn, AccountTsfn,
};

/// Account info returned by a successful Huawei Account login.
///
/// All fields except `access_token` are non-optional strings (empty when the
/// Account Kit omits them); `access_token` is only present in some scenarios.
/// Serialized as camelCase JSON for cross-language transfer.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AccountInfo {
    pub uid: String,
    pub open_id: String,
    pub union_id: String,
    pub display_name: String,
    pub avatar_uri: String,
    pub authorization_code: String,
    #[serde(default)]
    pub access_token: Option<String>,
}

/// Handle for Huawei Account one-tap login operations.
///
/// Account Kit has no per-app state, so this is a zero-sized handle. The TSFNs
/// are initialized globally during `render()` (see `render/xcomponent.rs`).
pub struct HuaweiAccount;

impl HuaweiAccount {
    /// Create a new handle. No per-instance state is held.
    pub fn new() -> Self {
        Self
    }

    /// Interactive login — forces the Huawei account login UI (`forceLogin = true`).
    /// Returns the resulting `AccountInfo` on user confirmation.
    pub async fn login(&self) -> Result<AccountInfo> {
        account_info_request(get_account_login_tsfn(), "account login").await
    }

    /// Silent login — no UI, succeeds only when the device is already logged in
    /// and the app is already authorized (`forceLogin = false`). Callers should
    /// fall back to `login` on the "not logged in" error (code `1001502001`).
    pub async fn silent_login(&self) -> Result<AccountInfo> {
        account_info_request(get_account_silent_login_tsfn(), "account silent_login").await
    }

    /// Logout — cancels the app's Huawei account authorization on this device
    /// (Account Kit's `createCancelAuthorizationRequest`, see design D8).
    pub async fn logout(&self) -> Result<()> {
        let tsfn = get_account_logout_tsfn()
            .ok_or_else(|| Error::from_reason("account logout TSFN not initialized"))?;

        let (tx, rx) = oneshot::channel::<std::result::Result<(), String>>();
        let tx_cell = Rc::new(Cell::new(Some(tx)));

        let status = tsfn.call_with_return_value(
            (),
            ThreadsafeFunctionCallMode::NonBlocking,
            move |result, _env| {
                match result {
                    Ok(value) => handle_void_promise(value, tx_cell.clone()),
                    Err(err) => send_once(&tx_cell, Err(err.to_string())),
                }
                Ok(())
            },
        );

        if status != Status::Ok {
            return Err(Error::from_reason(format!(
                "call accountLogout TSFN failed: {:?}",
                status
            )));
        }

        rx.await
            .map_err(|_| Error::from_reason("account logout receiver dropped"))?
            .map_err(|msg| Error::from_reason(msg))
    }
}

impl Default for HuaweiAccount {
    fn default() -> Self {
        Self::new()
    }
}

// ── Helpers ──────────────────────────────────────────────────────────

/// Drive an `AccountInfo`-returning TSFN call to completion.
///
/// `tsfn` is the (already-resolved) TSFN handle; `label` is used only for error
/// messages. The ArkTS Promise is resolved on the JS thread (NAPI values cannot
/// cross threads) via `handle_account_promise`.
async fn account_info_request(
    tsfn: Option<Arc<AccountTsfn>>,
    label: &str,
) -> Result<AccountInfo> {
    let tsfn = tsfn.ok_or_else(|| {
        Error::from_reason(format!("{} TSFN not initialized", label))
    })?;

    let (tx, rx) = oneshot::channel::<std::result::Result<AccountInfo, String>>();
    let tx_cell = Rc::new(Cell::new(Some(tx)));

    let status = tsfn.call_with_return_value(
        (),
        ThreadsafeFunctionCallMode::NonBlocking,
        move |result, _env| {
            match result {
                Ok(value) => handle_account_promise(value, tx_cell.clone()),
                Err(err) => send_once(&tx_cell, Err(err.to_string())),
            }
            Ok(())
        },
    );

    if status != Status::Ok {
        return Err(Error::from_reason(format!(
            "call {} TSFN failed: {:?}",
            label, status
        )));
    }

    rx.await
        .map_err(|_| Error::from_reason(format!("{} receiver dropped", label)))?
        .map_err(|msg| Error::from_reason(msg))
}

/// Send a value through a oneshot sender that is wrapped in `Rc<Cell<Option>>`.
/// Only the first call actually sends; subsequent calls are no-ops.
fn send_once<T>(cell: &Rc<Cell<Option<oneshot::Sender<T>>>>, value: T) {
    if let Some(sender) = cell.replace(None) {
        let _ = sender.send(value);
    }
}

/// Attach `.then`/`.catch` to the ArkTS `accountLogin`/`accountSilentLogin`
/// Promise. Extracts `AccountInfo` fields on the JS thread (NAPI values cannot
/// cross threads).
fn handle_account_promise(
    value: Unknown<'static>,
    tx: Rc<Cell<Option<oneshot::Sender<std::result::Result<AccountInfo, String>>>>>,
) {
    // SAFETY: `value` originates from an async ArkTS function (login/silentLogin)
    // that always returns a Promise<AccountInfo>, so casting Unknown to
    // PromiseRaw<Object> is sound. The cast skips runtime type validation
    // (napi-ohos Unknown::cast), so soundness relies on this invariant.
    let promise = unsafe { value.cast::<PromiseRaw<'static, Object<'static>>>() };
    let promise = match promise {
        Ok(p) => p,
        Err(e) => {
            send_once(&tx, Err(e.to_string()));
            return;
        }
    };

    let tx_then = tx.clone();
    let _ = promise
        .then(move |ctx: CallbackContext<Object<'static>>| {
            let result = parse_account_info(&ctx.value);
            send_once(&tx_then, result.map_err(|e| e.to_string()));
            Ok(())
        })
        .and_then(|p| {
            p.catch(move |ctx: CallbackContext<Unknown>| {
                let msg: String = ctx
                    .value
                    .coerce_to_string()
                    .and_then(|s| s.into_utf8().and_then(|u| u.into_owned()))
                    .unwrap_or_else(|_| "unknown rejection".to_string());
                send_once(&tx, Err(format!("rejected: {}", msg)));
                Ok(())
            })
        });
}

/// Attach `.then`/`.catch` to a `Promise<void>` (used by `logout`).
fn handle_void_promise(
    value: Unknown<'static>,
    tx: Rc<Cell<Option<oneshot::Sender<std::result::Result<(), String>>>>>,
) {
    // SAFETY: `value` originates from an async ArkTS function (logout) that
    // always returns a Promise<void>, so casting Unknown to PromiseRaw<()> is
    // sound. The cast skips runtime type validation (napi-ohos Unknown::cast),
    // so soundness relies on this invariant.
    let promise = unsafe { value.cast::<PromiseRaw<'static, ()>>() };
    let promise = match promise {
        Ok(p) => p,
        Err(e) => {
            send_once(&tx, Err(e.to_string()));
            return;
        }
    };

    let tx_then = tx.clone();
    let _ = promise
        .then(move |_ctx: CallbackContext<()>| {
            send_once(&tx_then, Ok(()));
            Ok(())
        })
        .and_then(|p| {
            p.catch(move |ctx: CallbackContext<Unknown>| {
                let msg: String = ctx
                    .value
                    .coerce_to_string()
                    .and_then(|s| s.into_utf8().and_then(|u| u.into_owned()))
                    .unwrap_or_else(|_| "unknown rejection".to_string());
                send_once(&tx, Err(format!("rejected: {}", msg)));
                Ok(())
            })
        });
}

/// Extract `AccountInfo` fields from a JS Object.
///
/// ArkTS (`account.ets`) constructs an object with canonical camelCase keys
/// (see design D4), so the Account Kit credential's real field casing is
/// isolated on the ArkTS side. Missing fields degrade to empty strings (or
/// `None` for `accessToken`) rather than erroring — see spec "可选字段缺失".
/// Must run on the JS main thread (NAPI values are thread-bound).
fn parse_account_info(obj: &Object<'static>) -> Result<AccountInfo> {
    Ok(AccountInfo {
        uid: obj
            .get_named_property::<String>("uid")
            .unwrap_or_default(),
        open_id: obj
            .get_named_property::<String>("openId")
            .unwrap_or_default(),
        union_id: obj
            .get_named_property::<String>("unionId")
            .unwrap_or_default(),
        display_name: obj
            .get_named_property::<String>("displayName")
            .unwrap_or_default(),
        avatar_uri: obj
            .get_named_property::<String>("avatarUri")
            .unwrap_or_default(),
        authorization_code: obj
            .get_named_property::<String>("authorizationCode")
            .unwrap_or_default(),
        access_token: obj.get("accessToken").ok().flatten(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_info_serde_roundtrip() {
        let info = AccountInfo {
            uid: "10001".into(),
            open_id: "OPENID_ABC".into(),
            union_id: "UNIONID_XYZ".into(),
            display_name: "Alice".into(),
            avatar_uri: "https://example.com/a.png".into(),
            authorization_code: "AUTHCODE123".into(),
            access_token: Some("ATOKEN".into()),
        };
        let json = serde_json::to_string(&info).unwrap();
        assert!(json.contains("\"openId\":\"OPENID_ABC\""));
        assert!(json.contains("\"unionId\":\"UNIONID_XYZ\""));
        assert!(json.contains("\"avatarUri\":\"https://example.com/a.png\""));
        assert!(json.contains("\"authorizationCode\":\"AUTHCODE123\""));
        assert!(json.contains("\"accessToken\":\"ATOKEN\""));

        let deserialized: AccountInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized, info);
    }

    #[test]
    fn account_info_optional_access_token_null() {
        // accessToken absent (Account Kit may omit it) → None, no error.
        let json = r#"{"uid":"1","openId":"o","unionId":"u","displayName":"","avatarUri":"","authorizationCode":"c","accessToken":null}"#;
        let info: AccountInfo = serde_json::from_str(json).unwrap();
        assert_eq!(info.access_token, None);
        assert_eq!(info.display_name, "");
    }

    #[test]
    fn account_info_optional_access_token_missing_key() {
        // accessToken key entirely missing → None (#[serde(default)]).
        let json = r#"{"uid":"1","openId":"o","unionId":"u","displayName":"n","avatarUri":"a","authorizationCode":"c"}"#;
        let info: AccountInfo = serde_json::from_str(json).unwrap();
        assert_eq!(info.access_token, None);
        assert_eq!(info.uid, "1");
        assert_eq!(info.display_name, "n");
    }

    #[test]
    fn account_info_default_empty() {
        let info = AccountInfo::default();
        assert_eq!(info.uid, "");
        assert_eq!(info.authorization_code, "");
        assert_eq!(info.access_token, None);
    }
}
