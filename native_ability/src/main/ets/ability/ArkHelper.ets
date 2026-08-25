import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { statusBarManager } from "@kit.DeskTopExtensionKit";
import { emitter, BusinessError, deviceInfo } from "@kit.BasicServicesKit";
import { notificationManager } from "@kit.NotificationKit";
import { inputMethod } from "@kit.IMEKit";
import { image } from "@kit.ImageKit";
import {
  ArkHelper,
  StatusBarIconRgba,
  UIAbilityWantParams,
  WebViewInitData as NativeWebViewInitData,
  WindowAvoidAreaInfo,
  WindowConfig,
} from "../ability/type";
import { exit, restart, check as updaterCheckFn, showUpdateDialog as updaterShowDialogFn, downloadAndInstall as updaterDownloadAndInstallFn, login as accountLoginFn, silentLogin as accountSilentLoginFn, logout as accountLogoutFn, objectAssign, writeImageToClipboard, openAutostartSettings, getAutostartStatus, registerHotkey, unregisterHotkey, unregisterAllHotkeys } from "../helper";
import { requestPermission } from "../helper/permission";
import { getPredefinedActionExecutor } from "../helper/menu";
import { PredefinedType } from "../helper/menu_types";
import {
  EmbeddedWebviewManager,
  RustWebviewNodeController,
  WebviewStyle,
  WebviewInitData,
} from "../webview/DefaultWebview";
import { WindowManager } from "../window/WindowManager";

// Safe error logging for NAPI-reentrant contexts.
// hilog.error may throw "Argc mismatch" when called from Rust's synchronous func.call
// (NAPI reentrant context, per C5 constraint). This wrapper catches any hilog failure
// and falls back to console, ensuring the catch block itself never throws.
function safeLogError(op: string, err: ESObject): void {
  try {
    hilog.error(0x0000, 'ArkHelper', '%{public}s failed: %{public}s', op, JSON.stringify(err));
  } catch (_e) {
    // hilog itself failed (NAPI reentrant context) — fall back to console
    console.error(`[ArkHelper] ${op} failed: ${JSON.stringify(err)}`);
  }
}
import { JsHelper, ProxyJsHelper } from "../webview/Utils";
import {
  getAbilityContext,
  createPixelMapFromRgba,
  fillMenuItemAbilityName,
  processMenuItemIcons,
  helperRef,
  reRegisterStatusBarClickHandlers,
} from "../helper/StatusBarUtils";
import { ConfigurationConstant, Want } from '@kit.AbilityKit';
import { primaryWebviewControllerCallback, clearPrimaryWebviewControllerCallback } from "../components/DefaultXComponent";
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from '../helper/constants';

/**
 * Global ArkHelper factory function.
 *
 * Design principles:
 * - Does not depend on any component instance's `this` pointer
 * - All window-related resources are managed centrally via WindowManager
 * - UIContext is obtained from WindowManager by windowId
 */
