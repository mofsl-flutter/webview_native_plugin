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

    // The server answers a history request with exactly the bars whose time lies in [from, to]: it
    // does not pad up to countBack when the window holds fewer, and does not trim when it holds more
    // (checked against both UAT and production). So a wider prefetch, cut to the library's window,
    // is the answer the server would have given, provided the cut keeps at least countBack bars.
    // Anything else returns null and the page asks the server itself.
    function sliceHistory(data, meta, request, maxLagSec) {
        if (!data || !Array.isArray(data.t) || data.t.length === 0) return null;
        if (typeof meta.from !== 'number' || typeof meta.to !== 'number') return null;
        if (!Number.isFinite(request.countBack)) return null;
        // The prefetch has to reach back past the library's window, or the older bars were never
        // fetched...
        if (!(meta.from < request.from)) return null;
        // ...and forward to about where the library's window ends. The newest bars the prefetch
        // could not have seen are the ones between its own `to` and the library's: that gap, not how
        // long the response has sat here, is how stale it is.
        if (request.to - meta.to > maxLagSec) return null;

        const keep = [];
        for (let i = 0; i < data.t.length; i++) {
            if (data.t[i] >= request.from && data.t[i] <= request.to) keep.push(i);
        }
        if (keep.length < request.countBack) return null;

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
                data = opts.accept(data, entry.meta || {}, ageMs);
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
            return take('history', request.ticker + '|' + request.resolution, {
                wait: false,
                maxAgeMs: maxAgeMs,
                accept: function (data, meta) { return sliceHistory(data, meta, request, maxAgeMs / 1000); },
            });
        }

        return {
            expect: expect,
            put: put,
            cancel: cancel,
            take: take,
            takeHistory: takeHistory,
            stats: function () { return Object.assign({}, counters); },
        };
    }

    const preload = create();
    preload.create = create;
    chartApp.preload = preload;
})(window, ChartApp);
