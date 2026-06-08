import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { statusBarManager } from "@kit.DeskTopExtensionKit";
import { emitter, BusinessError } from "@kit.BasicServicesKit";
import { image } from "@kit.ImageKit";
import {
  ArkHelper,
  StatusBarIconRgba,
  WebViewInitData as NativeWebViewInitData,
  WindowAvoidAreaInfo,
  WindowConfig,
} from "../ability/type";
import { exit, restart, check as updaterCheckFn, showUpdateDialog as updaterShowDialogFn, downloadAndInstall as updaterDownloadAndInstallFn, objectAssign, writeImageToClipboard, openAutostartSettings, getAutostartStatus } from "../helper";
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
import { JsHelper, ProxyJsHelper } from "../webview/Utils";
import {
  getAbilityContext,
  createPixelMapFromRgba,
  fillMenuItemAbilityName,
  processMenuItemIcons,
  helperRef,
  reRegisterStatusBarClickHandlers,
} from "../helper/StatusBarUtils";
import { ConfigurationConstant } from '@kit.AbilityKit';
import { primaryWebviewControllerCallback, clearPrimaryWebviewControllerCallback } from "../components/DefaultXComponent";

const DOMAIN: number = 0x1999;

/**
 * 全局 ArkHelper 工厂函数
 * 
 * 设计原则：
 * - 不依赖任何组件实例的 this 指针
 * - 所有窗口相关资源通过 WindowManager 统一管理
 * - UIContext 从 WindowManager 按 windowId 获取
 */
