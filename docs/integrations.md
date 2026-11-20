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
| `JWT_SSO_CLAIM_AUDIENCE` | Audience claim name, default `aud`. |
| `JWT_SSO_CLAIM_EMAIL` | Email claim name, default `email`. |
| `JWT_SSO_CLAIM_NAME` | Display name claim, default `name`. |
| `JWT_SSO_CLAIM_TENANT` | Optional claim holding an external tenant id. |
| `JWT_SSO_CLAIM_TIER` | Optional claim holding a plan or tier. |
| `JWT_SSO_ALLOWED_TIERS` | Optional comma separated allow-list of tiers. |

Endpoints: `GET /sso/handoff?token=<jwt>` (browser) and
`POST /api/auth/sso-handoff` with `{"token": "<jwt>"}` (JSON). Until the three
required variables are set both answer 404. The replay check on `jti` uses
`Rails.cache`; behind more than one app server it must be a shared store.

## Service JWT for the audit export

`GET /api/admin/audit_events` returns submission events to another service. It
accepts a bearer JWT verified against `SERVICE_JWT_JWKS_URL`, with the audience
`SERVICE_JWT_AUDIENCE` and the scope `SERVICE_JWT_AUDIT_SCOPE` (default
`audit.read`). Unconfigured, it answers 503.

## HTTP mail API

With `MAIL_API_ENABLED=true`, a short list of transactional mails goes to an
HTTP mail API instead of SMTP; all other mail still uses SMTP.

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

## Optional external plan service

`PREMIUM_SERVICE_URL` (with `PREMIUM_API_TOKEN`) points the plan, subscription
and video-KYC features at an external service. It is unset by default. When set,
the app sends plan lookups and event notifications (including submitter email
addresses and phone numbers for `form.completed`, `submission.completed` and
`submitter.created`) to that service, so treat it as a deliberate transfer of
personal data to a processor you control.

## Audit export is single-consumer

`GET /api/admin/audit_events` returns events for every account on the instance;
the service JWT carries no account binding and no issuer check. Only issue
tokens to one trusted consumer.
