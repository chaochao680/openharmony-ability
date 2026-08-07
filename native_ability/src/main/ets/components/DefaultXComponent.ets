import { NodeContent } from "@kit.ArkUI";
import display from '@ohos.display';
import {
  ArkHelper,
  StatusBarIconRgba,
  WebViewInitData as NativeWebViewInitData,
  WindowAvoidAreaInfo,
} from "../ability/type";
import { exit, objectAssign } from "../helper";
import { Loadable } from "../helper/loadable";
import { requestPermission } from "../helper/permission";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import {
  EmbeddedWebviewManager,
  RustWebviewNodeController,
  WebviewStyle,
  WebviewInitData,
} from "../webview/DefaultWebview";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WindowManager } from "../window/WindowManager";
import { createArkHelper } from "../ability/ArkHelper";
import {
  setAbilityContext,
  setHelperRef,
  helperRef,
  statusBarManager,
  emitter,
  BusinessError,
} from "../helper/StatusBarUtils";
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY, MAIN_WINDOW_ID } from '../helper/constants';

export const RouteName = "NativeAbility";

import web_webview from '@ohos.web.webview';

export let primaryWebviewControllerCallback: ((controller: web_webview.WebviewController) => void) | null = null;

export function setPrimaryWebviewControllerCallback(cb: (controller: web_webview.WebviewController) => void): void {
  primaryWebviewControllerCallback = cb;
}

export function clearPrimaryWebviewControllerCallback(): void {
  primaryWebviewControllerCallback = null;
}

@Component
export struct DefaultXComponent {
  // Main window mode: moduleName is non-empty
  @Prop moduleName: string = "";
  // Sub-window mode: windowId is non-zero
  @Prop windowId: number = 0;

  private rootSlot = new NodeContent();
  private webviewController: RustWebviewNodeController | null = null;
  private nativeModule: ESObject;

  // Global ArkHelper instance (window-agnostic)
  private helper: ArkHelper = createArkHelper();

  // Check if this is a UIAbility window (id=0 first instance or id>0 subsequent)
  // by querying windowKinds — NOT by windowId===0.
  private isUIAbilityWindow(): boolean {
    try {
      return WindowManager.getInstance().isUIAbilityMainWindow(this.windowId);
    } catch (e) {
      // WindowManager not ready (first instance hasn't registered yet) —
      // fall back to windowId===0 for the first instance
      return this.windowId === MAIN_WINDOW_ID;
    }
  }

  // Check if this is the first UIAbility instance (windowId=0)
  private isFirstUIAbility(): boolean {
    return this.windowId === MAIN_WINDOW_ID;
  }

  // loadMode is read only once in aboutToAppear; no need for @StorageProp reactive binding
  private loadMode: "async" | "sync" = "async";

  aboutToDisappear(): void {
    hilog.info(DOMAIN, 'DefaultXComponent', 'aboutToDisappear for windowId: %{public}d', this.windowId);
    // Clean up this window's controller and UIContext from WindowManager
    try {
      const wm = WindowManager.getInstance();
      wm.removeControllerAndUIContext(this.windowId);
    } catch (e) {
      hilog.warn(DOMAIN, 'DefaultXComponent', 'aboutToDisappear cleanup failed: %{public}s', String(e));
    }
    this.webviewController = null;
  }

