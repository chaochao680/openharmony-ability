use napi_ohos::bindgen_prelude::*;
use napi_ohos::threadsafe_function::{ThreadsafeCallContext, ThreadsafeFunction, ThreadsafeFunctionCallMode};
use napi_derive_ohos::napi;
use napi_ohos::Env;
use crate::{get_helper, get_main_thread_env};
use std::ffi::{c_char, c_int, c_void};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::OnceLock;

/// Global window ID generator to ensure unique IDs across Rust and ArkTS.
static NEXT_WINDOW_ID: AtomicI64 = AtomicI64::new(1);

/// Parameters for creating a new OS-level window on OpenHarmony.
///
/// `windowId` is not included — it is auto-generated internally by `create_os_window`
/// via `NEXT_WINDOW_ID` to ensure global uniqueness.
pub struct WindowCreateParams {
    /// Window label/name, used as the ArkTS sub-window name.
    pub name: String,
    /// OHOS window type enum value (0=App, 8=Float, etc.)
    pub window_type: i32,
    /// Initial window width in px. Default: 800.
    pub width: i32,
    /// Initial window height in px. Default: 600.
    pub height: i32,
    /// Initial window X position in px. Default: 100.
    pub x: i32,
    /// Initial window Y position in px. Default: 100.
    pub y: i32,
    /// Whether to show window decorations (title bar, drag area, close button).
    /// Phase 2: controls FloatPage conditional rendering via LocalStorage.
    pub decorations: bool,
    /// Whether the window background should be fully transparent.
    /// Phase 3: when true, overrides background_color with 0x00000000.
    pub transparent: bool,
    /// Window background color in 0xAARRGGBB format.
    /// Phase 3: ignored when transparent is true.
    pub background_color: Option<u32>,
}

impl Default for WindowCreateParams {
    fn default() -> Self {
        Self {
            name: String::new(),
            window_type: 0,
            width: 800,
            height: 600,
            x: 100,
            y: 100,
            decorations: true,
            transparent: false,
            background_color: None,
        }
    }
}

/// Generates a unique window ID for use when creating sub-windows
/// outside of `create_os_window` (e.g., from `handleWindowNew` when
/// `window_kind == "window"`). Uses the same `NEXT_WINDOW_ID` counter to
/// ensure no collision with Rust-created windows.
///
/// Currently unused — reserved for future when `OnWindowNewResult` carries
/// a pre-generated window ID for ArkTS-side sub-window creation.
#[allow(dead_code)]
pub fn generate_window_id() -> i64 {
    NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst)
}

/// Creates a new OS-level window on OpenHarmony.
///
/// Uses `WindowCreateParams` to pass all window attributes (geometry, decorations,
/// transparent, background_color) in a single struct, avoiding signature bloat
/// as Phase 2/3 add more parameters.
pub fn create_os_window(params: WindowCreateParams) -> napi_ohos::Result<i64> {
    // 1. Synchronously allocate a unique ID
    let id = NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst);
    crate::info!("Pre-allocated window ID: {}", id);

    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func =
                match obj.get_named_property::<Function<'_, Object, Unknown>>("createOSWindow") {
                    Ok(f) => f,
                    Err(e) => {
                        crate::error!("Property 'createOSWindow' NOT FOUND on helper: {:?}", e);
                        return Err(e);
                    }
                };

            crate::info!("Successfully found createOSWindow, building config object...");

            // 2. Create config object with all parameters
            let mut config = Object::new(env)?;
            config.set("name", params.name)?;
            // Note: "type" field is deprecated and no longer sent (OHOS createSubWindow only uses name)
            config.set("windowId", id)?;
            config.set("width", params.width)?;
            config.set("height", params.height)?;
            config.set("x", params.x)?;
            config.set("y", params.y)?;
            // Phase 2: decorations
            config.set("decorations", params.decorations)?;
            // Phase 3: transparent + backgroundColor
            config.set("transparent", params.transparent)?;
            if let Some(color) = params.background_color {
                config.set("backgroundColor", color)?;
            }

            crate::info!("Calling ArkTS with config object...");

            // 3. Call ArkTS and return the ID on success
            match func.call(config) {
                Ok(_) => {
                    crate::info!("ArkTS call succeeded, returning ID: {}", id);
                    return Ok(id);
                }
                Err(e) => {
                    crate::error!("ArkTS call failed: {:?}", e);
                    return Err(e);
                }
            }
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Sets window decorations (title bar visibility) at runtime via NAPI.
///
/// Calls ArkTS `setWindowDecorations(windowId, decorations)` handler which
/// updates LocalStorage → FloatPage `@LocalStorageProp` reactive re-render.
///
/// Phase 2 implementation.
pub fn set_window_decorations(window_id: i64, decorations: bool) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func =
                obj.get_named_property::<Function<'_, FnArgs<(i64, bool)>, ()>>("setWindowDecorations")?;
            func.call(FnArgs { data: (window_id, decorations) })?;
            return Ok(());
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Sets window background color at runtime via NAPI.
///
/// Calls ArkTS `setWindowBackgroundColor(windowId, color)` handler which
/// calls OHOS `window.Window.setWindowBackgroundColor('#AARRGGBB')`.
///
/// `color` is in `0xAARRGGBB` format (e.g., `0x00000000` = fully transparent).
///
/// Phase 3 implementation.

