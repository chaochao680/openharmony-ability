import { window, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import pointer from '@ohos.multimodalInput.pointer';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { RustWebviewNodeController, WebviewInitData, WebviewStyle } from '../webview/DefaultWebview';
import { ProxyJsHelper } from '../webview/Utils';
import * as FloatPage from '../components/FloatPage';
import { DOMAIN } from '../helper/constants';
import { objectAssign } from '../helper';

interface WindowEntry {
  window: window.Window;
  storage?: LocalStorage;
}

// Encapsulates all parameters for sub-window creation, replacing a 10-arg signature.
export interface SubWindowOptions {
  name: string;
  windowId: number;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  decorations?: boolean;
  transparent?: boolean;
  backgroundColor?: number;
}

// Enum of window kinds. All UIAbility windows are equal, no primary/subordinate distinction.
export enum WindowKind {
  UIAbility,  // All UIAbility main windows (id=0 or id>0, equivalent)
  Float,      // Float sub-window created by windowStage.createSubWindow
}

export class WindowManager {
  private static instance: WindowManager | null = null;
  private context: common.UIAbilityContext;
  private uiAbilityStages: Map<number, window.WindowStage> = new Map();
  // Per-instance UIAbilityContext (keyed by windowId). Needed to terminate a
  // specific secondary instance via context.terminateSelf() — the process-level
  // `this.context` only refers to the first instance, so without this map a
  // secondary instance cannot be truly closed (only hidden via hideAbility).
  private uiAbilityContexts: Map<number, common.UIAbilityContext> = new Map();
  private windows: Map<number, WindowEntry> = new Map();
  private controllers: Map<number, RustWebviewNodeController> = new Map();
  private uiContexts: Map<number, UIContext> = new Map();
  // transparentFlags tracks each UIAbility window's transparent flag (keyed by windowId).
  // Set in registerUIAbilityStage, queried by DefaultXComponent.aboutToAppear to apply
  // setWindowBackgroundColor/setWindowContainerColor after the window is fully ready.
  private transparentFlags: Map<number, boolean> = new Map();

  // windowKinds tracks each window's kind (UIAbility or Float) by windowId.
  // Used by isUIAbilityMainWindow() — windowId=0 is NOT special, all UIAbility
  // windows (id=0 or id>0) are equal and system-managed.
  private windowKinds: Map<number, WindowKind> = new Map();

  // Track the last focused window via WINDOW_ACTIVE (kept for backward compat / debugging)
  private lastFocusedWindow: window.Window | null = null;
  private lastFocusedWindowId: number = -1;

  // Track the window the user last physically touched (onTouch-based).
  // Unlike WINDOW_ACTIVE, onTouch only fires on actual user touch — immune to
  // cascade broadcasts, GoForeground events, and programmatic showWindow().
  // Semantically equivalent to macOS Key Window / Windows Foreground Window.
  private lastUserInteractedWindowId: number = -1;

  // Pending window action for StatusBar menu race condition fix
  // When a tray menu item is clicked, the system triggers onNewWant → GoForeground
  // which can undo our window operations (minimize/hide/close).
  // Solution: defer window operations until WINDOW_ACTIVE/WINDOW_SHOWN event fires.
  private pendingAction: (() => void) | null = null;
  private cleanupTimer: number | null = null;

  // Proxy object queue (caches Rust operations before Controller is ready)
  private pendingJsHelperProxies: Map<number, ProxyJsHelper> = new Map();

  // Pending URL queue
  private pendingUrls: Map<number, string> = new Map();
  // Pending WebView init queue (resolves race conditions)
  private pendingInits: Map<number, WebviewInitData> = new Map();
  // Pending window blur queue (vibrancy effect applied before webview controller is ready)
  private pendingBlurs: Map<number, number> = new Map();

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  static init(context: common.UIAbilityContext): void {
    if (!WindowManager.instance) {
      hilog.info(DOMAIN, 'WindowManager', 'WindowManager initialized');
      WindowManager.instance = new WindowManager(context);
    }
  }

  static getInstance(): WindowManager {
    hilog.info(DOMAIN, 'WindowManager', 'WindowManager getInstance');
    if (!WindowManager.instance) {
      hilog.error(DOMAIN, 'WindowManager', 'WindowManager not initialized');
      throw new Error("WindowManager not initialized");
    }
    return WindowManager.instance;
  }

  // Exposes the UIAbilityContext so NativeAbility.startUIAbility can call
  // context.startAbility without holding its own reference (WindowManager is the
  // shared singleton across EntryAbility instances in the same process).
  getContext(): common.UIAbilityContext {
    return this.context;
  }

  // Whether the primary (first-instance) WindowStage has been registered.
  // Unified registration for all UIAbility WindowStages (id=0 first instance
  // or id>0 subsequent instances — equal, no primary/subordinate distinction).
  // Stores stage in uiAbilityStages, sets windowKinds, replays pending init,
  // and registers focus tracking.
  registerUIAbilityStage(windowId: number, windowStage: window.WindowStage, context: common.UIAbilityContext, transparent: boolean = false): void {
    const wid = Number(windowId);
    this.uiAbilityStages.set(wid, windowStage);
    this.uiAbilityContexts.set(wid, context);
    this.windowKinds.set(wid, WindowKind.UIAbility);
    this.transparentFlags.set(wid, transparent);
    hilog.info(DOMAIN, 'WindowManager', 'UIAbility stage registered: id=%{public}d transparent=%{public}s', wid, String(transparent));
    this.replayPendingForWindow(wid);

    // Register focus tracking for this window
    try {
      const mainWindow = windowStage.getMainWindowSync();
      this.registerFocusTracking(mainWindow, wid);
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', 'Failed to register focus tracking for id=%{public}d: %{public}s', wid, String(e));
    }

    // Transparency is applied in createWebview (when data.transparent=true),
    // not here — onWindowStageCreate is too early (setWindowBackgroundColor
    // fails with "window state is abnormal"). createWebview runs after the
    // window is fully ready, so setWindowContainerColor succeeds there.
  }

  unregisterUIAbilityStage(windowId: number): void {
    const wid = Number(windowId);
    this.uiAbilityStages.delete(wid);
    this.uiAbilityContexts.delete(wid);
    this.windowKinds.delete(wid);
    this.transparentFlags.delete(wid);
    this.controllers.delete(wid);
    this.uiContexts.delete(wid);
    this.pendingInits.delete(wid);
    this.pendingUrls.delete(wid);
    this.pendingJsHelperProxies.delete(wid);
    this.pendingBlurs.delete(wid);
    hilog.info(DOMAIN, 'WindowManager', 'UIAbility stage unregistered: id=%{public}d', wid);
  }

  // Whether the given window is a UIAbility main window.
  // Such windows are system-managed: win.resize()/moveWindowTo() return 1300002,
  // decorations are system-provided, and per-button enable flags are no-ops.
  // windowId=0 alone must NOT be used for this judgement — a subsequent UIAbility
  // instance has id>0 but is still a system-managed main window.
  isUIAbilityMainWindow(windowId: number): boolean {
    const wid = Number(windowId);
    return this.windowKinds.get(wid) === WindowKind.UIAbility;
  }

  // Query whether a UIAbility window was created with transparent=true.
  isTransparent(windowId: number): boolean {
    const wid = Number(windowId);
    return this.transparentFlags.get(wid) === true;
  }

  // Apply transparent background + container color to a UIAbility main window.
  // Called by DefaultXComponent.aboutToAppear (window fully ready there).
  // active=transparent, inactive=opaque white (inactive alpha=0 triggers error 401).
  async applyTransparentBackground(windowId: number): Promise<void> {
    const wid = Number(windowId);
    if (!this.isTransparent(wid)) {
      return;
    }
    const stage = this.uiAbilityStages.get(wid);
    if (!stage) {
      hilog.warn(DOMAIN, 'WindowManager', 'applyTransparentBackground: no stage for id=%{public}d', wid);
      return;
    }
    try {
      const mainWindow = await stage.getMainWindow();
      mainWindow.setWindowBackgroundColor('#00000000');
      hilog.info(DOMAIN, 'WindowManager', 'applyTransparentBackground: windowId=%{public}d setWindowBackgroundColor transparent OK', wid);
      if (deviceInfo.sdkApiVersion >= 20) {
        try {
          mainWindow.setWindowContainerColor('#00000000', '#FFFFFFFF');
          hilog.info(DOMAIN, 'WindowManager', 'applyTransparentBackground: windowId=%{public}d setWindowContainerColor transparent OK (active=transparent inactive=white)', wid);
        } catch (containerErr: any) {
          hilog.warn(DOMAIN, 'WindowManager', 'applyTransparentBackground: windowId=%{public}d setWindowContainerColor failed: code=%{public}d', wid, containerErr.code);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', 'applyTransparentBackground: windowId=%{public}d failed: %{public}s', wid, String(e));
    }
  }

  // Replay pending WebView init data / URLs queued against a window id before its
  // controller was ready. Called by registerUIAbilityStage when the new
  // UIAbility instance's WindowStage is registered. The JsHelper proxy binding is
  // NOT done here — it requires a full JsHelper (result.controller from addWebview),
  // not the raw RustWebviewNodeController stored in this.controllers. Proxy binding
  // happens in registerController when DefaultXComponent.aboutToAppear runs and
  // calls addWebview (which returns the full JsHelper).
  private replayPendingForWindow(wid: number): void {
    const controller = this.controllers.get(wid);
    if (!controller) {
      // Controller not registered yet (DefaultXComponent.aboutToAppear hasn't run).
      // Replay will be triggered again by registerController.
      return;
    }
    const init = this.pendingInits.get(wid);
    if (init) {
      try {
        controller.addWebview(init);
      } catch (e) {
        hilog.warn(DOMAIN, 'WindowManager', 'replayPendingForWindow addWebview %{public}d failed: %{public}s', wid, String(e));
      }
      this.pendingInits.delete(wid);
    }
    const url = this.pendingUrls.get(wid);
    if (url) {
      try {
        const urlData: WebviewInitData = { url };
        controller.addWebview(urlData);
      } catch (e) {
        hilog.warn(DOMAIN, 'WindowManager', 'replayPendingForWindow url load %{public}d failed: %{public}s', wid, String(e));
      }
      this.pendingUrls.delete(wid);
    }
  }

  // Register WINDOW_ACTIVE listener for focus tracking
  // Also listens for RESUMED/WINDOW_ACTIVE to consume pending actions
  private registerFocusTracking(win: window.Window, windowId: number): void {
    win.on('windowEvent', (eventType: window.WindowEventType) => {
      // Track last focused window
      if (eventType === window.WindowEventType.WINDOW_ACTIVE) {
        this.lastFocusedWindow = win;
        this.lastFocusedWindowId = windowId;
        hilog.info(DOMAIN, 'WindowManager', 'Last focused window updated: id=%{public}d', windowId);
      }

      // Consume pending action when system foreground transition completes
      // WINDOW_ACTIVE: window gained focus (marks end of foreground transition)
      // WINDOW_SHOWN: window is visible (alternative trigger)
      if (eventType === window.WindowEventType.WINDOW_ACTIVE ||
          eventType === window.WindowEventType.WINDOW_SHOWN) {
        if (this.hasPendingAction()) {
          hilog.info(DOMAIN, 'WindowManager',
            'System foreground transition complete (event: %{public}s), executing pending action',
            eventType === window.WindowEventType.WINDOW_ACTIVE ? 'WINDOW_ACTIVE' : 'WINDOW_SHOWN');
          this.consumePendingAction();
        }
      }

    });
  }

  // Get the last focused window via WINDOW_ACTIVE (kept for backward compat)
  getFocusedWindow(): window.Window | null {
    return this.lastFocusedWindow;
  }

  // Get the last focused window ID
  getFocusedWindowId(): number {
    return this.lastFocusedWindowId;
  }

  // ─── User Interaction Tracking (onTouch-based window targeting) ───
  //
  // Called from page root Stack.onTouch() (MainPage/FloatPage, D8) when the user physically touches a window.
  // ArkUI onTouch bubbles from child to parent, covering MenuBarComponent + webview + drag bars.
  // Used by tray menu to determine which window to operate on.
  setUserInteractedWindow(windowId: number): void {
    this.lastUserInteractedWindowId = windowId;
    hilog.info(DOMAIN, 'WindowManager', 'User interacted with window: id=%{public}d', windowId);
  }

  // Get the window the user last physically touched (for Tray menu path)
  getUserInteractedWindow(): window.Window | null {
    if (this.lastUserInteractedWindowId < 0) {
      return null;
    }
    return this.getWindow(this.lastUserInteractedWindowId) ?? null;
  }

  // Get the ID of the window the user last physically touched
  getUserInteractedWindowId(): number {
    return this.lastUserInteractedWindowId;
  }

  // Reset user interaction tracking after window becomes invisible (minimize/hide/close).
  // Subsequent tray menu operations will fall back to main window.
  resetUserInteractionTracking(): void {
    this.lastUserInteractedWindowId = -1;
  }

  // ─── Window Operation Wrappers ───
  // These wrappers ensure resetUserInteractionTracking() is called after operations
  // that make a window invisible (minimize/hide/close).

  minimizeWindow(windowId: number): void {
    // 拦截:FLAG_MINIMIZABLE 为 0 时,不允许最小化(问题四:语义错位修复)
    if (!this.getDecorationFlag(windowId, 'minimizable')) {
      hilog.warn(DOMAIN, 'WindowManager', 'minimizeWindow blocked: minimizable flag not set (window %{public}d)', windowId);
      return;
    }
    const win = this.getWindow(windowId);
    if (!win) {
      hilog.warn(DOMAIN, 'WindowManager', 'minimizeWindow: window %{public}d not found', windowId);
      return;
    }
    // Fire-and-forget with .catch — matches sibling ops (moveWindowTo/resizeWindow/...).
    // The previous async/Promise-returning form leaked an unhandled rejection when the
    // caller (ArkHelper) invoked it without awaiting.
    win.minimize().then(() => {
      // Only reset tracking if the minimized window was the last interacted one
      if (this.lastUserInteractedWindowId === windowId) {
        this.resetUserInteractionTracking();
      }
    }).catch((err: ESObject) => {
      hilog.error(DOMAIN, 'WindowManager', 'minimizeWindow failed: %{public}s', JSON.stringify(err));
    });
  }

  focusWindow(windowId: number): void {
    const win = this.getWindow(windowId);
    if (!win) {
      hilog.warn(DOMAIN, 'WindowManager', 'focusWindow: window %{public}d not found', windowId);
      return;
    }
    win.raiseToAppTop().then(() => {
      hilog.debug(DOMAIN, 'WindowManager', 'focusWindow: window %{public}d raised to top', windowId);
    }).catch((err: ESObject) => {
      hilog.error(DOMAIN, 'WindowManager', 'focusWindow: raiseToAppTop failed: %{public}s', String(err));
    });
  }

  setWindowFocusable(windowId: number, focusable: boolean): void {
    const win = this.getWindow(windowId);
    if (!win) {
      hilog.warn(DOMAIN, 'WindowManager', 'setWindowFocusable: window %{public}d not found', windowId);
      return;
    }
    win.setWindowFocusable(focusable).then(() => {
      hilog.debug(DOMAIN, 'WindowManager', 'setWindowFocusable: window %{public}d focusable=%{public}s', windowId, String(focusable));
    }).catch((err: ESObject) => {
      hilog.error(DOMAIN, 'WindowManager', 'setWindowFocusable failed: %{public}s', JSON.stringify(err));
    });
  }

  // ─── Window operations (ohos-window-ops) ───

  moveWindowTo(windowId: number, x: number, y: number): void {
    const wid = Number(windowId);
    const win = this.getWindow(wid);
    if (!win) { this.logNotFound('moveWindowTo', wid); return; }
    win.moveWindowTo(x, y).catch((err: ESObject) => {
      hilog.warn(DOMAIN, 'WindowManager', 'moveWindowTo %{public}d failed: %{public}s', wid, JSON.stringify(err));
    });
  }

  resizeWindow(windowId: number, width: number, height: number): void {
    const wid = Number(windowId);
    const win = this.getWindow(wid);
    if (!win) { this.logNotFound('resizeWindow', wid); return; }
    win.resize(width, height).catch((err: ESObject) => {
      hilog.warn(DOMAIN, 'WindowManager', 'resizeWindow %{public}d failed: %{public}s', wid, JSON.stringify(err));
    });
  }

  maximizeWindow(windowId: number): void {
    // 拦截:FLAG_MAXIMIZABLE 为 0 时,不允许最大化(问题四:语义错位修复)
    if (!this.getDecorationFlag(windowId, 'maximizable')) {
      hilog.warn(DOMAIN, 'WindowManager', 'maximizeWindow blocked: maximizable flag not set (window %{public}d)', windowId);
      return;
    }
    const win = this.getWindow(windowId);
    if (!win) { hilog.warn(DOMAIN, 'WindowManager', 'maximizeWindow: window %{public}d not found', windowId); return; }
    win.maximize(window.MaximizePresentation.EXIT_IMMERSIVE).catch((err: ESObject) => {
      hilog.error(DOMAIN, 'WindowManager', 'maximizeWindow failed: %{public}s', JSON.stringify(err));
    });
  }

  setWindowTopmost(windowId: number, topmost: boolean): void {
    // win.setWindowTopmost() is API14+. Requires ohos.permission.WINDOW_TOPMOST
    // (system_grant, declared in module.json5). Main window only — Float sub-windows
    // will error (non-fatal). Only effective in freeform window mode; returns 801
    // on devices without freeform support (phone/tablet).
    if (deviceInfo.sdkApiVersion < 14) {
      hilog.warn(DOMAIN, 'WindowManager', 'setWindowTopmost: API14+ required, current %{public}d; no-op', deviceInfo.sdkApiVersion);
      return;
    }
    const win = this.getWindow(windowId);
    if (!win) { hilog.warn(DOMAIN, 'WindowManager', 'setWindowTopmost: window %{public}d not found', windowId); return; }
    win.setWindowTopmost(topmost).then(() => {
      hilog.info(DOMAIN, 'WindowManager', 'setWindowTopmost %{public}d topmost=%{public}s OK', windowId, String(topmost));
    }).catch((err: ESObject) => {
      // 801: non-freeform device/state; sub-window call; 1300002: window state abnormal — non-fatal
      hilog.warn(DOMAIN, 'WindowManager', 'setWindowTopmost %{public}d failed: %{public}s', windowId, JSON.stringify(err));
    });
  }

  setWindowTitle(windowId: number, title: string): void {
    // win.setWindowTitle(title) is Promise form (1 arg). Main window + Float sub-windows
    // both support title text (icon is NOT changeable at runtime). No extra permission
    // for main window. Only visible when window decorations are enabled (decorEnabled=true).
    const win = this.getWindow(windowId);
    if (!win) { hilog.warn(DOMAIN, 'WindowManager', 'setWindowTitle: window %{public}d not found', windowId); return; }
    // Also update LocalStorage 'title' so FloatPage @LocalStorageProp('title') refreshes the title bar text.
    const entry = this.windows.get(windowId);
    if (entry?.storage) {
      entry.storage.setOrCreate('title', title);
    }
    win.setWindowTitle(title).then(() => {
      hilog.info(DOMAIN, 'WindowManager', 'setWindowTitle %{public}d title="%{public}s" OK', windowId, title);
    }).catch((err: ESObject) => {
      hilog.warn(DOMAIN, 'WindowManager', 'setWindowTitle %{public}d failed: %{public}s', windowId, JSON.stringify(err));
    });
  }

  setWindowLimits(windowId: number, minW: number, minH: number, maxW: number, maxH: number): void {
    // win.setWindowLimits() is API11+. Params are px (0 = no limit / system default).
    // WindowLimits fields: minWidth/minHeight/maxWidth/maxHeight (NOT minWindowWidth etc.)
    // ⚠️ Triggers OnSizeChange — caller must not invoke frequently on main window (appfreeze risk).
    const win = this.getWindow(windowId);
    if (!win) { hilog.warn(DOMAIN, 'WindowManager', 'setWindowLimits: window %{public}d not found', windowId); return; }
    const limits: window.WindowLimits = {
      minWidth: minW,
      minHeight: minH,
      maxWidth: maxW,
      maxHeight: maxH,
    };
    win.setWindowLimits(limits).then((actual: window.WindowLimits) => {
      hilog.info(DOMAIN, 'WindowManager', 'setWindowLimits %{public}d OK: min=%{public}dx%{public}d max=%{public}dx%{public}d',
        windowId, actual.minWidth, actual.minHeight, actual.maxWidth, actual.maxHeight);
    }).catch((err: ESObject) => {
      hilog.warn(DOMAIN, 'WindowManager', 'setWindowLimits %{public}d failed: %{public}s', windowId, JSON.stringify(err));
    });
  }

  restoreWindow(windowId: number): void {
    // Mirror the Rust-side API14 guard (win.restore() is API14+). The Rust path
    // (restore_window) already guards, so this is defense-in-depth for any direct
    // ArkTS caller; on API<14 it is a no-op+warn instead of throwing.
    if (deviceInfo.sdkApiVersion < 14) {
      hilog.warn(DOMAIN, 'WindowManager', 'restoreWindow: win.restore() requires API14+, current %{public}d; no-op', deviceInfo.sdkApiVersion);
      return;
    }
    const win = this.getWindow(windowId);
    if (!win) { hilog.warn(DOMAIN, 'WindowManager', 'restoreWindow: window %{public}d not found', windowId); return; }
    win.restore().catch((err: ESObject) => {
      hilog.error(DOMAIN, 'WindowManager', 'restoreWindow failed: %{public}s', JSON.stringify(err));
    });
  }

  recoverWindow(windowId: number): void {
    const win = this.getWindow(windowId);
    if (!win) { hilog.warn(DOMAIN, 'WindowManager', 'recoverWindow: window %{public}d not found', windowId); return; }
    win.recover().catch((err: ESObject) => {
      hilog.error(DOMAIN, 'WindowManager', 'recoverWindow failed: %{public}s', JSON.stringify(err));
    });
  }

  showWindowMethod(windowId: number): void {
    // UIAbility main window: hideWindow did win.minimize() → window is in MINIMIZE state.
    // showWindow() cannot restore from MINIMIZE (it only shows a hidden window / raises an
    // already-shown main window to the top). The documented inverse of minimize() for the
    // main window is restore() (the minimize() API doc links restore() for restoration;
    // API14+, guarded inside restoreWindow). This replaces the prior
    // startAbility(instanceKey='main') path: under launchType "standard" (tauri-cli
    // template) instanceKey is ignored and every startAbility spawns a DUPLICATE
    // EntryAbility. The demo masked this (its module.json5 omits launchType → singleton →
    // onNewWant). Restore only when actually minimized so a redundant set_visible(true) on
    // a visible maximized window does not un-maximize it. (PR#45 review F3/D)
    if (this.isUIAbilityMainWindow(windowId)) {
      if (this.isMinimized(windowId)) {
        this.restoreWindow(windowId);
      }
      return;
    }
    // Sub-window: showWindow() restores from minimize (symmetric with hideWindow's minimize).
    const win = this.getWindow(windowId);
    if (!win) { hilog.warn(DOMAIN, 'WindowManager', 'showWindowMethod: window %{public}d not found', windowId); return; }
    win.showWindow().then(() => {
      hilog.info(DOMAIN, 'WindowManager', 'showWindowMethod %{public}d OK', windowId);
    }).catch((err: ESObject) => {
      hilog.warn(DOMAIN, 'WindowManager', 'showWindowMethod %{public}d failed: %{public}s', windowId, JSON.stringify(err));
    });
  }

  // hide: main window uses win.minimize() (hideAbility not supported on PC/2in1 — StartOptions check failed).
  // show: main window uses restore() — the documented inverse of minimize() (see showWindowMethod).
  // Sub-window: minimize + showWindow (symmetric, works).
  hideWindow(windowId: number): void {
    const win = this.getWindow(windowId);
    if (!win) { this.logNotFound('hideWindow', windowId); return; }
    win.minimize().then(() => {
      hilog.info(DOMAIN, 'WindowManager', 'hideWindow(minimize) %{public}d OK', windowId);
    }).catch((err: ESObject) => {
      hilog.warn(DOMAIN, 'WindowManager', 'hideWindow(minimize) %{public}d failed: %{public}s', windowId, JSON.stringify(err));
    });
  }

  // set_fullscreen → PC/2in1 immersive fullscreen: maximize(ENTER_IMMERSIVE) +
  // hide title bar / Dock hover.
  // Reference implementation: demo3signature/entry/src/main/ets/pages/Index.ets toggleFullScreen.
  // setWindowLayoutFullScreen is resolve-but-no-op for the main UIAbility window
  // (size unchanged), so it is not used here.
  // setTitleAndDockHoverShown is a PC/2in1-only API (throws on phones; the catch
  // fallback does not affect basic fullscreen).
  setFullscreen(windowId: number, on: boolean): void {
    const win = this.getWindow(windowId);
    if (!win) { this.logNotFound('setFullscreen', windowId); return; }
    hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d on=%{public}s ENTER', windowId, String(on));
    if (on) {
      // Enter immersive fullscreen: maximize(ENTER_IMMERSIVE) → hide title bar + Dock hover
      win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE).then(() => {
        hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d maximize(ENTER_IMMERSIVE) OK', windowId);
        return win.setTitleAndDockHoverShown(false, false);
      }).then(() => {
        hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d setTitleAndDockHoverShown(false,false) OK', windowId);
      }).catch((err: ESObject) => {
        hilog.warn(DOMAIN, 'WindowManager', 'setFullscreen %{public}d on=true failed: %{public}s', windowId, JSON.stringify(err));
      });
    } else {
      // Exit fullscreen: recover() → show title bar + Dock hover
      win.recover().then(() => {
        hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d recover() OK', windowId);
        return win.setTitleAndDockHoverShown(true, true);
      }).then(() => {
        hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d setTitleAndDockHoverShown(true,true) OK', windowId);
      }).catch((err: ESObject) => {
        hilog.warn(DOMAIN, 'WindowManager', 'setFullscreen %{public}d on=false failed: %{public}s', windowId, JSON.stringify(err));
      });
    }
  }

  // set_ignore_cursor_events → setWindowTouchable (touchable = !ignore, tao side inverts before passing in)
  setWindowTouchable(windowId: number, touchable: boolean): void {
    const win = this.getWindow(windowId);
    if (!win) { this.logNotFound('setWindowTouchable', windowId); return; }
    win.setWindowTouchable(touchable).catch((err: ESObject) => {
      hilog.warn(DOMAIN, 'WindowManager', 'setWindowTouchable %{public}d failed: %{public}s', windowId, JSON.stringify(err));
    });
  }

  // Group D decoration button bitfield: bit0 closable, bit1 maximizable, bit2 minimizable, bit3 resizable.
  // Only applies to Float sub-windows (writes LocalStorage); UIAbility main window is a no-op
  // (decorations are system-provided).
  // Read a decoration flag from LocalStorage (问题四: 拦截 API 执行路径)
  // key: 'closable' | 'maximizable' | 'minimizable' | 'resizable'
  // Returns true if not set (default = all available, backward compatible)
  getDecorationFlag(windowId: number, key: string): boolean {
    const entry = this.windows.get(windowId);
    if (!entry || !entry.storage) {
      return true;  // default: allowed (no storage = main window or not yet initialized)
    }
    const val = entry.storage.get<boolean>(key);
    return val === undefined ? true : val;
  }

  setDecorationFlags(windowId: number, flags: number): void {
    if (this.isUIAbilityMainWindow(windowId)) {
      hilog.info(DOMAIN, 'WindowManager', 'setDecorationFlags: UIAbility main window (id=%{public}d) no-op', windowId);
      return;
    }
    const entry = this.windows.get(windowId);
    if (!entry || !entry.storage) {
      hilog.warn(DOMAIN, 'WindowManager', 'setDecorationFlags: window %{public}d not found', windowId);
      return;
    }
    entry.storage.setOrCreate('closable', (flags & 1) !== 0);
    entry.storage.setOrCreate('maximizable', (flags & 2) !== 0);
    entry.storage.setOrCreate('minimizable', (flags & 4) !== 0);
    entry.storage.setOrCreate('resizable', (flags & 8) !== 0);
  }

  // Group E cursor: @ohos.multimodalInput.pointer
  setPointerVisible(visible: boolean): void {
    try { pointer.setPointerVisible(visible); }
    catch (err) { hilog.warn(DOMAIN, 'WindowManager', 'setPointerVisible failed: %{public}s', JSON.stringify(err)); }
  }

  setPointerStyle(windowId: number, style: number): void {
    // pointer.setPointerStyleSync needs the REAL OHOS window ID (from getWindowProperties().id),
    // not tao's placeholder windowId (0 for main window). Passing 0 succeeds but has no effect.
    const win = this.getWindow(windowId);
    if (!win) { hilog.warn(DOMAIN, 'WindowManager', 'setPointerStyle: window %{public}d not found', windowId); return; }
    try {
      const realWindowId = win.getWindowProperties().id;
      pointer.setPointerStyleSync(realWindowId, style as pointer.PointerStyle);
      hilog.info(DOMAIN, 'WindowManager', 'setPointerStyle taoId=%{public}d realId=%{public}d style=%{public}d OK', windowId, realWindowId, style);
    } catch (err) { hilog.warn(DOMAIN, 'WindowManager', 'setPointerStyle %{public}d failed: %{public}s', windowId, JSON.stringify(err)); }
  }

  isMaximized(windowId: number): boolean {
    const win = this.getWindow(windowId);
    if (!win) { return false; }
    return win.getWindowStatus() === window.WindowStatusType.MAXIMIZE;
  }

  isMinimized(windowId: number): boolean {
    const win = this.getWindow(windowId);
    if (!win) { return false; }
    return win.getWindowStatus() === window.WindowStatusType.MINIMIZE;
  }

  // Destroy a window and clean up all resources.
  // Works for both main window (id=0) and sub-windows.
  async destroyWindow(windowId: number): Promise<void> {
    // 拦截:FLAG_CLOSABLE 为 0 时,不允许关闭(问题四:语义错位修复)
    if (!this.getDecorationFlag(windowId, 'closable')) {
      hilog.warn(DOMAIN, 'WindowManager', 'destroyWindow blocked: closable flag not set (window %{public}d)', windowId);
      return;
    }
    const win = this.getWindow(windowId);
    if (!win) {
      hilog.warn(DOMAIN, 'WindowManager', 'destroyWindow: window %{public}d not found', windowId);
      return;
    }
    try {
      await win.destroyWindow();
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', 'destroyWindow failed for %{public}d: %{public}s', windowId, String(e));
    }
    this.removeWindow(windowId);
  }

  // Close a window for real (not hide).
  // - UIAbility main window (id=0 first instance or id>0 subsequent instance):
  //   terminate the Ability instance via context.terminateSelf(). This truly
  //   closes the instance (removed from recent tasks), distinct from hideAbility
  //   which only backgrounds it. The first instance (id=0) terminating == app
  //   exit; secondary instances (id>0) terminating == that instance only exits.
  // - Float sub-window: win.destroyWindow() + removeWindow cleanup.
  async closeWindow(windowId: number): Promise<void> {
    if (this.isUIAbilityMainWindow(windowId)) {
      const ctx = this.uiAbilityContexts.get(Number(windowId));
      if (ctx) {
        hilog.info(DOMAIN, 'WindowManager', 'closeWindow: terminateSelf for UIAbility id=%{public}d', windowId);
        try {
          await ctx.terminateSelf();
        } catch (e) {
          hilog.warn(DOMAIN, 'WindowManager', 'closeWindow: terminateSelf failed for id=%{public}d: %{public}s', windowId, String(e));
        }
      } else {
        hilog.warn(DOMAIN, 'WindowManager', 'closeWindow: no context for UIAbility id=%{public}d (not registered?), falling back to hideAbility', windowId);
        await this.hideAbility();
      }
      return;
    }
    const win = this.getWindow(windowId);
    if (!win) {
      hilog.warn(DOMAIN, 'WindowManager', 'closeWindow: window %{public}d not found', windowId);
      return;
    }
    try {
      await win.destroyWindow();
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', 'closeWindow destroy failed for %{public}d: %{public}s', windowId, String(e));
    }
    // removeWindow handles conditional resetUserInteractionTracking
    this.removeWindow(windowId);
  }

  private logNotFound(op: string, windowId: number): void {
    hilog.warn(DOMAIN, 'WindowManager', `%{public}s: window %{public}d not found`, op, windowId);
  }

  // Hide the entire Ability (app) to background.
  // Equivalent to macOS Cmd+H (hide:) — all windows become invisible, process stays alive.
  async hideAbility(): Promise<void> {
    if (!this.context) {
      hilog.warn(DOMAIN, 'WindowManager', 'hideAbility: context not set');
      return;
    }
    try {
      await this.context.hideAbility();
      this.resetUserInteractionTracking();
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', 'hideAbility failed: %{public}s', String(e));
    }
  }

  // ─── Pending Action Management (StatusBar menu race condition) ───
  //
  // When a tray menu item is clicked, the system triggers onNewWant → GoForeground
  // which can undo window operations executed in the menu click callback.
  //
  // Solution: defer window operations until RESUMED/WINDOW_ACTIVE event fires,
  // indicating the system's foreground transition is complete.
  //
  // Flow:
  // 1. Tray menu click → setPendingAction(action) + start 2s cleanup timer
  // 2. System triggers onNewWant → cancelCleanupTimer()
  // 3. RESUMED/WINDOW_ACTIVE fires → consumePendingAction() executes the action
  // 4. If onNewWant never fires (edge case), cleanup timer clears state after 2s

  setPendingAction(action: () => void): void {
    // Clear any existing pending action
    this.clearPendingAction();

    this.pendingAction = action;
    hilog.info(DOMAIN, 'WindowManager',
      'Pending action set, waiting for system foreground transition');

    // Start safety net cleanup timer (2s)
    this.cleanupTimer = setTimeout(() => {
      if (this.pendingAction) {
        hilog.warn(DOMAIN, 'WindowManager', 'Pending action timeout (2s), cleaning up stale state');
        this.pendingAction = null;
      }
      this.cleanupTimer = null;
    }, 2000);
  }

  consumePendingAction(): boolean {
    if (!this.pendingAction) {
      return false;
    }

    const action = this.pendingAction;
    this.pendingAction = null;

    // Cancel cleanup timer since we're executing the action
    this.cancelCleanupTimer();

    hilog.info(DOMAIN, 'WindowManager', 'Consuming pending action after system foreground transition');
    try {
      action();
      return true;
    } catch (e) {
      hilog.error(DOMAIN, 'WindowManager', 'Failed to execute pending action: %{public}s', String(e));
      return false;
    }
  }

  hasPendingAction(): boolean {
    return this.pendingAction !== null;
  }

  cancelCleanupTimer(): void {
    if (this.cleanupTimer !== null) {
      clearTimeout(this.cleanupTimer);
      this.cleanupTimer = null;
      hilog.info(DOMAIN, 'WindowManager', 'Cleanup timer cancelled');
    }
  }

  clearPendingAction(): void {
    if (this.pendingAction) {
      hilog.info(DOMAIN, 'WindowManager', 'Clearing pending action without execution');
      this.pendingAction = null;
    }
    this.cancelCleanupTimer();
  }

  async createSubWindow(opts: SubWindowOptions): Promise<number> {
    const { name, windowId, width = 800, height = 600, x = 100, y = 100,
            decorations = true, transparent = false, backgroundColor } = opts;

    // Validate windowId: sub-window ID must be greater than 0
    if (windowId <= 0) {
      hilog.error(DOMAIN, 'WindowManager', `Invalid windowId: %{public}d. Sub-window creation requires windowId > 0.`, windowId);
      throw new Error(`Invalid windowId: ${windowId}. Must be greater than 0.`);
    }

    // Check if windowStage has been set
    if (!this.uiAbilityStages.has(0)) {
      hilog.error(DOMAIN, 'WindowManager', 'WindowStage not set. Call setWindowStage() first.');
      throw new Error('WindowStage not set');
    }

    hilog.info(DOMAIN, 'WindowManager', `Creating sub-window via windowStage: %{public}s, id: %{public}d`, name, windowId);

    let win: window.Window;
    try {
      // Use windowStage.createSubWindow(name) instead of window.createWindow(config)
      win = await this.uiAbilityStages.get(0)?.createSubWindow(name);
      hilog.info(DOMAIN, 'WindowManager', `Sub-window created successfully: %{public}d`, windowId);
    } catch (err) {
      hilog.error(DOMAIN, 'WindowManager', `Failed to create sub-window: %{public}s`, JSON.stringify(err));
      throw err;
    }
    
    // Use LocalStorage to pass windowId and decorations, ensuring isolation between windows
    let storage = new LocalStorage();
    storage.setOrCreate('windowId', windowId);
    storage.setOrCreate('decorations', decorations);
    // D group decoration flags default (all available; setDecorationFlags updates them)
    storage.setOrCreate('closable', true);
    storage.setOrCreate('maximizable', true);
    storage.setOrCreate('minimizable', true);
    storage.setOrCreate('resizable', true);
    // Title (set by setWindowTitle → updates this via setWindowTitle impl)
    storage.setOrCreate('title', '');
    this.windows.set(windowId, { window: win, storage });

    // Register focus tracking for sub-window
    this.registerFocusTracking(win, windowId);

    try {
      hilog.info(DOMAIN, 'WindowManager', `Loading content: FloatPage for window %{public}d`, windowId);
      await win.loadContentByName(FloatPage.RouteName, storage);
      hilog.info(DOMAIN, 'WindowManager', `UI content loaded successfully for window: %{public}d`, windowId);
      
      // Register sub-window's UIContext
      try {
        const uiCtx = win.getUIContext();
        if (uiCtx) {
          this.registerUIContext(windowId, uiCtx);
          hilog.info(DOMAIN, 'WindowManager', `Sub-window UIContext registered for window: %{public}d`, windowId);
        }
      } catch (e) {
        hilog.warn(DOMAIN, 'WindowManager', `Failed to get UIContext for window %{public}d: %{public}s`, windowId, JSON.stringify(e));
      }
    } catch (err) {
      hilog.error(DOMAIN, 'WindowManager', `Failed to load content for window %{public}d: %{public}s`, windowId, JSON.stringify(err));
      throw err;
    }
    
    try {
      // Apply transparent/backgroundColor settings
      if (transparent) {
        hilog.info(DOMAIN, 'WindowManager', `Setting Float window %{public}d to transparent`, windowId);
        await win.setWindowBackgroundColor('#00000000');
        // Note: setWindowContainerColor is NOT called here — it only applies to
        // UIAbility main windows (which have a window container), not to Float
        // sub-windows (createSubWindow products). Float transparency comes from
        // setWindowBackgroundColor + the ArkUI container (DefaultXComponent) being
        // already transparent. UIAbility main window transparency is handled in
        // registerUIAbilityStage via setWindowContainerColor.
      } else if (backgroundColor !== undefined) {
        const colorStr = '#' + backgroundColor.toString(16).padStart(8, '0');
        hilog.info(DOMAIN, 'WindowManager', `Setting window %{public}d background color to %{public}s`, windowId, colorStr);
        await win.setWindowBackgroundColor(colorStr);
      }

      hilog.info(DOMAIN, 'WindowManager', `Resizing window %{public}d to %{public}dx%{public}d`, windowId, width, height);
      await win.resize(width, height);
      hilog.info(DOMAIN, 'WindowManager', `Moving window %{public}d to %{public}d,%{public}d`, windowId, x, y);
      await win.moveWindowTo(x, y);
      await win.showWindow();
      hilog.info(DOMAIN, 'WindowManager', `Window shown: %{public}d`, windowId);
    } catch (err) {
      hilog.error(DOMAIN, 'WindowManager', `Failed to resize/move/show window: %{public}s`, JSON.stringify(err));
      throw err;
    }

    return windowId;
  }
  
  // Load a URL into the specified window — unified via addWebview, consistent with main window path
  loadUrl(id: number, url: string): void {
    const controller = this.controllers.get(id);
    if (controller) {
      hilog.info(DOMAIN, 'WindowManager', `Loading URL for window ${id}: ${url}`);
      // Unified call to addWebview, consistent with main window ArkHelper.createWebview path
      controller.addWebview({ url: url });
      // Clear pending URL on successful load
      this.pendingUrls.delete(id);
    } else {
      hilog.warn(DOMAIN, 'WindowManager', `Controller not ready for window ${id}. Queuing URL.`);
      // Controller not ready yet — queue the URL and wait for registerController
      this.pendingUrls.set(id, url);
    }
  }
  
  // Trigger load when page initialization is complete and Controller is registered
  registerController(id: number, controller: RustWebviewNodeController): void {
    hilog.info(DOMAIN, 'WindowManager', `Controller registered for window: %{public}d`, id);
    // pendingBlurs key is normalized to number (applyWindowBlur stores Number(windowId)
    // because Rust NAPI i64 arrives as BigInt).
    const pb = this.pendingBlurs.get(Number(id));
    if (pb !== undefined) {
      this.pendingBlurs.delete(Number(id));
    }
    const injectBlur = (data: WebviewInitData): void => {
      if (pb !== undefined) {
        if (!data.style) {
          data.style = {};
        }
        data.style.blurRadius = pb;
      }
    };
    this.controllers.set(id, controller);

    // 1. Process pending WebView init requests (resolves race conditions)
    const pendingInit = this.pendingInits.get(id);
    if (pendingInit) {
      hilog.info(DOMAIN, 'WindowManager', `Processing pending init for window ${id}`);
      injectBlur(pendingInit);
      const result = controller.addWebview(pendingInit);
      this.pendingInits.delete(id);

      // Attach real implementations to result.controller
      // (same as ArkHelper.ets normal path — without this, ProxyJsHelper replays to no-op stubs)
      const applyStyle = (style: WebviewStyle) => {
        objectAssign(pendingInit.style as Record<string, ESObject>, style);
        controller.updateWebviewStyle(result.webTag, pendingInit.style as WebviewStyle);
      };

      result.controller.setBackgroundColor = (color: number) => {
        applyStyle({ backgroundColor: color } as WebviewStyle);
      };

      result.controller.setVisible = (visible: boolean) => {
        applyStyle({ visible } as WebviewStyle);
      };

      result.controller.setBounds = (x: number, y: number, width: number, height: number) => {
        applyStyle({ x, y, width, height } as WebviewStyle);
      };

      result.controller.dispose = () => {
        controller.removeWebview(result.webTag);
      };

      // 2. Activate proxy (bind real Controller to proxy)
      const proxy = this.takePendingJsHelperProxy(id);
      if (proxy) {
        hilog.info(DOMAIN, 'WindowManager', `Binding real controller to proxy for window ${id}`);
        proxy.bindToRealController(result.controller);
      }
    }

    // 3. Process pending URL load requests
    const pendingUrl = this.pendingUrls.get(id);
    if (pendingUrl) {
      hilog.info(DOMAIN, 'WindowManager', `Pending URL found! Triggering load for window ${id}: ${pendingUrl}`);
      const urlData: WebviewInitData = { url: pendingUrl };
      injectBlur(urlData);
      controller.addWebview(urlData);
      this.pendingUrls.delete(id);
    } else {
      hilog.info(DOMAIN, 'WindowManager', `No pending URL for window ${id}. Waiting for command.`);
    }
  }
  
  // Queue a WebView init request
  queueWebviewInit(id: number, init: WebviewInitData): void {
    hilog.warn(DOMAIN, 'WindowManager', `Controller not ready for window ${id}. Queuing init.`);
    this.pendingInits.set(id, init);
  }
  
  // Register a proxy object
  registerPendingJsHelperProxy(id: number, proxy: ProxyJsHelper): void {
    hilog.info(DOMAIN, 'WindowManager', `Registering pending proxy for window: %{public}d`, id);
    this.pendingJsHelperProxies.set(id, proxy);
  }

  // Get and remove proxy (no longer managed after binding)
  takePendingJsHelperProxy(id: number): ProxyJsHelper | undefined {
    const proxy = this.pendingJsHelperProxies.get(id);
    this.pendingJsHelperProxies.delete(id);
    return proxy;
  }
  
  getWindow(id: number): window.Window | undefined {
    // Normalize i64→BigInt marshalling from Rust NAPI: Number() is a no-op when id
    // arrives as a number, but fixes the main-window (id=0) lookup when id arrives as
    // BigInt (0n === 0 is false in JS, which would silently miss the windowStage branch
    // and the number-keyed Map). Centralizing here covers all callers.
    const wid = Number(id);
    // First main window (id=0) lives on the primary windowStage.
    if (wid === 0 && this.uiAbilityStages.has(0)) {
      try {
        return this.uiAbilityStages.get(0)?.getMainWindowSync();
      } catch (e) {
        hilog.warn(DOMAIN, 'WindowManager', 'Failed to get main window: %{public}s', String(e));
        return undefined;
      }
    }
    // Subsequent UIAbility instance main windows live on their own WindowStage.
    const secStage = this.uiAbilityStages.get(wid);
    if (secStage) {
      try {
        return secStage.getMainWindowSync();
      } catch (e) {
        hilog.warn(DOMAIN, 'WindowManager', 'Failed to get subsequent main window %{public}d: %{public}s', wid, String(e));
        return undefined;
      }
    }
    const entry = this.windows.get(wid);
    return entry?.window;
  }

  getAllWindowIds(): number[] {
    const ids = Array.from(this.windows.keys());
    // Include main window (id=0) if windowStage is set
    if (this.uiAbilityStages.has(0) && !ids.includes(0)) {
      ids.unshift(0);
    }
    // Include subsequent UIAbility main windows
    for (const sid of this.uiAbilityStages.keys()) {
      if (!ids.includes(sid)) {
        ids.push(sid);
      }
    }
    return ids;
  }

  // setDecorations: controls visibility of window decorations (title bar).
  // Main UIAbility window: win.setWindowDecorVisible(decorations) — PC/2in1 window decoration API (since API 20).
  //   Reference implementation: demo3signature/entry/src/main/ets/pages/Index.ets toggleWindowDecor.
  //   The old implementation used hideSystemBar/showSystemBar (status bar), which is wrong —
  //   status bar != title bar.
  //   May be unsupported on phones (throws 801); the catch fallback does not affect other logic.
  // Float sub-window: LocalStorage setOrCreate('decorations') — FloatPage @LocalStorageProp reactively re-renders.
  setDecorations(windowId: number, decorations: boolean): void {
    hilog.info(DOMAIN, 'WindowManager', 'setDecorations %{public}d decorations=%{public}s ENTER', windowId, String(decorations));
    // Float sub-window: write LocalStorage to drive FloatPage title bar show/hide
    const entry = this.windows.get(windowId);
    if (entry && entry.storage) {
      entry.storage.setOrCreate('decorations', decorations);
      hilog.info(DOMAIN, 'WindowManager', `Decorations set to %{public}s for Float window %{public}d (LocalStorage)`, String(decorations), windowId);
    }
    // UIAbility main window: call setWindowDecorVisible directly to control the system title bar
    if (this.isUIAbilityMainWindow(windowId)) {
      const win = this.getWindow(windowId);
      if (!win) {
        hilog.warn(DOMAIN, 'WindowManager', 'setDecorations: main window %{public}d not found', windowId);
        return;
      }
      try {
        win.setWindowDecorVisible(decorations);
        hilog.info(DOMAIN, 'WindowManager', 'setDecorations %{public}d setWindowDecorVisible(%{public}s) OK', windowId, String(decorations));
      } catch (err) {
        // 801: device not supported (phones); 1300002: abnormal window state. Does not affect other logic.
        hilog.warn(DOMAIN, 'WindowManager', 'setDecorations %{public}d setWindowDecorVisible failed: %{public}s', windowId, JSON.stringify(err));
      }
    }
  }

  setWindowBackgroundColor(windowId: number, color: number): void {
    const colorStr = '#' + color.toString(16).padStart(8, '0');
    hilog.info(DOMAIN, 'WindowManager', `setWindowBackgroundColor: windowId=%{public}d, color=%{public}s`, windowId, colorStr);
    // UIAbility main windows (first id=0 or subsequent id>0): set on the stage's main window
    if (this.isUIAbilityMainWindow(windowId)) {
      try {
        const mainWindow = this.getWindow(windowId);
        if (!mainWindow) {
          hilog.warn(DOMAIN, 'WindowManager', `setWindowBackgroundColor: main window %{public}d not found`, windowId);
          return;
        }
        mainWindow.setWindowBackgroundColor(colorStr);
        // NOTE: setWindowContainerColor is NOT called here — it controls the window
        // container layer (incl. title bar area) and is only set at creation time
        // (applyTransparentBackground). Calling it at runtime with the same color
        // for active+inactive overwrites the title bar. setWindowBackgroundColor
        // only affects the window background, not the container.
      } catch (e) {
        hilog.error(DOMAIN, 'WindowManager', `Failed to set main window background: %{public}s`, String(e));
      }
    } else {
      const entry = this.windows.get(windowId);
      if (entry?.window) {
        try {
          entry.window.setWindowBackgroundColor(colorStr);
        } catch (err) {
          hilog.error(DOMAIN, 'WindowManager', `Sub-window %{public}d background failed: %{public}s`, windowId, String(err));
        }
      }
    }
  }

  // Window vibrancy: Apply backdrop blur to WebView container component.
  // NOTE: backdropBlur must be applied at webview BUILD time (BuilderNode.update
  // does not refresh .backdropBlur). The blur radius is queued here and consumed
  // when the webview node is built. No hilog calls inside this method — hilog
  // throws "Argc mismatch" when invoked from a NAPI-reentrant ArkTS context.
  applyWindowBlur(windowId: number, radius: number): void {
    // windowId arrives from Rust NAPI as i64 → BigInt (1n). Normalize to number
    // so it matches the ArkTS number keys used by registerController.
    const id = Number(windowId);
    this.pendingBlurs.set(id, radius);
    // Runtime refresh: if the window's controller is already registered, apply blur immediately
    // via AttributeUpdater (BuilderNode.update does not refresh backdropBlur). For not-yet-built
    // windows, registerController will inject blurRadius from pendingBlurs at build time.
    const controller = this.controllers.get(id);
    if (controller) {
      controller.setAllWebviewsBlurRadius(radius);
    }
  }
  private hideSystemBar(): void {
    if (!this.uiAbilityStages.has(0)) return;
    try {
      const mainWindow = this.uiAbilityStages.get(0)?.getMainWindowSync();
      const names: Array<'status' | 'navigation'> = [];
      mainWindow.setWindowSystemBarEnable(names).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, 'WindowManager', `Failed to hide system bar: %{public}s`, err.message);
      });
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', `hideSystemBar failed: %{public}s`, JSON.stringify(e));
    }
  }

  // Phase 2: Show system status bar for main window (decorations=true)
  private showSystemBar(): void {
    if (!this.uiAbilityStages.has(0)) return;
    try {
      const mainWindow = this.uiAbilityStages.get(0)?.getMainWindowSync();
      const names: Array<'status' | 'navigation'> = ['status', 'navigation'];
      mainWindow.setWindowSystemBarEnable(names).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, 'WindowManager', `Failed to show system bar: %{public}s`, err.message);
      });
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', `showSystemBar failed: %{public}s`, JSON.stringify(e));
    }
  }

  getController(id: number): RustWebviewNodeController | undefined {
    return this.controllers.get(id);
  }

  // Register UIContext (main window calls in aboutToAppear, sub-window calls after loadContent)
  registerUIContext(windowId: number, ctx: UIContext): void {
    hilog.info(DOMAIN, 'WindowManager', `UIContext registered for window: %{public}d`, windowId);
    this.uiContexts.set(windowId, ctx);
  }

  // Get UIContext for the specified window
  getUIContext(windowId: number): UIContext | undefined {
    return this.uiContexts.get(windowId);
  }

  // Clean up controller and UIContext only (used by DefaultXComponent aboutToDisappear)
  // Does not remove from windows Map (managed by FloatPage's destroyWindow path)
  removeControllerAndUIContext(windowId: number): void {
    this.controllers.delete(windowId);
    this.uiContexts.delete(windowId);
    hilog.info(DOMAIN, 'WindowManager', 'Controller and UIContext removed for windowId: %{public}d', windowId);
  }

  // Remove window: clean up all Maps to prevent memory leaks
  removeWindow(windowId: number): void {
    hilog.info(DOMAIN, 'WindowManager', `Removing window %{public}d from all maps`, windowId);
    // Clear user interaction tracking if this window was the last interacted one
    if (this.lastUserInteractedWindowId === windowId) {
      this.lastUserInteractedWindowId = -1;
      hilog.info(DOMAIN, 'WindowManager', 'Cleared lastUserInteractedWindowId (removed window)');
    }
    this.windows.delete(windowId);
    this.windowKinds.delete(windowId);
    this.controllers.delete(windowId);
    this.uiContexts.delete(windowId);
    this.pendingJsHelperProxies.delete(windowId);
    this.pendingUrls.delete(windowId);
    this.pendingInits.delete(windowId);
    this.pendingBlurs.delete(windowId);
  }
}
