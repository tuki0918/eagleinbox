# Cloudflare Tunnel publishing template

Use this template to connect Eagle Inbox securely to an Eagle library running on a Mac at home, at work, or elsewhere.

Users connect to `https://<your-subdomain>`. Eagle's local API (`http://localhost:41595`) is not directly exposed to the Internet: Cloudflare Tunnel terminates HTTPS and forwards the request locally.

> **Important:** Limiting paths is not authentication. Always enable and use an Eagle API token. Do not share the public URL or API token with anyone.

## APIs allowed by this template

Only the Eagle Web API v2 endpoints required by Eagle Inbox are forwarded to Eagle.

| Purpose | Method | Path |
| --- | --- | --- |
| Test the connection | `GET` | `/api/v2/app/info` |
| Validate the library | `GET` | `/api/v2/library/info` |
| Load folders | `GET` | `/api/v2/folder/get` |
| Load tags | `GET` | `/api/v2/tag/get` |
| Load recent tags | `GET` | `/api/v2/tag/getRecentTags` |
| Load tag groups | `GET` | `/api/v2/tagGroup/get` |
| Add an item | `POST` | `/api/v2/item/add` |

Every other URL receives a `404` response from Cloudflare Tunnel and never reaches Eagle.

## Prerequisites

- Eagle is running and the destination library is open.
- You have a domain managed by Cloudflare, such as `example.com`.
- `cloudflared` is installed on macOS.

```sh
brew install cloudflared
```

## Setup

### 1. Create a Tunnel

Log in to Cloudflare and create a named Tunnel.

```sh
cloudflared tunnel login
cloudflared tunnel create eagle-inbox
```

Save the displayed Tunnel UUID. Then create a DNS route for a subdomain such as `eagle.example.com`.

```sh
cloudflared tunnel route dns eagle-inbox eagle.example.com
```

You can alternatively create the same public hostname in the Cloudflare dashboard under **Networking > Tunnels > Routes > Published application**, pointing it to `http://localhost:41595`.

### 2. Create the configuration file

Copy [`eagle-cloudflared-config.yml`](templates/eagle-cloudflared-config.yml) to `~/.cloudflared/config.yml` and replace the placeholders below.

| Placeholder | Example value |
| --- | --- |
| `<TUNNEL_UUID>` | `12345678-1234-1234-1234-123456789abc` |
| `<MACOS_USERNAME>` | `alice` |
| `<EAGLE_HOSTNAME>` | `eagle.example.com` |

Check that the rules are evaluated as intended.

```sh
cloudflared tunnel ingress validate
cloudflared tunnel ingress rule https://eagle.example.com/api/v2/app/info
cloudflared tunnel ingress rule https://eagle.example.com/api/v2/other
```

The first URL should resolve to `http://localhost:41595`; the second should resolve to `http_status:404`.

### 3. Require an Eagle API token

In Eagle, open **Settings > Developer** and create or copy the API token. Enter that same token in the Eagle Inbox connection settings. Eagle Inbox appends it to API requests as the `token` query parameter.

### 4. Start the Tunnel and connect

```sh
cloudflared tunnel run eagle-inbox
```

Create a connection in Eagle Inbox with these values:

| Field | Value |
| --- | --- |
| Protocol | `HTTPS` |
| Host | `eagle.example.com` |
| Port | `443` |
| API token | The token configured in Eagle |

Once **Test Connection** succeeds, the public URL is `https://eagle.example.com`; do not include `:41595`.

## Run as a macOS service

For a Tunnel that should start automatically whenever you log in, install `cloudflared` as a user launch agent. Confirm that `~/.cloudflared/config.yml` contains the `tunnel` and `credentials-file` values before installing it.

```sh
cloudflared service install
```

The service uses the configuration in `~/.cloudflared/` and starts at login. Manage the user launch agent with the following commands:

```sh
# Start the service now, or restart it after changing config.yml.
launchctl kickstart -k gui/$(id -u)/com.cloudflare.cloudflared

# Stop the service temporarily.
launchctl stop com.cloudflare.cloudflared

# Check whether the service is registered and inspect its status.
launchctl print gui/$(id -u)/com.cloudflare.cloudflared
```

To remove the automatic-login service entirely, run:

```sh
cloudflared service uninstall
```

## Stop or disconnect the Tunnel

If you started the Tunnel in a terminal with `cloudflared tunnel run eagle-inbox`, press `Control-C` in that same terminal. This stops the local `cloudflared` process immediately, so external requests can no longer reach Eagle. The DNS record remains, which is expected; visitors will receive an error until the Tunnel is started again.

To start it again, run:

```sh
cloudflared tunnel run eagle-inbox
```

If you installed `cloudflared` as a macOS service instead, stopping a terminal command will not stop it. Use the service command above instead:

```sh
launchctl stop com.cloudflare.cloudflared
```

Do not delete the Tunnel just to temporarily disconnect it. Tunnel deletion is permanent.

## Additional protection

- **Cloudflare Access:** Restrict access to your own account or selected email addresses. Non-browser clients such as Eagle Inbox require a compatible machine-authentication design, such as a Service Token-aware proxy, instead of an interactive login.
- **Cloudflare WAF / Rate Limiting:** Add protection against unwanted repeated uploads.
- **Dedicated subdomain:** Use a dedicated hostname such as `eagle.example.com` and keep it separate from your other sites.

Keep the Eagle API token enabled even when Cloudflare Access is used, providing defense in depth.

## Notes

- Eagle APIs are unavailable when Eagle is closed or the intended library is not open.
- Cloudflare Free plan uploads are limited to 100 MB per request. See [Cloudflare's upload-limit documentation](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/4xx-client-error/error-413/).
- This template is limited to the APIs currently required by Eagle Inbox. If supported APIs change, update the allowlist. See [EAGLE_WEB_API_COMPATIBILITY.md](EAGLE_WEB_API_COMPATIBILITY.md) for the current list.
