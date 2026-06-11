import { MenuItemData, PredefinedType, AboutMetadataData } from './menu_types';
import web_webview from '@ohos.web.webview';
import window from '@ohos.window';
import display from '@ohos.display';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WindowManager } from '../window/WindowManager';
import { getMenuDataCallback, windowKeyForId } from '../components/MenuBarComponent';
import { DOMAIN } from './constants';

// Global executor singleton — shared by Menu and Tray execution paths
let globalExecutor: PredefinedActionExecutor | null = null;

export function setPredefinedActionExecutor(executor: PredefinedActionExecutor): void {
  globalExecutor = executor;
}

export function getPredefinedActionExecutor(): PredefinedActionExecutor | null {
  return globalExecutor;
}

export class PredefinedActionExecutor {
  private controller: web_webview.WebviewController | null = null;
  private win: window.Window | null = null;
  private exitFn: (code: number) => void;
  private showAboutFn: ((metadata: AboutMetadataData) => void) | null = null;

  constructor(exitFn: (code: number) => void) {
    this.exitFn = exitFn;
  }

  setController(controller: web_webview.WebviewController): void {
    this.controller = controller;
  }

  setWindow(win: window.Window): void {
    this.win = win;
  }

  setShowAboutFn(fn: (metadata: AboutMetadataData) => void): void {
    this.showAboutFn = fn;
  }

  /**
   * Minimize with guard against OHOS system focus restoration.
   *
   * When a StatusBar tray menu closes, the system may automatically restore
   * focus to the main window (WINDOW_ACTIVE event). If win.minimize() is
   * called immediately, the system's focus restoration may race with it,
   * causing the window to "flash" (shrink then pop back).
   *
   * Fix: defer minimize() until the system's focus restoration settles.
   * - If WINDOW_ACTIVE fires (system restored focus): minimize immediately
   *   after, avoiding the race entirely. Only one minimize call, no stutter.
   * - If WINDOW_ACTIVE never fires (no focus restoration, e.g. from menu path):
   *   a 50ms timeout falls back to direct minimize.
   *
   * maximize/fullscreen are unaffected because they don't remove the window
   * from the foreground.
   */
  private async minimizeWithRestoreGuard(win: window.Window | null): Promise<void> {
    if (!win) {
      return;
    }
    let consumed = false;
    const doMinimize = () => {
      if (!consumed) {
        consumed = true;
        try { win.off('windowEvent', onWindowEvent); } catch (e) { hilog.warn(DOMAIN, 'Menu', 'win.off failed: %{public}s', String(e)); }
        win.minimize();
      }
    };
    const onWindowEvent = (eventType: window.WindowEventType) => {
      if (!consumed && eventType === window.WindowEventType.WINDOW_ACTIVE) {
        // System just restored focus — now safe to minimize
        doMinimize();
      }
    };
    try {
      win.on('windowEvent', onWindowEvent);
    } catch (e) {
      hilog.warn(DOMAIN, 'Menu', 'windowEvent not supported, falling back: %{public}s', String(e));
      // windowEvent not supported — fall back to direct minimize
      win.minimize();
      return;
    }
    // If system doesn't fire WINDOW_ACTIVE (no focus restoration), minimize directly
    setTimeout(doMinimize, 50);
  }

