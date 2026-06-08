import { UIContext } from "@ohos.arkui.UIContext";
import web_webview from "@ohos.web.webview";
import { ComponentContent, NodeController, BuilderNode, FrameNode } from "@ohos.arkui.node";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { randomString } from "../helper";
import { OnDownloadStartResult } from "../ability/type";
import { getCookies, JsHelper, convertRRGGBBAAtoAARRGGBB } from "./Utils";
import { WebHeader } from "@kit.ArkUI";
import { router } from '@kit.ArkUI';
import { WindowManager } from '../window/WindowManager';

const DOMAIN: number = 0x1999;

export interface WebviewStyle {
  x?: number | string;
  y?: number | string;
  backgroundColor?: string | Color | number;
  visible?: boolean;
}

export interface WebviewInitData {
  webTag?: string;
  url: string;
  windowId?: number;
  style?: WebviewStyle;
  controller?: WebviewController;
  javascriptEnable?: boolean;
  devtools?: boolean;
  autoplay?: boolean;
  userAgent?: string;
  initializationScripts?: ScriptItem[];
  headers?: Record<string, string>;
  html?: string;
  transparent?: boolean;
  onDragAndDrop?: (event: string) => void;
  onDownloadStart?: (url: string, tempPath: string | undefined) => OnDownloadStartResult;
  onDownloadEnd?: (url: string, tempPath: string | undefined, success: boolean) => void;
  onNavigationRequest?: (url: string) => boolean;
  onTitleChange?: (title: string) => void;
  onPageBegin?: (url: string) => void;
  onPageEnd?: (url: string) => void;
}

interface WebviewNodeData extends WebviewInitData {
  controller: WebviewController;
  didInitialLoad?: boolean;
}

@Builder
function WebBuilder(data: WebviewNodeData) {
  // init with empty url and reload with loadUrl or loadData with onControllerAttach
  Web({
    src: "",
    controller: data.controller as web_webview.WebviewController,
    renderMode: data?.transparent ? RenderMode.SYNC_RENDER : RenderMode.ASYNC_RENDER
  })
    .width("100%")
    .height("100%")
    .position({
      x: data.style?.x ?? 0,
      y: data.style?.y ?? 0,
    })
    .backgroundColor(convertRRGGBBAAtoAARRGGBB(data?.style?.backgroundColor))
    .visibility(data?.style?.visible === false ? Visibility.Hidden : Visibility.Visible)
    .javaScriptAccess(data?.javascriptEnable)
    .domStorageAccess(true)
    .mediaPlayGestureAccess(
      typeof data?.autoplay === "boolean" && data.autoplay === true ? false : true,
    )
    .javaScriptOnDocumentStart(data?.initializationScripts)
    .onControllerAttached(() => {
      hilog.info(DOMAIN, 'DefaultWebview', 'onControllerAttached fired');
      const ctrl = data.controller;
      // Set up download delegate after controller is attached
      setupDownloadDelegate(data);
      // load url or html string
      if (data?.url) {
        const header: WebHeader[] = Object.keys(
          (data?.headers || {}) as Record<string, string>,
        ).reduce((t: WebHeader[], i) => {
          t.push({ headerKey: i, headerValue: data.headers![i] } as WebHeader);
          return t;
        }, []);
        ctrl.loadUrl(data.url, header);
      } else {
        ctrl.loadData(data!.html, "text/html", "UTF-8", " ", " ");
      }
    })
    .onErrorReceive((event) => {
      hilog.error(DOMAIN, 'DefaultWebview', 'Web onErrorReceive: %{public}s', JSON.stringify(event));
      if (event.error) {
        const ctrl = data.controller;
        const errorCode = event.error.getErrorCode();
        const errorInfo = event.error.getErrorInfo();
        hilog.error(DOMAIN, 'DefaultWebview', 'Frame load failed: %{public}d - %{public}s', errorCode, errorInfo);

        // Check current URL to determine if this is an iframe error
        const currentUrl = ctrl.getUrl();
        hilog.info(DOMAIN, 'DefaultWebview', 'Current URL when error: %{public}s', currentUrl);

        // If current URL is tauri://localhost, main page loaded successfully,
        // this error is from an iframe (like isolation://), ignore it
        if (currentUrl && currentUrl.startsWith('tauri://localhost')) {
          hilog.warn(DOMAIN, 'DefaultWebview', 'Main page loaded, ignoring iframe error');
          return;
        }

        const errorHtml = `
          <html>
            <body style="display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f5f5f5;font-family:sans-serif;">
              <div style="text-align:center;padding:20px;">
                <h2>Network Error</h2>
                <p>Failed to load the page. Please check your connection.</p>
                <p style="color:#666;font-size:12px;">Error: ${errorCode} - ${errorInfo}</p>
              </div>
            </body>
          </html>
        `;
        ctrl.loadData(errorHtml, 'text/html', 'UTF-8', ' ', ' ');
      }
    })
    .onLoadIntercept((event) => {
      const url = event.data.getRequestUrl();
      // OHOS: intercept close-window URL to destroy the parent window.
      // This is used by test windows that cannot attach JS event listeners
      // due to OHOS Web component initialization_script limitations.
      if (url && event.data.isMainFrame() && url.startsWith('http://close-window.invalid')) {
        hilog.info(DOMAIN, 'DefaultWebview', 'Intercepted close-window URL, destroying window %{public}d', data?.windowId ?? -1);
        if (data?.windowId !== undefined) {
          try {
            const wm = WindowManager.getInstance();
            const entry = wm.getWindow(data.windowId);
            if (entry) {
              entry.destroyWindow().then(() => {
                wm.removeWindow(data.windowId!);
                hilog.info(DOMAIN, 'DefaultWebview', 'Window %{public}d destroyed and cleaned up via close-window', data.windowId!);
              }).catch((e: Error) => {
                hilog.error(DOMAIN, 'DefaultWebview', 'Failed to destroy window: %{public}s', JSON.stringify(e));
              });
            }
          } catch (e) {
            hilog.error(DOMAIN, 'DefaultWebview', 'Failed to destroy window: %{public}s', JSON.stringify(e));
          }
        }
        return true; // block navigation
      }
      if (typeof data?.onNavigationRequest === "function") {
        hilog.info(DOMAIN, 'DefaultWebview', 'onLoadIntercept → onNavigationRequest called: %{public}s', url);
        // onLoadIntercept: true = block, false = allow
        // onNavigationRequest: true = allow, false = block
        // So we negate the return value
        const ret = data.onNavigationRequest(url);
        hilog.info(DOMAIN, 'DefaultWebview', 'onNavigationRequest result: %{public}s, onLoadIntercept returns: %{public}s', ret ? 'allow' : 'block', ret ? 'false(allow)' : 'true(block)');
        return !ret;
      }
      return false;
    })
    .onTitleReceive((e) => {
      if (typeof data?.onTitleChange === "function") {
        hilog.info(DOMAIN, 'DefaultWebview', 'onTitleReceive → onTitleChange called: %{public}s', e.title);
        data.onTitleChange(e.title);
      }
    })
    .onPageBegin((e) => {
      if (typeof data?.onPageBegin === "function") {
        data.onPageBegin(e.url);
      }
    })
    .onPageEnd((e) => {
      if (typeof data?.onPageEnd === "function") {
        data.onPageEnd(e.url);
      }
    });
}

