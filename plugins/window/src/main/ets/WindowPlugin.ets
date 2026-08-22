import window from "@ohos.window";
import { deviceInfo } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import {
  BridgeCallContext,
  BridgePluginHookContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  AsyncPluginBase,
  WindowManager,
} from "@ohos-rs/ability";

const DOMAIN: number = 0x1999;
const TAG: string = "WindowPlugin";

const AVOID_AREA_REQUEST_TYPE = "ohos.window.AvoidAreaRequest";
const AVOID_AREA_RESPONSE_TYPE = "ohos.window.AvoidAreaResponse";
const CREATE_REQUEST_TYPE = "ohos.window.CreateRequest";
const CREATE_RESPONSE_TYPE = "ohos.window.CreateResponse";
const WINDOW_ID_REQUEST_TYPE = "ohos.window.WindowIdRequest";
const DECORATIONS_REQUEST_TYPE = "ohos.window.DecorationsRequest";
const FULLSCREEN_REQUEST_TYPE = "ohos.window.FullscreenRequest";
const COLOR_REQUEST_TYPE = "ohos.window.ColorRequest";
const BLUR_REQUEST_TYPE = "ohos.window.BlurRequest";
const MOVE_REQUEST_TYPE = "ohos.window.MoveRequest";
const RESIZE_REQUEST_TYPE = "ohos.window.ResizeRequest";
const FOCUSABLE_REQUEST_TYPE = "ohos.window.FocusableRequest";
const TOUCHABLE_REQUEST_TYPE = "ohos.window.TouchableRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.window.Acknowledgement";
const STATE_RESPONSE_TYPE = "ohos.window.StateResponse";
const MAX_SAFE_INTEGER: number = 9007199254740991;
const MAX_ARGB_COLOR: number = 0xffffffff;

function isSafeInteger(value: number): boolean {
  return Number.isInteger(value) && Math.abs(value) <= MAX_SAFE_INTEGER;
}

function isWindowId(value: number): boolean {
  return isSafeInteger(value) && value >= 0;
}

interface AvoidAreaRequest {
  areaType: number;
}

interface WindowCreateRequest {
  name: string;
  width: number;
  height: number;
  x: number;
  y: number;
  decorations: boolean;
  transparent: boolean;
  backgroundColor?: number | null;
}

interface WindowIdRequest {
  windowId: number;
}

interface WindowDecorationsRequest {
  windowId: number;
  decorations: boolean;
}

interface WindowFullscreenRequest {
  windowId: number;
  on: boolean;
}

interface WindowColorRequest {
  windowId: number;
  color: number;
}

interface WindowBlurRequest {
  windowId: number;
  radius: number;
}

interface WindowMoveRequest {
  windowId: number;
  x: number;
  y: number;
}

interface WindowResizeRequest {
  windowId: number;
  width: number;
  height: number;
}

interface WindowFocusableRequest {
  windowId: number;
  focusable: boolean;
}

interface WindowTouchableRequest {
  windowId: number;
  touchable: boolean;
}

class AvoidAreaRectResponse {
  readonly top: number;
  readonly left: number;
  readonly width: number;
  readonly height: number;

  constructor(rect: window.Rect) {
    this.top = rect.top;
    this.left = rect.left;
    this.width = rect.width;
    this.height = rect.height;
  }
}

class AvoidAreaValueResponse {
  readonly visible: boolean;
  readonly leftRect: AvoidAreaRectResponse;
  readonly topRect: AvoidAreaRectResponse;
  readonly rightRect: AvoidAreaRectResponse;
  readonly bottomRect: AvoidAreaRectResponse;

  constructor(area: window.AvoidArea) {
    this.visible = area.visible;
    this.leftRect = new AvoidAreaRectResponse(area.leftRect);
    this.topRect = new AvoidAreaRectResponse(area.topRect);
    this.rightRect = new AvoidAreaRectResponse(area.rightRect);
    this.bottomRect = new AvoidAreaRectResponse(area.bottomRect);
  }
}

class AvoidAreaResponse {
  readonly area: AvoidAreaValueResponse;

