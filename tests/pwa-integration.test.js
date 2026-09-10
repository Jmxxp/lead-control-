"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");
const test = require("node:test");

const root = resolve(__dirname, "..");
const indexSource = readFileSync(resolve(root, "index.html"), "utf8");
const appSource = readFileSync(resolve(root, "app.js"), "utf8");
const stylesSource = readFileSync(resolve(root, "styles.css"), "utf8");
const mobileSource = readFileSync(resolve(root, "mobile.css"), "utf8");
const supportSource = readFileSync(resolve(root, "support-assistant.css"), "utf8");
const manifest = JSON.parse(readFileSync(resolve(root, "manifest.webmanifest"), "utf8"));
const workflowSource = readFileSync(resolve(root, ".github/workflows/pages.yml"), "utf8");

test("HTML carrega cliente Push antes do app e expõe controles acessíveis", () => {
  const pushScriptIndex = indexSource.search(/<script[^>]+src="pwa-notifications\.js(?:\?[^\"]*)?"/);
  const appScriptIndex = indexSource.search(/<script[^>]+src="app\.js(?:\?[^\"]*)?"/);

  assert.ok(pushScriptIndex >= 0, "pwa-notifications.js deve ser carregado no HTML");
  assert.ok(appScriptIndex > pushScriptIndex, "o cliente Push deve existir antes de app.js executar");
  assert.match(indexSource, /id="pushNotificationButton"[^>]+aria-controls="pushNotificationModal"/);
  assert.match(indexSource, /id="pushNotificationModal"[^>]*hidden/);
  assert.match(indexSource, /role="dialog"[^>]+aria-modal="true"/);
  assert.match(indexSource, /id="dailyReportSettingsList"[^>]+aria-live="polite"/);
});

test("manifesto instala o app no mesmo escopo usado pelo Service Worker", () => {
  assert.equal(manifest.id, "./");
  assert.equal(manifest.start_url, "./");
  assert.equal(manifest.scope, "./");
  assert.equal(manifest.display, "standalone");
  assert.equal(manifest.lang, "pt-BR");
  assert.ok(manifest.icons.some((icon) => icon.sizes === "192x192"));
  assert.ok(manifest.icons.some((icon) => icon.sizes === "512x512" && icon.purpose === "maskable"));
});

test("publicação no GitHub Pages inclui cliente Push e Service Worker na raiz", () => {
  assert.match(workflowSource, /^\s+pwa-notifications\.js \\/m);
  assert.match(workflowSource, /^\s+service-worker\.js \\/m);
  assert.match(workflowSource, /^\s+manifest\.webmanifest \\/m);
});

test("app integra os cinco RPCs autenticados e salva agenda por loja e agência", () => {
  [
    "lc_get_push_public_key_v1",
    "lc_register_push_subscription_v1",
    "lc_unregister_push_subscription_v1",
    "lc_get_daily_report_settings_v1",
    "lc_save_daily_report_setting_v1",
  ].forEach((rpcName) => assert.match(appSource, new RegExp(`"${rpcName}"`)));
  assert.match(appSource, /p_subscription:\s*\{\s*\.\.\.subscription,\s*device\s*\}/);
  assert.match(appSource, /p_store_id:\s*setting\.storeId/);
  assert.match(appSource, /p_agency_user_id:\s*setting\.agencyUserId/);
  assert.match(appSource, /p_report_time:\s*`\$\{reportTime\}:00`/);
  assert.match(appSource, /const DEFAULT_DAILY_REPORT_TIME = "18:00"/);
});

test("modal Push fica acima dos painéis, prende o foco e preserva o estado no tema escuro", () => {
  assert.match(stylesSource, /\.pwa-notification-backdrop\s*\{[^}]*z-index:\s*90/s);
  assert.match(stylesSource, /\.pwa-notification-dialog\s*>\s*\.form-message\.success\s*\{[^}]*var\(--green\)/s);
  assert.match(stylesSource, /body\.is-dark\s+\.ghost-button\.pwa-notification-button\.is-subscribed/s);
  assert.match(appSource, /let pushNotificationReturnFocus = null/);
  assert.match(appSource, /function handlePushNotificationModalKeydown\(event\)/);
  assert.match(appSource, /pushNotificationModal\?\.addEventListener\("keydown", handlePushNotificationModalKeydown\)/);
});

test("topo móvel comporta todos os controles com alvos de toque de 44px", () => {
  assert.match(mobileSource, /grid-auto-rows:\s*44px/);
  assert.match(mobileSource, /> \.topbar-button\s*\{[^}]*width:\s*44px;[^}]*height:\s*44px/s);
  assert.match(supportSource, /grid-template-columns:\s*repeat\(6,\s*44px\)/);
  assert.doesNotMatch(supportSource, /topbar-button:not\(#supportAssistantToggle\)[^{]*\{[^}]*width:\s*28px/s);
});
