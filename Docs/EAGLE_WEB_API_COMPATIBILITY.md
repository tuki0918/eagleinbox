# Eagle Web API v2 Compatibility

Eagle Inbox can connect over HTTPS to a custom endpoint that implements the subset of [Eagle Web API v2](https://developer.eagle.cool/web-api) listed below. HTTPS support does not imply that the Eagle desktop app itself serves its Web API over HTTPS; a direct Eagle connection normally uses HTTP on port `41595`.

## Required Endpoints

| Method | Endpoint | Used for |
| --- | --- | --- |
| `GET` | `/api/v2/app/info` | Testing the connection |
| `GET` | `/api/v2/library/info` | Identifying and validating the open library |
| `GET` | `/api/v2/folder/get` | Loading folders and recent folders |
| `GET` | `/api/v2/tag/get` | Loading tags |
| `GET` | `/api/v2/tag/getRecentTags` | Loading recent tags |
| `GET` | `/api/v2/tagGroup/get` | Loading tag groups |
| `POST` | `/api/v2/item/add` | Adding files and bookmarks with metadata |

The endpoint must accept the same request parameters and return responses compatible with the Eagle Web API v2 endpoints above. If a connection has an API token, Eagle Inbox sends it as the `token` URL query parameter. HTTPS endpoints must use a certificate trusted by the device.
