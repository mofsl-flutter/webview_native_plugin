// Coalesces "save the chart" requests into few saves.
//
// Every save serialises the whole chart and POSTs it (about 28 KB with two indicators), and the
// page used to make one per visible-range change, so panning for 10 s sent 40 to 80 of them. This
// merges a burst into one save, taken `delayMs` after the last request, so a pan saves once when it
// pauses.
//
// A plain debounce has a flaw here: a pan that never pauses (a request every 250 ms against a 1 s
// delay) would never save at all, and a crash mid-pan would lose everything since the last pause.
// So the wait is also capped: a save is taken at most `maxWaitMs` after the first request that is
// still waiting, however many requests keep arriving.
//
//   const scheduler = ChartApp.saveScheduler.create({delayMs: 1000, maxWaitMs: 5000, run: save});
//   scheduler.request();   // "a save is needed"; cheap, call as often as you like
//
// `now`, `setTimer` and `clearTimer` default to the page's own and exist so tests can drive time.
(function (window, chartApp) {
    'use strict';

    function create(options) {
        const delayMs = options.delayMs;
        const maxWaitMs = options.maxWaitMs;
        const run = options.run;
        const onError = options.onError || function () {};
        const now = options.now || function () { return Date.now(); };
        const setTimer = options.setTimer || function (fn, ms) { return setTimeout(fn, ms); };
        const clearTimer = options.clearTimer || function (id) { clearTimeout(id); };

        let timer = null;
        let waitingSince = 0;

        function fire() {
            timer = null;
            try {
                run();
            } catch (err) {
                // One failed save must not stop the next: the chart would silently stop saving.
                onError(err);
            }
        }

        return {
            // A save is needed. Restarts the delay, but never lets the oldest waiting request wait
            // longer than maxWaitMs in total.
            request: function () {
                const t = now();
                if (timer === null) {
                    waitingSince = t;
                } else {
                    clearTimer(timer);
                }
                const left = Math.max(0, waitingSince + maxWaitMs - t);
                timer = setTimer(fire, Math.min(delayMs, left));
            },
            // Drops a waiting save without running it.
            cancel: function () {
                if (timer !== null) {
                    clearTimer(timer);
                    timer = null;
                }
            },
            // Runs a waiting save now (e.g. before the page goes away). A no-op when none is waiting.
            flush: function () {
                if (timer === null) return;
                clearTimer(timer);
                fire();
            },
            get pending() {
                return timer !== null;
            },
        };
    }

    chartApp.saveScheduler = {create: create};
})(window, ChartApp);
