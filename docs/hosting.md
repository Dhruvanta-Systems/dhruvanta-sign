# Hosting checklist

What a fresh deployment gets, and what to set before it faces the internet.

| Setting | Default | State | What to do |
| --- | --- | --- | --- |
| `SECRET_KEY_BASE` | Generated at first boot (128 hex characters) into `docuseal.env`, mode 0600. There is no built-in value. | Safe | Keep the file and the volume it lives on. Losing it logs everyone out and makes encrypted settings unreadable, so also set `ENCRYPTION_SECRET` and back it up. |
| Administrator account | None. The first visitor to `/setup` creates it. | Safe once set up | On a public host, set `SETUP_TOKEN` before the first start: the setup form then also asks for it. |
| Sign-up | None. Accounts are created by an administrator's invitation. | Safe | Nothing to do. |
| Debug and development routes | Mounted only when `RAILS_ENV=development` (mail preview, debugger). | Safe | Never run production with `RAILS_ENV=development`. |
| CORS | No CORS middleware: browsers cannot read responses cross-origin. | Safe | Call the API from a server, or put a proxy that adds CORS in front. |
| HTTPS | `FORCE_SSL` unset means plain HTTP, session cookies without the Secure flag and no HSTS. | **Opt in** | Set `FORCE_SSL` to your public host name (the bundled `docker-compose.yml` does). The app logs a warning at boot when it is unset. |
| Cookie flags | Session cookie is HttpOnly and SameSite=Lax; Secure is added by `FORCE_SSL`. | Safe with `FORCE_SSL` | Set `FORCE_SSL`. |
| Host header | Any host is accepted unless `ALLOWED_HOSTS` is set. Absolute links in e-mails and shared forms are built from `HOST`/the stored app URL, never from the request. | **Opt in** | Set `ALLOWED_HOSTS` to a comma separated list (wildcards such as `*.example.org` work). `/up` stays reachable for health checks. |
| `HOST` | `localhost`. | Set it | Links in e-mails point to this host. |
| Database password | The sample `docker-compose.yml` uses `postgres` and does not publish the database port. | Change for real use | Use your own password and keep the port private. |

`bin/rails runner 'puts ProductionDefaultsCheck.warnings(ENV)'` prints the weak
settings of the current environment.
