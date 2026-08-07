import { AbilityConstant, Configuration, UIAbility, Want } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import webview from "@ohos.web.webview";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { RouteName } from "../components/MainPage";
import { setMenuClickHandler, setMenuBarRecoverFn, getMenuDataCallback } from "../components/MenuBarComponent";
import { ApplicationLifecycle, Module } from "./type";
import { MenuManager, PredefinedActionExecutor, setPredefinedActionExecutor } from "../helper/menu";
import { AboutMetadataData } from "../helper/menu_types";
import { setCurrentAbilityName } from "../helper/StatusBarUtils";
import { WindowManager } from "../window/WindowManager";
import { DOMAIN } from '../helper/constants';
import { setPrimaryWebviewControllerCallback } from "../components/DefaultXComponent";
import { ProcessInitializer } from "./ProcessInitializer";

export const STATE_KEY = "ohos.rs.ability.application.state";

export class NativeAbility extends UIAbility {
  public moduleName: string | string[] = "";
  public defaultPage: boolean = true;
  public mode: "xcomponent" | "webview" = "xcomponent";
  public loadMode: "async" | "sync" = "async";
  // The Want that launched this instance. Saved in onCreate so onWindowStageCreate
  // can read want.parameters.tauri_window_id (windowId for subsequent instances).
  // Named appLaunchWant to avoid colliding with UIAbility base class members.
  private appLaunchWant: Want | null = null;

