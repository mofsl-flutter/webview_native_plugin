// One retry for an API GET that failed because the HTTP cache held a copy the page may not read.
//
// The page's API calls are cross-origin when it is served from the app. The server answers a
// cacheable GET (Symbols, 2 h; Config, 6 h) with `access-control-allow-origin` only when the request
// carries an Origin header, and says nothing about `Vary: Origin`. So a copy stored by a same-origin
// request (the hosted page, or the hosted Peak page, which shares the app's one WebView and requests
// the same two endpoints) has no such header, and the browser serves it to the bundled page's CORS
// request, which then fails with a TypeError (`net::ERR_FAILED`) and the chart says SymbolNotFound.
//
// The cure is to ask again with `cache: 'reload'`: it goes to the server, and the response is stored
// with the header, so every later request is served from a copy this page can read. Only a GET, only
// once, only after a network-level failure, and only when the caller did not choose a cache mode:
//
//   * a write may have reached the server, so it is never repeated;
//   * an HTTP status is an answer, not a failure;
//   * a caller that asked for `no-store`, `reload`... knows what it wants.
//
// Every request the page makes goes through here (there is exactly one call site, in
// static_config.js `fetchWith401Retry`), which tool/js_test/net_retry.test.mjs keeps true.
(function (window, chartApp) {
    'use strict';

    // Kept across a second load of this script, so a counter is never reset under a caller.
    const stats = (chartApp.netRetry && chartApp.netRetry._stats) || {retried: 0, recovered: 0, failed: 0};

    // `name`, not `instanceof TypeError`: a failed fetch rejects with the TypeError of whichever
    // realm made the request, and a test (or a frame) has a different one.
    function isNetworkFailure(err) {
        return !!err && err.name === 'TypeError';
    }

    function isGet(options) {
        const method = options && options.method;
        return method === undefined || String(method).toUpperCase() === 'GET';
    }

    // The path only: the query carries the symbol, and nothing about an account belongs in a log.
    function describe(target) {
        try {
            return new URL(String(target), 'https://x.invalid/').pathname;
        } catch (e) {
            return 'request';
        }
    }

    function note(message) {
        try {
            if (window.log && typeof window.log.info === 'function') window.log.info(message);
        } catch (e) {
            // A logger that throws must not turn a recovered request into a failed one.
        }
    }

    // `window.fetch` is looked up on every call: the test harness replaces it to simulate an outage.
    async function request(target, options) {
        try {
            return await window.fetch(target, options);
        } catch (err) {
            const retryable = isNetworkFailure(err) && isGet(options) &&
                !(options && options.cache !== undefined) &&
                !(options && options.signal && options.signal.aborted);
            if (!retryable) throw err;

            stats.retried++;
            note('GET ' + describe(target) + ' failed on a network error; retrying once with the cache bypassed');
            try {
                const response = await window.fetch(target, Object.assign({}, options, {cache: 'reload'}));
                stats.recovered++;
                return response;
            } catch (again) {
                stats.failed++;
                throw again;
            }
        }
    }

    chartApp.netRetry = {
        fetch: request,
        // { retried, recovered, failed }, for probes: how often the cache needed bypassing.
        stats: function () {
            return {retried: stats.retried, recovered: stats.recovered, failed: stats.failed};
        },
        _stats: stats,
    };
})(window, ChartApp);
