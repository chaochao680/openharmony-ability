import { window, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { RustWebviewNodeController, WebviewInitData } from '../webview/DefaultWebview';
import { ProxyJsHelper } from '../webview/Utils';
import * as FloatPage from '../components/FloatPage';
import { DOMAIN } from '../helper/constants';

interface WindowEntry {
  window: window.Window;
  storage?: LocalStorage;
}

export class WindowManager {
  private static instance: WindowManager | null = null;
  private context: common.UIAbilityContext;
  private windowStage: window.WindowStage | null = null;
  private windows: Map<number, WindowEntry> = new Map();
  private controllers: Map<number, RustWebviewNodeController> = new Map();
  private uiContexts: Map<number, UIContext> = new Map();
  
  // Proxy object queue (caches Rust operations before Controller is ready)
  private pendingJsHelperProxies: Map<number, ProxyJsHelper> = new Map();
  
  // Pending URL queue
  private pendingUrls: Map<number, string> = new Map();
  // Pending WebView init queue (resolves race conditions)
  private pendingInits: Map<number, WebviewInitData> = new Map();
  
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

  setWindowStage(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
    hilog.info(DOMAIN, 'WindowManager', 'WindowStage set');
  }

  async createSubWindow(name: string, type: number, windowId: number, width: number = 800, height: number = 600, x: number = 100, y: number = 100,
      decorations: boolean = true, transparent: boolean = false, backgroundColor?: number): Promise<number> {
    // Validate windowId: sub-window ID must be greater than 0
    if (windowId <= 0) {
      hilog.error(DOMAIN, 'WindowManager', `Invalid windowId: %{public}d. Sub-window creation requires windowId > 0.`, windowId);
      throw new Error(`Invalid windowId: ${windowId}. Must be greater than 0.`);
    }

    // Check if windowStage has been set
    if (!this.windowStage) {
      hilog.error(DOMAIN, 'WindowManager', 'WindowStage not set. Call setWindowStage() first.');
      throw new Error('WindowStage not set');
    }

    hilog.info(DOMAIN, 'WindowManager', `Creating sub-window via windowStage: %{public}s, id: %{public}d`, name, windowId);

    let win: window.Window;
    try {
      // Use windowStage.createSubWindow(name) instead of window.createWindow(config)
      win = await this.windowStage.createSubWindow(name);
      hilog.info(DOMAIN, 'WindowManager', `Sub-window created successfully: %{public}d`, windowId);
    } catch (err) {
      hilog.error(DOMAIN, 'WindowManager', `Failed to create sub-window: %{public}s`, JSON.stringify(err));
      throw err;
    }
    
    // Use LocalStorage to pass windowId and decorations, ensuring isolation between windows
    let storage = new LocalStorage();
    storage.setOrCreate('windowId', windowId);
    storage.setOrCreate('decorations', decorations);
    this.windows.set(windowId, { window: win, storage });

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
        hilog.info(DOMAIN, 'WindowManager', `Setting window %{public}d to transparent`, windowId);
        await win.setWindowBackgroundColor('#00000000');
        // On 2in1 devices (API 20+), also set container color for full transparency
        if (deviceInfo.sdkApiVersion >= 20) {
          try {
            await win.setWindowContainerColor('#00000000', '#00000000');
            hilog.info(DOMAIN, 'WindowManager', `Window %{public}d container color set to transparent (API %{public}d)`, windowId, deviceInfo.sdkApiVersion);
          } catch (containerErr: any) {
            if (containerErr.code === 801) {
              hilog.debug(DOMAIN, 'WindowManager', 'setWindowContainerColor not supported on this device (error 801)');
            } else if (containerErr.code === 201) {
              hilog.error(DOMAIN, 'WindowManager', 'setWindowContainerColor permission denied (error 201): missing ohos.permission.SET_WINDOW_TRANSPARENT');
            } else {
              hilog.warn(DOMAIN, 'WindowManager', `Sub-window container color failed: code=%{public}d`, containerErr.code);
            }
          }
        }
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
    this.controllers.set(id, controller);

    // 1. Process pending WebView init requests (resolves race conditions)
    const pendingInit = this.pendingInits.get(id);
    if (pendingInit) {
      hilog.info(DOMAIN, 'WindowManager', `Processing pending init for window ${id}`);
      const result = controller.addWebview(pendingInit);
      this.pendingInits.delete(id);

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
      controller.addWebview({ url: pendingUrl });
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
    const entry = this.windows.get(id);
    return entry?.window;
  }

  // Phase 2: Update window decorations at runtime via LocalStorage reactive update
  setDecorations(windowId: number, decorations: boolean): void {
    const entry = this.windows.get(windowId);
    if (entry && entry.storage) {
      entry.storage.setOrCreate('decorations', decorations);
      hilog.info(DOMAIN, 'WindowManager', `Decorations set to %{public}s for window %{public}d`, String(decorations), windowId);
    }
    // Main window (windowId=0): hide or restore system status bar
    if (windowId === 0) {
      if (!decorations) {
        this.hideSystemBar();
      } else {
        this.showSystemBar();
      }
    }
  }

  // Phase 3: Update window background color at runtime
  setWindowBackgroundColor(windowId: number, color: number): void {
    const colorStr = '#' + color.toString(16).padStart(8, '0');
    hilog.info(DOMAIN, 'WindowManager', `setWindowBackgroundColor: windowId=%{public}d, color=%{public}s`, windowId, colorStr);
    if (windowId === 0 && this.windowStage) {
      // Main window
      try {
        const mainWindow = this.windowStage.getMainWindowSync();
        mainWindow.setWindowBackgroundColor(colorStr);
        // On 2in1 devices, also set container color for full transparency (requires API 20+)
        if (deviceInfo.sdkApiVersion >= 20) {
          try {
            mainWindow.setWindowContainerColor(colorStr, colorStr);
          } catch (containerErr: any) {
            if (containerErr.code === 801) {
              hilog.debug(DOMAIN, 'WindowManager', 'setWindowContainerColor not supported on this device (error 801)');
            } else if (containerErr.code === 201) {
              hilog.error(DOMAIN, 'WindowManager', 'setWindowContainerColor permission denied (error 201): missing ohos.permission.SET_WINDOW_TRANSPARENT');
            } else {
              hilog.error(DOMAIN, 'WindowManager', `Failed to set container color: code=%{public}d, message=%{public}s`, containerErr.code, containerErr.message);
            }
          }
        }
      } catch (e) {
        hilog.error(DOMAIN, 'WindowManager', `Failed to set main window background: %{public}s`, JSON.stringify(e));
      }
    } else {
      const entry = this.windows.get(windowId);
      if (entry) {
        try {
          entry.window.setWindowBackgroundColor(colorStr);
          if (deviceInfo.sdkApiVersion >= 20) {
            try {
              entry.window.setWindowContainerColor(colorStr, colorStr);
            } catch (containerErr: any) {
              if (containerErr.code === 801) {
                hilog.debug(DOMAIN, 'WindowManager', 'setWindowContainerColor not supported on this device (error 801)');
              } else if (containerErr.code === 201) {
                hilog.error(DOMAIN, 'WindowManager', 'setWindowContainerColor permission denied (error 201): missing ohos.permission.SET_WINDOW_TRANSPARENT');
              } else {
                hilog.warn(DOMAIN, 'WindowManager', `Sub-window container color failed: code=%{public}d`, containerErr.code);
              }
            }
          }
        } catch (e) {
          hilog.warn(DOMAIN, 'WindowManager', `Failed to set background for window %{public}d: %{public}s`, windowId, JSON.stringify(e));
        }
      }
    }
  }

  // Phase 2: Hide system status bar for main window (decorations=false)
  private hideSystemBar(): void {
    if (!this.windowStage) return;
    try {
      const mainWindow = this.windowStage.getMainWindowSync();
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
    if (!this.windowStage) return;
    try {
      const mainWindow = this.windowStage.getMainWindowSync();
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
    this.windows.delete(windowId);
    this.controllers.delete(windowId);
    this.uiContexts.delete(windowId);
    this.pendingJsHelperProxies.delete(windowId);
    this.pendingUrls.delete(windowId);
    this.pendingInits.delete(windowId);
  }
}