export function createArkHelper(): ArkHelper {
  // Per-window EmbeddedWebviewManager instances, keyed by windowId
  const embeddedManagers: Map<number, EmbeddedWebviewManager> = new Map();

  // Monotonic notification id for requestUserAttention — avoids concurrent calls sharing a
  // fixed id and overwriting each other (PR#45 review F3). See requestUserAttention.
  let attentionNotifId: number = 0;

  // Last updateCursor result for setImePosition — the promise settles async, so the
  // sync NAPI call can't return it; Rust polls it back via getImePositionResult.
  let lastImeResult: ESObject = { ok: false, code: -1, message: 'not called', x: 0, y: 0, ts: 0 };

  const getEmbeddedManager = (windowId: number): EmbeddedWebviewManager => {
    if (!embeddedManagers.has(windowId)) {
      const wm = WindowManager.getInstance();
      const uiCtx = wm.getUIContext(windowId);
      if (!uiCtx) {
        throw new Error(`UIContext not found for window ${windowId}`);
      }
      embeddedManagers.set(windowId, new EmbeddedWebviewManager(uiCtx));
    }
    return embeddedManagers.get(windowId)!;
  };

  const getUIAbilityContext = (): common.UIAbilityContext | null => {
    try {
      const wm = WindowManager.getInstance();
      // Prefer main window (windowId=0) for context
      const uiCtx = wm.getUIContext(0);
      if (uiCtx) {
        return uiCtx.getHostContext() as common.UIAbilityContext;
      }
    } catch (e) {
      // NAPI-reentrant path (called before first await in accountLogin/silentLogin):
      // use safeLogError, not hilog.error, which can throw 'Argc mismatch' here
      // and mask the original failure (ohos-constraints 2.3).
      safeLogError('getUIAbilityContext', e);
    }
    return null;
  };

  return {
    exit,
    restart,

    updaterCheck: async (): Promise<Object> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'updaterCheck: UIAbilityContext not available');
          throw new Error('UIAbilityContext not available');
        }
        return await updaterCheckFn(context);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'updaterCheck failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    updaterShowDialog: async (): Promise<number> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'updaterShowDialog: UIAbilityContext not available');
          throw new Error('UIAbilityContext not available');
        }
        return await updaterShowDialogFn(context);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'updaterShowDialog failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    updaterDownloadAndInstall: async (): Promise<void> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'updaterDownloadAndInstall: UIAbilityContext not available');
          throw new Error('UIAbilityContext not available');
        }
        await updaterDownloadAndInstallFn(context);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'updaterDownloadAndInstall failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    // ─── Huawei account (no context needed — Account Kit has no per-app state) ───
    // Errors are normalized to "<code>:<message>" strings in account.ets and
    // propagated to Rust; safeLogError is used because the entry path is NAPI-reentrant.

    accountLogin: async (): Promise<Object> => {
      try {
        // One-tap login (createLoginWithHuaweiIDRequest, forceLogin=true).
        // A UIAbilityContext is required: the no-arg AuthenticationController
        // throws "Incorrect context parameter type" when forceLogin=true needs
        // to host the login UI (device-verified 2026-08-03). When the account
        // is already logged in & authorized, Account Kit returns the credential
        // without showing the UI.
        const context = getUIAbilityContext();
        if (!context) {
          throw new Error('UIAbilityContext not available');
        }
        return await accountLoginFn(context);
      } catch (err) {
        safeLogError('accountLogin', err);
        throw err;
      }
    },

    accountSilentLogin: async (): Promise<Object> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          throw new Error('UIAbilityContext not available');
        }
        return await accountSilentLoginFn(context);
      } catch (err) {
        safeLogError('accountSilentLogin', err);
        throw err;
      }
    },

    accountLogout: async (): Promise<void> => {
      try {
        await accountLogoutFn();
      } catch (err) {
        safeLogError('accountLogout', err);
        throw err;
      }
    },

    requestPermission: async (permission: string | string[]): Promise<number | number[]> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'Failed to get UIAbilityContext for permission request');
          return -1;
        }
        return await requestPermission(context, permission);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'Permission request failed: %{public}s', JSON.stringify(err));
        return -1;
      }
    },

    getWindowAvoidArea: (type: number, windowId: number): WindowAvoidAreaInfo | undefined => {
      try {
        let win: window.Window | null = null;

        if (windowId === 0) {
          // Main window
          hilog.info(DOMAIN, 'ArkHelper', 'Getting avoid area for MAIN window');
          const context = getUIAbilityContext();
          if (context) {
            win = context.windowStage.getMainWindowSync();
          }
        } else {
          // Sub-window
          hilog.info(DOMAIN, 'ArkHelper', 'Getting avoid area for SUB window: %{public}d', windowId);
          try {
            const wm = WindowManager.getInstance();
            win = wm.getWindow(windowId) || null;
          } catch (e) {
            hilog.error(DOMAIN, 'ArkHelper', 'Failed to get WindowManager instance: %{public}s', JSON.stringify(e));
          }
        }

        if (!win) {
          hilog.error(DOMAIN, 'ArkHelper', 'Window not found for windowId: %{public}d', windowId);
          return undefined;
        }

        const avoidType = type as window.AvoidAreaType;
        return {
          type: avoidType,
          area: win.getWindowAvoidArea(avoidType),
        } as WindowAvoidAreaInfo;
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'getWindowAvoidArea failed: %{public}s', JSON.stringify(err));
        return undefined;
      }
    },

    createWebview: (data: NativeWebViewInitData) => {
      try {
        const windowId = data.windowId ?? 0;
        hilog.info(DOMAIN, 'ArkHelper', 'createWebview called with windowId: %{public}d, url: %{public}s', windowId, data.url || 'null');
        
        // 1. Look up Controller strictly by windowId
        let targetController: RustWebviewNodeController | null = null;
        try {
          const wm = WindowManager.getInstance();
          targetController = wm.getController(windowId);
        } catch (e) {
          hilog.error(DOMAIN, 'ArkHelper', 'Failed to get WindowManager: %{public}s', JSON.stringify(e));
        }

        // 2. Prepare Init data
        const rawInitScripts: string[] = data?.initializationScripts || [];

        const initScripts: ScriptItem[] = rawInitScripts.map((i) => {
          return {
            script: i,
            scriptRules: ["*"],
          } as ScriptItem;
        });
        const init: WebviewInitData = {
          webTag: data?.id,
          url: data?.url,
          windowId: windowId,
          html: data?.html,
          headers: data?.headers,
          style: (data.style || {}) as WebviewStyle,
          javascriptEnable: data?.javascriptEnable ?? true,
          userAgent: data?.userAgent,
          devtools: data?.devtools,
          autoplay: data?.autoplay,
          initializationScripts: initScripts,
          onDragAndDrop: data?.onDragAndDrop,
          onDownloadStart: data?.onDownloadStart,
          onDownloadEnd: data?.onDownloadEnd,
          onNavigationRequest: data?.onNavigationRequest,
          onTitleChange: data?.onTitleChange,
          onPageBegin: data?.onPageBegin,
          onPageEnd: data?.onPageEnd,
          onWindowNew: data?.onWindowNew,
          onCloseWindow: () => {
            try {
              // Notify Rust event loop to process the close through proper lifecycle:
              // CloseRequested → Destroyed → WindowsStore cleanup.
              // notifyWindowClose() is synchronous — pushes window ID to Rust queue.
              // destroyWindow() is async (Promise) — actual destruction happens later.
              // Rust's drain runs at the top of the next event loop iteration (synchronous),
              // so it reads stored Rust values before destroyWindow completes.
              const nativeModule: ESObject = AppStorage.get<ESObject>(NATIVE_MODULE_STORAGE_KEY);
              if (nativeModule && typeof nativeModule.notifyWindowClose === 'function') {
                nativeModule.notifyWindowClose(windowId);
                hilog.info(DOMAIN, 'ArkHelper', 'Window %{public}d close notified via NAPI', windowId);
              } else {
                hilog.warn(DOMAIN, 'ArkHelper', 'NAPI notifyWindowClose not available for window %{public}d', windowId);
              }

              // Destroy OHOS native window and clean up WindowManager.
              // removeWindow BEFORE destroyWindow so that aboutToDisappear
              // (which fires during async destruction) sees the window as
              // already handled and skips the system-close notification.
              const wm = WindowManager.getInstance();
              const win = wm.getWindow(windowId);
              if (win) {
                wm.removeWindow(windowId);
                win.destroyWindow().then(() => {
                  hilog.info(DOMAIN, 'ArkHelper', 'Window %{public}d destroyed and cleaned up', windowId);
                }).catch((e: Error) => {
                  hilog.error(DOMAIN, 'ArkHelper', 'Failed to destroy window %{public}d: %{public}s', windowId, JSON.stringify(e));
                });
              }
            } catch (e) {
              hilog.error(DOMAIN, 'ArkHelper', 'onCloseWindow failed: %{public}s', JSON.stringify(e));
            }
          },
        } as WebviewInitData;

        hilog.info(DOMAIN, 'ArkHelper',
          'createWebview event handlers: nav=%{public}s, title=%{public}s, dlStart=%{public}s, dlEnd=%{public}s, pgBegin=%{public}s, pgEnd=%{public}s',
          typeof init.onNavigationRequest === 'function' ? 'YES' : 'NO',
          typeof init.onTitleChange === 'function' ? 'YES' : 'NO',
          typeof init.onDownloadStart === 'function' ? 'YES' : 'NO',
          typeof init.onDownloadEnd === 'function' ? 'YES' : 'NO',
          typeof init.onPageBegin === 'function' ? 'YES' : 'NO',
          typeof init.onPageEnd === 'function' ? 'YES' : 'NO',
        );

        init.style = init.style || {};
        // OHOS: Set WebView transparent only when requested.
        // The Web component only respects .backgroundColor() at creation, not at runtime.
        // Window shell transparency (setWindowContainerColor) is applied in
        // NativeAbility.onWindowStageCreate after loadContentByName — that's when
        // the window is fully ready. Calling here or in registerUIAbilityStage is
        // too early ("window state is abnormal").
        if (data?.transparent) {
          init.transparent = true;
          init.style.backgroundColor = Color.Transparent;
        }

        // 3. If Controller not ready, create proxy and enqueue
        if (!targetController) {
          hilog.warn(DOMAIN, 'ArkHelper', 'Controller not ready for window %{public}d. Creating proxy.', windowId);
          try {
            const wm = WindowManager.getInstance();
            wm.queueWebviewInit(windowId, init);
            
            // Create lightweight proxy object to return to Rust
            const proxy = new ProxyJsHelper();
            wm.registerPendingJsHelperProxy(windowId, proxy);
            return proxy;
          } catch (e) {
            hilog.error(DOMAIN, 'ArkHelper', 'Failed to queue init or create proxy: %{public}s', JSON.stringify(e));
            // Fallback: return ProxyJsHelper under extreme errors; operations are cached, not lost. TODO: handle errors on Rust side
            const fallbackProxy = new ProxyJsHelper();
            try {
              const wmFallback = WindowManager.getInstance();
              wmFallback.queueWebviewInit(windowId, init);
              wmFallback.registerPendingJsHelperProxy(windowId, fallbackProxy);
            } catch (e2) {
              hilog.error(DOMAIN, 'ArkHelper', 'Failed to queue fallback init: %{public}s', JSON.stringify(e2));
            }
            return fallbackProxy;
          }
        }

        // 4. Normal creation path
        const ret = targetController.addWebview(init);
        if (primaryWebviewControllerCallback && init.controller) {
          primaryWebviewControllerCallback(init.controller);
          clearPrimaryWebviewControllerCallback();
        }
        const applyStyle = (style: WebviewStyle) => {
          objectAssign(init.style as Record<string, ESObject>, style);
          targetController!.updateWebviewStyle(ret.webTag, init.style as WebviewStyle);
        };

        ret.controller.setBackgroundColor = (color: number) => {
          applyStyle({ backgroundColor: color });
        };

        ret.controller.setVisible = (visible: boolean) => {
          applyStyle({ visible });
        };

        ret.controller.setBounds = (x: number, y: number, width: number, height: number) => {
          applyStyle({ x, y, width, height });
        };
        ret.controller.setBlurRadius = (radius: number) => {
          applyStyle({ blurRadius: radius });
        };

        ret.controller.dispose = () => {
          targetController!.removeWebview(ret.webTag);
        };

        return ret.controller;
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'createWebview failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    createEmbeddedWebview: (data: NativeWebViewInitData) => {
      try {
        const windowId = data.windowId ?? 0;
        const manager = getEmbeddedManager(windowId);

        const rawInitScripts: string[] = data?.initializationScripts || [];

        const initScripts: ScriptItem[] = rawInitScripts.map((i) => {
          return {
            script: i,
            scriptRules: ["*"],
          } as ScriptItem;
        });
        const init: WebviewInitData = {
          webTag: data?.id,
          url: data?.url,
          windowId: windowId,
          html: data?.html,
          headers: data?.headers,
          style: (data.style || {}) as WebviewStyle,
          javascriptEnable: data?.javascriptEnable ?? true,
          userAgent: data?.userAgent,
          devtools: data?.devtools,
          autoplay: data?.autoplay,
          initializationScripts: initScripts,
          onDragAndDrop: data?.onDragAndDrop,
          onDownloadStart: data?.onDownloadStart,
          onDownloadEnd: data?.onDownloadEnd,
          onNavigationRequest: data?.onNavigationRequest,
          onTitleChange: data?.onTitleChange,
          onPageBegin: data?.onPageBegin,
          onPageEnd: data?.onPageEnd,
          onWindowNew: data?.onWindowNew,
        } as WebviewInitData;

        hilog.info(DOMAIN, 'ArkHelper',
          'createWebview event handlers: nav=%{public}s, title=%{public}s, dlStart=%{public}s, dlEnd=%{public}s, pgBegin=%{public}s, pgEnd=%{public}s',
          typeof init.onNavigationRequest === 'function' ? 'YES' : 'NO',
          typeof init.onTitleChange === 'function' ? 'YES' : 'NO',
          typeof init.onDownloadStart === 'function' ? 'YES' : 'NO',
          typeof init.onDownloadEnd === 'function' ? 'YES' : 'NO',
          typeof init.onPageBegin === 'function' ? 'YES' : 'NO',
          typeof init.onPageEnd === 'function' ? 'YES' : 'NO',
        );

        init.style = init.style || {};
        // OHOS: Set WebView transparent only when requested (same as createWebview).
        if (data?.transparent) {
          init.transparent = true;
          init.style.backgroundColor = Color.Transparent;
        }

        const ret = manager.createWebview(init);
        const applyStyle = (style: WebviewStyle) => {
          objectAssign(init.style as Record<string, ESObject>, style);
          manager.updateWebviewStyle(ret.webTag, init.style as WebviewStyle);
        };

        ret.controller.setBackgroundColor = (color: number) => {
          applyStyle({ backgroundColor: color });
        };

        ret.controller.setVisible = (visible: boolean) => {
          applyStyle({ visible });
        };

        ret.controller.setBounds = (x: number, y: number, width: number, height: number) => {
          applyStyle({ x, y, width, height });
        };
        ret.controller.setBlurRadius = (radius: number) => {
          applyStyle({ blurRadius: radius });
        };

        ret.controller.dispose = () => {
          manager.removeWebview(ret.webTag);
        };

        return ret;
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'createEmbeddedWebview failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    createOSWindow: async (config: WindowConfig): Promise<number> => {
      try {
        hilog.info(DOMAIN, 'ArkHelper', 'Received config from Rust: %{public}s', JSON.stringify(config));
        hilog.info(DOMAIN, 'ArkHelper', 'Parsed -> name: %{public}s, windowId: %{public}d',
          config.name, config.windowId);

        const wm = WindowManager.getInstance();
        hilog.info(DOMAIN, 'ArkHelper', 'WindowManager instance acquired');

        return await wm.createSubWindow({
          name: config.name,
          windowId: config.windowId,
          width: config.width,
          height: config.height,
          x: config.x,
          y: config.y,
          decorations: config.decorations,
          transparent: config.transparent,
          backgroundColor: config.backgroundColor,
        });
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'Failed to create OS window: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    // Start a new EntryAbility instance (multi-UIAbility-instance path).
    // Rust calls this via NAPI (start_ui_ability) with a want object carrying
    // abilityName + pre-allocated windowId + label + url + multiton flag.
    // Uses WindowManager's UIAbilityContext to call context.startAbility directly.
    // Requires launchType: "standard" in module.json5 for the new instance to be created.
    startUIAbility: (want: UIAbilityWantParams): void => {
      try {
        hilog.info(DOMAIN, 'ArkHelper', 'startUIAbility: %{public}s', JSON.stringify(want));
        const context = WindowManager.getInstance().getContext();
        // OHOS ArkTS requires parameters to be a Record<string, Object> declared
        // as a separate variable — an inline object literal is inferred as a
        // different type and AMS drops the custom keys. Match demo3's pattern.
        let params: Record<string, Object> = {
          'tauri_window_id': String(want.windowId),
          'tauri_window_label': String(want.label),
          'tauri_window_url': String(want.url),
          'tauri_multiton': String(want.multiton),
          'tauri_transparent': String(want.transparent),
        };
        let fullWant: Want = {
          bundleName: context.applicationInfo.name,
          abilityName: want.abilityName,
          parameters: params
        };
        // Defer to the next event-loop tick: this handler is invoked from a Rust
        // NAPI callback (func.call), and OHOS appears to drop want.parameters
        // when context.startAbility is called inside a NAPI-reentrant context.
        // setTimeout(0) moves the call to a pure ArkTS context (same as demo3's
        // button onClick), restoring parameter forwarding.
        hilog.info(DOMAIN, 'ArkHelper', 'startUIAbility fullWant: %{public}s', JSON.stringify(fullWant));
        setTimeout(() => {
          context.startAbility(fullWant).catch((err: ESObject) => {
            hilog.error(DOMAIN, 'ArkHelper', 'startAbility failed: %{public}s', JSON.stringify(err));
          });
        }, 0);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'startUIAbility failed: %{public}s', JSON.stringify(err));
      }
    },

    setWindowDecorations: (windowId: number, decorations: boolean): void => {
      try {
        const wm = WindowManager.getInstance();
        wm.setDecorations(windowId, decorations);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'setWindowDecorations failed: %{public}s', JSON.stringify(err));
      }
    },

    setWindowBackgroundColor: (windowId: number, color: number): void => {
      try {
        const wm = WindowManager.getInstance();
        wm.setWindowBackgroundColor(windowId, color);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'setWindowBackgroundColor failed: %{public}s', JSON.stringify(err));
      }
    },

    setWindowTopmost: (windowId: number, topmost: boolean): void => {
      try {
        WindowManager.getInstance().setWindowTopmost(windowId, topmost);
      } catch (err) {
        safeLogError('setWindowTopmost', err);
      }
    },

    setWindowTitle: (args: ESObject): void => {
      try {
        const windowId = Number(args.windowId);
        const title = String(args.title);
        WindowManager.getInstance().setWindowTitle(windowId, title);
      } catch (err) {
        safeLogError('setWindowTitle', err);
      }
    },

    setWindowLimits: (windowId: number, minW: number, minH: number, maxW: number, maxH: number): void => {
      try {
        WindowManager.getInstance().setWindowLimits(windowId, minW, minH, maxW, maxH);
      } catch (err) {
        safeLogError('setWindowLimits', err);
      }
    },

    focusWindow: (windowId: number): void => {
      try {
        const wm = WindowManager.getInstance();
        wm.focusWindow(windowId);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'focusWindow failed: %{public}s', String(err));
      }
    },

    setWindowFocusable: (windowId: number, focusable: boolean): void => {
      try {
        const wm = WindowManager.getInstance();
        wm.setWindowFocusable(windowId, focusable);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'setWindowFocusable failed: %{public}s', String(err));
      }
    },

    // ─── Window operations (ohos-window-ops) ───

    moveWindowTo: (params: ESObject): void => {
      try {
        const windowId = Number(params.windowId);
        const x = Number(params.x);
        const y = Number(params.y);
        WindowManager.getInstance().moveWindowTo(windowId, x, y);
      }
      catch (err) { safeLogError('moveWindowTo', err); }
    },

    resizeWindow: (params: ESObject): void => {
      try {
        const windowId = Number(params.windowId);
        const width = Number(params.width);
        const height = Number(params.height);
        WindowManager.getInstance().resizeWindow(windowId, width, height);
      }
      catch (err) { safeLogError('resizeWindow', err); }
    },

    maximizeWindow: (windowId: number): void => {
      try { WindowManager.getInstance().maximizeWindow(windowId); }
      catch (err) { safeLogError('maximizeWindow', err); }
    },

    minimizeWindow: (windowId: number): void => {
      try { WindowManager.getInstance().minimizeWindow(windowId); }
      catch (err) { safeLogError('minimizeWindow', err); }
    },

    restoreWindow: (windowId: number): void => {
      try { WindowManager.getInstance().restoreWindow(windowId); }
      catch (err) { safeLogError('restoreWindow', err); }
    },

    recoverWindow: (windowId: number): void => {
      try { WindowManager.getInstance().recoverWindow(windowId); }
      catch (err) { safeLogError('recoverWindow', err); }
    },

    showWindowMethod: (windowId: number): void => {
      try { WindowManager.getInstance().showWindowMethod(windowId); }
      catch (err) { safeLogError('showWindowMethod', err); }
    },

    // Close/destroy a window: Float sub-window → win.destroyWindow() (real destroy);
    // UIAbility main window → context.terminateSelf() (real close, not hide).
    // Called via NAPI destroy_window.
    closeWindow: (windowId: number): void => {
      try { WindowManager.getInstance().closeWindow(windowId); }
      catch (err) { safeLogError('closeWindow', err); }
    },

    // ─── A/D/E group completions ──────────────────────────────────────────────
    hideWindow: (windowId: number): void => {
      try { WindowManager.getInstance().hideWindow(windowId); }
      catch (err) { safeLogError('hideWindow', err); }
    },
    setFullscreen: (windowId: number, on: boolean): void => {
      try { WindowManager.getInstance().setFullscreen(windowId, on); }
      catch (err) { safeLogError('setFullscreen', err); }
    },
    setWindowTouchable: (windowId: number, touchable: boolean): void => {
      try { WindowManager.getInstance().setWindowTouchable(windowId, touchable); }
      catch (err) { safeLogError('setWindowTouchable', err); }
    },
    setWindowDecorationFlags: (windowId: number, flags: number): void => {
      try { WindowManager.getInstance().setDecorationFlags(windowId, flags); }
      catch (err) { safeLogError('setWindowDecorationFlags', err); }
    },
    setPointerVisible: (visible: boolean): void => {
      try { WindowManager.getInstance().setPointerVisible(visible); }
      catch (err) { safeLogError('setPointerVisible', err); }
    },
    setPointerStyle: (windowId: number, style: number): void => {
      try { WindowManager.getInstance().setPointerStyle(windowId, style); }
      catch (err) { safeLogError('setPointerStyle', err); }
    },
    getRealWindowId: (windowId: number): number => {
      try { return WindowManager.getInstance().getRealWindowId(windowId); }
      catch (err) { safeLogError('getRealWindowId', err); return -1; }
    },

    isMaximized: (windowId: number): boolean => {
      try { return WindowManager.getInstance().isMaximized(windowId); }
      catch (err) { safeLogError('isMaximized', err); return false; }
    },

    isMinimized: (windowId: number): boolean => {
      try { return WindowManager.getInstance().isMinimized(windowId); }
      catch (err) { safeLogError('isMinimized', err); return false; }
    },

    setWindowBlur: (windowId: number, radius: number): void => {
      try {
        WindowManager.getInstance().applyWindowBlur(windowId, radius);
      } catch (_err) {
        // Intentionally no hilog here: this is called from Rust NAPI (NAPI-reentrant ArkTS
        // context), where hilog throws "Argc mismatch" and would mask the original error.
        // Note: the error is NOT propagated to Rust — set_window_blur uses TSFN fire-and-forget
        // (NonBlocking, no return value wait), so Rust receives Ok regardless of ArkTS failure.
        // applyWindowBlur has internal fallbacks (queue pendingBlurs for build-time inject,
        // modifier refresh for runtime), so a throw here is non-fatal. If synchronous error
        // propagation is needed later, switch to call_with_return_value + oneshot (like
        // clipboard_write_image).
      }
    },

    loadUrl: (id: number, url: string): void => {
      try {
        hilog.info(DOMAIN, 'ArkHelper', 'loadUrl called for window %{public}d: %{public}s', id, url);
        const wm = WindowManager.getInstance();
        wm.loadUrl(id, url);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'loadUrl failed for window %{public}d: %{public}s', id, JSON.stringify(err));
      }
    },

    requestUserAttention: (): void => {
      // OHOS 窗口层无 requestAttention API。通过 notificationManager 发通知实现类似效果。
      // 必须用静态 import 的 notificationManager — 动态 import('@kit.NotificationKit')
      // 在设备上加载 native so 失败(libnotificationkit.z.so not exist)。
      // 通知 id:用闭包内单调递增计数器,避免并发调用共用固定 id:1 导致后调用覆盖前者
      // (PR#45 review F3)。tao 侧 request_user_attention 未透传 windowId,故此处无法按窗口
      // 分配 id(那需要 tao→ability crate→ArkTS 全链路加 windowId 形参)。
      const notifId = ++attentionNotifId;
      try {
        const doPublish = () => {
          notificationManager.publish({
            id: notifId,
            content: {
              contentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
              normal: { title: 'Tauri App', text: '请查看应用窗口' as string },
            } as ESObject,
          } as ESObject).then(() => {
            hilog.info(DOMAIN, 'ArkHelper', 'requestUserAttention: notification published OK (id=%{public}d)', notifId);
          }).catch((err: ESObject) => {
            const code = (err && (err as ESObject).code) ? (err as ESObject).code : -1;
            hilog.warn(DOMAIN, 'ArkHelper', 'requestUserAttention: publish failed id=%{public}d code=%{public}s: %{public}s', notifId, String(code), JSON.stringify(err));
            // 1600004 = 通知未授权 → 弹系统授权弹窗(requestEnableNotification)
            if (code === 1600004) {
              notificationManager.requestEnableNotification().then(() => {
                hilog.info(DOMAIN, 'ArkHelper', 'requestUserAttention: notification enabled, retry publish (id=%{public}d)', notifId);
                doPublish();
              }).catch((e2: ESObject) => {
                hilog.warn(DOMAIN, 'ArkHelper', 'requestUserAttention: requestEnableNotification failed: %{public}s', JSON.stringify(e2));
              });
            }
          });
        };
        doPublish();
      } catch (err) {
        // safeLogError: 同步 catch 处于 NAPI 重入上下文(Rust func.call),hilog.warn
        // 可能抛 "Argc mismatch" 掩盖原始错误(C5)。
        safeLogError('requestUserAttention', err);
      }
    },

    setImePosition: (windowId: number, x: number, y: number): void => {
      // IME 位置:通过 inputMethod.getController().updateCursor(CursorInfo) 通知输入法光标坐标。
      // API 10+。tao 传的是物理像素(px),CursorInfo 的 left/top 也以 px 计,直接透传。
      // 前置条件:窗口内有已聚焦的编辑框(HTML input 亦可,ArkWeb 走系统输入法框架,
      // 见官方《Web 组件对接软键盘》)。无聚焦编辑框时报 12800009
      // (input method client detached) — 任何应用无聚焦编辑框时调用皆如此,非 webview 特有。
      // 聚焦 HTML input 后实测返回 OK(2026-08-19 A/B 实验)。
      try {
        const cursorInfo: ESObject = {
          left: Math.round(x),
          top: Math.round(y),
          width: 1,       // 光标宽度(px)
          height: 24,     // 光标高度(px,近似行高)
        };
        inputMethod.getController().updateCursor(cursorInfo).then(() => {
          lastImeResult = { ok: true, code: 0, message: 'OK', x: Math.round(x), y: Math.round(y), ts: Date.now() };
          hilog.info(DOMAIN, 'ArkHelper', 'setImePosition: updateCursor OK window=%{public}d x=%{public}d y=%{public}d', windowId, x, y);
        }).catch((err: ESObject) => {
          const code = (err && (err as ESObject).code) ? (err as ESObject).code : -1;
          lastImeResult = { ok: false, code: code, message: JSON.stringify(err), x: Math.round(x), y: Math.round(y), ts: Date.now() };
          // 12800009 = input method client detached — 调用时无聚焦编辑框,正常
          hilog.warn(DOMAIN, 'ArkHelper', 'setImePosition: updateCursor failed code=%{public}s: %{public}s', String(code), JSON.stringify(err));
        });
      } catch (err) {
        // Sync throw — the .then/.catch callbacks never run, so nothing would
        // update lastImeResult; record the failure here or the readback channel
        // would return a stale success from a previous call (review finding).
        lastImeResult = { ok: false, code: -1, message: 'sync throw', x: Math.round(x), y: Math.round(y), ts: Date.now() };
        // safeLogError: 同步 catch 处于 NAPI 重入上下文(C5)。
        safeLogError('setImePosition', err);
      }
    },

    getImePositionResult: (): string => {
      // poll 回读:上一次 setImePosition 里 updateCursor promise 的真实结果
      return JSON.stringify(lastImeResult);
    },

    setWindowDraggable: (windowId: number, enable: boolean): void => {
      // enableDrag (API20+) — 允许/禁止窗口边缘拖拽缩放
      // safeLogError: 本方法经 Rust func.call 同步调用(NAPI 重入上下文),同步段
      // (window-not-found 分支、外层 catch)的 hilog 可能抛 "Argc mismatch"(C5);
      // 异步 .then/.catch 回调不在重入上下文,保留 hilog。
      // API guard: enableDrag 是 API20+,低版本 win.enableDrag 为 undefined → TypeError,
      // 对齐同文件的 startMoving(API14)/setWindowTopmost(API14) guard 模式。
      if (deviceInfo.sdkApiVersion < 20) {
        safeLogError('setWindowDraggable(api-below-20)', { code: -1, msg: `enableDrag requires API20+, current ${deviceInfo.sdkApiVersion}; no-op` } as ESObject);
        return;
      }
      try {
        const win = WindowManager.getInstance().getWindow(windowId);
        if (!win) { safeLogError('setWindowDraggable(window-not-found)', { code: -1, msg: `window ${windowId} not found` } as ESObject); return; }
        win.enableDrag(enable).then(() => {
          hilog.info(DOMAIN, 'ArkHelper', 'setWindowDraggable: window %{public}d enable=%{public}s OK', windowId, String(enable));
        }).catch((err: ESObject) => {
          hilog.warn(DOMAIN, 'ArkHelper', 'setWindowDraggable: window %{public}d failed: %{public}s', windowId, JSON.stringify(err));
        });
      } catch (err) {
        safeLogError('setWindowDraggable', err);
      }
    },

    addToStatusBarWithRgba: (iconsRgba: StatusBarIconRgba, iconSize: number, quickOperation: ESObject, statusBarGroupMenu?: ESObject[][], hoverTips?: string) => {
      hilog.info(DOMAIN, 'ArkHelper',`[StatusBar] addToStatusBarWithRgba called: iconSize=${iconSize}, hasWhite=${!!(iconsRgba.white)}, whiteLen=${iconsRgba.white?.length ?? 0}, hasBlack=${!!(iconsRgba.black)}, blackLen=${iconsRgba.black?.length ?? 0}`);
      const context = getAbilityContext();
      if (!context) { hilog.error(DOMAIN, 'ArkHelper','[StatusBar] no context'); return; }
      // NOTE: Do NOT auto-fill abilityName when it's empty string.
      // Per OHOS docs: abilityName="" means "no QuickOperation panel, fire statusBarIconClick event instead".
      // Only fill when abilityName is explicitly undefined/null (not empty string).
      if (quickOperation.abilityName == null) {
        quickOperation.abilityName = context.abilityInfo.name;
      }
      const icons: ESObject = {};
      if (iconsRgba.white && iconsRgba.white.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.white, iconSize);
        if (pm) icons.white = pm;
        hilog.info(DOMAIN, 'ArkHelper',`[StatusBar] white PixelMap: ${pm ? 'OK' : 'NULL'}`);
      }
      if (iconsRgba.black && iconsRgba.black.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.black, iconSize);
        if (pm) icons.black = pm;
        hilog.info(DOMAIN, 'ArkHelper',`[StatusBar] black PixelMap: ${pm ? 'OK' : 'NULL'}`);
      }
      if (Object.keys(icons).length === 0) { hilog.error(DOMAIN, 'ArkHelper','[StatusBar] no valid icons, aborting'); return; }
      const opts: ESObject = {
        icons: icons,
        quickOperation: quickOperation,
        statusBarGroupMenu: statusBarGroupMenu ?? []
      };
      if (statusBarGroupMenu) {
        fillMenuItemAbilityName(statusBarGroupMenu, context.abilityInfo.name);
        processMenuItemIcons(statusBarGroupMenu);
      }
      if (hoverTips && hoverTips.length > 0 && hoverTips.length <= 128) {
        opts.hoverTips = hoverTips;
      }
      // Register click handlers AFTER addToStatusBar returns, because addToStatusBar
      // internally calls initScbServerMessageReceiver which creates a new receiver
      // and wipes any handlers registered before it.
      try {
        statusBarManager.addToStatusBar(context, opts);
        reRegisterStatusBarClickHandlers();
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, 'ArkHelper',`[StatusBar] addToStatusBar failed: ${err.code} ${err.message}`);
      }
    },

    updateStatusBarIconWithRgba: (iconsRgba: StatusBarIconRgba, iconSize: number) => {
      const context = getAbilityContext();
      if (!context) return;
      const icons: ESObject = {};
      if (iconsRgba.white && iconsRgba.white.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.white, iconSize);
        if (pm) icons.white = pm;
      }
      if (iconsRgba.black && iconsRgba.black.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.black, iconSize);
        if (pm) icons.black = pm;
      }
      if (Object.keys(icons).length === 0) return;
      try {
        statusBarManager.updateStatusBarIcon(context, icons);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, 'ArkHelper',`[StatusBar] updateStatusBarIcon failed: ${err.code} ${err.message}`);
      }
    },

    registerIconClickHandler: (eventName: string, callback: Callback<emitter.EventData>) => {
      hilog.info(DOMAIN, 'ArkHelper',`[StatusBar] registerIconClickHandler: legacy call (using _onIconClick instead)`);
    },

    registerMenuClickHandler: (eventName: string, callback: Callback<emitter.EventData>) => {
      hilog.info(DOMAIN, 'ArkHelper',`[StatusBar] registerMenuClickHandler: legacy call (using _onMenuClick instead)`);
    },

    unregisterIconClickHandler: (eventName: string) => {
      statusBarManager.off(eventName as 'statusBarIconClick');
    },

    unregisterMenuClickHandler: (eventName: string) => {
      statusBarManager.off(eventName as 'rightMenuClick');
    },

    updateStatusBarMenu: (statusBarGroupMenu: ESObject[][]) => {
      const context = getAbilityContext();
      if (!context) return;
      try {
        fillMenuItemAbilityName(statusBarGroupMenu, context.abilityInfo.name);
        processMenuItemIcons(statusBarGroupMenu);
        statusBarManager.updateStatusBarMenu(context, statusBarGroupMenu);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, 'ArkHelper',`[StatusBar] updateStatusBarMenu failed: ${err.code} ${err.message}`);
      }
    },

    updateStatusBarHoverTips: (hoverTips: string) => {
      const context = getAbilityContext();
      if (!context) return;
      try {
        statusBarManager.updateStatusBarHoverTips(context, hoverTips);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, 'ArkHelper',`[StatusBar] updateStatusBarHoverTips failed: ${err.code} ${err.message}`);
      }
    },

    removeFromStatusBar: () => {
      const context = getAbilityContext();
      if (!context) return;
      try {
        statusBarManager.removeFromStatusBar(context);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, 'ArkHelper',`[StatusBar] removeFromStatusBar failed: ${err.code} ${err.message}`);
      }
    },

    executePredefinedAction: (actionType: string) => {
      const executor = getPredefinedActionExecutor();
      if (!executor) {
        hilog.warn(DOMAIN, 'ArkHelper',
          'PredefinedActionExecutor not initialized, action: %{public}s', actionType);
        return;
      }

      // Window operations from tray menu must be deferred to avoid race condition
      // with system's onNewWant → GoForeground transition.
      // These operations are deferred until RESUMED/WINDOW_ACTIVE event fires.
      const WINDOW_OPERATIONS: PredefinedType[] = ['minimize', 'hide', 'close'];
      if (WINDOW_OPERATIONS.includes(actionType as PredefinedType)) {
        hilog.info(DOMAIN, 'ArkHelper',
          'Deferring window operation "%{public}s" to avoid race with system foreground transition',
          actionType);
        const wm = WindowManager.getInstance();
        wm.setPendingAction(() => {
          executor.execute(actionType as PredefinedType);
        });
      } else {
        // Non-window operations (quit, showAll, bringAllToFront, etc.) execute immediately
        executor.execute(actionType as PredefinedType);
      }
    },

    setColorMode: (mode: number) => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'setColorMode: UIAbilityContext not available');
          return;
        }
        let colorMode: ConfigurationConstant.ColorMode;
        switch (mode) {
          case 0:
            colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
            break;
          case 1:
            colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
            break;
          default:
            colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
            break;
        }
        // Defer setColorMode to next event loop to avoid deadlock:
        // setColorMode synchronously triggers onConfigurationUpdate callback,
        // which calls back into Rust. If we're already in a NAPI call from Rust,
        // this creates a deadlock on the main thread.
        setTimeout(() => {
          try {
            context!.getApplicationContext().setColorMode(colorMode);
            hilog.info(DOMAIN, 'ArkHelper', 'setColorMode: applied mode %{public}d', mode);
          } catch (err) {
            hilog.error(DOMAIN, 'ArkHelper', 'setColorMode deferred callback failed (ability may be destroyed): %{public}s', String(err));
          }
        }, 0);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'setColorMode failed: %{public}s', JSON.stringify(err));
      }
    },

    checkCanIUse: (syscap: string): boolean => {
      return canIUse(syscap);
    },

    writeImageToClipboard: async (rgbaData: Uint8Array, width: number, height: number): Promise<void> => {
      return await writeImageToClipboard(rgbaData, width, height);
    },

    autostartEnable: async (): Promise<void> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'autostartEnable: UIAbilityContext not available');
          throw new Error('UIAbilityContext not available');
        }
        await openAutostartSettings(context);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'autostartEnable failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    autostartDisable: async (): Promise<void> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'autostartDisable: UIAbilityContext not available');
          throw new Error('UIAbilityContext not available');
        }
        await openAutostartSettings(context);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'autostartDisable failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    autostartIsEnabled: async (): Promise<boolean> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'autostartIsEnabled: UIAbilityContext not available');
          throw new Error('UIAbilityContext not available');
        }
        return await getAutostartStatus(context);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'autostartIsEnabled failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    openWithSystem: async (uri: string): Promise<void> => {
      const context = getUIAbilityContext();
      if (!context) {
        throw new Error('UIAbilityContext not available');
      }
      await context.startAbility({
        action: 'ohos.want.action.viewData',
        uri: uri,
        entities: ['entity.system.browsable'],
      });
    },

    revealInDir: async (dirUri: string): Promise<void> => {
      const context = getUIAbilityContext();
      if (!context) {
        throw new Error('UIAbilityContext not available');
      }
      await context.startAbility({
        action: 'ohos.want.action.viewData',
        uri: dirUri,
      });
    },

    registerHotkey: (jsonStr: string): void => {
      registerHotkey(jsonStr);
    },

    unregisterHotkey: (id: number): void => {
      unregisterHotkey(id);
    },

    unregisterAllHotkeys: (): void => {
      unregisterAllHotkeys();
    },

  };
}
