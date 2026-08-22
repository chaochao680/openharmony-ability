//! Rust-owned WebView callback declarations.
//!
//! The registry stores only Rust closures keyed by module-local WebView ID. ArkTS receives a boolean
//! subscription snapshot as part of create, then invokes every ArkWeb callback through a scoped
//! named N-API event. No ArkTS Function, ObjectRef, or JSON event payload is kept by Rust.

use std::{
    collections::BTreeMap,
    sync::{Arc, LazyLock, RwLock},
};

use napi_ohos::{Error, Result};

use super::{
    controller, WebviewCallbackOptions, WebviewDownloadEndEvent, WebviewDownloadStartRequest,
    WebviewDownloadStartResponse, WebviewDragEvent, WebviewDropEvent, WebviewHttpsInterceptRequest,
    WebviewHttpsInterceptResponse, WebviewNavigationRequest, WebviewNavigationResponse,
    WebviewNewWindowRequest, WebviewNewWindowResponse, WebviewPageEvent, WebviewTitleChangeEvent,
};

type NavigationCallback = Arc<dyn Fn(WebviewNavigationRequest) -> bool + Send + Sync + 'static>;
type DownloadStartCallback = Arc<
    dyn Fn(WebviewDownloadStartRequest) -> WebviewDownloadStartResponse + Send + Sync + 'static,
>;
type DownloadEndCallback = Arc<dyn Fn(WebviewDownloadEndEvent) + Send + Sync + 'static>;
type TitleChangeCallback = Arc<dyn Fn(WebviewTitleChangeEvent) + Send + Sync + 'static>;
type DragEnterCallback = Arc<dyn Fn(WebviewDragEvent) + Send + Sync + 'static>;
type DragOverCallback = Arc<dyn Fn(WebviewDragEvent) + Send + Sync + 'static>;
type DragDropCallback = Arc<dyn Fn(WebviewDropEvent) + Send + Sync + 'static>;
type DragLeaveCallback = Arc<dyn Fn(WebviewDragEvent) + Send + Sync + 'static>;
type NewWindowCallback =
    Arc<dyn Fn(WebviewNewWindowRequest) -> bool + Send + Sync + 'static>;
type PageBeginCallback = Arc<dyn Fn(WebviewPageEvent) + Send + Sync + 'static>;
type PageEndCallback = Arc<dyn Fn(WebviewPageEvent) + Send + Sync + 'static>;
type CloseWindowCallback = Arc<dyn Fn() + Send + Sync + 'static>;
type HttpsInterceptCallback = Arc<
    dyn Fn(WebviewHttpsInterceptRequest) -> WebviewHttpsInterceptResponse + Send + Sync + 'static,
>;

/// URL prefixes that route to the close-window callback instead of the navigation callback.
const CLOSE_WINDOW_URL_PREFIXES: &[&str] = &["close-window.invalid", "http://close-window.invalid"];

#[derive(Default, Clone)]
struct WebviewCallbacks {
    navigation: Option<NavigationCallback>,
    download_start: Option<DownloadStartCallback>,
    download_end: Option<DownloadEndCallback>,
    title_change: Option<TitleChangeCallback>,
    drag_enter: Option<DragEnterCallback>,
    drag_over: Option<DragOverCallback>,
    drag_drop: Option<DragDropCallback>,
    drag_leave: Option<DragLeaveCallback>,
    new_window: Option<NewWindowCallback>,
    page_begin: Option<PageBeginCallback>,
    page_end: Option<PageEndCallback>,
    close_window: Option<CloseWindowCallback>,
    https_intercept: Option<HttpsInterceptCallback>,
}

