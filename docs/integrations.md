# Optional integrations

Everything below is off until the listed environment variables are set. No
service name, URL or credential is built in.

## OpenID Connect sign-in (`AUTH_MODE=external`)

With `AUTH_MODE=external` the app is an OpenID Connect relying party for any
standards-compliant provider. It is a confidential client using the authorization
code flow with PKCE (`S256`), `state`, `nonce` and the RFC 9207 `iss` check. The
protocol plumbing (discovery, the authorization and token requests, JWS
verification) is the [`openid_connect`](https://github.com/nov/openid_connect) gem
(MIT; with `rack-oauth2` and `json-jwt`, also MIT; released 2026-06, widely used).

| Variable | Meaning |
| --- | --- |
| `OIDC_ISSUER` | The issuer URL, exactly as published, e.g. `https://id.example.com`. Discovery is read from `<issuer>/.well-known/openid-configuration`. Required. |
| `OIDC_CLIENT_ID` | This app's client id. Required. |
| `OIDC_CLIENT_SECRET_FILE` | Path of a file holding the client secret. Required; the secret is never read from the environment. |
| `OIDC_REDIRECT_URI` | The registered redirect URI, byte-exact. Default: this app's `/auth/oidc/callback`. |
| `OIDC_POST_LOGOUT_REDIRECT_URI` | The registered post-logout URI. Default: this app's root. |
| `OIDC_SCOPES` | Default `openid email profile`. `offline_access` is never requested: there are no refresh tokens. |
| `OIDC_TOKEN_AUTH_METHOD` | `basic` (`client_secret_basic`, client id and secret URL-encoded before base64) or `post`. Default: basic, or post when the provider does not offer basic. |
| `OIDC_ID_TOKEN_ALGS` | Accepted signature algorithms, default `ES256 ES384 RS256 PS256`. `none` and HMAC algorithms are never accepted. |
| `OIDC_ALLOW_SIGNUP` | `false` refuses a person who has no user and no invitation. |
| `OIDC_SESSION_MAX_AGE_SECONDS` | Longest a sign-in lasts, default 43200 (12 hours). |
| `OIDC_MAX_ID_TOKEN_AGE_SECONDS` | Oldest an id_token may be on arrival, default 600. |
| `OIDC_STEP_UP_ACR`, `OIDC_STEP_UP_ACR_ORDER`, `OIDC_STEP_UP_ACTIONS` | Step-up, see below. |

Register `<app>/auth/oidc/callback` as the redirect URI, the post-logout URI, and
`<app>/auth/oidc/backchannel-logout` as the back-channel logout URI (with
`backchannel_logout_session_required`).

Routes: `GET /auth/oidc/start`, `GET /auth/oidc/callback`, `GET /auth/oidc/step_up`,
`DELETE /auth/oidc/logout`, `POST /auth/oidc/backchannel-logout`.

### The sign-in

1. `GET /auth/oidc/start` stores a fresh `state`, `nonce` and PKCE verifier (each at
   least 256 bits) in the encrypted browser session, never in a URL, and redirects to
   the authorization endpoint. A `return_to` path (or the page that asked for
   sign-in) is remembered; only a path on this app is ever followed.
2. The callback checks `state` (then deletes it), checks `iss` when present
   (RFC 9207; refused when absent and the provider says it always sends one), shows a
   provider `error` such as `access_denied` as "not signed in", and exchanges the
   code with the verifier.
3. The id_token must be signed with an allowed algorithm by a key in the provider's
   JWKS (`kid` selected; an unknown `kid` refetches the set at most 5 times a minute;
   a `jku` is never followed) and carry the right `iss`, `aud` (with `azp` when there
   are several), `exp`, `iat`, `nonce` and `sub`. **`email_verified` must be `true`.**
4. The person is linked (below), `reset_session` runs, and a row in the server-side
   session registry (`oidc_sessions`: provider `sid`, `auth_time`, `acr`, `amr`,
   expiry) is created. The browser holds only a random token. The registry is checked
   on every request; a revoked or expired row sends the person to sign in again.

### Who is who: the subject, not the email

A person is identified only by the provider's stable `(issuer, sub)`, stored on the
user (`sso_issuer`, `sso_subject`, unique together). A user bound to the pair is that
person whatever address the provider now reports; when it reports a new, free,
verified address the user follows it. For an unseen `sub`, a pending invitation for
the verified address joins the inviting account, once; otherwise a new account is
created (unless `OIDC_ALLOW_SIGNUP=false`). An address that already belongs to a user
is never handed to a different subject (a recycled or taken-over address): that
sign-in is refused with 409.

### Logout

- **Sign-out here** (`DELETE /auth/oidc/logout`): the registry row is revoked, the
  session is destroyed, and the browser is sent to the provider's
  `end_session_endpoint` with `id_token_hint`, `post_logout_redirect_uri`,
  `client_id` and `state`.
- **Back-channel logout** (`POST /auth/oidc/backchannel-logout`, form field
  `logout_token`): the token must be a `logout+jwt` with a valid signature, `iss`,
  `aud`, `exp`/`iat`, the back-channel `events` claim and no `nonce`. Its `jti` is
  accepted once, stored in the database table `oidc_logout_tokens` (shared by every
  process). Every active registry row with that `sid` (or, when only `sub` is named,
  that person) is revoked. Answers `200` with `Cache-Control: no-store`, or `400`.

### Step-up

Set `OIDC_STEP_UP_ACR` (the acr value to ask for), optionally `OIDC_STEP_UP_ACR_ORDER`
(comma list, lowest first, so a stronger result also counts) and
`OIDC_STEP_UP_ACTIONS` (comma list of `api_token`, `account_deletion`, `webhooks`,
`role_change`). For a listed action the person is sent back to the provider with
`acr_values=<OIDC_STEP_UP_ACR>`, `max_age=0` and a nonce that is an HMAC of the
action and the session. The result unlocks that one action once, only when the
`acr` is high enough, `auth_time` is not before the request, the nonce is the
action's, and the same person answered.

## Service JWT for the audit export

`GET /api/admin/audit_events` returns submission events to another service. It
accepts a bearer JWT verified against `SERVICE_JWT_JWKS_URL`, with the audience
`SERVICE_JWT_AUDIENCE` and the scope `SERVICE_JWT_AUDIT_SCOPE` (default
`audit.read`). Unconfigured, it answers 503.

The export is limited to one account. The token must carry that account's id in
the claim named by `SERVICE_JWT_ACCOUNT_CLAIM` (default `account_id`); a token
without it is refused with 403, and there is no token that reads every account.
An `account_id` query parameter may only repeat the token's account. Set
`SERVICE_JWT_ISSUER` to also require the `iss` claim.

## HTTP mail API

With `MAIL_API_ENABLED=true`, a short list of transactional mails goes to an
HTTP mail API instead of SMTP; all other mail still uses SMTP. The routing headers (`X-Mailer-*`, `X-Docuseal-*`,
`X-Template-Variables`) exist only for that API path and are removed from every
mail that goes out over SMTP.

| Variable | Meaning |
| --- | --- |
| `MAIL_API_BASE_URL`, `MAIL_API_PATH` | Endpoint (path defaults to `/email`). |
| `MAIL_API_TEMPLATE_KEYS` | JSON object mapping `Mailer#action` to a template key. |
| `MAIL_API_MAX_ATTEMPTS`, `MAIL_API_HTTP_TIMEOUT_SECONDS` | Retry and timeout tuning. |

## OAuth2 client-credentials token client

Used by the mail API client to authenticate. `OAUTH_TOKEN_URL`,
`OAUTH_CLIENT_ID`, and `OAUTH_CLIENT_SECRET_PATH` (a file) or
`OAUTH_CLIENT_SECRET`; optional `OAUTH_SCOPE` and `OAUTH_AUDIENCE`.

## Outbound webhook outbox

`submission_created`, `submitter_signed` and `submission_completed` events are
queued in `webhook_outbox` and delivered by `Outbound::WebhookOutboxDrainWorker`
to a single receiver: `WEBHOOK_OUTBOX_URL`, signed with HMAC-SHA256 using
`WEBHOOK_OUTBOX_SECRET` (header `X-Webhook-Signature`, lowercase hex). Payloads
carry `external_tenant_id` and `external_user_id` when SSO provided them; rename
the fields with `WEBHOOK_OUTBOX_TENANT_FIELD` and `WEBHOOK_OUTBOX_USER_FIELD`.

## Extension ports

Everything an operator usually wants to supply is a named port (`lib/extensions.rb`).
With nothing registered each port has a stock default and the app behaves like
upstream.

| Port (short name) | Interface name | Methods |
|---|---|---|
| `notifier` | `notifier` | `deliver(channel:, to:, subject:, html:, text:, template_key:, vars:, attachments:, ...)` |
| `otp` | `otp_provider` | `send_code(subject:, purpose:, channel:, to:, locale:, account_id:)`, `verify(subject:, code:, purpose:)` |
| `plan` | `plan_provider` | `account_plan(account_id)` returning `{ plan:, status:, features:, limits: { docs:, users:, templates:, sends: }, suspended: }` |
| `storage` | `storage_service` | `name` (an Active Storage service) |
| `event_sink` | `event_sink` | `emit(event, payload)` |
| `verification` | `verification_provider` | `start(payload)`, `status(submitter_slug)` |
| `payment_step` | `payment_step_provider` | `create(submitter, field)`, `status(session_id)` |

Reference fakes of every port, usable as a starting point, are in
`spec/support/extensions/`.

Register an adapter in process from a file in `config/extensions.d/` (loaded at
boot, in name order):

```ruby
Extensions.register(:notifier, MyNotifier.new)
```

Or let the HTTP implementation (`PremiumBridge`) supply ports from a server that
speaks a small JSON contract. `PREMIUM_SERVICE_URL` (with `PREMIUM_API_TOKEN`,
sent as `X-Premium-Token`) is unset by default; `EXTENSIONS_HTTP_PORTS` chooses the
ports it supplies (default `plan,event_sink,verification`):

| Port | Request |
|---|---|
| `plan` | `GET /api/premium/account/:id/plan` |
| `event_sink` | `POST /api/hooks/:event` (JSON body; `submitter.completed` is sent as `form.completed`) |
| `verification` | `POST /api/video-kyc/session`, `GET /api/video-kyc/status/:slug` |
| `notifier` | `POST /api/notifications` (attachments as `content_base64`) |
| `otp` | `POST /api/otp/send`, `POST /api/otp/verify` (answers `{ "verified": true }`) |

When set, the app sends plan lookups and event notifications (including submitter
email addresses and phone numbers for `form.completed` and `submission.completed`,
sent when a submitter finishes) to that service, so treat it as a deliberate
transfer of personal data to a processor you control.

### Plan gate

The plan answer is cached per account for `PLAN_CACHE_TTL_SECONDS` (default 60).
When the provider fails, the last answer is used for up to `PLAN_MAX_STALE_SECONDS`
(default 3600); after that every gated action fails closed. Limits are checked
before the cost is incurred: submissions (`docs`, per calendar month) when a
submission is created, and `sends` (invitations, reminders, per calendar month)
before a message goes out. `users` and `templates` limits are checked before a user
or a template is written, and also when an archived user or template is brought
back; archived ones are not counted. A limit the plan does not name is unlimited. A plan
with `suspended: true` (or status `suspended`) cannot create or send anything. The
API answers 402 for a reached quota, 403 for a suspended account and 503 when the
plan service is unavailable. There are no bundled plans or prices.

### Rate limits

`HOSTED_MODE=true` (or `ABUSE_CONTROLS=true`) limits creating submissions and
sending, per account (`RATE_LIMIT_ACCOUNT`, default 60) and per IP address
(`RATE_LIMIT_IP`, default 120) in a 10 minute fixed window. The counters live in
the Redis that Sidekiq already uses (`REDIS_URL`), so the limit holds across every
app process. If that Redis cannot be reached: in hosted mode the action is
refused (503 from the API), fail closed; otherwise the app falls back to a
per-process counter.

### External sign-in

`AUTH_MODE=external` does not draw the local sign-in, password, reset, invitation,
setup, two-factor or user-creation routes at all. People sign in only through the
OpenID Connect provider (see above); an account is created on first sign-in.

#### Receiver requirements for a hosted deployment

- Cookies: with `HOSTED_MODE=true` the session cookie is `__Host-sign_session`:
  Secure, `Path=/`, no `Domain`, HttpOnly, `SameSite=Lax`. Every request is treated
  as https (`assume_ssl`) so the Secure cookie is always written behind a proxy.
- The custom JWT handoff of earlier versions (`JWT_SSO_*`, `/sso/handoff`) is
  removed; hosted mode refuses to boot while any `JWT_SSO_*` variable is set.
- With `AUTH_MODE=external` a failed sign-in shows a retry page and signed-out
  visitors are sent to `/auth/oidc/start`; there is no local sign-in page.
- Download URLs: every `/file`, `/blobs_proxy` and `/disk` URL carries an ASCII slug as
  its filename (lowercase `[a-z0-9._-]`, spaces to `-`, `file` when nothing is left),
  so the path never needs a percent-escape. The real name stays in
  `Content-Disposition` (`filename*`), so the person still downloads "My Contract.pdf".
- A payment field: the builder offers it only when a `payment_step_provider` is
  configured, and in hosted mode a submission whose template carries one is refused
  (422 from the API) without one.

#### Teammate invitations

An admin invites an email address with a role (admin, editor or viewer) from
Settings > Users. There is no link and no token: when that email signs in through
the OpenID Connect provider and the id_token asserts a verified email
(`email_verified: true`), the person is created in the inviting account with
the invited role. An invitation is used once and expires after
`INVITATION_TTL_DAYS` (default 7); inviting the same address again replaces it. An
unverified email never joins an account (the sign-in is refused). The `users` plan
limit applies when the person joins.

### Hosted mode

`HOSTED_MODE=true` refuses to boot unless the `notifier`, `otp`, `plan` and
`storage` ports are configured, OpenID Connect is configured and the client secret
file is readable and not empty, no local auth route is drawn, SMTP is not
configured and storage is not the local disk. In hosted mode every mail goes to
the `notifier` (no allow-list, no SMTP fallback, attachments carried; a failure
raises), signer one-time codes come from the `otp_provider` (the local code module
raises `OtpChallenges::NotConfigured`), and the per-account SMTP, storage and SMS
settings screens are removed.

## Audit export is single-consumer

`GET /api/admin/audit_events` returns events for every account on the instance;
the service JWT carries no account binding and no issuer check. Only issue
tokens to one trusted consumer.