  async execute(type: PredefinedType, aboutMetadata?: AboutMetadataData, targetWindowId?: number): Promise<void> {
    // Resolve target window for window operations
    let win: window.Window | null = this.win;
    if (targetWindowId !== undefined && targetWindowId !== 0) {
      try {
        const wm = WindowManager.getInstance();
        win = wm.getWindow(targetWindowId) ?? this.win;
      } catch (e) {
        hilog.warn(DOMAIN, 'Menu', 'Window lookup failed, using main window: %{public}s', String(e));
      }
    }

    const windowKey = windowKeyForId(targetWindowId ?? 0);

    switch (type) {
      case 'copy': {
        try {
          const raw = await this.controller?.runJavaScript('window.getSelection().toString()');
          if (raw) {
            const text = JSON.parse(raw as string);
            if (text) {
              const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text as string);
              const sysPasteboard = pasteboard.getSystemPasteboard();
              await sysPasteboard.setData(pasteData);
            }
          }
        } catch (e) {
          hilog.warn(DOMAIN, 'Menu', 'Clipboard copy failed: %{public}s', String(e));
        }
        break;
      }
      case 'cut': {
        try {
          const raw = await this.controller?.runJavaScript('window.getSelection().toString()');
          if (raw) {
            const text = JSON.parse(raw as string);
            if (text) {
              const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text as string);
              const sysPasteboard = pasteboard.getSystemPasteboard();
              await sysPasteboard.setData(pasteData);
              await this.controller?.runJavaScript('document.execCommand("delete")');
            }
          }
        } catch (e) {
          hilog.warn(DOMAIN, 'Menu', 'Clipboard cut failed: %{public}s', String(e));
        }
        break;
      }
      case 'paste': {
        try {
          const sysPasteboard = pasteboard.getSystemPasteboard();
          const pasteData = await sysPasteboard.getData();
          const text = pasteData.getPrimaryText();
          if (text) {
            // Use JSON.stringify for safe JS string escaping (prevents JS injection)
            const safeText = JSON.stringify(text);
            await this.controller?.runJavaScript(
              `document.execCommand("insertText", false, ${safeText})`
            );
          }
        } catch (e) {
          hilog.warn(DOMAIN, 'Menu', 'Clipboard paste failed: %{public}s', String(e));
        }
        break;
      }
      case 'selectAll':
        await this.controller?.runJavaScript('document.execCommand("selectAll")');
        break;
      case 'undo':
        await this.controller?.runJavaScript('document.execCommand("undo")');
        break;
      case 'redo':
        await this.controller?.runJavaScript('document.execCommand("redo")');
        break;
      case 'minimize':
      case 'hide':
      case 'close':
        await this.minimizeWithRestoreGuard(win);
        break;
      case 'maximize':
        await win?.maximize();
        break;
      case 'fullscreen': {
        // Hide menubar via callback (MW-5)
        const cb = getMenuDataCallback(windowKey);
        cb?.onMenubarVisible?.(false);
        cb?.onMenuShown?.(false);
        try {
          const displayInfo = display.getDefaultDisplaySync();
          if (displayInfo.width > 800) {
            await win?.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
          } else {
            await win?.setWindowLayoutFullScreen(true);
            await win?.setWindowSystemBarEnable([]);
          }
        } catch (e) {
          await win?.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
        }
        break;
      }
      case 'recover': {
        // Show menubar via callback (MW-5)
        const cb = getMenuDataCallback(windowKey);
        cb?.onMenubarVisible?.(true);
        await win?.recover();
        break;
      }
      case 'quit':
        this.exitFn(0);
        break;
      case 'hideOthers':
      case 'showAll':
        break;
      case 'about':
        this.showAboutFn?.(aboutMetadata ?? {} as AboutMetadataData);
        break;
      case 'restore':
        break;
    }
  }
}

export class MenuManager {
  private executor: PredefinedActionExecutor;
  private emitMenuEventFn: (menuId: string, windowId?: string) => void;
  private currentWindowId: string = "main";
  private currentWindowIdNumeric: number = 0;

  constructor(executor: PredefinedActionExecutor, emitMenuEventFn: (menuId: string, windowId?: string) => void) {
    this.executor = executor;
    this.emitMenuEventFn = emitMenuEventFn;
  }

  popupFromJson(jsonData: string, x?: number, y?: number, windowId?: string): void {
    try {
      const wid = windowId ?? "main";
      this.currentWindowId = wid;
      this.currentWindowIdNumeric = wid === "main" ? 0 : Number(wid);

      // Use callback to push data to the correct MenuBarComponent instance (MW-5)
      const cb = getMenuDataCallback(wid);
      if (cb) {
        cb.onMenuPopup?.(jsonData, x ?? 0, y ?? 0);
      } else {
        console.error(`[Menu] No callback registered for window "${wid}"`);
      }
    } catch (e) {
      console.error('[Menu] Failed to popup menu:', e);
    }
  }

  handleItemClick(item: MenuItemData): void {
    if (item.type === 'predefined' && item.predefinedType) {
      this.executor.execute(item.predefinedType, item.aboutMetadata, this.currentWindowIdNumeric);
    } else {
      this.emitMenuEventFn(item.id, this.currentWindowId);
    }
  }
}
