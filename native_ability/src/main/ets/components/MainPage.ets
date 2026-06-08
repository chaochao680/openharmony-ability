import { DefaultXComponent } from "./DefaultXComponent";
import { Loadable } from "../helper/loadable";
import { AcceleratorMatcher } from "../helper/accelerator_matcher";
import {
  MenuBarComponent,
  getMenuClickHandler,
  getMenuBarRecoverFn,
  isMenubarVisible,
} from "./MenuBarComponent";
import { KeyCode } from "@kit.InputKit";
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x1999;

export const RouteName = "NativeAbility";

@Entry({ routeName: RouteName })
@Component
struct MainPage {
  @StorageProp("moduleName") moduleNames: string | string[] = "";
  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";

  @State private nativeModule: ESObject | null = null;
  @State private resolvedModuleName: string = "";

  private acceleratorMatcher: AcceleratorMatcher = new AcceleratorMatcher();

  async aboutToAppear(): Promise<void> {
    hilog.info(DOMAIN, 'MainPage', '=== MainPage aboutToAppear START ===');
    hilog.info(DOMAIN, 'MainPage', 'Initializing MAIN WINDOW');

    // Main window specific logic: load Native Module
    const moduleName = Loadable.resolvePrimaryModuleName(this.moduleNames);
    if (!moduleName) {
      hilog.error(DOMAIN, 'MainPage', 'moduleName is empty, cannot initialize main window');
      throw new Error("MainPage.moduleName is required for main window");
    }

    hilog.info(DOMAIN, 'MainPage', 'Resolved moduleName: %{public}s', moduleName);
    this.resolvedModuleName = moduleName;

    hilog.info(DOMAIN, 'MainPage', 'Loading native module: %{public}s', moduleName);
    this.nativeModule = await Loadable.load(moduleName, this.loadMode);
    hilog.info(DOMAIN, 'MainPage', 'Native module loaded successfully');
  }

  onBackPress(): boolean {
    // Main window specific: handle back button interception
    try {
      if (typeof this.nativeModule?.onBackPressIntercept === "function") {
        return this.nativeModule.onBackPressIntercept();
      }
      if (typeof this.nativeModule?.on_back_press_intercept === "function") {
        return this.nativeModule.on_back_press_intercept();
      }
    } catch (err) {
      hilog.error(DOMAIN, 'MainPage', 'onBackPress failed: %{public}s', JSON.stringify(err));
    }
    return false;
  }

  build() {
    Stack() {
      Column() {
        MenuBarComponent({
          windowId: 0,
          acceleratorMatcher: this.acceleratorMatcher,
        })

        Row() {
          Column() {
            if (this.resolvedModuleName !== "") {
              DefaultXComponent({ moduleName: this.resolvedModuleName, windowId: 0 })
            } else {
              Text("Loading Main Window...")
                .fontSize(20)
                .fontColor(Color.Gray)
            }
          }.width("100%")
        }.layoutWeight(1).height("100%")

      }.width("100%").height("100%")
      .backgroundColor(Color.Transparent)
      .onKeyPreIme((event: KeyEvent) => {
        // Accelerator matching (non-clipboard shortcuts)
        if (event.type === KeyType.Down && this.acceleratorMatcher.matches(event)) {
          const matchedItem = this.acceleratorMatcher.getMatchedItem();
          if (matchedItem) {
            const handler = getMenuClickHandler(0);
            if (handler) {
              handler(matchedItem);
            }
          }
          return true;
        }
        // ESC to restore menubar from fullscreen
        if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE && !isMenubarVisible(0)) {
          const recoverFn = getMenuBarRecoverFn(0);
          if (recoverFn) {
            recoverFn();
          }
          return true;
        }
        return false;
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
