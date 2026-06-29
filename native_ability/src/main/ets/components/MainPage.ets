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
import { DOMAIN, MAIN_WINDOW_ID } from '../helper/constants';
import { WindowManager } from '../window/WindowManager';

export const RouteName = "NativeAbility";

@Entry({ routeName: RouteName })
@Component
struct MainPage {
  @StorageProp("moduleName") moduleNames: string | string[] = "";

  // loadMode is immutable after onCreate, no need for @StorageProp reactive binding
  private loadMode: "async" | "sync" = "async";

  @State private nativeModule: ESObject | null = null;
  @State private resolvedModuleName: string = "";

  // Key repeat test overlay state
  @State private keyTestVisible: boolean = false;
  @State private keyTestLog: string[] = [];
  private pressedKeys: Set<number> = new Set();

  private acceleratorMatcher: AcceleratorMatcher = new AcceleratorMatcher();

  async aboutToAppear(): Promise<void> {
    hilog.info(DOMAIN, 'MainPage', '=== MainPage aboutToAppear START ===');
    this.loadMode = (AppStorage.get<string>("loadMode") as "async" | "sync") ?? "async";
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
          windowId: MAIN_WINDOW_ID,
          acceleratorMatcher: this.acceleratorMatcher,
        })

        Row() {
          Column() {
            if (this.resolvedModuleName !== "") {
              DefaultXComponent({ moduleName: this.resolvedModuleName, windowId: MAIN_WINDOW_ID })
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
            const handler = getMenuClickHandler(MAIN_WINDOW_ID);
            if (handler) {
              handler(matchedItem);
            }
          }
          return true;
        }
        // ESC to restore menubar from fullscreen
        if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE && !isMenubarVisible(MAIN_WINDOW_ID)) {
          const recoverFn = getMenuBarRecoverFn(MAIN_WINDOW_ID);
          if (recoverFn) {
            recoverFn();
          }
          return true;
        }
        // ESC to close key repeat test overlay
        if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE && this.keyTestVisible) {
          this.keyTestVisible = false;
          this.keyTestLog = [];
          this.pressedKeys.clear();
          return true;
        }
        return false;
      })

      // Floating button to toggle key repeat test overlay
      Button("⌨ Key Test")
        .fontSize(11)
        .height(28)
        .padding({ left: 8, right: 8 })
        .backgroundColor(this.keyTestVisible ? "#4CAF50" : "#666")
        .fontColor(Color.White)
        .borderRadius(14)
        .position({ x: "75%", y: "92%" })
        .opacity(0.8)
        .onClick(() => {
          this.keyTestVisible = !this.keyTestVisible;
          if (!this.keyTestVisible) {
            this.keyTestLog = [];
            this.pressedKeys.clear();
          }
        })

      // Key repeat test overlay — bypasses WebView, captures keys at ArkUI level
      if (this.keyTestVisible) {
        Column() {
          Row() {
            Text("Key Repeat Test (ArkUI level)").fontSize(16).fontColor(Color.White).fontWeight(FontWeight.Bold)
            Blank()
            Text("✕").fontSize(20).fontColor(Color.White)
              .onClick(() => {
                this.keyTestVisible = false;
                this.keyTestLog = [];
                this.pressedKeys.clear();
              })
          }.width("100%").padding({ left: 16, right: 16, top: 8, bottom: 8 })

          Text("Hold a key to test repeat detection. Press ESC or ✕ to close.")
            .fontSize(12).fontColor("#AAA").padding({ left: 16, bottom: 8 })

          Scroll() {
            Column() {
              ForEach(this.keyTestLog, (item: string) => {
                Text(item)
                  .fontSize(13)
                  .fontFamily("monospace")
                  .fontColor(item.includes("repeat=true") ? "#4CAF50" : "#CCC")
                  .fontWeight(item.includes("repeat=true") ? FontWeight.Bold : FontWeight.Normal)
                  .width("100%")
              }, (item: string) => item + Math.random())
            }.width("100%").padding({ left: 16, right: 16 })
          }.layoutWeight(1)
        }
        .id("keyTestOverlay")
        .width("80%")
        .height("60%")
        .backgroundColor("#1E1E1E")
        .borderRadius(12)
        .border({ width: 2, color: "#4CAF50" })
        .shadow({ radius: 20, color: "#00000080" })
        .focusable(true)
        .defaultFocus(true)
        .onKeyEvent((event: KeyEvent) => {
          const keyCode = event.keyCode;
          const keyText = event.keyText || `code:${keyCode}`;
          let isRepeat = false;

          if (event.type === KeyType.Down) {
            isRepeat = this.pressedKeys.has(keyCode);
            this.pressedKeys.add(keyCode);
          } else if (event.type === KeyType.Up) {
            this.pressedKeys.delete(keyCode);
          }

          const entry = `key="${keyText}" type=${event.type === KeyType.Down ? "Down" : "Up"} repeat=${isRepeat}`;
          this.keyTestLog = [...this.keyTestLog.slice(-29), entry];
          hilog.info(DOMAIN, 'KeyTest', '%{public}s', entry);
        })
        .onAppear(() => {
          // Request focus so onKeyEvent fires for keyboard input
          try {
            focusControl.requestFocus("keyTestOverlay");
          } catch (e) {
            hilog.warn(DOMAIN, 'KeyTest', 'focusControl failed: %{public}s', String(e));
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    // Track user touch for tray menu window targeting (D8: migrated from DefaultXComponent).
    // ArkUI onTouch bubbles from child to parent, covering MenuBarComponent + webview + all children.
    // Note: Web component may internally consume some touch events (scroll/zoom).
    // If webview touch tracking is unreliable, add onTouch to DefaultXComponent as fallback.
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        try {
          WindowManager.getInstance().setUserInteractedWindow(MAIN_WINDOW_ID);
        } catch (e) {
          hilog.warn(DOMAIN, 'MainPage', 'onTouch: WindowManager not ready: %{public}s', String(e));
        }
      }
    })
  }
}