  protected forEachLifecycle(handler: (lifecycle: ApplicationLifecycle) => void): void {
    const lifecycles = ProcessInitializer.getLifecycles();
    for (const lifecycle of lifecycles) {
      try {
        handler(lifecycle);
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'Lifecycle callback error: %{public}s', String(e));
      }
    }
  }

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    setCurrentAbilityName(want.abilityName ?? "");
    this.appLaunchWant = want;

    hilog.info(DOMAIN, 'NativeAbility', 'onCreate - moduleName: %{public}s', JSON.stringify(this.moduleName));
    AppStorage.setOrCreate("moduleName", this.moduleName);
    AppStorage.setOrCreate("loadMode", this.loadMode);

    // Process-level initialization (runs only once; subsequent instances skip it)
    const context = this.context as common.UIAbilityContext;
    await ProcessInitializer.initialize(context, this.moduleName, this.loadMode, want);
  }

  private setupMenuPopup(windowStage: window.WindowStage): void {
    const nativeModules = ProcessInitializer.getNativeModules();
    const primaryModule: ESObject = nativeModules[0] as ESObject;
    if (!primaryModule || typeof primaryModule.onMenuRequest !== 'function') {
      return;
    }

    AppStorage.setOrCreate("__openharmony_ability_is_desktop__", primaryModule.isDesktopDevice());

    const emitMenuEventFn: (menuId: string, windowId?: string) => void = primaryModule.emitMenuEvent as (menuId: string, windowId?: string) => void;

    const executor = new PredefinedActionExecutor((code: number) => {
      this.context?.terminateSelf();
    });
    const mainWindow = windowStage.getMainWindowSync();
    executor.setWindow(mainWindow);
    executor.setContext(this.context as common.UIAbilityContext);
    setPredefinedActionExecutor(executor);
    executor.setShowAboutFn((metadata: AboutMetadataData) => {
      const appName = metadata.name ?? '';
      const appVersion = metadata.version ?? '';
      const appCopyright = metadata.copyright ?? '';
      const appAuthors = metadata.authors?.join(', ') ?? '';
      const appComments = metadata.comments ?? '';
      const appWebsite = metadata.website ?? '';

      const lines: string[] = [];
      if (appName) lines.push(appName);
      if (appVersion) lines.push(`Version: ${appVersion}`);
      if (appCopyright) lines.push(appCopyright);
      if (appAuthors) lines.push(`Authors: ${appAuthors}`);
      if (appComments) lines.push(appComments);
      if (appWebsite) lines.push(appWebsite);
      const message = lines.join('\n');
      const title = appName || 'About';

      try {
        const uiContext = mainWindow.getUIContext();
        uiContext.showAlertDialog({
          title: title,
          message: message,
          autoCancel: true,
          confirm: {
            value: 'OK',
            action: () => {},
          },
        });
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'Show about dialog failed: %{public}s', String(e));
      }
    });

    const menuManager = new MenuManager(executor, emitMenuEventFn);

    // Wire up per-window menu click handler (MW-1): routes through MenuManager for predefined/custom actions
    setMenuClickHandler(0, (item) => {
      menuManager.handleItemClick(item);
    });

    // Wire up per-window recover function (MW-1)
    setMenuBarRecoverFn(0, () => {
      mainWindow.recover();
    });

    setPrimaryWebviewControllerCallback((controller: webview.WebviewController) => {
      executor.setController(controller);
    });

    // Route menu requests via callback (MW-5) instead of AppStorage
    primaryModule.onMenuRequest((data: { jsonData: string; x?: number; y?: number; visible?: boolean; windowId?: string }) => {
      const windowId = data.windowId ?? "main";

      // Handle menubar visibility changes via callback
      if (data.visible !== undefined && data.visible !== null) {
        const cb = getMenuDataCallback(windowId);
        cb?.onMenubarVisible?.(data.visible);
        primaryModule.notifyMenubarVisibility(windowId, data.visible);
        return;
      }

      // Handle popup menu requests via callback
      if (data.x !== undefined && data.y !== undefined) {
        try {
          menuManager.popupFromJson(data.jsonData, data.x ?? 0, data.y ?? 0, windowId);
        } catch (e) {
          console.error(`[Menu] Popup failed: ${e}`);
        }
        return;
      }

      // Handle menubar JSON updates via callback
      const cb = getMenuDataCallback(windowId);
      cb?.onMenubarJson?.(data.jsonData);
    });
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageCreate());

    // All UIAbility instances are equal — unified registration.
    // windowId from want (subsequent instances) or 0 (first instance).
    const windowId = this.readWindowId();
    const transparent = this.readTransparent();
    WindowManager.getInstance().registerUIAbilityStage(windowId, windowStage, this.context, transparent);
    hilog.info(DOMAIN, 'NativeAbility', 'onWindowStageCreate: windowId=%{public}d transparent=%{public}s', windowId, String(transparent));

    try {
      windowStage.on("windowStageEvent", (event: window.WindowStageEventType) => {
        this.forEachLifecycle((lifecycle) =>
          lifecycle.windowStageEventCallback.onWindowStageEvent(event),
        );
      });
    } catch (e) {
      hilog.error(DOMAIN, 'NativeAbility', 'windowStage.on failed: %{public}s', String(e));
    }

    let win: window.Window | null = null;
    try {
      win = await windowStage.getMainWindow();
    } catch (e) {
      hilog.error(DOMAIN, 'NativeAbility', 'getMainWindow failed: %{public}s', String(e));
      win = null;
    }

    if (win) {
      try {
        win.on("windowSizeChange", (size: window.Size) => {
          this.forEachLifecycle((lifecycle) =>
            lifecycle.windowStageEventCallback.onWindowSizeChange(size),
          );
        });
        win.on("windowRectChange", (options: window.RectChangeOptions) => {
          if (options.reason === window.RectChangeReason.RECOVER) {
            const cb = getMenuDataCallback("main");
            cb?.onMenubarVisible?.(true);
          }
          this.forEachLifecycle((lifecycle) =>
            lifecycle.windowStageEventCallback.onWindowRectChange(options),
          );
        });
        win.on("avoidAreaChange", (options: window.AvoidAreaOptions) => {
          this.forEachLifecycle((lifecycle) =>
            lifecycle.windowStageEventCallback.onAvoidAreaChange(options),
          );
        });
        win.on("keyboardHeightChange", (height) => {
          this.forEachLifecycle((lifecycle) =>
            lifecycle.keyboardEventCallback.onKeyboardHeightChange(height),
          );
        });
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'Window event registration failed: %{public}s', String(e));
      }
    }

    if (this.defaultPage) {
      try {
        // Subsequent instances (windowId > 0): pass windowId via LocalStorage so
        // MainPage's DefaultXComponent reads the correct id. First instance
        // (windowId=0): no LocalStorage needed (default 0).
        if (windowId > 0) {
          let storage = new LocalStorage();
          storage.setOrCreate('windowId', windowId);
          await windowStage.loadContentByName(RouteName, storage);
          hilog.info(DOMAIN, 'NativeAbility', 'loadContentByName with windowId=%{public}d', windowId);
        } else {
          await windowStage.loadContentByName(RouteName);
        }
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'loadContentByName failed: %{public}s', String(e));
      }
    }

    // Transparent window background/container color is applied in
    // DefaultXComponent.aboutToAppear (window fully ready there). The transparent
    // flag is stored in WindowManager.registerUIAbilityStage and applied via
    // WindowManager.applyTransparentBackground(windowId) in aboutToAppear.

    try {
      this.setupMenuPopup(windowStage);
    } catch (menuErr) {
      console.error(`[Menu] setupMenuPopup threw: ${menuErr}`);
    }
  }

  onWindowStageDestroy(): void | Promise<void> {
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageDestroy());
    try {
      const windowId = this.readWindowId();
      WindowManager.getInstance().unregisterUIAbilityStage(windowId);
    } catch (e) {
      hilog.error(DOMAIN, 'NativeAbility', 'onWindowStageDestroy cleanup failed: %{public}s', String(e));
    }
  }

  // Reads windowId from want.parameters.tauri_window_id.
  // Returns 0 (first instance, no want param) or >0 (subsequent instances).
  private readWindowId(): number {
    if (!this.appLaunchWant || !this.appLaunchWant.parameters) {
      return 0;
    }
    const raw = this.appLaunchWant.parameters['tauri_window_id'];
    if (raw === undefined || raw === null) {
      return 0;
    }
    const id = Number(raw);
    return Number.isFinite(id) ? id : 0;
  }

  // Reads transparent flag from want.parameters.tauri_transparent.
  // Returns false (default opaque) for first instance or when param absent.
  private readTransparent(): boolean {
    if (!this.appLaunchWant || !this.appLaunchWant.parameters) {
      return false;
    }
    const raw = this.appLaunchWant.parameters['tauri_transparent'];
    if (raw === undefined || raw === null) {
      return false;
    }
    return String(raw) === 'true';
  }

  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    this.forEachLifecycle((lifecycle) => lifecycle.environmentCallback.onMemoryLevel(level));
  }

  onDestroy(): void | Promise<void> {
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onAbilityDestroy());
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const uri = want.uri ?? '';
    const parametersJson = JSON.stringify(want.parameters ?? {});
    hilog.info(DOMAIN, 'NativeAbility', 'onNewWant - uri: %{public}s, parametersJson.length: %{public}d', uri, parametersJson.length);

    // Cancel cleanup timer when system triggers onNewWant
    // This indicates the system's foreground transition has started,
    // so we don't need the safety net timer anymore.
    try {
      const wm = WindowManager.getInstance();
      if (wm.hasPendingAction()) {
        hilog.info(DOMAIN, 'NativeAbility', 'onNewWant detected pending action, cancelling cleanup timer');
        wm.cancelCleanupTimer();
      }
    } catch (e) {
      // WindowManager might not be initialized yet, ignore
    }

    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onNewWant({ uri, parametersJson }));
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.forEachLifecycle((lifecycle) =>
      lifecycle.environmentCallback.onConfigurationUpdated(newConfig),
    );
  }

  onSaveState(
    reason: AbilityConstant.StateType,
    wantParam: Record<string, Object>,
  ): AbilityConstant.OnSaveResult {
    const stateMap: Record<string, string> = {};

    const lifecycles = ProcessInitializer.getLifecycles();
    const loadedModuleNames = ProcessInitializer.getLoadedModuleNames();
    for (let i = 0; i < lifecycles.length; i++) {
      const lifecycle = lifecycles[i];
      const moduleName = loadedModuleNames[i];
      if (!moduleName) {
        continue;
      }

      try {
        stateMap[moduleName] = lifecycle.windowStageEventCallback.onAbilitySaveState() ?? "";
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'onAbilitySaveState failed: %{public}s', String(e));
      }
    }

    const stateValues = Object.values(stateMap);
    if (stateValues.length === 1) {
      wantParam[STATE_KEY] = stateValues[0];
    } else if (stateValues.length > 1) {
      wantParam[STATE_KEY] = JSON.stringify(stateMap);
    } else {
      wantParam[STATE_KEY] = "";
    }

    return AbilityConstant.OnSaveResult.RECOVERY_AGREE;
  }
}
