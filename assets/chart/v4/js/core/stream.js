(function (window, chartApp) {
    const logger = log.getLogger("stream");
    //Map of ticker and its last bar
    const _lastBarCache = new Map();
    //Map of ticker_resolution and its subscriptionItem
    const _subscriptions = new Map();

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
                resolution,
                lastDailyBar,
                handlers: [handler],
            };
            _subscriptions.set(key, subscriptionItem);
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
                        break;
                    }
                }
            }
            logger.debug("Subscription Map :", _subscriptions.keys());
        },
        get: function (ticker, resolution) {
            return _subscriptions.get(`${ticker}_${resolution}`);
        },
        getV2:function (ticker){
            return Array.from(_subscriptions.entries())
                .filter(([key, _]) => key.startsWith(ticker))
                .map(([_, value]) => value);
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

    stream.onTickReceived = function (ticker, resolution, ltp, close, volume, tradeTime) {
        const subscriptionItems = stream.getV2(ticker, resolution);
        subscriptionItems.forEach((subscriptionItem) => {
            if (subscriptionItem === undefined)
                return;

            const lastDailyBar = subscriptionItem.lastDailyBar;
            if (!lastDailyBar || lastDailyBar.close === ltp)
                return;

            if (close !== 0) {
                let ch = ltp - close;
                let chp = ch / close * 100;
                chartApp.quote.publishQuote(ticker, ch, chp);
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
                        tickVolume = (volume ?? 0) - (lastDailyBar?.firstVolume ?? 0);
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
                logger.warn(`exception in stream.onTickReceived: ${ticker}_${resolution}`, err);
            }
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