  constructor(area: window.AvoidArea) {
    this.area = new AvoidAreaValueResponse(area);
  }
}

class WindowCreateResponse {
  readonly windowId: number;

  constructor(windowId: number) {
    this.windowId = windowId;
  }
}

class WindowAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class WindowStateResponse {
  readonly value: boolean;

  constructor(value: boolean) {
    this.value = value;
  }
}

function parseAvoidAreaRequest(payload: BridgeTypedValue): AvoidAreaRequest {
  if (payload.typeName !== AVOID_AREA_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.get-avoid-area requires bridge type ${AVOID_AREA_REQUEST_TYPE}`);
  }
  const request = payload.value as AvoidAreaRequest;
  if (!Number.isInteger(request?.areaType)) {
    throw new Error("get-avoid-area.areaType must be an integer");
  }
  return request;
}

function parseCreateRequest(payload: BridgeTypedValue): WindowCreateRequest {
  if (payload.typeName !== CREATE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.create-os-window requires bridge type ${CREATE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowCreateRequest;
  if (!request.name?.trim()) {
    throw new Error("create-os-window.name must not be empty");
  }
  if (
    !isSafeInteger(request.width) ||
    !isSafeInteger(request.height) ||
    request.width <= 0 ||
    request.height <= 0
  ) {
    throw new Error("create-os-window.width and height must be positive");
  }
  if (
    !isSafeInteger(request.x) ||
    !isSafeInteger(request.y) ||
    typeof request.decorations !== "boolean" ||
    typeof request.transparent !== "boolean"
  ) {
    throw new Error("create-os-window position and appearance fields are invalid");
  }
  if (
    request.backgroundColor !== undefined &&
    request.backgroundColor !== null &&
    (!Number.isInteger(request.backgroundColor) ||
      request.backgroundColor < 0 ||
      request.backgroundColor > MAX_ARGB_COLOR)
  ) {
    throw new Error("create-os-window.backgroundColor must be an integer in 0xAARRGGBB format");
  }
  return request;
}

function parseWindowIdRequest(payload: BridgeTypedValue): WindowIdRequest {
  if (payload.typeName !== WINDOW_ID_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window requires bridge type ${WINDOW_ID_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowIdRequest;
  if (!isWindowId(request?.windowId)) {
    throw new Error("windowId must be a non-negative integer");
  }
  return request;
}

function parseDecorationsRequest(payload: BridgeTypedValue): WindowDecorationsRequest {
  if (payload.typeName !== DECORATIONS_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-decorations requires bridge type ${DECORATIONS_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowDecorationsRequest;
  if (!isWindowId(request?.windowId) || typeof request.decorations !== "boolean") {
    throw new Error("set-decorations requires a valid windowId and boolean decorations");
  }
  return request;
}

function parseFullscreenRequest(payload: BridgeTypedValue): WindowFullscreenRequest {
  if (payload.typeName !== FULLSCREEN_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-fullscreen requires bridge type ${FULLSCREEN_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowFullscreenRequest;
  if (!isWindowId(request?.windowId) || typeof request.on !== "boolean") {
    throw new Error("set-fullscreen requires a valid windowId and boolean on");
  }
  return request;
}

function parseColorRequest(payload: BridgeTypedValue): WindowColorRequest {
  if (payload.typeName !== COLOR_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-background-color requires bridge type ${COLOR_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowColorRequest;
  if (
    !isWindowId(request?.windowId) ||
    !Number.isInteger(request.color) ||
    request.color < 0 ||
    request.color > MAX_ARGB_COLOR
  ) {
    throw new Error("set-background-color requires a valid windowId and integer color");
  }
  return request;
}

function parseBlurRequest(payload: BridgeTypedValue): WindowBlurRequest {
  if (payload.typeName !== BLUR_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-blur requires bridge type ${BLUR_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowBlurRequest;
  if (
    !isWindowId(request?.windowId) ||
    typeof request.radius !== "number" ||
    !Number.isFinite(request.radius) ||
    request.radius < 0
  ) {
    throw new Error("set-blur.radius must be a non-negative finite number");
  }
  return request;
}

function parseMoveRequest(payload: BridgeTypedValue): WindowMoveRequest {
  if (payload.typeName !== MOVE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.move-to requires bridge type ${MOVE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowMoveRequest;
  if (!isWindowId(request?.windowId) || !isSafeInteger(request.x) || !isSafeInteger(request.y)) {
    throw new Error("move-to requires a valid windowId and finite coordinates");
  }
  return request;
}

function parseResizeRequest(payload: BridgeTypedValue): WindowResizeRequest {
  if (payload.typeName !== RESIZE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.resize requires bridge type ${RESIZE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowResizeRequest;
  if (
    !isWindowId(request?.windowId) ||
    !isSafeInteger(request.width) ||
    !isSafeInteger(request.height) ||
    request.width <= 0 ||
    request.height <= 0
  ) {
    throw new Error("resize.width and height must be positive");
  }
  return request;
}

function parseFocusableRequest(payload: BridgeTypedValue): WindowFocusableRequest {
  if (payload.typeName !== FOCUSABLE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-focusable requires bridge type ${FOCUSABLE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowFocusableRequest;
  if (!isWindowId(request?.windowId) || typeof request.focusable !== "boolean") {
    throw new Error("set-focusable.focusable must be a boolean");
  }
  return request;
}

function parseTouchableRequest(payload: BridgeTypedValue): WindowTouchableRequest {
  if (payload.typeName !== TOUCHABLE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-touchable requires bridge type ${TOUCHABLE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowTouchableRequest;
  if (!isWindowId(request?.windowId) || typeof request.touchable !== "boolean") {
    throw new Error("set-touchable.touchable must be a boolean");
  }
  return request;
}

/** One host-scoped implementation. Repeated calls are isolated by the platform window id. */
export class WindowPlugin extends AsyncPluginBase {
  readonly id = "ohos.window";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];
  private readonly windows: Map<number, window.Window> = new Map();

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (action === "get-avoid-area") {
      const request = parseAvoidAreaRequest(payload);
      try {
        const areaType = request.areaType as window.AvoidAreaType;
        const response = new AvoidAreaResponse(context.getWindow().getWindowAvoidArea(areaType));
        return { typeName: AVOID_AREA_RESPONSE_TYPE, value: response };
      } catch (error) {
        throw new Error(`Unable to get window avoid area: ${String(error)}`);
      }
    }

    if (action === "create-os-window") {
      const request = parseCreateRequest(payload);
      let created: window.Window | undefined;
      try {
        created = await context.getWindowStage().createSubWindow(request.name.trim());
        this.assertCallActive(context);
        await created.moveWindowTo(request.x, request.y);
        await created.resize(request.width, request.height);
        created.setWindowDecorVisible(request.decorations);
        const backgroundColor = request.transparent
          ? "#00000000"
          : this.colorString(request.backgroundColor ?? 0xffffffff);
        created.setWindowBackgroundColor(backgroundColor);
        // Float sub-windows also have a window container layer. Without making
        // it transparent, an opaque container sits between the window background
        // and ArkUI content — blocking backgroundBlurStyle from sampling through
        // the transparent window (vibrancy/frosted glass effect invisible).
        if (request.transparent && deviceInfo.sdkApiVersion >= 20) {
          try {
            created.setWindowContainerColor('#00000000', '#00000000');
          } catch (containerErr: any) {
            if (containerErr.code !== 801) {
              // 801 = API not supported; other errors logged but non-fatal
            }
          }
        }
        await created.showWindow();
        this.assertCallActive(context);
        const windowId = created.getWindowProperties().id;
        if (!isWindowId(windowId)) {
          throw new Error(`createSubWindow returned invalid window id '${windowId}'`);
        }
        const replaced = this.windows.get(windowId);
        if (replaced !== undefined && replaced !== created) {
          await replaced.destroyWindow();
        }
        this.windows.set(windowId, created);
        return { typeName: CREATE_RESPONSE_TYPE, value: new WindowCreateResponse(windowId) };
      } catch (error) {
        if (created !== undefined) {
          try {
            await created.destroyWindow();
          } catch {}
        }
        throw new Error(`createSubWindow failed: ${String(error)}`);
      }
    }

    if (action === "set-decorations") {
      const request = parseDecorationsRequest(payload);
      const win = this.requireWindow(request.windowId, context);
      try {
        win.setWindowDecorVisible(request.decorations);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`set-decorations failed: ${String(error)}`);
      }
    }

    if (action === "set-fullscreen") {
      const request = parseFullscreenRequest(payload);
      const win = this.requireWindow(request.windowId, context);
      try {
        // Immersive fullscreen: expand layout into system-bar regions and hide
        // both bars. `on=false` reverses — restore layout and re-show bars.
        await win.setWindowLayoutFullScreen(request.on);
        await win.setWindowSystemBarEnable(request.on ? [] : ["status", "navigation"]);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`set-fullscreen failed: ${String(error)}`);
      }
    }

    if (action === "set-background-color") {
      const request = parseColorRequest(payload);
      const win = this.requireWindow(request.windowId, context);
      try {
        win.setWindowBackgroundColor(this.colorString(request.color));
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`setWindowBackgroundColor failed: ${String(error)}`);
      }
    }

    if (action === "set-blur") {
      const request = parseBlurRequest(payload);
      hilog.info(DOMAIN, TAG,
        'set-blur: ENTER windowId=%{public}d radius=%{public}f',
        Number(request.windowId), request.radius);
      // Use WindowManager.applyWindowBlur (backdropBlur on WebView container)
      // instead of setWindowShadowRadius (window shadow — wrong API for vibrancy)
      WindowManager.getInstance().applyWindowBlur(request.windowId, request.radius);
      hilog.info(DOMAIN, TAG, 'set-blur: applyWindowBlur returned, ack=true');
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
    }

    if (action === "focus") {
      const request = parseWindowIdRequest(payload);
      const win = this.requireWindow(request.windowId, context);
      try {
        const dynamic: ESObject = this.dynamic(win);
        if (typeof dynamic.raiseToAppTop !== "function") {
          throw new Error("raiseToAppTop is unavailable on this API level");
        }
        await (dynamic.raiseToAppTop() as Promise<void>);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`focus failed: ${String(error)}`);
      }
    }

    if (action === "set-focusable") {
      const request = parseFocusableRequest(payload);
      const win = this.requireWindow(request.windowId, context);
      try {
        await win.setFocusable(request.focusable);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`setFocusable failed: ${String(error)}`);
      }
    }

    if (action === "set-touchable") {
      const request = parseTouchableRequest(payload);
      const win = this.requireWindow(request.windowId, context);
      try {
        await win.setWindowTouchable(request.touchable);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`set-touchable failed: ${String(error)}`);
      }
    }

    if (action === "move-to") {
      const request = parseMoveRequest(payload);
      const win = this.requireWindow(request.windowId, context);
      try {
        await win.moveWindowTo(request.x, request.y);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`moveWindowTo failed: ${String(error)}`);
      }
    }

    if (action === "resize") {
      const request = parseResizeRequest(payload);
      const win = this.requireWindow(request.windowId, context);
      try {
        await win.resize(request.width, request.height);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`resize failed: ${String(error)}`);
      }
    }

    if (action === "minimize") {
      return await this.windowCommand("minimize", payload, context);
    }
    if (action === "maximize") {
      return await this.windowCommand("maximize", payload, context);
    }
    if (action === "restore") {
      return await this.windowCommand("restore", payload, context);
    }
    if (action === "recover") {
      return await this.windowCommand("recover", payload, context);
    }
    if (action === "show") {
      return await this.windowCommand("show", payload, context);
    }
    if (action === "destroy-window") {
      return await this.windowCommand("destroy-window", payload, context);
    }
    if (action === "is-maximized") {
      return this.windowState("is-maximized", payload, context);
    }
    if (action === "is-minimized") {
      return this.windowState("is-minimized", payload, context);
    }

    throw new Error(`Unsupported ohos.window action '${action}'`);
  }

  private async windowCommand(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    const request = parseWindowIdRequest(payload);
    const win = this.requireWindow(request.windowId, context);
    try {
      const dynamic: ESObject = this.dynamic(win);
      if (action === "minimize") {
        await (dynamic.minimize() as Promise<void>);
      } else if (action === "maximize") {
        // Use FOLLOW_APP_IMMERSIVE_SETTING (not the default ENTER_IMMERSIVE) to
        // preserve the existing fullscreen layout mode. ENTER_IMMERSIVE causes a
        // layout gap (white bar at bottom) after recover().
        await win.maximize(window.MaximizePresentation.FOLLOW_APP_IMMERSIVE_SETTING);
      } else if (action === "restore") {
        await (dynamic.restore() as Promise<void>);
      } else if (action === "recover") {
        await (dynamic.recover() as Promise<void>);
        // NOTE: Do NOT call showWindow() after recover() — recover() already makes
        // the window visible, and showWindow() resets the window position to centered
        // state, causing the window to jump to the center of the screen.
      } else if (action === "show") {
        await win.showWindow();
      } else if (action === "destroy-window") {
        // id 0 is the host Ability's own main window — it cannot be destroyed by the
        // plugin (it is owned by the Ability lifecycle, not create-os-window). Only
        // tear down entries the plugin itself created.
        if (request.windowId === 0) {
          throw new Error("Cannot destroy the main Ability window (id 0)");
        }
        await win.destroyWindow();
        this.windows.delete(request.windowId);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
    } catch (error) {
      throw new Error(`${action} failed: ${String(error)}`);
    }
  }

  private windowState(action: string, payload: BridgeTypedValue, context: BridgeCallContext): BridgeTypedValue {
    const request = parseWindowIdRequest(payload);
    const win = this.requireWindow(request.windowId, context);
    try {
      const status = win.getWindowStatus();
      const value: boolean =
        action === "is-maximized"
          ? status === window.WindowStatusType.MAXIMIZE
          : status === window.WindowStatusType.MINIMIZE;
      return { typeName: STATE_RESPONSE_TYPE, value: new WindowStateResponse(value) };
    } catch (error) {
      throw new Error(`${action} failed: ${String(error)}`);
    }
  }

  private requireWindow(windowId: number, context: BridgeCallContext): window.Window {
    // Plugin-created sub-windows live in the `windows` Map (populated by create-os-window).
    // The main UIAbility window (logical id 0) and Float sub-windows created via the legacy
    // core `create_os_window` path are NOT in this Map — they live in the process-wide
    // WindowManager registry. p1-ohos-window-ops migrated window *operations* to this plugin
    // but left window *creation* on the old path, so the two registries never synced.
    // Resolve the gap by falling back to WindowManager (which knows about main + Float windows)
    // when the plugin Map misses. For id=0 prefer context.getWindow() (the host component's own
    // window) — fastest, matches the get-avoid-area path and avoids assuming which host received
    // the call.
    let win = this.windows.get(windowId);
    if (win === undefined) {
      if (windowId === 0) {
        try {
          win = context.getWindow();
        } catch (error) {
          // context.getWindow() may fail on a non-main host; fall through to WindowManager.
        }
      }
      if (win === undefined) {
        const fallback = WindowManager.getInstance().getWindow(windowId);
        if (fallback === undefined) {
          throw new Error(`Unknown OS sub-window '${windowId}' for this plugin instance`);
        }
        win = fallback;
      }
    }
    return win;
  }

  private assertCallActive(context: BridgeCallContext): void {
    if (!context.isActive()) {
      throw new Error("Window bridge call is no longer active");
    }
  }

  private colorString(color: number): string {
    return `#${(color >>> 0).toString(16).padStart(8, "0")}`;
  }

  override async onDispose(_context: BridgePluginHookContext): Promise<void> {
    const windows = Array.from(this.windows.values());
    this.windows.clear();
    await Promise.all(
      windows.map(async (win: window.Window): Promise<void> => {
        try {
          await win.destroyWindow();
        } catch {}
      }),
    );
  }

  private dynamic(win: window.Window): ESObject {
    return win as ESObject;
  }
}