  async aboutToAppear(): Promise<void> {
    // Read loadMode once from AppStorage (avoids reactive re-render on AppStorage changes)
    this.loadMode = (AppStorage.get<string>("loadMode") as "async" | "sync") ?? "async";
    hilog.info(DOMAIN, 'DefaultXComponent', '=== aboutToAppear START ===');
    hilog.info(DOMAIN, 'DefaultXComponent', 'Props -> moduleName: "%{public}s", windowId: %{public}d',
      this.moduleName, this.windowId);

    setAbilityContext(this.getUIContext().getHostContext() as common.UIAbilityContext);
    // Only set helperRef for the first UIAbility (windowId=0). Subsequent UIAbility
    // instances and Float sub-windows must NOT overwrite the global helperRef.
    if (this.isFirstUIAbility()) {
      setHelperRef(this.helper);
    }

    try {
      // Register UIContext to WindowManager
      const uiCtx = this.getUIContext();
      if (uiCtx) {
        try {
          const wm = WindowManager.getInstance();
          wm.registerUIContext(this.windowId, uiCtx);
          hilog.info(DOMAIN, 'DefaultXComponent', 'UIContext registered for window %{public}d', this.windowId);
        } catch (e) {
          hilog.error(DOMAIN, 'DefaultXComponent', 'Failed to register UIContext: %{public}s', JSON.stringify(e));
        }
      }

      // Initialize webviewController
      this.webviewController = new RustWebviewNodeController(uiCtx);
      hilog.info(DOMAIN, 'DefaultXComponent', 'RustWebviewNodeController created');

      if (this.isUIAbilityWindow()) {
        // UIAbility window (id=0 first instance or id>0 subsequent — equal)
        if (this.isFirstUIAbility()) {
          // First instance: load native module + render (initializes global singletons:
          // set_helper / set_main_thread_env / TSFN / RootNode + XComponent)
          hilog.info(DOMAIN, 'DefaultXComponent', 'First UIAbility: loading native module + render');
          const moduleName = this.moduleName.trim();
          if (!moduleName) {
            throw new Error("DefaultXComponent.moduleName is required for first UIAbility");
          }
          this.nativeModule = await Loadable.load(moduleName, this.loadMode);
          AppStorage.setOrCreate<ESObject>(NATIVE_MODULE_STORAGE_KEY, this.nativeModule);
          this.nativeModule.render(this.helper, this.rootSlot);
          hilog.info(DOMAIN, 'DefaultXComponent', 'render() completed for windowId=%{public}d', this.windowId);
        } else {
          // Subsequent UIAbility (id>0): skip render (global singletons already
          // initialized by first instance). nativeModule from ProcessInitializer/AppStorage.
          hilog.info(DOMAIN, 'DefaultXComponent', 'Subsequent UIAbility: skipping render, windowId=%{public}d', this.windowId);
          this.nativeModule = AppStorage.get<ESObject>(NATIVE_MODULE_STORAGE_KEY) as ESObject;
        }

        // Register controller for all UIAbility windows
        try {
          const wm = WindowManager.getInstance();
          wm.registerController(this.windowId, this.webviewController);
          hilog.info(DOMAIN, 'DefaultXComponent', 'UIAbility controller registered: id=%{public}d', this.windowId);
        } catch (err) {
          hilog.warn(DOMAIN, 'DefaultXComponent', 'Failed to register controller: %{public}s', JSON.stringify(err));
        }

        // Apply transparent background/container color (window fully ready here).
        try {
          await WindowManager.getInstance().applyTransparentBackground(this.windowId);
        } catch (e) {
          hilog.warn(DOMAIN, 'DefaultXComponent', 'applyTransparentBackground failed: %{public}s', String(e));
        }
      } else {
        // Float sub-window mode: register to WindowManager (no render)
        hilog.info(DOMAIN, 'DefaultXComponent', 'Float sub-window: windowId=%{public}d', this.windowId);
        const wm = WindowManager.getInstance();
        wm.registerController(this.windowId, this.webviewController);
        hilog.info(DOMAIN, 'DefaultXComponent', 'Float sub-window controller registered');
      }
    } catch (err) {
      hilog.error(DOMAIN, 'DefaultXComponent', 'aboutToAppear FAILED: %{public}s', JSON.stringify(err));
      throw err;
    }
  }

  build() {
    Stack() {
      ContentSlot(this.rootSlot)
      Row() {
        Column() {
          NodeContainer(this.webviewController)
            .height("100%")
            .width("100%")
        }
        .width("100%")
        .backgroundColor(Color.Transparent)
      }
      .height("100%")
      .backgroundColor(Color.Transparent)
    }
    .backgroundColor(Color.Transparent);
  }
}