// ─── TSFN for cross-thread vibrancy calls (threadsafe, no main-thread Env needed) ───
// Fire-and-forget (NonBlocking, no return value wait): applyWindowBlur queues pendingBlurs
// (build-time inject via registerController) or calls setAllWebviewsBlurRadius (runtime
// modifier refresh), both idempotent, so no synchronous result needed.
type SetWindowBlurTsfn = ThreadsafeFunction<(i64, f64), (), FnArgs<(i64, f64)>, Status, false>;
type SetWindowBgColorTsfn = ThreadsafeFunction<(i64, u32), (), FnArgs<(i64, u32)>, Status, false>;

static TSFN_SET_WINDOW_BLUR: OnceLock<SetWindowBlurTsfn> = OnceLock::new();
static TSFN_SET_WINDOW_BG_COLOR: OnceLock<SetWindowBgColorTsfn> = OnceLock::new();

/// Initialize vibrancy ThreadsafeFunctions. Must be called on ArkTS main thread (during
/// ArkHelper setup, like init_clipboard_tsfn). After init, set_window_blur /
/// set_window_background_color are callable from any thread (TSFN is threadsafe, does not
/// need the thread_local MAIN_THREAD_ENV, so no run_on_main_thread required).
pub fn init_vibrancy_tsfn(env: &Env) -> Result<()> {
    if TSFN_SET_WINDOW_BLUR.get().is_some() {
        return Ok(());
    }
    let helper_obj = {
        let helper_rc = unsafe { get_helper() };
        let helper_guard = helper_rc.borrow();
        let helper_ref = helper_guard
            .as_ref()
            .ok_or_else(|| Error::from_reason("ArkHelper not initialized"))?;
        helper_ref.get_value(env)?
    };

    let blur_fn: Function<'_, FnArgs<(i64, f64)>, ()> = helper_obj
        .get_named_property("setWindowBlur")
        .map_err(|e| Error::from_reason(format!("setWindowBlur not found: {}", e)))?;
    let blur_tsfn = blur_fn
        .build_threadsafe_function::<(i64, f64)>()
        .callee_handled::<false>()
        .build_callback(move |ctx: ThreadsafeCallContext<(i64, f64)>| {
            Ok(FnArgs { data: ctx.value })
        })?;
    let _ = TSFN_SET_WINDOW_BLUR.set(blur_tsfn);

    let bg_fn: Function<'_, FnArgs<(i64, u32)>, ()> = helper_obj
        .get_named_property("setWindowBackgroundColor")
        .map_err(|e| Error::from_reason(format!("setWindowBackgroundColor not found: {}", e)))?;
    let bg_tsfn = bg_fn
        .build_threadsafe_function::<(i64, u32)>()
        .callee_handled::<false>()
        .build_callback(move |ctx: ThreadsafeCallContext<(i64, u32)>| {
            Ok(FnArgs { data: ctx.value })
        })?;
    let _ = TSFN_SET_WINDOW_BG_COLOR.set(bg_tsfn);

    Ok(())
}

