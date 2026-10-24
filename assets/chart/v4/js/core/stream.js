(function (window, chartApp) {
    const logger = log.getLogger("stream");
    //Map of ticker and its last bar
    const _lastBarCache = new Map();
    //Map of ticker_resolution and its subscriptionItem
    const _subscriptions = new Map();
    //Map of ticker and the subscriptionItems for it, one per resolution. Lookup by key prefix would
    //also match a different ticker that merely starts with this one (NSE:ACC and NSE:ACCELYA).
    const _byTicker = new Map();

    const stream = {
        data: {
            _lastBarCache: _lastBarCache,
            _subscriptions: _subscriptions
        },
        saveBar: function (ticker, resolution, bar) {
            _lastBarCache.set(`${ticker}_${resolution}`, bar)
        },
        subscribe: function (ticker, resolution, guid, callback) {
            const key = `${ticker}_${resolution}`;
            const handler = {
                id: guid,
                callback: callback,
            };
            let subscriptionItem = _subscriptions.get(key);
            if (subscriptionItem) {
                // already subscribed to the channel, use the existing subscription
                subscriptionItem.handlers.push(handler);
                return;
            }
            const lastDailyBar = _lastBarCache.get(key);
            subscriptionItem = {
                guid,
                ticker,
                resolution,
                lastDailyBar,
                handlers: [handler],
            };
            _subscriptions.set(key, subscriptionItem);
            let forTicker = _byTicker.get(ticker);
            if (!forTicker) {
                forTicker = new Set();
                _byTicker.set(ticker, forTicker);
            }
            forTicker.add(subscriptionItem);
            logger.debug("Subscription Map :", _subscriptions.keys());
        },
        unsubscribe: function (guid) {
            for (const key of _subscriptions.keys()) {
                const subscriptionItem = _subscriptions.get(key);
                const handlerIndex = subscriptionItem.handlers
                    .findIndex(handler => handler.id === guid);

                if (handlerIndex !== -1) {
                    // remove from handlers
                    subscriptionItem.handlers.splice(handlerIndex, 1);

                    if (subscriptionItem.handlers.length === 0) {
                        // unsubscribe from the channel, if it was the last handler
                        _subscriptions.delete(key);
                        const forTicker = _byTicker.get(subscriptionItem.ticker);
                        if (forTicker) {
                            forTicker.delete(subscriptionItem);
                            if (forTicker.size === 0) _byTicker.delete(subscriptionItem.ticker);
                        }
                        break;
                    }
                }
            }
            logger.debug("Subscription Map :", _subscriptions.keys());
        },
        get: function (ticker, resolution) {
            return _subscriptions.get(`${ticker}_${resolution}`);
        },
        // Every subscription for exactly this ticker, whatever its resolution.
        getV2:function (ticker){
            const forTicker = _byTicker.get(ticker);
            return forTicker ? Array.from(forTicker) : [];
        },
        getQuote:function (ticker,resolution){
            const key = `${ticker}_${resolution}`;
            let ch = 0;
            let chp = 0;
            let ltp=0;
            const lastDailyBar = _lastBarCache.get(key);
            if(lastDailyBar!==undefined)
                ltp=lastDailyBar.close;
            
            let bars = chartApp.tvWidget.chart().getSeries().data().bars()._items;
            if (bars.length >1) {
                let bar1 = bars[bars.length - 1].value[4]
                let bar2 = bars[bars.length - 2].value[4]
                if (bar1 && bar2) {
                    ch = bar1 - bar2
                    chp = (ch / bar2) * 100
                }
            }
            
            return {
                n: ticker,
                s: "ok",
                v:{
                    ask:ltp,
                    bid:ltp,
                    ch:ch,
                    chp:chp
                }
            }
        }
    }

    // Candles a gap in live ticks leaves behind (app backgrounded, feed dropped).
    //
    // A tick only extends the last bar or opens the next one, so after a gap the chart jumps from
    // the last bar to the tick's and every bar in between is missing. History is the only place those
    // bars exist; setHistorySource says how to ask it. The library refuses a bar older than its last
    // one, so the missing bars must be fed before a tick jumps past them: a tick that skips at least
    // one whole bar is held back while they are fetched, then applied. If history is slow, empty or
    // fails, held ticks are applied exactly as they were before this existed.
    const gap = {
        // How long a tick that opens a gap waits for history.
        timeoutMs: 3000,
        // How long a fill the host asked for waits for history.
        hostTimeoutMs: 10000,
        // After a tick-triggered fill, ticks that open a gap are applied as before for this long, so a
        // server that cannot close the gap is asked once rather than on every tick.
        cooldownMs: 20000,
        // More new bars than this are not fed one by one; the caller is told 'too-large'.
        maxFeed: 1000,
        // Ticks kept per subscription while a fill runs; the oldest are dropped beyond it.
        maxHeld: 500,
        now: () => Date.now(),
    };
    //(ticker, resolution, fromSec, toSec, countBack) => Promise<bars>, set by the datafeed.
    let _historySource = null;
    //Map ticker_resolution its latest fill result, for probes.
    const _fills = new Map();

    stream.gap = gap;
    stream.data.fills = _fills;
    // Called with the fill's result when a fill could not close the gap, so the host can fall back to
    // loading the page again. See report(). Set by main.js; optional.
    stream.onGapNotClosed = null;
    stream.setHistorySource = function (source) {
        _historySource = typeof source === 'function' ? source : null;
    };

    function withTimeout(call, ms) {
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error(`history did not answer within ${ms} ms`)), ms);
            let pending;
            try {
                pending = Promise.resolve(call());
            } catch (err) {
                clearTimeout(timer);
                reject(err);
                return;
            }
            pending.then(
                value => { clearTimeout(timer); resolve(value); },
                err => { clearTimeout(timer); reject(err); });
        });
    }

    const isNumber = value => typeof value === 'number' && Number.isFinite(value);

    // Feeds what history returned into the subscription, from its current last bar onwards.
    function feed(item, raw, startedAt) {
        const outcome = (status, extra) => ({
            status, ticker: item.ticker, resolution: item.resolution, ms: gap.now() - startedAt, ...extra
        });
        // The last bar as of now, not as of the request: ticks may have moved it while history was out.
        const last = item.lastDailyBar;
        if (!last) return outcome('no-bar');

        // The server answers an empty window with older bars, so only bars from the last one onwards count.
        const byTime = new Map();
        for (const bar of Array.isArray(raw) ? raw : []) {
            if (bar && isNumber(bar.time) && bar.time >= last.time &&
                isNumber(bar.open) && isNumber(bar.high) && isNumber(bar.low) && isNumber(bar.close)) {
                byTime.set(bar.time, bar);
            }
        }
        const bars = Array.from(byTime.values()).sort((a, b) => a.time - b.time);
        if (bars.length === 0) return outcome('nothing-new', {fetched: 0});
        if (bars.length > gap.maxFeed) return outcome('too-large', {fetched: bars.length});

        let toFeed = bars;
        if (bars[0].time === last.time) {
            if (bars.length > 1) {
                // Later bars exist, so the last one is closed and history's version is the final one.
                toFeed = bars;
            } else if (bars[0].high > last.high || bars[0].low < last.low) {
                // Still the current bar. Ticks lost while away may have moved its range; widen it and
                // keep what ticks established.
                toFeed = [{
                    ...last,
                    high: Math.max(last.high, bars[0].high),
                    low: Math.min(last.low, bars[0].low),
                }];
            } else {
                return outcome('nothing-new', {fetched: 1});
            }
        }

        for (const bar of toFeed) {
            item.lastDailyBar = bar;
            item.handlers.forEach(handler => {
                try {
                    handler.callback(bar);
                } catch (err) {
                    logger.warn(`exception feeding a missing bar: ${item.ticker}_${item.resolution}`, err);
                }
            });
        }
        stream.saveBar(item.ticker, item.resolution, {...item.lastDailyBar});
        return outcome('filled', {fetched: bars.length, fed: toFeed.length, toMs: item.lastDailyBar.time});
    }

    // Tells the host a fill could not close the gap, once per fill. 'too-large' always: nothing a retry
    // does changes it. 'failed' only when the host asked for the fill; a fill a tick started failing
    // (slow or erroring history) is routine, and the held tick has already been applied as before.
    function report(result, byHost) {
        const reportable = result.status === 'too-large' || (byHost && result.status === 'failed');
        if (!reportable || typeof stream.onGapNotClosed !== 'function') return;
        try {
            stream.onGapNotClosed(result);
        } catch (err) {
            logger.warn('exception in onGapNotClosed', err);
        }
    }

    // Fetches the bars between the subscription's last bar and now (or untilMs if later) and feeds
    // them. One request per subscription at a time. Never rejects. source is 'host' for a fill the host
    // (or the page becoming visible) asked for and 'tick' for one a tick started.
    function fillGap(item, untilMs, timeoutMs, source) {
        if (item.fill) {
            // A host call that joins a fill a tick started still wants to hear if it failed.
            if (source === 'host') item.fillByHost = true;
            return item.fill;
        }
        const quick = status =>
            Promise.resolve({status, ticker: item.ticker, resolution: item.resolution, ms: 0});
        const last = item.lastDailyBar;
        const interval = getFixedIntervalMs(item.resolution);
        if (!_historySource) return quick('no-source');
        if (!last) return quick('no-bar');
        if (!interval) return quick('unsupported');
        const startedAt = gap.now();
        const until = Math.max(startedAt, untilMs || 0);
        // The bar the last one belongs to has not ended yet: nothing can be missing.
        if (until < last.time + interval) return quick('current');

        const fromSec = Math.floor(last.time / 1000);
        const toSec = Math.ceil((until + interval) / 1000);
        const countBack = Math.min(Math.ceil((until - last.time) / interval) + 1, gap.maxFeed);
        const record = withTimeout(
            () => _historySource(item.ticker, item.resolution, fromSec, toSec, countBack), timeoutMs)
            .then(
                raw => feed(item, raw, startedAt),
                err => ({
                    status: 'failed', ticker: item.ticker, resolution: item.resolution,
                    ms: gap.now() - startedAt, error: String((err && err.message) || err)
                }))
            .then(result => {
                if (item.fill === record) item.fill = null;
                _fills.set(`${item.ticker}_${item.resolution}`, result);
                const byHost = source === 'host' || item.fillByHost === true;
                item.fillByHost = false;
                report(result, byHost);
                return result;
            });
        item.fill = record;
        return record;
    }

    // Whether a tick at tradeTime skips at least one whole bar after the subscription's last one.
    function opensGap(item, tradeTime) {
        const last = item.lastDailyBar;
        const interval = getFixedIntervalMs(item.resolution);
        return !!(_historySource && last && interval &&
            gap.now() >= (item.noGapFillUntil || 0) &&
            tradeTime >= last.time + 2 * interval);
    }

    function release(item, held) {
        if (item.held !== held) return;
        clearTimeout(held.timer);
        item.held = null;
        item.noGapFillUntil = gap.now() + gap.cooldownMs;
        held.ticks.forEach(tick => {
            try {
                applyTick(item, ...tick);
            } catch (err) {
                logger.warn(`exception applying a held tick: ${item.ticker}_${item.resolution}`, err);
            }
        });
    }

    function startHold(item, tick, tradeTime) {
        const held = {ticks: [tick], timer: null};
        item.held = held;
        const done = () => release(item, held);
        // A fill the host started earlier may have a longer timeout than a tick should wait.
        held.timer = setTimeout(done, gap.timeoutMs);
        fillGap(item, tradeTime, gap.timeoutMs, 'tick').then(done, done);
    }

    // Fills the gap on every subscription of ticker (every subscription if omitted). Never rejects;
    // resolves with one result per subscription.
    stream.fillGaps = function (ticker) {
        const items = ticker === undefined
            ? Array.from(_subscriptions.values())
            : stream.getV2(ticker);
        return Promise.all(items.map(item => fillGap(item, 0, gap.hostTimeoutMs, 'host')));
    };

    function applyTick(subscriptionItem, resolution, ltp, close, volume, tradeTime) {
        const lastDailyBar = subscriptionItem.lastDailyBar;
        if (!lastDailyBar || lastDailyBar.close === ltp)
            return;

        if (close !== 0) {
            let ch = ltp - close;
            let chp = ch / close * 100;
            chartApp.quote.publishQuote(subscriptionItem.ticker, ch, chp);
        }
        try {
            const nextBarTime = computeNextBarTime(lastDailyBar.time, resolution);
            let bar;
            if (tradeTime >= nextBarTime) {
                bar = {
                    time: tradeTime,
                    open: ltp,
                    high: ltp,
                    low: ltp,
                    close: ltp,
                    volume: 0,
                    firstVolume: volume,
                };
            } else if (tradeTime >= lastDailyBar.time) {
                let tickVolume;
                if (lastDailyBar.firstVolume === undefined) {
                    lastDailyBar.firstVolume = volume;
                    tickVolume = 0;
                } else {
                    tickVolume = (volume ?? 0) - (lastDailyBar.firstVolume ?? 0);
                }
                bar = {
                    ...lastDailyBar,
                    high: Math.max(lastDailyBar.high, ltp),
                    low: Math.min(lastDailyBar.low, ltp),
                    close: ltp,
                    volume: tickVolume,
                };
            } else {
                logger.warn(`tradeTime: ${tradeTime} is less than lastBarTime: ${lastDailyBar.time}`);
                return;
            }
            subscriptionItem.lastDailyBar = bar;
            subscriptionItem.handlers.forEach(handler => handler.callback(bar));
        } catch (err) {
            logger.warn(`exception in stream.onTickReceived: ${subscriptionItem.ticker}_${resolution}`, err);
        }
    }

    stream.onTickReceived = function (ticker, resolution, ltp, close, volume, tradeTime) {
        const subscriptionItems = stream.getV2(ticker, resolution);
        subscriptionItems.forEach((subscriptionItem) => {
            if (subscriptionItem === undefined)
                return;

            const tick = [resolution, ltp, close, volume, tradeTime];
            if (subscriptionItem.held) {
                subscriptionItem.held.ticks.push(tick);
                if (subscriptionItem.held.ticks.length > gap.maxHeld) subscriptionItem.held.ticks.shift();
                return;
            }
            if (opensGap(subscriptionItem, tradeTime)) {
                startHold(subscriptionItem, tick, tradeTime);
                return;
            }
            applyTick(subscriptionItem, ...tick);
        });
    }

    stream.UpdateAskAndBidValues=function (ticker,ask,bid){
        chartApp.quote.publishQuote(ticker, 0, 0,ask,bid)
    }

    function computeNextBarTime(barTime, timeframe) {
        const oneSecond = 1000;
        const oneMinute = 60 * 1000;
        const oneHour = 60 * oneMinute;
        const oneDay = 24 * oneHour;
        const oneWeek = 7 * oneDay;
        const date = new Date(barTime);
        if (timeframe.toUpperCase().endsWith('S')) {
            date.setMilliseconds(0);
        } else {
            date.setSeconds(0, 0);
        }
        switch (timeframe.toUpperCase()) {
            case "5S":
                date.setTime(date.getTime() + 5 * oneSecond);
                break;
            case "15S":
                date.setTime(date.getTime() + 15 * oneSecond);
                break;
            case "30S":
                date.setTime(date.getTime() + 30 * oneSecond);
                break;
            case "1":
                date.setTime(date.getTime() + oneMinute);
                break;
            case "3":
                date.setTime(date.getTime() + 3 * oneMinute);
                break;
            case "5":
                date.setTime(date.getTime() + 5 * oneMinute);
                break;
            case "10":
                date.setTime(date.getTime() + 10 * oneMinute);
                break;
            case "15":
                date.setTime(date.getTime() + 15 * oneMinute);
                break;
            case "30":
                date.setTime(date.getTime() + 30 * oneMinute);
                break;
            case "60":
                date.setTime(date.getTime() + oneHour);
                break;
            case "1D":
            case "D":
                date.setTime(date.getTime() + oneDay);
                break;
            case "1W":
            case "W":
                date.setTime(date.getTime() + oneWeek);
                break;
            case "1M":
            case "M":
                date.setMonth(date.getMonth() + 1);
                break;
            default:
                if (timeframe.toUpperCase().endsWith('S')) {
                    date.setTime(date.getTime() + parseInt(timeframe) * oneSecond);
                } else {
                    date.setTime(date.getTime() + parseInt(timeframe) * oneMinute);
                }
                break;
        }
        return date.getTime();
    }

    // Fixed duration in ms for a resolution, or null for calendar-based ones (e.g. "1M")
    // whose length varies, and which computeNextBarTime must step through instead.
    function getFixedIntervalMs(timeframe) {
        const oneSecond = 1000;
        const oneMinute = 60 * oneSecond;
        const oneHour = 60 * oneMinute;
        const oneDay = 24 * oneHour;
        const oneWeek = 7 * oneDay;
        switch (timeframe.toUpperCase()) {
            case "5S":
                return 5 * oneSecond;
            case "15S":
                return 15 * oneSecond;
            case "30S":
                return 30 * oneSecond;
            case "1":
                return oneMinute;
            case "3":
                return 3 * oneMinute;
            case "5":
                return 5 * oneMinute;
            case "10":
                return 10 * oneMinute;
            case "15":
                return 15 * oneMinute;
            case "30":
                return 30 * oneMinute;
            case "60":
                return oneHour;
            case "1D":
            case "D":
                return oneDay;
            case "1W":
            case "W":
                return oneWeek;
            case "1M":
            case "M":
                return null;
            default:
                return timeframe.toUpperCase().endsWith('S')
                    ? parseInt(timeframe) * oneSecond
                    : parseInt(timeframe) * oneMinute;
        }
    }

    // Latest bar boundary at or before tradeTime, anchored to lastBarTime's own grid
    // (not midnight) so it stays aligned across session/day gaps without drifting
    // and without stepping through every interval one tick at a time.
    function getBarTimeForTick(lastBarTime, timeframe, tradeTime) {
        const intervalMs = getFixedIntervalMs(timeframe);
        if (intervalMs) {
            const steps = Math.floor((tradeTime - lastBarTime) / intervalMs);
            return lastBarTime + steps * intervalMs;
        }
        // Variable-length interval (calendar month) - step forward one period at a time;
        // bounded by the number of months elapsed, never by minutes/seconds.
        let barTime = lastBarTime;
        let next = computeNextBarTime(barTime, timeframe);
        while (next <= tradeTime) {
            barTime = next;
            next = computeNextBarTime(barTime, timeframe);
        }
        return barTime;
    }

    stream.computeNextBarTime = computeNextBarTime;

    chartApp.stream = stream;
})(window, ChartApp);