// Where the chart's API calls go when the page is served from inside the app.
//
// The hosted page reaches its API with relative paths: "api/Chart/..." and "../api/Chart/...",
// which resolve to <server>/chart/api/... because the page lives at <server>/chart/v4/. When the
// plugin serves the page itself (Android: https://appassets.androidplatform.net/chart/v4/...,
// iOS: mochart://app/chart/v4/...), those same paths would resolve to the app's own virtual host,
// which has no API. The host app passes the real server in the page URL instead:
//
//   .../v4/RiseApp_Mobile.html?apiBase=https%3A%2F%2Fserver%2Fchart%2F
//
// apiBase is the URL that "api/..." is relative to, i.e. the directory that contains api/.
//
// Rules:
//   * apiBase given      -> used, wherever the page is served from.
//   * not given, remote  -> null: relative paths keep working exactly as they always did.
//   * not given, local   -> an error. Silently calling the app's own host would 404 every request
//                           and look like a broken server.
//   * given but invalid  -> an error, never a guess. It must be an https URL, with no credentials,
//                           query or fragment, and not the app's own host.
(function (window, chartApp) {
    'use strict';

    const LOCAL_HOSTS = ['appassets.androidplatform.net'];
    const LOCAL_PROTOCOLS = ['mochart:'];

    function isLocalOrigin(loc) {
        return LOCAL_PROTOCOLS.indexOf(loc.protocol) !== -1 || LOCAL_HOSTS.indexOf(loc.hostname) !== -1;
    }

    // -> { base: string | null } or { error: string }
    function parse(loc) {
        const raw = new URLSearchParams(loc.search).get('apiBase');
        if (raw === null || raw === '') {
            return isLocalOrigin(loc)
                ? {error: 'apiBase is required when the chart is served from the app'}
                : {base: null};
        }
        let url;
        try {
            url = new URL(raw);
        } catch (e) {
            return {error: 'apiBase is not an absolute URL'};
        }
        if (url.protocol !== 'https:') return {error: 'apiBase must be an https URL'};
        if (url.username || url.password) return {error: 'apiBase must not carry credentials'};
        if (url.search || url.hash) return {error: 'apiBase must not carry a query or fragment'};
        if (LOCAL_HOSTS.indexOf(url.hostname) !== -1) {
            return {error: 'apiBase must not be the app\'s own host'};
        }
        return {base: url.origin + url.pathname.replace(/\/*$/, '/')};
    }

    // "api/x" and "../api/x" both mean <apiBase>api/x. Anything else (an absolute URL, a path to
    // a bundled file) is not an API path and passes through. Idempotent: its own output is an
    // absolute URL, which passes through, so a retry queue can resolve a URL twice.
    function resolve(parsed, url) {
        if (parsed.error) throw new Error(parsed.error);
        if (parsed.base === null) return url;
        const m = /^(?:\.\.\/)?(api\/.*)$/.exec(url);
        return m ? parsed.base + m[1] : url;
    }

    const parsed = parse(window.location);

    chartApp.apiBase = {
        // The resolved base ("https://server/chart/"), or null on a remote page.
        base: parsed.base === undefined ? null : parsed.base,
        error: parsed.error || null,
        resolve: function (url) {
            return resolve(parsed, url);
        },
        // Exposed for tests; pages use resolve().
        _parse: parse,
        _resolve: resolve,
    };
})(window, ChartApp);
