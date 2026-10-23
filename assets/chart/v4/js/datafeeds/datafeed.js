(function (window, chartApp) {
    const logger = log.getLogger("data-feed");

    const _dataMap = new Map();
    //Map of guid and ticker
    const _guidTickerMap = new Map();
    //Map of ticker and its callback set in 'subscribeQuotes'
    const _subscriptions = new Map();

    const _searchQueryMap = new Map();


    //Expose data maps.
    const quote = {
        data: {
            _dataMap: _dataMap,
            _guidTickerMap: _guidTickerMap,
            _subscriptions: _subscriptions
        },
        saveQuote: function (ticker, resolution, ch, chp) {
            _dataMap.set(`${ticker}_${resolution}`, {
                n: ticker,
                s: "ok",
                v: {
                    ch: ch,
                    chp: chp,
                }
            })
        },
        getQuote: function (ticker, resolution) {
            return _dataMap.get(`${ticker}_${resolution}`)
        },
        subscribe: function (ticker, guid, callback) {
            _guidTickerMap.set(guid, ticker);
            _subscriptions.set(ticker, callback);
        },
        unsubscribe: function (guid) {
            const ticker = _guidTickerMap.get(guid);
            _subscriptions.delete(ticker);
        },
        get: function (ticker) {
            return _subscriptions.get(ticker);
        },
        reRenderLastQuote: function (ticker, resolution) {
            let data = chartApp.stream.getQuote(ticker, resolution);
            if (data) {
                this.publishQuote(ticker, data.v.ch, data.v.chp)
            } else {
                logger.debug('No quote data')
            }
        },
        publishQuote: function (ticker, ch, chp, ask, bid) {
            logger.debug('publishQuote', ticker, `ch:${ch} chp:${chp}`)
            try {
                const data = [{
                    n: ticker,
                    s: "ok",
                    v: {
                        ask: ask,
                        bid: bid,
                        ch: ch,
                        chp: chp,
                    }
                }];
                const callback = this.get(ticker);
                if (callback) {
                    callback(data);
                }
            } catch (err) {
                logger.warn(`exception in quote.publishQuote: ${ticker}`, err)
                //chartApp.LogException('', 'quote/publishQuote', `${err.stack}, symbol: ${ticker} ,ch: ${ch}, chp: ${chp}`)
            }
        }
    }
    chartApp.quote = quote;

    const httpAdapter = chartApp.adapter.chartHttp;
    let ticker;
    let searchQuery;


    const datafeed = {
        onReady: cb => {
            logger.debug('[onReady]: Method call');
            httpAdapter.config().then(data => {
                    cb(data);
                }
            ).catch(err => {
                //This case should never happen
                logger.error("onReady failed: " + err)
                chartApp.showError('tv_chart_container', "Something went wrong. Please try again.");
            })
        },
        resolveSymbol: (symbolName, onSymbolResolvedCallback, onResolveErrorCallback) => {
            logger.debug('[resolveSymbol]: Method call', symbolName);
            if (symbolName.startsWith("undefined:")) {
                symbolName = ticker;
            }

            httpAdapter.symbolInfo(symbolName).then(data => {
                ticker = data.ticker
                onSymbolResolvedCallback(data)
            }).catch(err => {
                chartApp.channel.sendChartStatus('resolveSymbol', symbolName);
                onResolveErrorCallback(new Error("Symbol Not Found"));
            })
        },
        getBars: (symbolInfo, resolution, periodParams, onHistoryCallback, onErrorCallback) => {
            const ticker = symbolInfo.ticker;
            logger.debug('[getBars]: Method call', ticker, resolution, periodParams);
            httpAdapter.getData(ticker, resolution, periodParams.from, periodParams.to, periodParams.countBack, periodParams.firstDataRequest)
                .then(bars => {
                    if (periodParams.firstDataRequest && bars.length > 0) {
                        const last2Raw = bars.slice(-2).map(b => ({...b, timeISO: new Date(b.time).toISOString()}));
                        console.log(`[getBars] last 2 raw API bars for ${ticker}_${resolution}:`, last2Raw);
                        let lastBar = bars[bars.length - 1];
                        if (bars.length > 1) {
                            const prevBar = bars[bars.length - 2];
                            // Resolution comes from TradingView as a string (e.g. "1", "5", "D").
                            // Convert to milliseconds so we can compare against bar time diffs.
                            const resolutionMs = (function (res) {
                                if (typeof res !== 'string') return Number(res) * 60 * 1000;
                                const r = res.toUpperCase();
                                if (r.endsWith('D')) return (parseInt(r, 10) || 1) * 24 * 60 * 60 * 1000;
                                if (r.endsWith('W')) return (parseInt(r, 10) || 1) * 7 * 24 * 60 * 60 * 1000;
                                if (r.endsWith('M')) return (parseInt(r, 10) || 1) * 30 * 24 * 60 * 60 * 1000;
                                if (r.endsWith('S')) return (parseInt(r, 10) || 1) * 1000;
                                return (parseInt(r, 10) || 1) * 60 * 1000; // minutes
                            })(resolution);

                            const diff = lastBar.time - prevBar.time;
                            // If the gap doesn't match the resolution interval, the last bar's time
                            // is misaligned (stamped from the last tick instead of the period start).
                            // Snap it to the grid anchored on prevBar, keeping its OHLCV so we don't
                            // lose the latest price/volume. If no full period has elapsed yet, fall
                            // back to prevBar as before.
                            if (diff !== resolutionMs) {
                                const steps = Math.floor(diff / resolutionMs);
                                lastBar = steps > 0
                                    ? { ...lastBar, time: prevBar.time + steps * resolutionMs }
                                    : prevBar;
                            }
                        }
                        console.log(`Last bar set for ${ticker}_${resolution}: barTime: ${lastBar.time}, close: ${lastBar.close}`);
                        // Keep the array we hand to the chart in sync with the (possibly snapped)
                        // lastBar — otherwise the chart library caches the raw, unsnapped time as
                        // its "current" bar while the stream computes live updates off the
                        // corrected time, and every subsequent tick gets rejected as a time
                        // violation by the library's own monotonic-time check.
                        bars[bars.length - 1] = lastBar;
                        chartApp.stream.saveBar(ticker, resolution, {
                            ...lastBar,
                        });
                        datafeed.renderQuoteData(ticker, resolution, bars)
                    }
                    onHistoryCallback(bars, {noData: false})
                    httpAdapter.AddBuySellButton(chartApp.config.isMobileApp)
                }).catch(err => {
                logger.error('getBars failed: ' + err)
                onHistoryCallback([], {noData: true})
                if (err.message.includes('StatusCode:204') || err.message.includes('StatusCode:500')) {
                    return;
                }

                // if(err.message.includes('StatusCode:401')){
                //     httpAdapter.ShowRiseAppRefreshPagePopUpForWeb();
                // }
                // chartApp.LogException('401', 'getBars', err.message, '', resolution, ticker, periodParams.from, periodParams.to);
            });
        },
        subscribeBars: (symbolInfo, resolution, onRealtimeCallback, subscriberUID, onResetCacheNeededCallback) => {
            const ticker = symbolInfo.ticker;
            logger.debug('[subscribeBars]: Method call', ticker, resolution, subscriberUID);
            chartApp.stream.subscribe(ticker, resolution, subscriberUID, onRealtimeCallback)
        },
        unsubscribeBars: (subscriberUID) => {
            logger.debug('[unsubscribeBars]: Method call', subscriberUID);
            chartApp.stream.unsubscribe(subscriberUID);
        },
        getQuotes: (symbols, onDataCallback, onErrorCallback) => {
            logger.debug('[getQuotes]: Method call', symbols);
            const data = symbols.map((n, s) => {
                return chartApp.stream.getQuote(n, chartApp.tvWidget.chart().resolution())
            })
            setTimeout(() => onDataCallback(data))
            httpAdapter.AddBuySellButton(chartApp.config.isMobileApp)
        },
        subscribeQuotes: (symbols, fastSymbols, onRealtimeCallback, listenerGUID) => {
            logger.debug('[subscribeQuotes]: Method call', symbols, listenerGUID);
            for (let i = 0; i < symbols.length; i++) {
                quote.subscribe(symbols[i], listenerGUID, onRealtimeCallback);
            }
        },
        unsubscribeQuotes: (listenerGUID) => {
            logger.debug('[unsubscribeQuotes]: Method call', listenerGUID);
            quote.unsubscribe(listenerGUID);
        },
        searchSymbols: (userInput, exchange, symbolType, SearchSymbolsCallback) => {
            if (userInput.length < 2)
                return;

            userInput = userInput.toUpperCase()
            let filterData;
            if (searchQuery === userInput) {
                let data = _searchQueryMap.get(userInput)
                if (symbolType !== "")
                    filterData = data.filter(item => item.type.toUpperCase() === symbolType.toUpperCase())
                else
                    filterData = data;

                SearchSymbolsCallback(filterData);
                return;
            }
            searchQuery = userInput;
            _searchQueryMap.clear();

            httpAdapter.Search(userInput).then(data => {
                _searchQueryMap.set(userInput, data)
                if (symbolType !== "")
                    filterData = data.filter(item => item.type.toUpperCase() === symbolType.toUpperCase())
                else
                    filterData = data;
                SearchSymbolsCallback(filterData);
            }).catch(err => {
                // if(err.message.includes('StatusCode:401')){
                //     httpAdapter.ShowRiseAppRefreshPagePopUpForWeb();
                // }
                logger.error('searchSymbols failed: ' + err)
            })

        },
        //Custom method impl
        renderQuoteData: (ticker, resolution, bars) => {
            let ch = 0;
            let chp = 0;
            let ltp = 0;
            if (bars) {
                let bar1 = bars[bars.length - 1];
                let bar2 = bars[bars.length - 2];
                if (bar1 && bar2) {
                    ch = bar1.close - bar2.close;
                    chp = (ch / bar2.close) * 100;
                }
                ltp = bar1.close
            }

            quote.publishQuote(ticker, ch, chp, ltp, ltp);
        }
    };

    chartApp.datafeed = datafeed;
})(window, ChartApp);