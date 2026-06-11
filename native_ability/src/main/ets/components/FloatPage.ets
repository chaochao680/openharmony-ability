import { DefaultXComponent } from "./DefaultXComponent";
import {
  MenuBarComponent,
  getMenuClickHandler,
  getMenuBarRecoverFn,
  isMenubarVisible,
} from "./MenuBarComponent";
import { AcceleratorMatcher } from "../helper/accelerator_matcher";
import { KeyCode, pointer } from "@kit.InputKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window as arkWindow, CursorController } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { WindowManager } from '../window/WindowManager';
import { DOMAIN } from '../helper/constants';

export const RouteName = "FloatWindow";

interface Position {
  x: number,
  y: number
}

@Entry({ routeName: RouteName, storage: LocalStorage.getShared() })
@Component
struct FloatPage {
  // Receive windowId from WindowManager.createSubWindow
  @LocalStorageProp('windowId') windowId: number = 0;
  @LocalStorageProp('decorations') decorations: boolean = true;
  @StorageProp("__openharmony_ability_is_desktop__") isDesktop: boolean = false;

  // Window control
  private windowClass: arkWindow.Window | null = null;
  @State @Watch("moveAndSetWindow") windowPosition: Position = { x: 100, y: 100 };
  @State dpiScale: number = 1;
  private cursorController: CursorController | null = null;
  private acceleratorMatcher: AcceleratorMatcher = new AcceleratorMatcher();

  // Resize tracking
  private startWidth: number = 0;
  private startHeight: number = 0;
  private currentWidth: number = 800;
  private currentHeight: number = 600;

  moveAndSetWindow() {
    this.windowClass?.moveWindowTo(this.windowPosition.x, this.windowPosition.y);
  }

  async aboutToAppear(): Promise<void> {
    hilog.info(DOMAIN, 'FloatPage', '=== FloatPage aboutToAppear START ===');
    hilog.info(DOMAIN, 'FloatPage', 'Received windowId: %{public}d', this.windowId);

    if (this.windowId <= 0) {
      hilog.error(DOMAIN, 'FloatPage', 'Invalid windowId: %{public}d. FloatPage requires windowId > 0.', this.windowId);
      return;
    }

    try {
      const ui = this.getUIContext();
      const winName = ui.getWindowName();
      if (winName) {
        this.windowClass = arkWindow.findWindow(winName);
        if (this.windowClass) {
          try {
            const rect = this.windowClass.getGlobalRect();
            this.windowPosition = { x: rect.left, y: rect.top };
            if (rect.width > 0) this.currentWidth = rect.width;
            if (rect.height > 0) this.currentHeight = rect.height;
            hilog.info(DOMAIN, 'FloatPage', 'Got windowClass: left=%{public}d, top=%{public}d, w=%{public}d, h=%{public}d', rect.left, rect.top, this.currentWidth, this.currentHeight);
          } catch (e) {
            hilog.error(DOMAIN, 'FloatPage', 'Failed to get window rect: %{public}s', JSON.stringify(e));
          }
        } else {
          hilog.error(DOMAIN, 'FloatPage', 'findWindow returned null for name: %{public}s', winName);
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, 'FloatPage', 'Failed to get windowClass: %{public}s', JSON.stringify(e));
    }

    try {
      this.cursorController = this.getUIContext().getCursorController();
    } catch (e) {
      hilog.warn(DOMAIN, 'FloatPage', 'Failed to get CursorController: %{public}s', JSON.stringify(e));
    }

    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      this.dpiScale = defaultDisplay.densityPixels;
      hilog.info(DOMAIN, 'FloatPage', 'Display densityPixels: %{public}f', this.dpiScale);
    } catch (e) {
      hilog.warn(DOMAIN, 'FloatPage', 'Failed to get display scale: %{public}s', JSON.stringify(e));
    }
  }

  aboutToDisappear(): void {
    hilog.info(DOMAIN, 'FloatPage', 'aboutToDisappear for windowId: %{public}d', this.windowId);
    // Safety net: ensure WindowManager resources are cleaned up even if the close button's destroyWindow path was not triggered
    try {
      WindowManager.getInstance().removeWindow(this.windowId);
    } catch (e) {
      hilog.warn(DOMAIN, 'FloatPage', 'aboutToDisappear removeWindow failed: %{public}s', String(e));
    }
  }