/// Sets window background color via TSFN (threadsafe, callable from any thread).
pub fn set_window_background_color(window_id: i64, color: u32) -> napi_ohos::Result<()> {
    let tsfn = TSFN_SET_WINDOW_BG_COLOR.get()
        .ok_or_else(|| Error::from_reason("set_window_background_color TSFN not initialized"))?;
    let status = tsfn.call((window_id, color), ThreadsafeFunctionCallMode::NonBlocking);
    if status != Status::Ok {
        return Err(Error::from_reason(format!("TSFN call failed: {:?}", status)));
    }
    Ok(())
}

/// Sets window blur radius via TSFN (threadsafe, callable from any thread).
///
/// Calls ArkTS `setWindowBlur(windowId, radius)` handler which applies
/// `backdropBlur(radius)` to the WebView container component.
///
/// `radius` is the blur radius in pixels (0 = no blur).
pub fn set_window_blur(window_id: i64, radius: f64) -> napi_ohos::Result<()> {
    let tsfn = TSFN_SET_WINDOW_BLUR.get()
        .ok_or_else(|| Error::from_reason("set_window_blur TSFN not initialized"))?;
    let status = tsfn.call((window_id, radius), ThreadsafeFunctionCallMode::NonBlocking);
    if status != Status::Ok {
        return Err(Error::from_reason(format!("TSFN call failed: {:?}", status)));
    }
    Ok(())
}

/// Brings a Float sub-window to the front and focuses it.
///
/// Calls ArkTS `focusWindow(windowId)` which calls OHOS `window.Window.raiseToAppTop()`.
/// Requires OHOS API 14+.
///
/// **Note**: This is a fire-and-forget call — the ArkTS `raiseToAppTop()` is async,
/// but this function returns `Ok(())` synchronously after dispatching the NAPI call.
/// If the ArkTS side fails, the error is logged via `hilog` but not propagated to Rust.
/// For the main window (windowId = 0), this is a no-op (focus is OS-managed).
pub fn focus_window(window_id: i64) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func = obj.get_named_property::<Function<'_, i64, ()>>("focusWindow")?;
            func.call(window_id)?;
            return Ok(());
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Sets whether a Float sub-window can receive focus.
///
/// Calls ArkTS `setWindowFocusable(windowId, focusable)` which calls
/// OHOS `window.Window.setWindowFocusable(isFocusable)`.
pub fn set_window_focusable(window_id: i64, focusable: bool) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func =
                obj.get_named_property::<Function<'_, FnArgs<(i64, bool)>, ()>>("setWindowFocusable")?;
            func.call(FnArgs { data: (window_id, focusable) })?;
            return Ok(());
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Sets window topmost via ArkTS `setWindowTopmost(windowId, topmost)` → `win.setWindowTopmost(bool)`.
///
/// OHOS API 14+. **Main window only** — Float sub-windows will error (caught + warned in
/// ArkTS, non-fatal). Only effective in freeform window mode; returns 801 on devices
/// without freeform support (phone/tablet) — caught + warned.
/// Requires `ohos.permission.WINDOW_TOPMOST` (system_grant, declared in module.json5).
pub fn set_window_topmost(window_id: i64, topmost: bool) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func =
                obj.get_named_property::<Function<'_, FnArgs<(i64, bool)>, ()>>("setWindowTopmost")?;
            func.call(FnArgs { data: (window_id, topmost) })?;
            return Ok(());
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Sets window title via ArkTS `setWindowTitle(windowId, title)` → `win.setWindowTitle(title)`.
///
/// OHOS API 9+ (callback form) / API 12+ (decor title field). Main window and Float
/// sub-windows both support title text (icon is NOT changeable at runtime). No extra
/// permission for main window; Float sub-window creation already needs SYSTEM_FLOAT_WINDOW.
/// Uses Object param (not FnArgs) because the title is a String — matches start_ui_ability pattern.
pub fn set_window_title(window_id: i64, title: String) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func = obj.get_named_property::<Function<'_, Object, ()>>("setWindowTitle")?;
            let mut args = Object::new(env)?;
            args.set("windowId", window_id)?;
            args.set("title", title)?;
            func.call(args)?;
            return Ok(());
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Sets window min/max size limits via ArkTS `setWindowLimits(windowId, minW, minH, maxW, maxH)`
/// → `win.setWindowLimits({minWindowWidth, minWindowHeight, maxWindowWidth, maxWindowHeight})`.
///
/// OHOS API 11+. All four params are u32 (px). None = 0 means "no limit" (system default).
/// ⚠️ Triggers OnSizeChange — may cause appfreeze if called frequently on main window.
/// No extra permission. Uses FnArgs (all numeric, safe for sync NAPI).
pub fn set_window_limits(
    window_id: i64,
    min_w: u32,
    min_h: u32,
    max_w: u32,
    max_h: u32,
) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func = obj.get_named_property::<
                Function<'_, FnArgs<(i64, u32, u32, u32, u32)>, ()>,
            >("setWindowLimits")?;
            func.call(FnArgs {
                data: (window_id, min_w, min_h, max_w, max_h),
            })?;
            return Ok(());
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}
// synchronous queries returning bool via getWindowStatus().
// ============================================================================