impl WebviewCallbacks {
    fn options(&self) -> WebviewCallbackOptions {
        WebviewCallbackOptions {
            navigation_intercept: self.navigation.is_some() || self.close_window.is_some(),
            download_start: self.download_start.is_some(),
            download_end: self.download_end.is_some(),
            title_change: self.title_change.is_some(),
            drag_drop: self.drag_enter.is_some()
                || self.drag_over.is_some()
                || self.drag_drop.is_some()
                || self.drag_leave.is_some(),
            new_window: self.new_window.is_some(),
            page_begin: self.page_begin.is_some(),
            page_end: self.page_end.is_some(),
        }
    }

    fn is_empty(&self) -> bool {
        self.navigation.is_none()
            && self.download_start.is_none()
            && self.download_end.is_none()
            && self.title_change.is_none()
            && self.drag_enter.is_none()
            && self.drag_over.is_none()
            && self.drag_drop.is_none()
            && self.drag_leave.is_none()
            && self.new_window.is_none()
            && self.page_begin.is_none()
            && self.page_end.is_none()
            && self.close_window.is_none()
            && self.https_intercept.is_none()
    }
}

static CALLBACKS: LazyLock<RwLock<BTreeMap<String, WebviewCallbacks>>> =
    LazyLock::new(|| RwLock::new(BTreeMap::new()));

/// Builder for Rust-owned WebView lifecycle and platform callbacks.
///
/// Build this before WebviewClient::create. Calling build for the same ID replaces the previous
/// declaration and callback declarations remain valid across a remove and create cycle.
#[derive(Default)]
pub struct WebviewCallbacksBuilder {
    webview_id: String,
    callbacks: WebviewCallbacks,
}

impl WebviewCallbacksBuilder {
    pub fn new(webview_id: impl Into<String>) -> Self {
        Self {
            webview_id: webview_id.into(),
            callbacks: WebviewCallbacks::default(),
        }
    }

    /// Decides whether ArkWeb should intercept a navigation. The callback runs synchronously on
    /// the active N-API main-thread callback and must return promptly.
    pub fn on_navigation_request<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewNavigationRequest) -> bool + Send + Sync + 'static,
    {
        self.callbacks.navigation = Some(Arc::new(callback));
        self
    }

    /// Admits, cancels, or redirects a download before ArkWeb starts it. The callback runs
    /// synchronously on the active N-API main-thread callback and must return promptly.
    pub fn on_download_start<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewDownloadStartRequest) -> WebviewDownloadStartResponse + Send + Sync + 'static,
    {
        self.callbacks.download_start = Some(Arc::new(callback));
        self
    }

    /// Receives successful and failed download completion notifications on the active N-API
    /// callback. It has no platform decision response, but should still return promptly.
    pub fn on_download_end<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewDownloadEndEvent) + Send + Sync + 'static,
    {
        self.callbacks.download_end = Some(Arc::new(callback));
        self
    }

    /// Receives page title updates on the active N-API callback and should return promptly.
    pub fn on_title_change<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewTitleChangeEvent) + Send + Sync + 'static,
    {
        self.callbacks.title_change = Some(Arc::new(callback));
        self
    }

    /// Receives drag-enter notifications. `getData()` is not valid in this callback; paths are
    /// empty.
    pub fn on_drag_enter<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewDragEvent) + Send + Sync + 'static,
    {
        self.callbacks.drag_enter = Some(Arc::new(callback));
        self
    }

    /// Receives drag-move (over) notifications.
    pub fn on_drag_over<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewDragEvent) + Send + Sync + 'static,
    {
        self.callbacks.drag_over = Some(Arc::new(callback));
        self
    }

    /// Receives drag-drop notifications. `getData()` is valid; paths are extracted from UDMF
    /// records.
    pub fn on_drag_drop<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewDropEvent) + Send + Sync + 'static,
    {
        self.callbacks.drag_drop = Some(Arc::new(callback));
        self
    }

    /// Receives drag-leave notifications.
    pub fn on_drag_leave<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewDragEvent) + Send + Sync + 'static,
    {
        self.callbacks.drag_leave = Some(Arc::new(callback));
        self
    }

    /// Decides whether ArkWeb should allow a new window. Returns `true` to allow, `false` to deny.
    /// When no callback is registered, the default is deny.
    pub fn on_new_window_request<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewNewWindowRequest) -> bool + Send + Sync + 'static,
    {
        self.callbacks.new_window = Some(Arc::new(callback));
        self
    }

    /// Receives page-begin (navigation started) notifications.
    pub fn on_page_begin<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewPageEvent) + Send + Sync + 'static,
    {
        self.callbacks.page_begin = Some(Arc::new(callback));
        self
    }

    /// Receives page-end (navigation completed) notifications.
    pub fn on_page_end<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewPageEvent) + Send + Sync + 'static,
    {
        self.callbacks.page_end = Some(Arc::new(callback));
        self
    }

    /// Called when a `close-window.invalid` URL is intercepted, requesting the host window to
    /// close. The callback signature is `Fn() + Send + Sync + 'static` (not FnMut).
    pub fn on_close_window<F>(mut self, callback: F) -> Self
    where
        F: Fn() + Send + Sync + 'static,
    {
        self.callbacks.close_window = Some(Arc::new(callback));
        self
    }

    /// Synchronously handles an https intercept request from ArkWeb's `onInterceptRequest`.
    ///
    /// The callback runs on the active N-API main-thread callback and must return promptly, before
    /// the `Env` is released. Returning `handled: false` lets ArkWeb fall through to its default
    /// network stack; returning `handled: true` delivers the embedded response to ArkWeb.
    pub fn on_https_intercept_request<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewHttpsInterceptRequest) -> WebviewHttpsInterceptResponse
            + Send
            + Sync
            + 'static,
    {
        self.callbacks.https_intercept = Some(Arc::new(callback));
        self
    }

    pub fn build(self) -> Result<()> {
        if self.webview_id.trim().is_empty() {
            return Err(Error::from_reason("WebView callback id must not be empty"));
        }
        if self.callbacks.is_empty() {
            return Err(Error::from_reason(
                "WebView callbacks must declare at least one callback",
            ));
        }
        CALLBACKS
            .write()
            .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
            .insert(self.webview_id, self.callbacks);
        Ok(())
    }
}