@Builder
function EmbeddedWebBuilder(data: WebviewNodeData) {
  // The embedded path needs a bounded ArkTS root so hit testing stays clipped
  // to the host slot owned by native. A bare `Web` component can render in the
  // right place while still participating in input as an unbounded layer.
  Stack() {
    Web({
      src: "",
      controller: data.controller as web_webview.WebviewController,
      renderMode: data?.transparent ? RenderMode.SYNC_RENDER : RenderMode.ASYNC_RENDER
    })
      .width("100%")
      .height("100%")
      .backgroundColor(convertRRGGBBAAtoAARRGGBB(data?.style?.backgroundColor))
      .javaScriptAccess(data?.javascriptEnable)
      .domStorageAccess(true)
      .mediaPlayGestureAccess(
        typeof data?.autoplay === "boolean" && data.autoplay === true ? false : true,
      )
      .javaScriptOnDocumentStart(data?.initializationScripts)
      .onControllerAttached(() => {
        if (data.didInitialLoad === true) {
          return;
        }
        data.didInitialLoad = true;
        const ctrl = data.controller;
        // Set up download delegate after controller is attached
        setupDownloadDelegate(data);
        if (data?.url) {
          const header: WebHeader[] = Object.keys(
            (data?.headers || {}) as Record<string, string>,
          ).reduce((t: WebHeader[], i) => {
            t.push({ headerKey: i, headerValue: data.headers![i] } as WebHeader);
            return t;
          }, []);
          ctrl.loadUrl(data.url, header);
        } else {
          ctrl.loadData(data!.html, "text/html", "UTF-8", " ", " ");
        }
      })
      .onErrorReceive((event) => {
        hilog.error(DOMAIN, 'DefaultWebview', 'Embedded Web onErrorReceive: %{public}s', JSON.stringify(event));
        if (event.error) {
          const ctrl = data.controller;
          const errorCode = event.error.getErrorCode();
          const errorInfo = event.error.getErrorInfo();
          hilog.error(DOMAIN, 'DefaultWebview', 'Embedded Main frame load failed: %{public}d - %{public}s', errorCode, errorInfo);
          const errorHtml = `
            <html>
              <body style="display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f5f5f5;font-family:sans-serif;">
                <div style="text-align:center;padding:20px;">
                  <h2>Network Error</h2>
                  <p>Failed to load the page. Please check your connection.</p>
                  <p style="color:#666;font-size:12px;">Error: ${errorCode} - ${errorInfo}</p>
                </div>
              </body>
            </html>
          `;
          ctrl.loadData(errorHtml, 'text/html', 'UTF-8', ' ', ' ');
        }
      })
      .onLoadIntercept((event) => {
        if (typeof data?.onNavigationRequest === "function") {
          const url = event.data.getRequestUrl();
          // onLoadIntercept: true = block, false = allow
          // onNavigationRequest: true = allow, false = block
          const ret = data.onNavigationRequest(url);
          return !ret;
        }
        return false;
      })
      .onTitleReceive((e) => {
        if (typeof data?.onTitleChange === "function") {
          data.onTitleChange(e.title);
        }
      })
      .onPageBegin((e) => {
        if (typeof data?.onPageBegin === "function") {
          data.onPageBegin(e.url);
        }
      })
      .onPageEnd((e) => {
        if (typeof data?.onPageEnd === "function") {
          data.onPageEnd(e.url);
        }
      })
    }
  .width("100%")
  .height("100%")
  .backgroundColor(Color.Transparent)
  .clip(true)
  .visibility(data?.style?.visible === false ? Visibility.Hidden : Visibility.Visible)
  .hitTestBehavior(HitTestMode.Default);
}