/// Moves a window to (x, y) via ArkTS `moveWindowTo(windowId, x, y)` → `win.moveWindowTo(x, y)`.
pub fn move_window_to(window_id: i64, x: i64, y: i64) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, Object, ()>>("moveWindowTo")?;
            let mut params = Object::new(env)?;
            params.set("windowId", window_id)?;
            params.set("x", x)?;
            params.set("y", y)?;
            func.call(params)?;
            return Ok(());
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Resizes a window via ArkTS `resizeWindow(windowId, w, h)` → `win.resize(w, h)`.
pub fn resize_window(window_id: i64, width: i64, height: i64) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, Object, ()>>("resizeWindow")?;
            let mut params = Object::new(env)?;
            params.set("windowId", window_id)?;
            params.set("width", width)?;
            params.set("height", height)?;
            func.call(params)?;
            return Ok(());
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Minimizes a window via ArkTS `minimizeWindow(windowId)` → `win.minimize()`.
pub fn minimize_window(window_id: i64) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, i64, ()>>("minimizeWindow")?;
            func.call(window_id)?;
            return Ok(());
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Maximizes a window via ArkTS `maximizeWindow(windowId)` → `win.maximize(MaximizePresentation.EXIT_IMMERSIVE)`.
/// EXIT_IMMERSIVE yields a true MAXIMIZE state (default ENTER_IMMERSIVE enters FULL_SCREEN).
pub fn maximize_window(window_id: i64) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, i64, ()>>("maximizeWindow")?;
            func.call(window_id)?;
            return Ok(());
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Restores a window from minimized state via ArkTS `restoreWindow(windowId)` → `win.restore()`.
/// API14+ only (restore is API14). On API < 14, no-op + warn.
/// Note: restore() only restores from MINIMIZE, NOT from MAXIMIZE.
pub fn restore_window(window_id: i64) -> napi_ohos::Result<()> {
    if crate::version::sdk_api_version() < 14 {
        log::warn!(
            "[ohos-window] restore() requires API14+, current API {}; no-op",
            crate::version::sdk_api_version()
        );
        return Ok(());
    }
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, i64, ()>>("restoreWindow")?;
            func.call(window_id)?;
            return Ok(());
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Recovers a window from maximized/fullscreen to floating via ArkTS `recoverWindow(windowId)` → `win.recover()`.
/// API 7+, public. Switches MAXIMIZE/FULL_SCREEN → FLOATING, restoring previous size/position.
pub fn recover_window(window_id: i64) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, i64, ()>>("recoverWindow")?;
            func.call(window_id)?;
            return Ok(());
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Shows a window via ArkTS `showWindowMethod(windowId)` → `win.showWindow()`.
/// Note: showWindow only restores hidden subwindows, not minimized main windows.
pub fn show_window(window_id: i64) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, i64, ()>>("showWindowMethod")?;
            func.call(window_id)?;
            return Ok(());
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Destroys/closes a window via ArkTS `closeWindow(windowId)`:
/// - Float sub-window: `win.destroyWindow()` (real destroy, removes from screen).
/// - UIAbility main window: `hideAbility()` (background, OHOS doesn't allow
///   programmatic Ability kill; instance stays in recent tasks but becomes invisible).
///
/// This is the real OHOS window destruction — tao's `Window::close` is a no-op on
/// OHOS (doesn't call destroyWindow), so `WebviewWindow::close()` removes the
/// window from Rust's manager but leaves the system window visible on screen.
/// Callers that need the system window actually gone must call this explicitly.
pub fn destroy_window(window_id: i64) -> napi_ohos::Result<()> {
    log::info!("[ohos-window] destroy_window wid={} ENTER (sync)", window_id);
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, i64, ()>>("closeWindow")?;
            func.call(window_id)?;
            log::info!("[ohos-window] destroy_window wid={} ArkHelper.closeWindow called OK", window_id);
            return Ok(());
        } else { log::error!("[ohos-window] destroy_window wid={} Main thread env not available", window_id); }
    } else { log::error!("[ohos-window] destroy_window wid={} Helper not initialized", window_id); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Queries whether a window is maximized via ArkTS `isMaximized(windowId)` →
/// `win.getWindowStatus() === window.WindowStatusType.MAXIMIZE`.
/// Synchronous (getWindowStatus is a sync getter, API12).
pub fn is_window_maximized(window_id: i64) -> napi_ohos::Result<bool> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, i64, bool>>("isMaximized")?;
            return func.call(window_id);
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Queries whether a window is minimized via ArkTS `isMinimized(windowId)` →
/// `win.getWindowStatus() === window.WindowStatusType.MINIMIZE`.
/// Synchronous (getWindowStatus is a sync getter, API12).
pub fn is_window_minimized(window_id: i64) -> napi_ohos::Result<bool> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, i64, bool>>("isMinimized")?;
            return func.call(window_id);
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

// ─── Group A completion: hide / fullscreen / ignore cursor ──────────────────────────────
// Multi-arg (2+) parameters must be wrapped with FnArgs (a bare tuple is
// passed as a single argument; see napi-ohos JsValuesTupleIntoVec blanket
// impl). Single-arg func.call(id) is unaffected.

/// `set_visible(false)` → main window hideAbility; sub-window minimize (OHOS has no standalone hide API).
pub fn hide_window(window_id: i64) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, i64, ()>>("hideWindow")?;
            func.call(window_id)?;
            return Ok(());
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// `set_fullscreen` → setWindowLayoutFullScreen + setWindowSystemBarEnable([]).
pub fn set_fullscreen(window_id: i64, on: bool) -> napi_ohos::Result<()> {
    log::info!("[ohos-window] set_fullscreen ENTER wid={} on={}", window_id, on);
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, FnArgs<(i64, bool)>, ()>>("setFullscreen")?;
            func.call(FnArgs { data: (window_id, on) })?;
            log::info!("[ohos-window] set_fullscreen wid={} ArkHelper.setFullscreen called OK", window_id);
            return Ok(());
        } else { log::error!("[ohos-window] set_fullscreen wid={} Main thread env not available", window_id); }
    } else { log::error!("[ohos-window] set_fullscreen wid={} Helper not initialized", window_id); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// `set_ignore_cursor_events` → setWindowTouchable (touchable = !ignore).
pub fn set_window_touchable(window_id: i64, touchable: bool) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, FnArgs<(i64, bool)>, ()>>("setWindowTouchable")?;
            func.call(FnArgs { data: (window_id, touchable) })?;
            return Ok(());
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

// ─── Group D: decoration button availability (FloatPage LocalStorage) ──────────────────────────
// Bitfield: bit0 closable, bit1 maximizable, bit2 minimizable, bit3 resizable.
// Default 0b1111=15. Only effective for Float sub-windows; no-op for main window.
pub fn set_window_decoration_flags(window_id: i64, flags: u8) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, FnArgs<(i64, u8)>, ()>>("setWindowDecorationFlags")?;
            func.call(FnArgs { data: (window_id, flags) })?;
            return Ok(());
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

// ─── Group E: cursor visibility / icon (@ohos.multimodalInput.pointer) ─────────────────
/// `set_cursor_visible` → pointer.setPointerVisible (global).
pub fn set_pointer_visible(visible: bool) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, bool, ()>>("setPointerVisible")?;
            func.call(visible)?;
            return Ok(());
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Request window redraw (no-op on OHOS — vsync auto-drives rendering).
pub fn request_redraw(window_id: i64) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("...: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, FnArgs<(i64,)>, ()>>("requestRedraw")?;
            func.call(FnArgs { data: (window_id,) })?;
            return Ok(());
        }
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Request user attention via notificationManager (no window-level API).
pub fn request_user_attention() -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("...: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, (), ()>>("requestUserAttention")?;
            func.call(())?;
            return Ok(());
        }
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Set IME cursor position via inputMethod.updateCursor(CursorInfo). API 10+.
/// Requires a focused edit box in the window, else ArkTS catches 12800003.
pub fn set_ime_position(window_id: i64, x: i64, y: i64) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("...: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, FnArgs<(i64, i64, i64)>, ()>>("setImePosition")?;
            func.call(FnArgs { data: (window_id, x, y,) })?;
            return Ok(());
        }
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Enable/disable window edge drag-resize (enableDrag API20+).
pub fn set_window_draggable(window_id: i64, enable: bool) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("...: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, FnArgs<(i64, bool)>, ()>>("setWindowDraggable")?;
            func.call(FnArgs { data: (window_id, enable,) })?;
            return Ok(());
        }
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}
/// `style` is an OHOS PointerStyle enum value (mapped from tao's CursorIcon).
pub fn set_pointer_style(window_id: i64, style: i32) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("Failed to get helper: {:?}", e); e })?;
            let func = obj.get_named_property::<Function<'_, FnArgs<(i64, i32)>, ()>>("setPointerStyle")?;
            func.call(FnArgs { data: (window_id, style) })?;
            return Ok(());
        } else { crate::error!("Main thread env not available"); }
    } else { crate::error!("Helper object not initialized"); }
    Err(Error::from_reason("Helper or Env not initialized"))
}