pub(crate) fn options_for(webview_id: &str) -> Result<WebviewCallbackOptions> {
    let callbacks = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?;
    Ok(callbacks
        .get(webview_id)
        .map(WebviewCallbacks::options)
        .unwrap_or_default())
}

pub(crate) fn navigation_decision(
    request: WebviewNavigationRequest,
) -> Result<WebviewNavigationResponse> {
    if !controller::is_current(&request.id, &request.native_tag)? {
        return Ok(WebviewNavigationResponse { intercept: false });
    }
    // Route close-window URLs to the dedicated close_window callback before the generic
    // navigation callback, so both can coexist without double-firing.
    if is_close_window_url(&request.url) {
        let close_callback = CALLBACKS
            .read()
            .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
            .get(&request.id)
            .and_then(|callbacks| callbacks.close_window.as_ref())
            .cloned();
        if let Some(close_callback) = close_callback {
            close_callback();
        }
        return Ok(WebviewNavigationResponse { intercept: true });
    }
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&request.id)
        .and_then(|callbacks| callbacks.navigation.as_ref())
        .cloned();
    Ok(WebviewNavigationResponse {
        intercept: callback.map(|callback| callback(request)).unwrap_or(false),
    })
}

/// Returns true if the URL matches a close-window route prefix.
fn is_close_window_url(url: &str) -> bool {
    CLOSE_WINDOW_URL_PREFIXES
        .iter()
        .any(|prefix| url.starts_with(prefix))
}

pub(crate) fn download_start_decision(
    request: WebviewDownloadStartRequest,
) -> Result<WebviewDownloadStartResponse> {
    if !controller::is_current(&request.id, &request.native_tag)? {
        return Ok(WebviewDownloadStartResponse::cancel());
    }
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&request.id)
        .and_then(|callbacks| callbacks.download_start.as_ref())
        .cloned();
    Ok(callback
        .map(|callback| callback(request))
        .unwrap_or_else(WebviewDownloadStartResponse::cancel))
}

