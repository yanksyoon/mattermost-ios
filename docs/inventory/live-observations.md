# Live-observation captures (T25) — hostnames redacted

REA 6.7.0 (`rea-agents`, MIT) Playwright browser scenarios, launched headless Chrome
(Chromium 156) from local macOS against a live public Mattermost server (v12.1.0 enterprise,
observed 2026-10-24). Raw evidence JSONs (ev_* with full capture records) stay in the T25
workspace — this file is the sanitized, committable summary. `{server}` replaces the observed
hostname; no tokens were captured (unauthenticated pages).

Scenarios and what they confirmed:

1. `{server}/login` (scenario: goto, wait 6 s, capture network/console/page-errors/downloads +
   url/dom/storage/history/screenshot; 288 network/console events retained).
   Boot API calls made by the login screen:
   - GET `{server}/api/v4/config/client?format=old`
   - GET `{server}/api/v4/license/client`
   - GET `{server}/api/v4/plugins/webapp`
   - GET `{server}/api/v4/brand/image?t=0`
   - GET `{server}/api/v4/cloud/check-cws-connection`
   - GET `{server}/api/v4/properties/groups/access_control/system/fields?target_type=system`
   Plugin REST calls fired even on the unauthenticated page (evidence plugin surfaces are
   numerous and server-specific): `{server}/plugins/com.mattermost.google-meet/api/v1/config/status`,
   `{server}/plugins/com.github.manland.mattermost-plugin-gitlab/api/v1/connected?reminder=true`,
   `{server}/plugins/github/api/v1/connected?reminder=true`,
   `{server}/plugins/com.mattermost.plugin-todo/{config,list?reminder=…&list=…}`,
   `{server}/plugins/mattermost-ai/ai_bots`.
   DOM facts: form fields `input_loginId` (email-or-username) + `input_password-input`;
   links to `{server}/signup_user_complete`, `{server}/reset_password`, and
   `{server}/login/sso/saml` (Microsoft SAML); footer carries server version + FIPS password
   policy notice. Navigation history: bare host → `{server}/landing#/login` → `{server}/login`
   (the desktop-app interstitial redirect chain).
2. `{server}/signup_user_complete` — "Create Account": email + password fields
   (14–72 char policy), boot calls identical to login.
3. `{server}/reset_password` — "Password Reset": email-only form; boot calls identical.

Plugin bundles loaded by the login page (`/static/plugins/<id>/*bundle.js`): msteams-sync,
calls, metrics, badges, gcal, msteams-devsecops, jira, dataminr, connect4, ms-embedded
(10+ bundles on one page).

No account was created and no authenticated surface was observed on this host (see
docs/native-inventory.md §0 "honest gaps"). Endpoint and WS event names are verified
against the documented REST v4 / WS v4 contract and the Apache-2.0 reference client.