// ─── Group F: cursor grab (OH_WindowManager_LockCursor/UnlockCursor, NDK C API 22+) ───
//
// No ArkTS API exists for cursor locking — the only public surface is the NDK
// C API in libnative_window_manager.so (oh_window.h, @since 22, permission
// ohos.permission.LOCK_WINDOW_CURSOR / normal / system_grant). The library is
// resolved lazily via dlopen+dlsym instead of a static `#[link]`:
// compatibleSdkVersion is API 12 and system images below API 22 do not export
// these symbols, so a load-time link would prevent the app from starting on
// older devices. Symbol presence doubles as the version guard
// (dlsym null ⇒ device below API 22 ⇒ NotSupported).

type LockCursorFn = unsafe extern "C" fn(window_id: i32, is_cursor_follow_movement: bool) -> i32;
type UnlockCursorFn = unsafe extern "C" fn(window_id: i32) -> i32;

struct CursorLockApi {
    lock_cursor: LockCursorFn,
    unlock_cursor: UnlockCursorFn,
}

/// WindowManager C API error code for "capability not supported" (oh_window_comm.h).
const WM_ERRORCODE_DEVICE_NOT_SUPPORTED: i32 = 801;
/// WindowManager C API error code for "window state abnormal" (oh_window_comm.h).
const WM_ERRORCODE_STATE_ABNORMAL: i32 = 1300002;