/// Synchronously resolves an https intercept request by invoking the registered Rust handler.
///
/// Returns `handled: false` when no handler is registered, the controller generation is stale,
/// or the handler declines. The caller (ArkTS `onInterceptRequest`) translates `handled: false`
/// into a `null` return so ArkWeb uses its default network stack.
pub(crate) fn https_intercept_decision(
    request: WebviewHttpsInterceptRequest,
) -> Result<WebviewHttpsInterceptResponse> {
    if !controller::is_current(&request.id, &request.native_tag)? {
        return Ok(WebviewHttpsInterceptResponse::passthrough());
    }
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&request.id)
        .and_then(|callbacks| callbacks.https_intercept.as_ref())
        .cloned();
    Ok(callback
        .map(|callback| callback(request))
        .unwrap_or_else(|| WebviewHttpsInterceptResponse::passthrough()))
}

pub(crate) fn dispatch_drag_enter(event: WebviewDragEvent) -> Result<()> {
    if !controller::is_current(&event.id, &event.native_tag)? {
        return Ok(());
    }
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&event.id)
        .and_then(|callbacks| callbacks.drag_enter.as_ref())
        .cloned();
    if let Some(callback) = callback {
        callback(event);
    }
    Ok(())
}

pub(crate) fn dispatch_drag_over(event: WebviewDragEvent) -> Result<()> {
    if !controller::is_current(&event.id, &event.native_tag)? {
        return Ok(());
    }
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&event.id)
        .and_then(|callbacks| callbacks.drag_over.as_ref())
        .cloned();
    if let Some(callback) = callback {
        callback(event);
    }
    Ok(())
}

pub(crate) fn dispatch_drag_drop(event: WebviewDropEvent) -> Result<()> {
    if !controller::is_current(&event.id, &event.native_tag)? {
        return Ok(());
    }
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&event.id)
        .and_then(|callbacks| callbacks.drag_drop.as_ref())
        .cloned();
    if let Some(callback) = callback {
        callback(event);
    }
    Ok(())
}

pub(crate) fn dispatch_drag_leave(event: WebviewDragEvent) -> Result<()> {
    if !controller::is_current(&event.id, &event.native_tag)? {
        return Ok(());
    }
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&event.id)
        .and_then(|callbacks| callbacks.drag_leave.as_ref())
        .cloned();
    if let Some(callback) = callback {
        callback(event);
    }
    Ok(())
}

pub(crate) fn new_window_decision(
    request: WebviewNewWindowRequest,
) -> Result<WebviewNewWindowResponse> {
    if !controller::is_current(&request.id, &request.native_tag)? {
        return Ok(WebviewNewWindowResponse { allow: false });
    }
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&request.id)
        .and_then(|callbacks| callbacks.new_window.as_ref())
        .cloned();
    Ok(WebviewNewWindowResponse {
        allow: callback.map(|callback| callback(request)).unwrap_or(false),
    })
}

pub(crate) fn dispatch_page_begin(event: WebviewPageEvent) -> Result<()> {
    if !controller::is_current(&event.id, &event.native_tag)? {
        return Ok(());
    }
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&event.id)
        .and_then(|callbacks| callbacks.page_begin.as_ref())
        .cloned();
    if let Some(callback) = callback {
        callback(event);
    }
    Ok(())
}

pub(crate) fn dispatch_page_end(event: WebviewPageEvent) -> Result<()> {
    if !controller::is_current(&event.id, &event.native_tag)? {
        return Ok(());
    }
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&event.id)
        .and_then(|callbacks| callbacks.page_end.as_ref())
        .cloned();
    if let Some(callback) = callback {
        callback(event);
    }
    Ok(())
}

