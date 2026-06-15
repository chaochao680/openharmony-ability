import { hilog } from '@kit.PerformanceAnalysisKit';
import webview from "@ohos.web.webview";
import { DOMAIN } from '../helper/constants';

export const getCookies = (url: string): string => {
  return webview.WebCookieManager.fetchCookieSync(url);
};

/**
 * Convert `#RRGGBBAA` format from wry to `#AARRGGBB` format accepted by OHOS.
 * Supports string, Color enum, number, and undefined inputs:
 * - Color enum: passed through as-is
 * - number (0xAARRGGBB): alpha=0 is converted to Color.Transparent (OHOS Web component requirement)
 * - undefined: returns undefined
 * - Only converts `#RRGGBBAA` format strings (e.g. `#FF000080`)
 */
export function convertRRGGBBAAtoAARRGGBB(color: string | Color | number | undefined): string | Color | number | undefined {
  if (color === undefined) return undefined;
  // OHOS Web component only respects transparency when using Color.Transparent,
  // not when using numeric 0x00XXXXXX. Convert alpha=0 numbers explicitly.
  if (typeof color === 'number') {
    const alpha = (color >>> 24) & 0xFF;
    if (alpha === 0) return Color.Transparent;
    return color;
  }
  if (typeof color !== 'string') return color;
  if (!color.startsWith('#') || color.length !== 9) return color;
  const rrggbb = color.substring(1, 7);
  const aa = color.substring(7, 9);
  return `#${aa}${rrggbb}`;
}

export interface JsWebviewStyle {
  x?: number | string;
  y?: number | string;
  backgroundColor?: string | Color | number;
  visible?: boolean;
}

export interface SnapshotData {
  rgba: Uint8Array;
  width: number;
  height: number;
}

export interface JsHelper {
  getCookies: (url: string) => string;
  getUrl: () => string;
  loadUrl: (url: string, header?: Record<string, string>) => void;
  loadHtml: (html: string) => void;
  zoom: (scale: number) => void;
  refresh: () => void;
  requestFocus: () => void;
  runJavaScript: (code: string, callback: (result?: string) => void) => void;
  setBackgroundColor: (color: number) => void;
  setVisible: (visible: boolean) => void;
  dispose: () => void;
  clearAllBrowsingData: () => void;
  webPageSnapshot: () => Promise<SnapshotData>;
}

/**
 * Lightweight proxy class: solves the problem of Rust receiving a null reference
 * when the window is not yet ready. Caches all operations initially and replays
 * them automatically once the real Controller is bound.
 */
export class ProxyJsHelper implements JsHelper {
  private realController: JsHelper | null = null;
  private pendingOperations: Array<() => void> = [];

  /**
   * Bind the real Controller and replay all cached operations
   */
  bindToRealController(real: JsHelper): void {
    hilog.info(DOMAIN, 'ProxyJsHelper', 'Binding real controller and replaying pending operations.');
    this.realController = real;
    const ops = this.pendingOperations;
    this.pendingOperations = [];
    ops.forEach(op => op());
    hilog.info(DOMAIN, 'ProxyJsHelper', `Replayed ${ops.length} operations.`);
  }

  // --- JsHelper interface implementation ---

  getCookies(url: string): string {
    return this.realController ? this.realController.getCookies(url) : '';
  }

  getUrl(): string {
    return this.realController ? this.realController.getUrl() : '';
  }

  loadUrl(url: string, header?: Record<string, string>): void {
    if (this.realController) {
      this.realController.loadUrl(url, header);
    } else {
      hilog.info(DOMAIN, 'ProxyJsHelper', 'Caching loadUrl: %{public}s', url);
      this.pendingOperations.push(() => this.realController!.loadUrl(url, header));
    }
  }

  loadHtml(html: string): void {
    if (this.realController) {
      this.realController.loadHtml(html);
    } else {
      hilog.info(DOMAIN, 'ProxyJsHelper', 'Caching loadHtml');
      this.pendingOperations.push(() => this.realController!.loadHtml(html));
    }
  }

  zoom(scale: number): void {
    if (this.realController) {
      this.realController.zoom(scale);
    } else {
      this.pendingOperations.push(() => this.realController!.zoom(scale));
    }
  }

  refresh(): void {
    if (this.realController) {
      this.realController.refresh();
    } else {
      this.pendingOperations.push(() => this.realController!.refresh());
    }
  }

  requestFocus(): void {
    if (this.realController) {
      this.realController.requestFocus();
    } else {
      this.pendingOperations.push(() => this.realController!.requestFocus());
    }
  }

  runJavaScript(code: string, callback: (result?: string) => void): void {
    if (this.realController) {
      this.realController.runJavaScript(code, callback);
    } else {
      hilog.info(DOMAIN, 'ProxyJsHelper', 'Caching runJavaScript');
      this.pendingOperations.push(() => this.realController!.runJavaScript(code, callback));
    }
  }

  setBackgroundColor(color: number): void {
    if (this.realController) {
      this.realController.setBackgroundColor(color);
    } else {
      this.pendingOperations.push(() => this.realController!.setBackgroundColor(color));
    }
  }

  setVisible(visible: boolean): void {
    if (this.realController) {
      this.realController.setVisible(visible);
    } else {
      this.pendingOperations.push(() => this.realController!.setVisible(visible));
    }
  }

  dispose(): void {
    if (this.realController) {
      this.realController.dispose();
    } else {
      this.pendingOperations.push(() => this.realController!.dispose());
    }
  }

  clearAllBrowsingData(): void {
    if (this.realController) {
      this.realController.clearAllBrowsingData();
    } else {
      this.pendingOperations.push(() => this.realController!.clearAllBrowsingData());
    }
  }

  webPageSnapshot(): Promise<SnapshotData> {
    if (this.realController) {
      return this.realController.webPageSnapshot();
    }
    return Promise.reject(new Error('WebviewController not bound yet'));
  }
}