static CURSOR_LOCK_API: OnceLock<Option<CursorLockApi>> = OnceLock::new();

extern "C" {
    fn dlopen(filename: *const c_char, flags: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
}

/// Resolves the cursor lock C API once per process; `None` when the system
/// does not provide it (API < 22). The handle is intentionally never closed —
/// the library stays loaded for the process lifetime.
fn cursor_lock_api() -> Option<&'static CursorLockApi> {
    CURSOR_LOCK_API
        .get_or_init(|| unsafe {
            // RTLD_NOW | RTLD_LOCAL = 2 on OHOS musl.
            let handle = dlopen(
                b"libnative_window_manager.so\0".as_ptr() as *const c_char,
                2,
            );
            if handle.is_null() {
                crate::warn!("[ohos-window] dlopen libnative_window_manager.so failed (library missing/broken) — cursor grab unsupported");
                return None;
            }
            let lock = dlsym(handle, b"OH_WindowManager_LockCursor\0".as_ptr() as *const c_char);
            let unlock = dlsym(handle, b"OH_WindowManager_UnlockCursor\0".as_ptr() as *const c_char);
            if lock.is_null() || unlock.is_null() {
                crate::warn!("[ohos-window] OH_WindowManager_LockCursor/UnlockCursor not exported — cursor grab unsupported");
                return None;
            }
            Some(CursorLockApi {
                lock_cursor: std::mem::transmute::<*mut c_void, LockCursorFn>(lock),
                unlock_cursor: std::mem::transmute::<*mut c_void, UnlockCursorFn>(unlock),
            })
        })
        .as_ref()
}

