// Responses the host fetched for the chart before the page asked for them.
//
// Opening a chart is a chain of requests: Symbols, then GetChartSavedInfo, then (once the widget
// exists) Config and the first HistoryV3. The page cannot start any of them before it has loaded,
// but the host can, in parallel with loading it. The host fetches them and hands the raw response
// bodies to this store; the page's own adapter takes them here instead of going to the network, and
// parses them with the code it has always used, so there is still exactly one interpretation of each
// response.
//
//   ChartApp.preload.expect(kind, key)                    a fetch is in flight; take() will wait for it
//   ChartApp.preload.put(kind, key, body, fetchedAtMs, meta)   the 200 body, as text
//   ChartApp.preload.cancel(kind, key)                    the fetch failed; stop waiting for it
//   ChartApp.preload.take(kind, key, {maxAgeMs}) -> Promise<response | undefined>
//   ChartApp.preload.takeHistory(request)         -> Promise<response | undefined>
//
// Everything here is a shortcut, never a source of truth, so every doubt resolves to "undefined" and
// the caller makes the request itself:
//   * an entry is single-use. It is consumed by the first reader whether or not it was usable, so a
//     response refused once is never offered to a later, different request;
//   * an entry older than maxAgeMs is refused;
//   * a body that is not JSON is refused;
//   * waiting for an in-flight entry is bounded, and a response that arrives after its waiter gave
//     up is discarded rather than kept for someone else;
//   * history is never waited for. Whether it is usable depends on what the server sent (a slow or
//     faulty server can return a window that does not cover the one asked for), so waiting for it
//     and then refusing it would make the chart slower than not prefetching at all. It is used if it
//     has already arrived; otherwise the page asks, exactly as it would have.
//
// `now`, `setTimer` and `clearTimer` default to the page's own and exist so tests can drive time.
(function (window, chartApp) {
    'use strict';

    // History moves with the market, so a prefetched slice is only trusted for a moment: long
    // enough to cover page start-up, short enough that at most one bar can have formed since. This
    // bounds both how long it may sit in the store and how far its `to` may trail the library's.
    const MAX_HISTORY_AGE_MS = 15000;

    // The length of a bar in ms, read the way datafeed.js reads a resolution string.
    function resolutionMs(resolution) {
        if (typeof resolution !== 'string') return Number(resolution) * 60000;
        const r = resolution.toUpperCase();
        const n = parseInt(r, 10) || 1;
        if (r.endsWith('S')) return n * 1000;
        if (r.endsWith('D')) return n * 86400000;
        if (r.endsWith('W')) return n * 7 * 86400000;
        if (r.endsWith('M')) return n * 30 * 86400000;
        return n * 60000;
    }

    // TradingView says `D` in some places and `1D` in others for the same resolution; one spelling
    // for the key, matching ChartPrefetch.normalizeResolution on the Dart side.
    function normalizeResolution(resolution) {
        const r = String(resolution);
        return /^[DWM]$/i.test(r) ? '1' + r.toUpperCase() : r;
    }

    // What the server answers a history request with, as observed on production:
    //   * a window with bars in it: exactly the bars whose time lies in [from, to], however few
    //     (windows of 1, 2, 4, 10 and 12 bars came back as exactly those, with countBack 300 and 1)
    //     and however many (no trimming to countBack);
    //   * a window with NO bars in it (the market is closed): a long run of bars from before the
    //     window, none of them inside it.
    // So a wider prefetch, cut to the library's window, is the answer the server would have given
    // whenever the cut is non-empty. An empty cut is refused: the server's answer to that is
    // something else, which a slice cannot reproduce. (UAT is not consistent about any of this: it
    // can return an older window whatever was asked, so nothing is served from a UAT response that
    // does not cover the window.) Anything refused returns null and the page asks the server itself.
    function sliceHistory(data, meta, request, maxLagSec, nowSec, why) {
        if (!data || !Array.isArray(data.t) || data.t.length === 0) return why('the body has no bars');
        if (typeof meta.from !== 'number' || typeof meta.to !== 'number') return why('no window was recorded');
        // The prefetch has to reach back past the library's window, or the older bars were never
        // fetched...
        if (!(meta.from < request.from)) {
            return why('does not reach back far enough: starts ' + (meta.from - request.from) + ' s after the library\'s from');
        }
        // ...and forward to about now. The bars the prefetch could not have seen are those between
        // its own `to` and the present: that gap, not how long the response has sat here, is how
        // stale it is. The library's `to` is not the present: it asks up to the END of the current
        // bar (a full minute ahead for one-minute bars), and no bars exist in that future, so it is
        // capped at now.
        const lag = Math.min(request.to, nowSec) - meta.to;
        if (lag > maxLagSec) {
            return why('its to trails now by ' + lag + ' s (allowed ' + maxLagSec + ' s)');
        }

        const keep = [];
        for (let i = 0; i < data.t.length; i++) {
            if (data.t[i] >= request.from && data.t[i] <= request.to) keep.push(i);
        }
        if (keep.length === 0) {
            return why('no bars in the window (the server answers an empty window with older bars)');
        }

        const out = {};
        Object.keys(data).forEach(function (key) {
            const value = data[key];
            out[key] = Array.isArray(value) && value.length === data.t.length
                ? keep.map(function (i) { return value[i]; })
                : value;
        });
        return out;
    }

    function create(options) {
        options = options || {};
        const now = options.now || function () { return Date.now(); };
        const setTimer = options.setTimer || function (fn, ms) { return setTimeout(fn, ms); };
        const clearTimer = options.clearTimer || function (id) { clearTimeout(id); };
        // The host cancels a failed fetch, so this only bounds a host that goes silent.
        const waitMs = options.waitMs === undefined ? 30000 : options.waitMs;

        // id -> {state: 'pending' | 'ready' | 'abandoned', body, fetchedAt, meta, waiters: []}
        const entries = new Map();
        const counters = {
            hits: 0, misses: 0, expired: 0, rejected: 0, timedOut: 0, discarded: 0, skipped: 0, notReady: 0,
        };
        // Why the most recent refusal happened. A refusal otherwise looks like a plain miss.
        let lastReject = null;

        const idOf = function (kind, key) { return kind + '|' + key; };

        // What the adapter reads from a fetch() result: status, ok, json().
        function response(data, ageMs) {
            return {
                status: 200,
                ok: true,
                preloaded: true,
                ageMs: ageMs,
                json: function () { return Promise.resolve(data); },
            };
        }

        // Takes the entry out, then decides whether it can be used. Out first: single-use means
        // single-use even when the answer is no.
        function consume(id, entry, opts) {
            entries.delete(id);
            const ageMs = now() - entry.fetchedAt;
            if (opts.maxAgeMs !== undefined && ageMs > opts.maxAgeMs) {
                counters.expired++;
                return undefined;
            }
            let data;
            try {
                data = JSON.parse(entry.body);
            } catch (e) {
                counters.rejected++;
                return undefined;
            }
            if (opts.accept) {
                const why = function (reason) { lastReject = reason; return null; };
                data = opts.accept(data, entry.meta || {}, ageMs, why);
                if (!data) {
                    counters.rejected++;
                    return undefined;
                }
            }
            counters.hits++;
            return response(data, ageMs);
        }

        function expect(kind, key) {
            const id = idOf(kind, key);
            if (!entries.has(id)) entries.set(id, {state: 'pending', waiters: []});
        }

        function put(kind, key, body, fetchedAt, meta) {
            const id = idOf(kind, key);
            const entry = entries.get(id);
            if (entry && entry.state === 'abandoned') {
                // The one waiter gave up and went to the network; nobody wants this any more.
                entries.delete(id);
                counters.discarded++;
                return;
            }
            const ready = {state: 'ready', body: body, fetchedAt: fetchedAt, meta: meta, waiters: []};
            if (!entry) {
                entries.set(id, ready);
                return;
            }
            entry.state = 'ready';
            entry.body = body;
            entry.fetchedAt = fetchedAt;
            entry.meta = meta;
            const waiters = entry.waiters.splice(0);
            waiters.forEach(function (w, i) {
                clearTimer(w.timer);
                // The first waiter gets it; the entry is gone by the time the rest look.
                w.resolve(i === 0 ? consume(id, entry, w.opts) : undefined);
            });
        }

        function cancel(kind, key) {
            const id = idOf(kind, key);
            const entry = entries.get(id);
            if (!entry) return;
            entries.delete(id);
            entry.waiters.splice(0).forEach(function (w) {
                clearTimer(w.timer);
                w.resolve(undefined);
            });
        }

        function take(kind, key, opts) {
            opts = opts || {};
            const id = idOf(kind, key);
            const entry = entries.get(id);
            if (!entry || entry.state === 'abandoned') {
                counters.misses++;
                return Promise.resolve(undefined);
            }
            if (entry.state === 'ready') return Promise.resolve(consume(id, entry, opts));

            if (opts.wait === false) {
                // In flight and this caller will not wait: leave it to the network, and discard the
                // response when it lands rather than keep it for a later, different request.
                counters.notReady++;
                if (entry.waiters.length === 0) entry.state = 'abandoned';
                return Promise.resolve(undefined);
            }

            return new Promise(function (resolve) {
                const waiter = {resolve: resolve, opts: opts, timer: null};
                waiter.timer = setTimer(function () {
                    const at = entry.waiters.indexOf(waiter);
                    if (at !== -1) entry.waiters.splice(at, 1);
                    counters.timedOut++;
                    if (entry.waiters.length === 0) entry.state = 'abandoned';
                    resolve(undefined);
                }, waitMs);
                entry.waiters.push(waiter);
            });
        }

        // request: {ticker, resolution, from, to, countBack, firstDataRequest}, as getData receives it.
        function takeHistory(request) {
            if (!request.firstDataRequest) {
                // Scrolling back asks for older ranges; a prefetch was only ever for the first load.
                counters.skipped++;
                return Promise.resolve(undefined);
            }
            const maxAgeMs = Math.min(MAX_HISTORY_AGE_MS, resolutionMs(request.resolution));
            return take('history', request.ticker + '|' + normalizeResolution(request.resolution), {
                wait: false,
                maxAgeMs: maxAgeMs,
                accept: function (data, meta, ageMs, why) {
                    return sliceHistory(data, meta, request, maxAgeMs / 1000, now() / 1000, why);
                },
            });
        }

        return {
            expect: expect,
            put: put,
            cancel: cancel,
            take: take,
            takeHistory: takeHistory,
            stats: function () { return Object.assign({}, counters, {lastReject: lastReject}); },
        };
    }

    const preload = create();
    preload.create = create;
    chartApp.preload = preload;
})(window, ChartApp);
