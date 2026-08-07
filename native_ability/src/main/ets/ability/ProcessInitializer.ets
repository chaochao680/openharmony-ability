import { AbilityConstant, Want } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import webview from "@ohos.web.webview";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { ApplicationLifecycle, Module, AbilityInitContext } from "./type";
import { Loadable } from "../helper/loadable";
import { WindowManager } from "../window/WindowManager";
import { DOMAIN } from '../helper/constants';

/**
 * ProcessInitializer — process-level initialization, executed only once.
 *
 * Extracts process-level initialization code from NativeAbility.onCreate that is
 * independent of any single UIAbility instance:
 * - WindowManager singleton initialization
 * - native module (.so dynamic library) loading
 * - custom scheme registration
 * - Web engine initialization
 * - module.init → init NAPI → openharmony → run → run_app → render (global singleton)
 *
 * Subsequent UIAbility instances skip these initializations (initialized=true) to
 * avoid panicking from duplicate global-singleton initialization.
 * WebViews of subsequent instances are driven by DefaultXComponent.aboutToAppear → registerController.
 */
export class ProcessInitializer {
  private static initialized: boolean = false;
  private static nativeModules: Module[] = [];
  private static lifecycles: ApplicationLifecycle[] = [];
  private static loadedModuleNames: string[] = [];

  static isInitialized(): boolean {
    return this.initialized;
  }

  static getLifecycles(): ApplicationLifecycle[] {
    return this.lifecycles;
  }

  static getNativeModules(): Module[] {
    return this.nativeModules;
  }

  static getLoadedModuleNames(): string[] {
    return this.loadedModuleNames;
  }

  private static createInitContext(context: common.UIAbilityContext, moduleName: string): AbilityInitContext {
    return {
      basePath: context?.filesDir ?? "",
      prefPath: context?.filesDir ?? "",
      preferredLocales: context?.config?.language ?? "",
      moduleName,
      resourceManager: context?.resourceManager,
      sdkApiVersion: deviceInfo.sdkApiVersion,
      distributionOSApiVersion: deviceInfo.distributionOSApiVersion,
    };
  }

  /**
   * Process-level initialization. The first instance runs the full flow; later
   * instances return immediately.
   */
  static async initialize(
    context: common.UIAbilityContext,
    moduleName: string | string[],
    loadMode: "async" | "sync",
    want: Want,
  ): Promise<void> {
    if (this.initialized) {
      hilog.info(DOMAIN, 'ProcessInitializer', 'Already initialized, skipping');
      return;
    }

    // 1. WindowManager singleton initialization
    WindowManager.init(context);

    // 2. Load native module (.so dynamic library, process-level)
    const requestedModules = Loadable.resolveModuleNames(moduleName);
    if (requestedModules.length === 0) {
      throw new Error("moduleName must contain at least one module");
    }

    let webEngineRequired = false;
    for (const name of requestedModules) {
      const module: Module = await Loadable.load(name, loadMode);
      this.nativeModules.push(module);
      this.loadedModuleNames.push(name);

      if (typeof module.registerCustomProtocol === "function") {
        module.registerCustomProtocol();
        webEngineRequired = true;
      }
    }

    // 3. Web engine initialization
    if (webEngineRequired) {
      webview.WebviewController.initializeWebEngine();
    }

    // 4. module.init → init NAPI → openharmony → run → run_app → render
    //    Global singleton: set_helper / set_main_thread_env / TSFN / hilog / tray / sentry
    const isRestore = (want.parameters?.["ohos.ability.params.abilityRecoveryRestart"] as boolean) ?? false;
    const state = isRestore ? ((want.parameters?.["ohos.rs.ability.application.state"] as string) ?? "") : "";

    for (let i = 0; i < this.nativeModules.length; i++) {
      const module: Module = this.nativeModules[i];
      const moduleName: string = this.loadedModuleNames[i];
      const initContext = this.createInitContext(context, moduleName);
      const lifecycle: ApplicationLifecycle = module.init(initContext);
      this.lifecycles.push(lifecycle);

      const restoredState = state;
      try {
        lifecycle.windowStageEventCallback.onAbilityCreate(restoredState);
      } catch (e) {
        hilog.error(DOMAIN, 'ProcessInitializer', 'onAbilityCreate failed: %{public}s', String(e));
      }
      try {
        hilog.info(DOMAIN, 'ProcessInitializer', 'onAbilityCreateWithWant want.uri: %{public}s', want.uri ?? '');
        lifecycle.windowStageEventCallback.onAbilityCreateWithWant?.({ uri: want.uri ?? '' });
      } catch (e) {
        hilog.error(DOMAIN, 'ProcessInitializer', 'onAbilityCreateWithWant failed: %{public}s', String(e));
      }
    }

    this.initialized = true;
    hilog.info(DOMAIN, 'ProcessInitializer', 'Process initialization complete');
  }
}