/// Typed error for `set_cursor_grab` — tao maps `NotSupported` to
/// `ExternalError::NotSupported` (pre-change behavior on unsupported devices)
/// and the other variants to `ExternalError::Os`.
#[derive(Debug)]
pub enum CursorGrabError {
    /// System does not support cursor lock: dlsym failed (API < 22) or the
    /// FFI call returned 801 (DEVICE_NOT_SUPPORTED).
    NotSupported,
    /// FFI error code: 201 (no permission), 1300002 (window state abnormal),
    /// 1300003 (window manager service abnormal), or any other nonzero code.
    OsCode(i32),
    /// NAPI bridge unavailable (helper/env not ready) or window not found
    /// (realWindowId ≤ 0).
    Bridge(String),
}

impl std::fmt::Display for CursorGrabError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CursorGrabError::NotSupported => write!(f, "cursor lock not supported on this device"),
            CursorGrabError::OsCode(code) => write!(f, "window manager error code {code}"),
            CursorGrabError::Bridge(reason) => write!(f, "cursor grab bridge failure: {reason}"),
        }
    }
}

/// Resolves tao's window id to the real OHOS window id via the ArkTS helper
/// (`getRealWindowId` → `getWindowProperties().id`), same synchronous
/// single-arg call pattern as `isMaximized`. Must run on the main thread.
///
/// NOTE: explicit `std::result::Result` — the `Result` alias from
/// `napi_ohos::bindgen_prelude` is `Result<T, Error<S>>` (payload-generic),
/// not a free error type.
fn real_window_id(window_id: i64) -> std::result::Result<i32, CursorGrabError> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| { crate::error!("[ohos-window] getRealWindowId: helper lookup failed: {:?}", e); CursorGrabError::Bridge(format!("helper lookup: {e:?}")) })?;
            let func = obj.get_named_property::<Function<'_, i64, i64>>("getRealWindowId")
                .map_err(|e| CursorGrabError::Bridge(format!("getRealWindowId property missing: {e:?}")))?;
            let id = func.call(window_id)
                .map_err(|e| CursorGrabError::Bridge(format!("getRealWindowId call failed: {e:?}")))?;
            if id > 0 && id <= i32::MAX as i64 {
                return Ok(id as i32);
            }
            // Helper returns -1 for unknown windows; tao's placeholder ids (0)
            // never resolve to a real instance id either.
            return Err(CursorGrabError::Bridge(format!("window {window_id} has no real window id (helper returned {id})")));
        }
        return Err(CursorGrabError::Bridge("main thread env not available".to_string()));
    }
    Err(CursorGrabError::Bridge("helper not initialized".to_string()))
}

/// Locks/unlocks the mouse cursor to a window (tao `set_cursor_grab`).
///
/// Lock uses confined-follow mode (`isCursorFollowMovement=true`, cursor keeps
/// moving within the window area — matches Windows ClipCursor semantics). The
/// lock only takes effect while the window is focused; the system releases it
/// automatically on focus loss. Unlock restores free cursor movement.
///
/// Must be called from the main thread (NAPI helper lookup); tao's window ops
/// already run there. Returns a typed error (explicit `std::result::Result`)
/// so tao can map `NotSupported` vs OS errors without string matching.
pub fn set_cursor_grab(window_id: i64, grab: bool) -> std::result::Result<(), CursorGrabError> {
    let real_id = real_window_id(window_id)?;
    let api = cursor_lock_api().ok_or(CursorGrabError::NotSupported)?;
    let code = if grab {
        unsafe { (api.lock_cursor)(real_id, true) }
    } else {
        unsafe { (api.unlock_cursor)(real_id) }
    };
    match code {
        0 => Ok(()),
        // Unlock is idempotent: the system auto-releases the lock on focus
        // loss, so unlocking an already-unlocked window returns STATE_ABNORMAL
        // (1300002). Treat that as success — matches Windows, where clearing
        // the ClipCursor flag when not grabbed succeeds silently.
        WM_ERRORCODE_STATE_ABNORMAL if !grab => Ok(()),
        WM_ERRORCODE_DEVICE_NOT_SUPPORTED => Err(CursorGrabError::NotSupported),
        other => Err(CursorGrabError::OsCode(other)),
    }
}