pub(crate) fn dispatch_download_end(event: WebviewDownloadEndEvent) -> Result<()> {
    if !controller::is_current(&event.id, &event.native_tag)? {
        return Ok(());
    }
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&event.id)
        .and_then(|callbacks| callbacks.download_end.as_ref())
        .cloned();
    if let Some(callback) = callback {
        callback(event);
    }
    Ok(())
}

pub(crate) fn dispatch_title_change(event: WebviewTitleChangeEvent) -> Result<()> {
    if !controller::is_current(&event.id, &event.native_tag)? {
        return Ok(());
    }
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&event.id)
        .and_then(|callbacks| callbacks.title_change.as_ref())
        .cloned();
    if let Some(callback) = callback {
        callback(event);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    use super::{is_close_window_url, navigation_decision, WebviewCallbacksBuilder};
    use crate::{controller, WebviewNavigationRequest};

    #[test]
    fn callback_builder_rejects_an_empty_declaration() {
        assert!(WebviewCallbacksBuilder::new("webview").build().is_err());
    }

    #[test]
    fn stale_controller_callback_cannot_reach_a_replacement_webview() {
        let calls = Arc::new(AtomicUsize::new(0));
        let callback_calls = Arc::clone(&calls);
        WebviewCallbacksBuilder::new("stale-callback-test")
            .on_navigation_request(move |_| {
                callback_calls.fetch_add(1, Ordering::Relaxed);
                true
            })
            .build()
            .unwrap();
        controller::on_attached("stale-callback-test", "native-new").unwrap();

        let stale = navigation_decision(WebviewNavigationRequest {
            id: "stale-callback-test".to_owned(),
            native_tag: "native-old".to_owned(),
            url: "https://stale.example".to_owned(),
        })
        .unwrap();
        assert!(!stale.intercept);
        assert_eq!(calls.load(Ordering::Relaxed), 0);

        let current = navigation_decision(WebviewNavigationRequest {
            id: "stale-callback-test".to_owned(),
            native_tag: "native-new".to_owned(),
            url: "https://current.example".to_owned(),
        })
        .unwrap();
        assert!(current.intercept);
        assert_eq!(calls.load(Ordering::Relaxed), 1);
        controller::on_removed("stale-callback-test", "native-new").unwrap();
    }

    #[test]
    fn close_window_url_prefix_is_detected() {
        assert!(is_close_window_url("close-window.invalid"));
        assert!(is_close_window_url("http://close-window.invalid"));
        assert!(is_close_window_url("close-window.invalid/some/path"));
        assert!(is_close_window_url("http://close-window.invalid/foo"));
        assert!(!is_close_window_url("https://example.com"));
        assert!(!is_close_window_url("http://example.com/close-window.invalid"));
    }

    #[test]
    fn close_window_callback_routes_and_intercepts_navigation() {
        let close_calls = Arc::new(AtomicUsize::new(0));
        let close_callback_calls = Arc::clone(&close_calls);
        WebviewCallbacksBuilder::new("close-window-test")
            .on_close_window(move || {
                close_callback_calls.fetch_add(1, Ordering::Relaxed);
            })
            .build()
            .unwrap();
        controller::on_attached("close-window-test", "native-cw").unwrap();

        let response = navigation_decision(WebviewNavigationRequest {
            id: "close-window-test".to_owned(),
            native_tag: "native-cw".to_owned(),
            url: "http://close-window.invalid".to_owned(),
        })
        .unwrap();
        assert!(response.intercept);
        assert_eq!(close_calls.load(Ordering::Relaxed), 1);

        // Normal URL does not trigger close-window.
        let normal = navigation_decision(WebviewNavigationRequest {
            id: "close-window-test".to_owned(),
            native_tag: "native-cw".to_owned(),
            url: "https://example.com".to_owned(),
        })
        .unwrap();
        assert!(!normal.intercept);
        assert_eq!(close_calls.load(Ordering::Relaxed), 1);

        controller::on_removed("close-window-test", "native-cw").unwrap();
    }
}
