import { authentication } from '@kit.AccountKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AccountInfo } from '../ability/type';

const DOMAIN: number = 0x1999;
const TAG = 'account.ets';

/**
 * Safe error logging for the account bridge.
 *
 * account.ets is reached from Rust via NAPI `func.call`, a reentrant context
 * where `hilog` may throw "Argc mismatch" (ohos-constraints 2.3). The catch
 * blocks here run in async Promise-rejection callbacks (not the reentrant
 * path), so hilog is generally usable — but we wrap it in try/catch and fall
 * back to `console` so the catch itself never throws and masks the original
 * error (same pattern as ArkHelper.safeLogError).
 */
function logError(op: string, err: ESObject): void {
  const e = err as BusinessError;
  const msg = (e && e.code !== undefined && e.message !== undefined)
    ? `${e.code}:${e.message}`
    : String(err);
  try {
    hilog.error(DOMAIN, TAG, '%{public}s failed: %{public}s', op, msg);
  } catch (_e) {
    console.error(`[${TAG}] ${op} failed: ${msg}`);
  }
}

// Pseudo error code for the CSRF state mismatch check (not covered by Account
// Kit's BusinessError). Embedded in the thrown Error's message as "<code>:<message>"
// so Rust can propagate it; the plugin layer parses the code prefix (design D5).
const CODE_STATE_MISMATCH = 1001502002;

/**
 * Huawei Account one-tap login via Account Kit.
 *
 * Invoked from Rust through the ArkHelper bridge (`accountLogin` /
 * `accountSilentLogin` / `accountLogout` TSFNs). The synchronous entry path
 * (request construction) runs in a NAPI-reentrant context, so logging uses
 * `logError` (hilog via try/catch with `console` fallback) per the
 * safeLogError pattern (ohos-constraints 2.3 / C5).
 *
 * ArkTS strictness notes (design D5 update):
 * - `throw` only accepts Error objects (arkts-limited-throw), so errors are
 *   thrown as `new Error("<code>:<message>")` rather than bare strings.
 * - `any`/`unknown` are forbidden (arkts-no-any-unknown); credential fields are
 *   accessed via the typed `LoginWithHuaweiIDCredential` (casing verified by
 *   hvigor compile: openID / unionID with capital "ID").
 *
 * canIUse gate removed (p3 device-verify, 2026-07-30): `canIUse('SystemCapability
 * .Account.OAuth')` returned false on the test device (HarmonyOS PC) despite
 * Account Kit being usable, so the pre-check blocked all login. Per p1 design
 * Open Questions fallback, Account Kit is now called directly; if the device
 * truly lacks the capability, Account Kit surfaces a real BusinessError which
 * propagated to the plugin (no crash).
 */

/** Build the "<code>:<message>" message string embedded in thrown Errors. */
function accountError(code: number, message: string): string {
  return `${code}:${message}`;
}

/**
 * Normalize any caught value into an Error whose message is "<code>:<message>".
 * - Account Kit `BusinessError` → `new Error("${code}:${message}")`
 * - Error already thrown by the state check (message is already "<code>:<message>")
 *   → rethrown as-is
 */
function normalizeError(err: ESObject): Error {
  const e = err as BusinessError;
  if (e && e.code !== undefined && e.message !== undefined) {
    return new Error(`${e.code}:${e.message}`);
  }
  if (err instanceof Error) {
    return err as Error;
  }
  return new Error(String(err));
}

/**
 * Shared login flow. `forceLogin=true` → interactive UI; `false` → silent.
 *
 * A `UIAbilityContext` is required: `AuthenticationController(context)` needs
 * it to host the one-tap login UI when forceLogin=true and the user is not
 * already logged in/authorized (device-verified 2026-08-03: the no-arg
 * constructor throws `Parameter error. Incorrect context parameter type` in
 * that case). When the account is already logged in & authorized, Account Kit
 * returns the credential directly without showing the UI.
 *
 * Passed from ArkHelper via `getUIAbilityContext()`.
 */
async function loginWithHuaweiID(forceLogin: boolean, context: common.UIAbilityContext): Promise<AccountInfo> {
  try {
    const request = new authentication.HuaweiIDProvider().createLoginWithHuaweiIDRequest();
    request.forceLogin = forceLogin;
    request.state = util.generateRandomUUID();

    const controller = new authentication.AuthenticationController(context);
    const response = await controller.executeRequest(request) as authentication.LoginWithHuaweiIDResponse;

    // CSRF state check (best-effort).
    if (response.state && request.state !== response.state) {
      throw new Error(accountError(CODE_STATE_MISMATCH, 'state mismatch (possible CSRF)'));
    }

    // Map LoginWithHuaweiIDCredential to canonical AccountInfo (camelCase keys
    // read by Rust parse_account_info). Field casing verified by hvigor compile
    // (design D4): the credential only carries openID / unionID / authorizationCode
    // (+ idToken). Profile fields (displayName / avatarUri), uid, and accessToken
    // are NOT returned by the login flow — see design D9 (profile requires a
    // separate createAuthorizationWithHuaweiIDRequest with scopes=['profile']).
    const credential = response.data;
    return {
      uid: '',
      openId: credential?.openID ?? '',
      unionId: credential?.unionID ?? '',
      displayName: '',
      avatarUri: '',
      authorizationCode: credential?.authorizationCode ?? '',
      accessToken: null,
    } as AccountInfo;
  } catch (err) {
    logError('loginWithHuaweiID', err);
    throw normalizeError(err);
  }
}

/** Interactive login — forces the Huawei account login UI. */
export const login = async (context: common.UIAbilityContext): Promise<AccountInfo> => {
  return await loginWithHuaweiID(true, context);
};

/** Silent login — no UI; succeeds only when already logged in & authorized. */
export const silentLogin = async (context: common.UIAbilityContext): Promise<AccountInfo> => {
  return await loginWithHuaweiID(false, context);
};

/**
 * Logout — cancels the app's Huawei account authorization on this device.
 * Account Kit has no `signOut`/`createSignOutRequest`; `createCancelAuthorizationRequest`
 * is the official "sign out" equivalent (p1 design D8).
 */
export const logout = async (): Promise<void> => {
  try {
    const request = new authentication.HuaweiIDProvider().createCancelAuthorizationRequest();
    const controller = new authentication.AuthenticationController();
    await controller.executeRequest(request);
  } catch (err) {
    logError('logout', err);
    throw normalizeError(err);
  }
};