  build() {
    Stack() {
      Column() {
        // Menubar (only on desktop when menu items are available and decorations are enabled)
        if (this.isDesktop && this.decorations) {
          MenuBarComponent({
            windowId: this.windowId,
            acceleratorMatcher: this.acceleratorMatcher,
          })
        }

        Stack({ alignContent: Alignment.TopEnd }) {
          // 1. WebView content area (full screen)
          DefaultXComponent({ windowId: this.windowId })
            .width('100%')
            .height('100%');

          // 2. Top drag control area + right close button (only when decorations are enabled)
          if (this.windowClass && this.decorations) {
            Row() {
              Row() {}
                .layoutWeight(1)
                .height(40);

              Button() {
                Image($r('sys.media.ohos_ic_public_cancel'))
                  .width(20)
                  .height(20)
                  .fillColor('#666666');
              }
              .width(32)
              .height(32)
              .borderRadius(16)
              .backgroundColor('#f0f0f0')
              .margin({ top: 4, right: 8 })
              .onClick(async () => {
                hilog.info(DOMAIN, 'FloatPage', 'Close button clicked for window %{public}d', this.windowId);
                try {
                  if (this.windowClass) {
                    await this.windowClass.destroyWindow();
                    WindowManager.getInstance().removeWindow(this.windowId);
                  }
                } catch (e) {
                  hilog.error(DOMAIN, 'FloatPage', 'Failed to destroy window %{public}d: %{public}s', this.windowId, JSON.stringify(e));
                }
              });
            }
            .width('100%')
            .height(40)
            .align(Alignment.TopEnd)
            .gesture(
              PanGesture({ direction: PanDirection.All })
                .onActionUpdate((event: GestureEvent) => {
                  if (this.windowClass) {
                    this.windowPosition.x = this.windowClass.getGlobalRect().left;
                    this.windowPosition.y = this.windowClass.getGlobalRect().top;
                    this.windowPosition.x += event.offsetX;
                    this.windowPosition.y += event.offsetY;
                  }
                })
            );
          }
        }
        .layoutWeight(1)
        .width('100%');
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent);

      // 3. Resize handles (only on desktop with decorations enabled)
      if (this.isDesktop && this.windowClass && this.decorations) {
        // Right edge resize handle
        Row() {}
          .width(10)
          .height('100%')
          .position({ right: 0 })
          .backgroundColor(Color.Transparent)
          .onHover((isHover: boolean) => {
            if (isHover) {
              this.cursorController?.setCursor(pointer.PointerStyle.WEST_EAST);
            } else {
              this.cursorController?.restoreDefault();
            }
          })
          .gesture(
            PanGesture({ direction: PanDirection.Horizontal })
              .onActionStart(() => {
                this.startWidth = this.currentWidth;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (!this.windowClass) return;
                try {
                  this.currentWidth = Math.round(Math.max(200, this.startWidth + event.offsetX * this.dpiScale));
                  this.windowClass.resize(this.currentWidth, this.currentHeight);
                } catch (e) {
                  hilog.error(DOMAIN, 'FloatPage', 'Right resize failed: w=%{public}d, h=%{public}d, err=%{public}s', this.currentWidth, this.currentHeight, JSON.stringify(e));
                }
              })
          );

        // Bottom edge resize handle
        Row() {}
          .width('100%')
          .height(10)
          .position({ bottom: 0 })
          .backgroundColor(Color.Transparent)
          .onHover((isHover: boolean) => {
            if (isHover) {
              this.cursorController?.setCursor(pointer.PointerStyle.NORTH_SOUTH);
            } else {
              this.cursorController?.restoreDefault();
            }
          })
          .gesture(
            PanGesture({ direction: PanDirection.Vertical })
              .onActionStart(() => {
                this.startHeight = this.currentHeight;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (!this.windowClass) return;
                try {
                  this.currentHeight = Math.round(Math.max(150, this.startHeight + event.offsetY * this.dpiScale));
                  this.windowClass.resize(this.currentWidth, this.currentHeight);
                } catch (e) {
                  hilog.error(DOMAIN, 'FloatPage', 'Bottom resize failed: w=%{public}d, h=%{public}d, err=%{public}s', this.currentWidth, this.currentHeight, JSON.stringify(e));
                }
              })
          );

        // Bottom-right corner resize handle
        Row() {}
          .width(15)
          .height(15)
          .position({ right: 0, bottom: 0 })
          .backgroundColor(Color.Transparent)
          .onHover((isHover: boolean) => {
            if (isHover) {
              this.cursorController?.setCursor(pointer.PointerStyle.NORTH_WEST_SOUTH_EAST);
            } else {
              this.cursorController?.restoreDefault();
            }
          })
          .gesture(
            PanGesture({ direction: PanDirection.All })
              .onActionStart(() => {
                this.startWidth = this.currentWidth;
                this.startHeight = this.currentHeight;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (!this.windowClass) return;
                try {
                  this.currentWidth = Math.round(Math.max(200, this.startWidth + event.offsetX * this.dpiScale));
                  this.currentHeight = Math.round(Math.max(150, this.startHeight + event.offsetY * this.dpiScale));
                  this.windowClass.resize(this.currentWidth, this.currentHeight);
                } catch (e) {
                  hilog.error(DOMAIN, 'FloatPage', 'Corner resize failed: w=%{public}d, h=%{public}d, err=%{public}s', this.currentWidth, this.currentHeight, JSON.stringify(e));
                }
              })
          );
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onKeyPreIme((event: KeyEvent) => {
      if (event.type === KeyType.Down && this.acceleratorMatcher.matches(event)) {
        const matchedItem = this.acceleratorMatcher.getMatchedItem();
        if (matchedItem) {
          const handler = getMenuClickHandler(this.windowId);
          if (handler) {
            handler(matchedItem);
          }
        }
        return true;
      }
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE && !isMenubarVisible(this.windowId)) {
        const recoverFn = getMenuBarRecoverFn(this.windowId);
        if (recoverFn) {
          recoverFn();
        }
        return true;
      }
      return false;
    })
  }
}