/// Allocates the next global window ID without creating a window.
///
/// Used by tao when a subsequent UIAbility is created: tao
/// pre-allocates an ID, passes it to the new EntryAbility instance via
/// `want.parameters`, then calls `start_ui_ability`. The new instance's
/// `onWindowStageCreate` registers its WindowStage against this ID via
/// `register_ui_ability_stage`.
pub fn next_window_id() -> i64 {
    NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst)
}

/// Starts a new EntryAbility instance to host a window.
///
/// OHOS `context.startAbility(want)` with `abilityName: "EntryAbility"` creates
/// a new instance of the same EntryAbility class (requires `launchType: standard`
/// in module.json5). Each instance gets an independent WindowStage / main window /
/// lifecycle. `windowId` is pre-allocated by tao and carried via `want.parameters`
/// so the new instance can register its WindowStage against it.
///
/// Returns immediately (startAbility is async); the new instance's
/// `onWindowStageCreate` will call back to register its stage. tao returns
/// `window_id = Some(id)` right away so wry/WebView creation can proceed — the
/// `ProxyJsHelper` queue handles the race until the controller is ready.
pub fn start_ui_ability(
    window_id: i64,
    label: String,
    url: String,
    multiton: bool,
    transparent: bool,
) -> napi_ohos::Result<()> {
    // The ability name is fixed to "EntryAbility" here — tao (the only caller)
    // does not need to pass it. openharmony-ability owns this decision so the
    // ability class name stays a single source of truth.
    let ability_name = "EntryAbility".to_string();
    crate::info!(
        "start_ui_ability: id={}, label={}, ability={}, multiton={}, transparent={}",
        window_id, label, ability_name, multiton, transparent
    );

    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func = obj.get_named_property::<Function<'_, Object, ()>>("startUIAbility")
                .map_err(|e| {
                    crate::error!("Property 'startUIAbility' NOT FOUND on helper: {:?}", e);
                    e
                })?;

            // Build the want parameter object. ArkTS startUIAbility reads these
            // and calls context.startAbility({abilityName, parameters: {...}}).
            let mut want = Object::new(env)?;
            want.set("abilityName", ability_name)?;
            want.set("windowId", window_id)?;
            want.set("label", label)?;
            want.set("url", url)?;
            want.set("multiton", multiton)?;
            want.set("transparent", transparent)?;
            // instanceKey: unique per call → onAcceptWant returns unique key → new instance
            want.set("instanceKey", format!("win-{}", window_id))?;

            func.call(want)?;
            return Ok(());
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// instance via `register_ui_ability_stage`. Used by automated tests
/// (get_last_ui_ability_window_id command) to verify that want.parameters
/// survived the startAbility call to the new instance.
static LAST_UI_ABILITY_WINDOW_ID: AtomicI64 = AtomicI64::new(-1);

/// NAPI: Called by the new EntryAbility instance's `onWindowStageCreate` (via
/// ArkTS `WindowManager.registerUIAbilityStage`) to report the windowId
/// it received from want.parameters. Records the id globally so automated tests
/// can poll `get_last_ui_ability_window_id` and verify want-parameter forwarding.
#[napi]
pub fn register_ui_ability_stage(window_id: i64) {
    crate::info!(
        "register_ui_ability_stage: id={} (ArkTS-side registration triggered replay)",
        window_id
    );
    LAST_UI_ABILITY_WINDOW_ID.store(window_id, Ordering::SeqCst);
}

/// Reads the last windowId reported by a subsequent instance. Returns -1 if no
/// subsequent instance has registered yet. Used by automated tests.
#[napi]
pub fn get_last_ui_ability_window_id() -> i64 {
    LAST_UI_ABILITY_WINDOW_ID.load(Ordering::SeqCst)
}