export function createArkHelper(): ArkHelper {
  // 每个窗口的 EmbeddedWebviewManager 实例按 windowId 管理
  const embeddedManagers: Map<number, EmbeddedWebviewManager> = new Map();

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
      // 优先从主窗口 (windowId=0) 获取 context
      const uiCtx = wm.getUIContext(0);
      if (uiCtx) {
        return uiCtx.getHostContext() as common.UIAbilityContext;
      }
    } catch (e) {
      hilog.error(DOMAIN, 'ArkHelper', 'Failed to get UIAbilityContext: %{public}s', JSON.stringify(e));
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
          // 主窗口
          hilog.info(DOMAIN, 'ArkHelper', 'Getting avoid area for MAIN window');
          const context = getUIAbilityContext();
          if (context) {
            win = context.windowStage.getMainWindowSync();
          }
        } else {
          // 子窗口
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
        
        // 1. 严格根据 windowId 查找 Controller
        let targetController: RustWebviewNodeController | null = null;
        try {
          const wm = WindowManager.getInstance();
          targetController = wm.getController(windowId);
        } catch (e) {
          hilog.error(DOMAIN, 'ArkHelper', 'Failed to get WindowManager: %{public}s', JSON.stringify(e));
        }

        // 2. 准备 Init 数据
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
        // Window shell transparency is controlled separately by setWindowBackgroundColor().
        if (data?.transparent) {
          init.transparent = true;
          init.style.backgroundColor = Color.Transparent;
        }

        // 3. 如果 Controller 未就绪，创建代理并入队
        if (!targetController) {
          hilog.warn(DOMAIN, 'ArkHelper', 'Controller not ready for window %{public}d. Creating proxy.', windowId);
          try {
            const wm = WindowManager.getInstance();
            wm.queueWebviewInit(windowId, init);
            
            // 创建轻量级代理对象返回给 Rust
            const proxy = new ProxyJsHelper();
            wm.registerPendingJsHelperProxy(windowId, proxy);
            return proxy;
          } catch (e) {
            hilog.error(DOMAIN, 'ArkHelper', 'Failed to queue init or create proxy: %{public}s', JSON.stringify(e));
            // 极端异常下返回 ProxyJsHelper 兜底，操作被缓存而非丢失 TODO:rust侧处理错误
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

        // 4. 正常创建
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
        hilog.info(DOMAIN, 'ArkHelper', 'Parsed -> name: %{public}s, type: %{public}d',
          config.name, config.type);

        const wm = WindowManager.getInstance();
        hilog.info(DOMAIN, 'ArkHelper', 'WindowManager instance acquired');

        return await wm.createSubWindow(
          config.name,
          config.type,
          config.windowId,
          config.width,
          config.height,
          config.x,
          config.y,
          config.decorations,
          config.transparent,
          config.backgroundColor
        );
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'Failed to create OS window: %{public}s', JSON.stringify(err));
        throw err;
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

    loadUrl: (id: number, url: string): void => {
      try {
        hilog.info(DOMAIN, 'ArkHelper', 'loadUrl called for window %{public}d: %{public}s', id, url);
        const wm = WindowManager.getInstance();
        wm.loadUrl(id, url);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'loadUrl failed for window %{public}d: %{public}s', id, JSON.stringify(err));
      }
    },

    addToStatusBarWithRgba: (iconsRgba: StatusBarIconRgba, iconSize: number, quickOperation: ESObject, statusBarGroupMenu?: ESObject[][], hoverTips?: string) => {
      console.info(`[StatusBar] addToStatusBarWithRgba called: iconSize=${iconSize}, hasWhite=${!!(iconsRgba.white)}, whiteLen=${iconsRgba.white?.length ?? 0}, hasBlack=${!!(iconsRgba.black)}, blackLen=${iconsRgba.black?.length ?? 0}`);
      const context = getAbilityContext();
      if (!context) { console.error('[StatusBar] no context'); return; }
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
        console.info(`[StatusBar] white PixelMap: ${pm ? 'OK' : 'NULL'}`);
      }
      if (iconsRgba.black && iconsRgba.black.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.black, iconSize);
        if (pm) icons.black = pm;
        console.info(`[StatusBar] black PixelMap: ${pm ? 'OK' : 'NULL'}`);
      }
      if (Object.keys(icons).length === 0) { console.error('[StatusBar] no valid icons, aborting'); return; }
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
        console.error(`[StatusBar] addToStatusBar failed: ${err.code} ${err.message}`);
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
        console.error(`[StatusBar] updateStatusBarIcon failed: ${err.code} ${err.message}`);
      }
    },

    registerIconClickHandler: (eventName: string, callback: Callback<emitter.EventData>) => {
      console.info(`[StatusBar] registerIconClickHandler: legacy call (using _onIconClick instead)`);
    },

    registerMenuClickHandler: (eventName: string, callback: Callback<emitter.EventData>) => {
      console.info(`[StatusBar] registerMenuClickHandler: legacy call (using _onMenuClick instead)`);
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
        console.error(`[StatusBar] updateStatusBarMenu failed: ${err.code} ${err.message}`);
      }
    },

    updateStatusBarHoverTips: (hoverTips: string) => {
      const context = getAbilityContext();
      if (!context) return;
      try {
        statusBarManager.updateStatusBarHoverTips(context, hoverTips);
      } catch (e) {
        const err = e as BusinessError;
        console.error(`[StatusBar] updateStatusBarHoverTips failed: ${err.code} ${err.message}`);
      }
    },

    removeFromStatusBar: () => {
      const context = getAbilityContext();
      if (!context) return;
      try {
        statusBarManager.removeFromStatusBar(context);
      } catch (e) {
        const err = e as BusinessError;
        console.error(`[StatusBar] removeFromStatusBar failed: ${err.code} ${err.message}`);
      }
    },

    executePredefinedAction: (actionType: string) => {
      const executor = getPredefinedActionExecutor();
      if (executor) {
        // Tray actions always target main window (no targetWindowId → defaults to this.win)
        executor.execute(actionType as PredefinedType);
      } else {
        hilog.warn(DOMAIN, 'ArkHelper',
          'PredefinedActionExecutor not initialized, action: %{public}s', actionType);
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
          context!.getApplicationContext().setColorMode(colorMode);
          hilog.info(DOMAIN, 'ArkHelper', 'setColorMode: applied mode %{public}d', mode);
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

  };
}