const webViewWrap = wrapBuilder<[WebviewNodeData]>(WebBuilder);
const embeddedWebViewWrap = wrapBuilder<[WebviewNodeData]>(EmbeddedWebBuilder);

interface AddWebviewMethod {
  webTag: string;
  controller: JsHelper;
}

export interface EmbeddedWebviewHandle extends AddWebviewMethod {
  content: ComponentContent<WebviewNodeData>;
}

interface EmbeddedWebviewEntry {
  data: WebviewNodeData;
  content: ComponentContent<WebviewNodeData>;
}

function ensureWebviewNodeData(data: WebviewInitData): WebviewNodeData {
  if (!data.webTag) {
    data.webTag = randomString();
  }
  if (!data.controller) {
    data.controller = new web_webview.WebviewController(data.webTag) as WebviewController;
  }
  data.style = data.style || {};
  if (typeof data.javascriptEnable !== "boolean") {
    data.javascriptEnable = true;
  }
  const prepared = data as WebviewNodeData;
  prepared.didInitialLoad = prepared.didInitialLoad === true;

  if (prepared?.devtools) {
    web_webview.WebviewController.setWebDebuggingAccess(true);
  }

  return prepared;
}

function setupDownloadDelegate(data: WebviewNodeData) {
  if (typeof data?.onDownloadStart !== "function" && typeof data?.onDownloadEnd !== "function") {
    hilog.info(DOMAIN, 'DefaultWebview', 'setupDownloadDelegate: no download handlers registered');
    return;
  }

  hilog.info(DOMAIN, 'DefaultWebview', 'setupDownloadDelegate: registering download delegate');
  const download = new web_webview.WebDownloadDelegate();

  if (typeof data?.onDownloadStart === "function") {
    download.onBeforeDownload((e) => {
      const url = e.getUrl();
      const tempPath = e.getFullPath();
      hilog.info(DOMAIN, 'DefaultWebview', 'onBeforeDownload → onDownloadStart: %{public}s', url);
      const ret = data.onDownloadStart!(url, tempPath);

      if (ret.allow) {
        e.start(ret.tempPath || tempPath);
      } else {
        e.cancel();
      }
    });
  }

  if (typeof data?.onDownloadEnd === "function") {
    download.onDownloadFinish((e) => {
      const url = e.getUrl();
      const tempPath = e.getFullPath();
      hilog.info(DOMAIN, 'DefaultWebview', 'onDownloadFinish → onDownloadEnd: %{public}s, success=true', url);
      data.onDownloadEnd!(url, tempPath, true);
    });
    download.onDownloadFailed((e) => {
      const url = e.getUrl();
      hilog.info(DOMAIN, 'DefaultWebview', 'onDownloadFailed → onDownloadEnd: %{public}s, success=false', url);
      data.onDownloadEnd!(url, undefined, false);
    });
  }

  data.controller.setDownloadDelegate(download);
}

