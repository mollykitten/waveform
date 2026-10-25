# data and auth

- waveform talks to soundcloud's **undocumented `api-v2`**. the `client_id` gets scraped from soundcloud.com at runtime, nothing is shipped or hardcoded
- your personal stuff needs your own soundcloud login through the webview. the oauth token sits in a file in the app's sandboxed support dir, anonymous requests never carry it
- personal collections use `/users/{id}/…` because the `/me/…` versions 404 in api-v2

see also [limitations](limitations.md) for what this setup can't do
