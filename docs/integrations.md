# Optional integrations

Everything below is off until the listed environment variables are set. No
service name, URL or credential is built in.

## JWT single sign-on (`JwtSso`)

An external identity provider signs a short-lived JWT; this app verifies it
against the provider's JWKS, signs the person in and creates the user (inside a
new account) on first sight.

| Variable | Meaning |
| --- | --- |
| `JWT_SSO_ISSUER` | Expected `iss` claim. Required. |
| `JWT_SSO_JWKS_URL` | URL of the issuer's JWKS. Required. |
| `JWT_SSO_AUDIENCE` | Expected audience. Required. |
| `JWT_SSO_ALGORITHM` | `ES256` (default), `ES384`, `RS256` or `RS384`. |
| `JWT_SSO_LOGIN_URL` | Where `GET /sso/start` sends the browser. Gets `state` and `redirect_uri` query parameters. |
| `JWT_SSO_CLAIM_NONCE` | Claim that must echo `state`, default `nonce`. |
| `JWT_SSO_CLAIM_AUDIENCE` | Audience claim name, default `aud`. |
| `JWT_SSO_CLAIM_EMAIL` | Email claim name, default `email`. |
| `JWT_SSO_CLAIM_NAME` | Display name claim, default `name`. |
| `JWT_SSO_CLAIM_TENANT` | Optional claim holding an external tenant id. |
| `JWT_SSO_CLAIM_TIER` | Optional claim holding a plan or tier. |
| `JWT_SSO_ALLOWED_TIERS` | Optional comma separated allow-list of tiers. |

The flow is bound to the browser, and no token ever appears in a URL:

1. The browser opens `GET /sso/start`. The app stores a random `state` in an
   encrypted, HttpOnly, SameSite=Lax cookie and redirects to `JWT_SSO_LOGIN_URL`
   with `state` and `redirect_uri` query parameters.
2. The identity provider signs the person in and puts `state` into the token's
   `nonce` claim, then auto-submits a form to `redirect_uri`
   (`POST /sso/handoff`, fields `token` and `state`).
3. The app checks that `state` equals the cookie and the token's nonce, consumes
   the cookie, and signs the person in.

`POST /api/auth/sso-handoff` with `{"token": "<jwt>", "state": "<state>"}`
(JSON) applies the same checks. There is no GET handoff. Until the three
required variables are set the handoff answers 404 and `/sso/start` needs
`JWT_SSO_LOGIN_URL` as well. The replay check on `jti` uses
`Rails.cache`; behind more than one app server it must be a shared store.

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
| `auth` | `auth_provider` | `verify_handoff(token, expected_nonce:)`, `lookup_or_provision_user(handoff)`, `audit_received`, `audit_failed` |
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
generic JWT handoff (`/sso/start`, `/sso/handoff`); an account is created on first
sign-in.

#### Who is who: the subject, not the email

A person is identified by the provider's stable `(issuer, subject)`, stored on the
user (`sso_issuer`, `sso_subject`, unique together); sign-in finds the user by that
pair first. An email address is used only to link a user that has no identity yet
(an older account) and to bind an invitation, and only when the provider asserts it
is verified. If the verified address of a known person changes and is free, their
user follows it. A user already bound to a different subject is never handed to a
new person who arrives with the same address (a recycled or taken-over address):
that sign-in is refused (`sso-handoff-email-bound`, 409). A token without a subject
is refused.

#### Receiver requirements for a hosted deployment

- Cookies: with `HOSTED_MODE=true` the state cookie is `__Host-sso_state` and the
  session cookie `__Host-sign_session`: Secure, `Path=/`, no `Domain`, HttpOnly,
  `SameSite=Lax`.
- Replay memory: the `jti` of an accepted token is kept in the Redis that Sidekiq
  uses (shared by every process); if it cannot be reached the sign-in is refused
  (503). Outside hosted mode the Rails cache is used.
- An unknown `kid` refetches the key set at most 5 times a minute.
- With `AUTH_MODE=external` a failed handoff shows a retry page and signed-out
  visitors are sent to `/sso/start`; there is no local sign-in page.
- A sign-in lasts at most `SSO_SESSION_MAX_AGE_SECONDS` (default 43200), then the
  person goes through the handoff again.
- `JWT_SSO_STATE_DELIVERY=fragment` (the default in hosted mode) delivers `state`
  and `redirect_uri` after the `#` of `JWT_SSO_LOGIN_URL`; `query` is the default
  elsewhere.
- `JWT_SSO_SIGNED_OUT_URL` (https) is where sign-out sends the browser.
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
the identity provider and the handoff asserts a verified email
(`JWT_SSO_CLAIM_EMAIL_VERIFIED`), the person is created in the inviting account with
the invited role. An invitation is used once and expires after
`INVITATION_TTL_DAYS` (default 7); inviting the same address again replaces it. An
unverified email never joins an account. The `users` plan limit applies when the
person joins. A custom `auth_provider` should call `AccountInvitation.accept!` for
a verified address before it creates a new account.

### Hosted mode

`HOSTED_MODE=true` refuses to boot unless the `auth`, `notifier`, `otp`, `plan` and
`storage` ports are configured, no local auth route is drawn, SMTP is not
configured and storage is not the local disk. In hosted mode every mail goes to
the `notifier` (no allow-list, no SMTP fallback, attachments carried; a failure
raises), signer one-time codes come from the `otp_provider` (the local code module
raises `OtpChallenges::NotConfigured`), and the per-account SMTP, storage and SMS
settings screens are removed.

## Audit export is single-consumer

`GET /api/admin/audit_events` returns events for every account on the instance;
the service JWT carries no account binding and no issuer check. Only issue
tokens to one trusted consumer.