function buildJsHelper(controller: WebviewController): JsHelper {
  const getUrl = () => {
    return controller.getUrl();
  };
  const getCookiesHelper = (url: string) => {
    return getCookies(url) as string;
  };
  const loadUrl = (url: string, header?: Record<string, string>) => {
    const headers = Object.keys((header || {}) as Record<string, string>).reduce(
      (t, i) => {
        if (!!header![i]) {
          t.push({ headerKey: i, headerValue: header![i] });
        }
        return t;
      },
      [] as Array<WebHeader>,
    );
    controller.loadUrl(url, headers);
  };

  const loadHtml = (html: string) => {
    controller.loadData(html, "text/html", "UTF-8", " ", " ");
  };

  const zoom = (scale: number) => {
    controller.zoom(scale);
  };

  const refresh = () => {
    controller.refresh();
  };

  const requestFocus = () => {
    controller.requestFocus();
  };

  const clearAllBrowsingData = () => {
    web_webview.WebStorage.deleteAllData(true);
    web_webview.WebDataBase.deleteHttpAuthCredentials();
    controller.removeCache(true);
    controller.clearHistory();
  };

  const runJavaScript = (code: string, cb: (result?: string) => void) => {
    controller.runJavaScript(code).then((ret) => {
      cb(ret ?? undefined);
    }).catch((err) => {
      hilog.error(DOMAIN, 'DefaultWebview', 'runJavaScript ERR message=%{public}s code=%{public}s', String(err?.message || err), code.substring(0, 120));
      cb(undefined);
    });
  };

  return {
    getUrl,
    getCookies: getCookiesHelper,
    loadUrl,
    loadHtml,
    zoom,
    refresh,
    requestFocus,
    clearAllBrowsingData,
    runJavaScript,
    setBackgroundColor: (_color: number) => {},
    setVisible: (_visible: boolean) => {},
    dispose: () => {},
  } as JsHelper;
}

export class RustWebviewNodeController extends NodeController {
  private rootNode: FrameNode | null = null;
  private webviewEntries: Map<string, WebviewNodeData> = new Map();
  private webviewList: Map<string, BuilderNode<[WebviewNodeData]>> = new Map();
  private uiContext: UIContext | null = null;

  constructor(uiContext: UIContext) {
    super();
    this.uiContext = uiContext;
  }

  updateWebviewStyle(webTag: string, style: WebviewStyle) {
    const entry = this.webviewEntries.get(webTag);
    const node = this.webviewList.get(webTag);
    if (!entry || !node) {
      return;
    }

    entry.style = style;
    node.update(entry);
  }

  private buildData(controller: WebviewController) {
    return buildJsHelper(controller);
  }

  makeNode(uiContext: UIContext): FrameNode {
    if (this.rootNode === null) {
      this.rootNode = new FrameNode(uiContext);
    }
    return this.rootNode;
  }

  addWebview(data: WebviewInitData): AddWebviewMethod {
    const prepared = ensureWebviewNodeData(data);
    const webTag = prepared.webTag!;
    if (this.rootNode === null) {
      this.rootNode = new FrameNode(this.uiContext!);
    }

    const node = new BuilderNode<[WebviewNodeData]>(this.uiContext!);
    node.build(webViewWrap, prepared);

    const controller = this.buildData(prepared.controller);
    this.webviewEntries.set(webTag, prepared);
    this.webviewList.set(webTag, node);

    this.rootNode?.appendChild(node.getFrameNode());

    return {
      webTag,
      controller,
    };
  }

  removeWebview(webTag: string) {
    const node = this.webviewList.get(webTag);
    if (!node) {
      return;
    }

    this.webviewEntries.delete(webTag);
    this.webviewList.delete(webTag);

    this.rootNode?.removeChild(node.getFrameNode());
  }
}

export class EmbeddedWebviewManager {
  private uiContext: UIContext;
  private entries: Map<string, EmbeddedWebviewEntry> = new Map();

  constructor(uiContext: UIContext) {
    this.uiContext = uiContext;
  }

  createWebview(data: WebviewInitData): EmbeddedWebviewHandle {
    const prepared = ensureWebviewNodeData(data);
    const webTag = prepared.webTag!;

    const content = new ComponentContent<WebviewNodeData>(
      this.uiContext,
      embeddedWebViewWrap,
      prepared,
    );

    content.update(prepared);

    const controller = buildJsHelper(prepared.controller);
    this.entries.set(webTag, {
      data: prepared,
      content,
    });

    return {
      webTag,
      controller,
      content,
    };
  }

  updateWebviewStyle(webTag: string, style: WebviewStyle) {
    const entry = this.entries.get(webTag);
    if (!entry) {
      return;
    }

    entry.data.style = style;
    entry.content.update(entry.data);
  }

  removeWebview(webTag: string) {
    const entry = this.entries.get(webTag);
    if (!entry) {
      return;
    }

    this.entries.delete(webTag);
    entry.content.dispose();
  }
}

// extend WebviewController method
declare class WebviewController extends web_webview.WebviewController {
  getCookies: (url: string) => string;
  setBackgroundColor: (color: number) => void;
  setVisible: (visible: boolean) => void;
  dispose: () => void;
  clearAllBrowsingData: () => void;
}
