(function (window, document, chartApp) {
    const chartConfig = {
        "supported_resolutions": [
            "1",
            "3",
            "5",
            "15",
            "30",
            "60",
            "D",
            "W",
            "M"
        ],
        "supports_group_request": false,
        "supports_marks": false,
        "supports_search": false,
        "supports_timescale_marks": false,
        "supports_time": false,
        /* "exchanges":
             [
                 {
                     "desc": "",
                     "name": "All Exchanges",
                     "value": ""
                 },
                 {
                     "desc": "NSE",
                     "name": "NSE",
                     "value": "NSE"
                 },
                 {
                     "desc": "BSE",
                     "name": "BSE",
                     "value": "BSE"
                 }
             ],*/
        "symbols_types": [
            {
                "name": "All types",
                "value": ""
            },
            {
                "name": "Stock",
                "value": "stock"
            },
            {
                "Name": "Options",
                "Value": "options"
            },
            {
                "Name": "Futures",
                "Value": "futures"
            }
        ]
    };

    const hvtChartConfig = {
        "supported_resolutions": [
            "1",
            "3",
            "5",
            "15",
            "30",
            "60",
            "D",
            "W",
            "M",
            "10"
        ],
        "supports_group_request": false,
        "supports_marks": false,
        "supports_search": false,
        "supports_timescale_marks": false,
        "supports_time": false,
        /* "exchanges":
             [
                 {
                     "desc": "",
                     "name": "All Exchanges",
                     "value": ""
                 },
                 {
                     "desc": "NSE",
                     "name": "NSE",
                     "value": "NSE"
                 },
                 {
                     "desc": "BSE",
                     "name": "BSE",
                     "value": "BSE"
                 }
             ],*/
        "symbols_types": [
            {
                "name": "All types",
                "value": ""
            },
            {
                "name": "Stock",
                "value": "stock"
            },
            {
                "Name": "Options",
                "Value": "options"
            },
            {
                "Name": "Futures",
                "Value": "futures"
            }
        ]
    };

    const twsChartTvConfig = {
        "supported_resolutions": [
            "1",
            "3",
            "5",
            "15",
            "30",
            "60",
            "D",
            "W",
            "M"
        ],
        "supports_group_request": false,
        "supports_marks": false,
        "supports_search": false,
        "supports_timescale_marks": false,
        "supports_time": false,
        /* "exchanges":
             [
                 {
                     "desc": "",
                     "name": "All Exchanges",
                     "value": ""
                 },
                 {
                     "desc": "NSE",
                     "name": "NSE",
                     "value": "NSE"
                 },
                 {
                     "desc": "BSE",
                     "name": "BSE",
                     "value": "BSE"
                 }
             ],*/
        "symbols_types": [
            {
                "name": "All types",
                "value": ""
            },
            {
                "name": "Stock",
                "value": "stock"
            },
            {
                "Name": "Options",
                "Value": "options"
            },
            {
                "Name": "Futures",
                "Value": "futures"
            }
        ]
    };

    prefix.reg(log);
    prefix.apply(log, {template: '%l (%n):'});

    //#region localStorage keys
    chartApp.keys = {
        AppVersion: 'chart.appVersion',
        ChartSavedLayouts: 'chart.data.layouts',
        ChartSavedTemplates: 'chart.data.templates',
        ChartSettings: 'chart.data.settings',
        ChartSelectedInterval: 'chart.user.selectedInterval',
        ChartCurrentTheme: 'chart.user.theme',
        AccessToken: 'chart.user.token',
        OldAccessToken: 'chart.user.oldToken',
    };
    //#endregion
    const riseAppMobileConfig = {
        "supported_resolutions": [
            "5S", "15S", "30S",
            "1", "3", "5", "15", "30", "60",
            "D", "W", "M"
        ],
        "supports_group_request": false,
        "supports_marks": false,
        "supports_search": false,
        "supports_timescale_marks": false,
        "supports_time": false,
        "symbols_types": [
            {"name": "All types", "value": ""},
            {"name": "Stock", "value": "stock"},
            {"Name": "Options", "Value": "options"},
            {"Name": "Futures", "Value": "futures"}
        ]
    };

    chartApp.config.initialConfig = chartConfig;
    chartApp.config.hvtInitialConfig = hvtChartConfig;
    chartApp.config.twsInitialConfig = twsChartTvConfig;
    chartApp.config.riseAppMobileInitialConfig = riseAppMobileConfig;



    function getVersionNumber(input) {
        if (input) {
            return parseInt(input.replace('_', ''));
        }
        return 0;
    }

    //#region This will decide whether to clear localStorage or not.
    chartApp.config.shouldClearStorage = function (existingVersion) {
        // oldVersion unavailable - This will be true for:
        // first run
        // or first run after implementing versioning
        // or localStorage got cleared.  
        if (!existingVersion) {
            const oldToken = localStorage.getItem('MainChartSaveToken');
            //return true (to clear cache) if oldToken is available else false.
            return oldToken ? true : false;
        }
        const currentAppVersionNo = getVersionNumber(existingVersion);
        const newAppVersionNo = getVersionNumber(chartApp.config.version);

        //Version downgrade detected
        if (newAppVersionNo < currentAppVersionNo) {
            return true;
        }
        //Version upgrade detected
        if (newAppVersionNo > currentAppVersionNo) {
            return true;
        }

        return newAppVersionNo !== currentAppVersionNo;
    };
    //#endregion

    const currentAppVersion = localStorage.getItem(chartApp.keys.AppVersion);
    if (currentAppVersion) {
        const currentAppVersionNo = getVersionNumber(currentAppVersion);
        const newAppVersionNo = getVersionNumber(chartApp.config.version);
        if (newAppVersionNo !== currentAppVersionNo) {
            log.info(`ChartApp Migrated from ${currentAppVersion} to ${chartApp.config.version}`);
        } else {
            log.info(`ChartApp Version: ${chartApp.config.version}`);
        }
    } else {
        log.info(`ChartApp Version: ${chartApp.config.version}`);
    }
    if (chartApp.config.shouldClearStorage(currentAppVersion)) {
        log.info('LocalStorage purged');
        localStorage.clear();
        chartApp.config.versionModified = true;
    } else {
        chartApp.config.versionModified = false;
    }
    localStorage.setItem(chartApp.keys.AppVersion, chartApp.config.version);

    //Apply LogLevel
    log.setLevel(chartApp.config.logLevel);

    const channel = {};
    channel.sendPageReady = function (version) {
        pushMessage({
            context: 'PageReady',
            success: {
                source: version,
                resetCache: chartApp.config.versionModified || false
            }
        });
    }
    channel.sendChartStatus = function (from, ticker, theme) {
        const symbol = chartApp.data.tickerSymbolMap.get(ticker) || ticker;
        const symbolInfo = chartApp.data.symbolInfoMap.get(ticker);
        const tvWidget = chartApp.tvWidget;
        if (tvWidget) {
            const chart = tvWidget.chart();
            const symbolExt = chart.symbolExt()
            //TODO Need to verify thoroughly - this may give error when changing timeframe
            const barCount = chart.getSeries().data().bars()._items.length;

            let reason = "Success"
            if (symbolExt == null || symbolInfo == null) {
                reason = 'SymbolNotFound';
            } else if (barCount === 0) {
                reason = 'DataNotAvailable';
            }
            if (reason === 'Success') {
                pushMessage({
                    context: 'Chart',
                    success: {
                        source: from,
                        symbol: symbol,
                        theme: theme
                    }
                });
            } else {
                pushMessage({
                    context: 'Chart',
                    error: {
                        source: from,
                        reason: reason,
                        symbol: symbol,
                    }
                });
            }
        }
    }
    // A fill of the candles live ticks missed could not close the gap (reason 'too-large' or
    // 'failed'). Same envelope as sendError, which the host already parses; the host then decides
    // whether to load the page again.
    channel.sendGapFill = function (status, ticker) {
        pushMessage({
            context: 'GapFill',
            error: {
                source: 'stream',
                reason: status,
                symbol: chartApp.data.tickerSymbolMap.get(ticker) || ticker,
            }
        });
    }
    channel.sendError = function (context, source, message, symbol) {
        pushMessage({
            context: context,
            error: {
                source: source,
                reason: message,
                symbol: symbol,
            }
        });
    }
    
    channel.SendPageReadySymbols=function(){
        let openedSymbols = [];
        if (ChartApp.tvWidget && ChartApp.tvWidget._ready) {
            let chartCount = ChartApp.tvWidget.chartsCount();
            for (let i = 0; i < chartCount; i++) {
                try {
                    let chart = chartApp.tvWidget.chart(i);
                    let ticker = chart.symbol();
                    let symbolInfo=chartApp.data.symbolInfoMap.get(ticker);
                    let scripCode;
                    let exchangeCode;
                    let isIndex = false;
                    
                    if(symbolInfo.ticker.startsWith('IDX')){
                        isIndex = true;
                        const parts = symbolInfo.ticker.split(':');
                        scripCode = parts[parts.length - 1];
                        exchangeCode = symbolInfo.exchangeCode;
                    }else{
                        scripCode = symbolInfo.scripCode;
                        exchangeCode = symbolInfo.exchangeCode;
                    }
                    

                    openedSymbols.push({
                        scripCode:scripCode,
                        exchangeCode:exchangeCode,
                        isIndex:isIndex
                    });
                } catch (err) {
                    log.warn(`Error getting symbol for chart ${i}:`, err);
                }
            }
        }
        if(chartApp.config.isMobileApp){
            channel.sendMobileEvents('pageReadySymbols',openedSymbols)
        }
        else{
            window.parent.postMessage({
                name: 'pageReadySymbols',
                data: openedSymbols,
            }, '*')
        }
    }
    channel.sendMobileEvents=function(eventName,data){
        pushMessage({
            event: eventName,
            data: data
        })
    }
    chartApp.channel = channel;

    function pushMessage(message) {
        const strMessage = (typeof message === "object") ? JSON.stringify(message) : message;
        const appDelegate = window.ChartAppDelegate;
        if (appDelegate) {
            appDelegate.postMessage(strMessage);
        } else {
            log.info('ChartAppDelegate not available, message skipped :', strMessage)
        }
    }

    chartApp.showError = function (containerId, message) {
        let container = document.getElementById(containerId);
        container.style.color = 'grey'
        container.style.fontSize = '20px'
        container.style.textAlign = 'Center'
        container.innerHTML = message;
    }

    //Data object to keep track of all data-maps
    const data = {};
    //Map of symbol and symbolInfo, ticker and symbolInfo
    data.symbolInfoMap = new Map();
    data.tickerSymbolMap = new Map();
    chartApp.data = data;

    //#region $http function is implemented in order to follow the standard Adapter pattern
    function $http(path, headers, params) {
        const baseUrl = "api/";
        params = params || {};
        const query = Object.keys(params)
            .map(name => `${name}=${encodeURIComponent(params[name])}`)
            .join('&');
        const callUrl = query.length > 0 ? `${baseUrl}${path}?${query}` : `${baseUrl}${path}`;
        return fetchWith401Retry(callUrl, {
            headers: headers
        }).then(response => {
            if (response.status === 200) {
                return response.json()
            } else if (response.status === 401) {
                chartApp.channel.sendError('Api', path, `${response.status}`, params.symbol);
                chartApp.LogException('401', 'GET ' + callUrl, 'Unauthorized access', null, null, null, null);
                throw new Error(`ApiError:StatusCode:${response.status}`)
            }
            throw new Error(`No Data Found, StatusCode:${response.status}`)
        })
    }
    //#endregion


    const adapter = {};
    //#region Adapter for localStorage
    adapter.localStorageAdapter = function () {
        const storage = window.localStorage;
        this.accessToken = function () {
            return storage.getItem(chartApp.keys.AccessToken);
        };

        this.oldAccessToken = function () {
            return storage.getItem(chartApp.keys.OldAccessToken);
        };

        this.saveToken = function (token) {
            return storage.setItem(chartApp.keys.AccessToken, token);
        };
        this.saveOldToken = function (token) {
            return storage.setItem(chartApp.keys.OldAccessToken, token);
        };

        this.apiKey = function () {
            return storage.getItem(chartApp.adminChart.keys.ApiKey);
        };

        this.saveApiKey = function (apiKey) {
            return storage.setItem(chartApp.adminChart.keys.ApiKey, apiKey);
        };

        this.theme = function () {
            return storage.getItem(chartApp.keys.ChartCurrentTheme);
        };

        this.saveTheme = function (theme) {
            return storage.setItem(chartApp.keys.ChartCurrentTheme, theme);
        };
    };
    //#endregion

    adapter.localStore = new adapter.localStorageAdapter();

    adapter.httpAdapter = function (purpose) {
        const symbolInfoMap = chartApp.data.symbolInfoMap;
        const localStore = adapter.localStore;

        function _callApi(path, params) {
            if (purpose === 'adminChart') {
                return $http(`ResearchChart/${path}`, {
                    'x-api-key': localStore.apiKey()
                }, params)
            }
            return $http(`Chart/${path}`, {
                'Authorization': `Bearer ${localStore.accessToken()}`
            }, params)
        }

        //#region Config,Symbols,HistoryV3,Search,GetToday1DayData
        // Assumes localStore and fetchWith401Retry are available in scope

        this.config = async function () {
            try {
                const configPage = chartApp.config.page === "RiseApp_Mobile.html" ? "RiseApp_Mobile_V4.html" : chartApp.config.page;
                let response = (await preloaded('config', configPage, 60000)) || await fetchWith401Retry(`api/Chart/Config?page=${configPage}`, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                });
                if (response.status === 200) {
                    return await response.json();
                }
                if(chartApp.config.page==="HVTChart.html"){
                    return chartApp.config.hvtInitialConfig;
                }
                if(chartApp.config.page==="TwsChart.html"){
                    return chartApp.config.twsInitialConfig;
                }
                if(chartApp.config.page==="RiseApp_Mobile.html"){
                    return chartApp.config.riseAppMobileInitialConfig;
                }
                return chartApp.config.initialConfig;
            } catch (err) {
                if(chartApp.config.page==="HVTChart.html"){
                    return chartApp.config.hvtInitialConfig
                }
                if(chartApp.config.page==="RiseApp_Mobile.html"){
                    return chartApp.config.riseAppMobileInitialConfig
                }
                return chartApp.config.initialConfig;
            }
        }

        this.symbolInfo = async function (symbol) {
            const symbolInfo = symbolInfoMap.get(symbol);
            if (symbolInfo) {
                return symbolInfo;
            }
            let response = (await preloaded('symbols', symbol, 60000)) || await fetchWith401Retry(`api/Chart/Symbols?symbol=${encodeURIComponent(symbol)}`, {
                method: 'GET',
                headers: {
                    'Authorization': `Bearer ${localStore.accessToken()}`
                }
            });
            if (response.status === 200) {
                let data = await response.json();
                symbolInfoMap.set(symbol, data);
                symbolInfoMap.set(data.ticker, data);
                chartApp.data.tickerSymbolMap.set(data.ticker, symbol);
                return data;
            }
            throw new Error(`No Data Found, StatusCode:${response.status}`)
        }

        this.getData = async function (ticker, resolution, from, to, countBack, firstDataRequest) {
            const urlParameters = {
                symbol: ticker,
                resolution: resolution,
                from: from,
                to: to,
                countBack: countBack,
                firstDataRequest: firstDataRequest
            };
            const query = Object.keys(urlParameters)
                .map(name => `${name}=${encodeURIComponent(urlParameters[name])}`)
                .join('&');
            let response = (await preloadedHistory({ticker, resolution, from, to, countBack, firstDataRequest})) || await fetchWith401Retry(`api/Chart/HistoryV3?${query}`, {
                method: 'GET',
                headers: {
                    'Authorization': `Bearer ${localStore.accessToken()}`
                }
            });
            if (response.status === 200) {
                let historyData = await response.json();
                if (resolution === "D" || resolution === "1D") {
                    if (urlParameters.firstDataRequest) {
                        let today = new Date(to * 1000);
                        to = Math.floor(today.setDate(today.getDate() + 1) / 1000)
                    }
                }
                const isSecondsResolution = resolution.toUpperCase().endsWith('S');
                return historyData.t
                    .map((value, index) => {
                        let date = new Date(value * 1000);
                        if (!isSecondsResolution) {
                            date.setSeconds(0, 0);
                        } else {
                            date.setMilliseconds(0);
                        }
                        return {
                            time: date.getTime(),
                            low: (historyData.l[index] / historyData.divisor),
                            high: (historyData.h[index] / historyData.divisor),
                            open: (historyData.o[index] / historyData.divisor),
                            close: (historyData.c[index] / historyData.divisor),
                            volume: historyData.v[index]
                        }
                    });
            }
            throw new Error(`No Data Found, StatusCode:${response.status}`)
        }

        this.Search = async function (query) {
            let response = await fetchWith401Retry(`api/Chart/Search?query=${encodeURIComponent(query)}`, {
                method: 'GET',
                headers: {
                    'Authorization': `Bearer ${localStore.accessToken()}`
                }
            });
            if (response.status === 200) {
                let data = await response.json();
                return data.entries;
            }
            throw new Error(`No Data Found, StatusCode:${response.status}`)
        }

        this.getLiveTick = async function (symbol) {
            if (symbol === undefined)
                return;
            let response = await fetchWith401Retry(`api/Chart/GetToday1DayData?id=${encodeURIComponent(symbol)}`, {
                method: 'GET',
                headers: {
                    'Authorization': `Bearer ${localStore.accessToken()}`
                }
            });
            if (response.status === 200) {
                let data = await response.json();
                const tick = data.tick;
                if (tick === null)
                    throw Error("Data Not Available");
                return {
                    o: tick.open / data.divisor,
                    c: tick.close / data.divisor,
                    h: tick.high / data.divisor,
                    l: tick.low / data.divisor,
                    v: tick.volume,
                    t: tick.time
                };
            }
            throw new Error(`No Data Found, StatusCode:${response.status}`)
        }
        //#endregion

        this.logError = function (data) {
            return fetchWith401Retry('../api/Chart/LogJsErrors', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify(data)
            }).then(response => {
                if (response.status === 200) {
                    return response.json();
                }
            }).then(data => log.debug(data))
        }

        //#region Save Chart Layout
        this.saveLayouts = function (data) {
            log.debug(`saveLayouts api called`)
            return fetchWith401Retry('api/chart/SaveLayouts?page=' + chartApp.config.page, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${localStore.accessToken()}`
                },
                body: JSON.stringify(data)
            }).then(res => {
                if (res.status !== 200)
                    throw new Error('Save layout failed, Error Code: ' + res)
                return res.json()
            }).then(data => log.debug(data))
                .catch(ex => {
                    log.error(ex)
                })
        }
        this.getAllLayouts = async function () {
            try {
                log.debug(`getAllLayouts api called`)
                let response = await fetchWith401Retry('api/chart/getAllLayouts?page=' + chartApp.config.page, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                })
                if (response.status === 200) {
                    return await response.json();
                }
                return [];
            } catch (ex) {
                log.error('Error fetching chart layouts', ex);
                return [];
            }
        }
        this.removeChart = function (chartId) {
            log.debug(`removeChart api called ${chartId}`)
            fetchWith401Retry('api/chart/RemoveChartById?id=' + chartId + '&page=' + chartApp.config.page, {
                method: 'GET',
                headers: {
                    'Authorization': `Bearer ${localStore.accessToken()}`
                }
            }).then(resp => {
                if (resp.status === 200) {
                    return resp.json();
                }
            })
                .then(data => log.debug(data))
                .catch(ex => {
                    log.error(ex)
                })
        }
        this.getChartContent = async function (chartId) {
            try {
                log.debug(`getChartContent api called`)
                let response = await fetchWith401Retry('api/chart/GetChartContent?id=' + chartId + '&page=' + chartApp.config.page, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                });
                if (response.status === 200)
                    return await response.json();
                throw new Error('GetChartContent failed, Error Code: ' + response.status)
            } catch (ex) {
                log.error('Error fetching chart layouts', ex);
            }
        }
        //#endregion

        //#region Save Study Template
        this.saveStudyTemplate = function (data) {
            log.debug(`saveStudyTemplate api called`)
            return fetchWith401Retry('api/chart/SaveStudyTemplate?page=' + chartApp.config.page, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${localStore.accessToken()}`
                },
                body: JSON.stringify(data)
            }).then(res => {
                if (res.status !== 200)
                    throw new Error('SaveStudyTemplate failed, Error Code: ' + res)
                return res.json()
            }).then(data => log.debug(data))
                .catch(ex => {
                    log.error(ex)
                })
        }
        this.removeStudyTemplate = function (name) {
            log.debug(`removeStudyTemplate api called, name:  ${name}`)
            const encodedName = encodeURIComponent(name);
            fetchWith401Retry('api/chart/RemoveStudyTemplateByName?name=' + encodedName + '&page=' + chartApp.config.page, {
                method: 'GET',
                headers: {
                    'Authorization': `Bearer ${localStore.accessToken()}`
                }
            }).then(resp => {
                if (resp.status === 200) {
                    return resp.json();
                }
            })
                .then(data => log.debug(data))
                .catch(ex => {
                    log.error(ex)
                })
        }
        this.getStudyTemplateContent = async function (name) {
            try {
                log.debug(`getStudyTemplateContent api called, name:  ${name}`)
                let response = await fetchWith401Retry('api/chart/GetStudyTemplateContent?name=' + name + '&page=' + chartApp.config.page, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                });
                if (response.status === 200) {
                    return await response.json();
                }
                return [];
            } catch (ex) {
                log.error('Error fetching chart Study templates', ex);
            }
        }
        this.getAllStudyTemplates = async function () {
            try {
                log.debug(`getAllStudyTemplates api called`)
                let response = await fetchWith401Retry('api/chart/GetAllStudyTemplates?page=' + chartApp.config.page, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                })
                if (response.status === 200) {
                    return await response.json();
                }
                return [];
            } catch (ex) {
                log.error('Error fetching chart Study templates', ex);
                return [];
            }
        }
        //#endregion

        //#region Save settings
        this.initialSettings = async function () {
            try {
                log.debug(`initialSettings api called`)
                let response = await fetchWith401Retry(`api/Chart/GetInitialSettings?page=` + chartApp.config.page, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                });
                if (response.status === 200) {
                    let settings = await response.json();
                    let initialSettings = {}
                    for (let setting of settings) {
                        initialSettings[`${setting.key}`] = setting.value
                    }
                    return initialSettings;
                }
                return {};
            } catch (ex) {
                log.error('Error fetching settings:', ex);
                return {};
            }
        }
        this.saveSettings = function (key, value) {
            log.debug(`saveSettings api called, key: ${key} ,value: ${value}`)
            fetchWith401Retry('api/Chart/SaveSettings?page=' + chartApp.config.page, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${localStore.accessToken()}`
                },
                body: JSON.stringify({key, value})
            })
                .then(response => {
                    if (response.status === 200) {
                        return response.json();
                    }
                })
                .then(data => log.debug('Settings saved:', data))
                .catch((ex) => {
                    log.error('Error:', ex)
                })
        }
        this.RemoveSettings = function (key) {
            log.debug(`RemoveSettings api called, key: ${key} `)
            fetchWith401Retry('api/Chart/RemoveSettings?page=' + chartApp.config.page, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${localStore.accessToken()}`
                },
                body: JSON.stringify(key)
            })
                .then(response => {
                    if (response.status === 200) {
                        return response.json();
                    }
                })
                .then(data => log.debug('Removed setting:', data))
                .catch((ex) => {
                    log.error('Error:', ex)
                });
        }
        //#endregion

        //#region Save Indicator (not in used)
        this.SaveIndicator = function (name) {
            log.debug(`SaveIndicator api called, name: ${name} `)
            fetchWith401Retry('api/Chart/SaveIndicator?name=' + name + '&page=' + chartApp.config.page, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${localStore.accessToken()}`
                },
            })
                .then(response => {
                    if (response.status === 200) {
                        return response.json();
                    }
                })
                .then(data => log.debug('Settings saved:', data))
                .catch((ex) => {
                    log.error('Error:', ex)
                })
        }
        this.GetAllSavedIndicators = async function () {
            try {
                log.debug(`GetAllSavedIndicators api called`)
                let response = await fetchWith401Retry(`api/Chart/GetAllSavedIndicators?page=` + chartApp.config.page, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                });
                if (response.status === 200) {
                    return await response.json();
                }
                return [];
            } catch (ex) {
                log.error('Error fetching settings:', ex);
                return [];
            }
        }
        //#endregion

        //#region Get Saved chart info
        this.GetChartSavedInfo = async function (symbol) {
            try {
                log.debug(`GetChartSavedInfo api called, symbol: ${symbol}`)
                let response = (await preloaded('savedInfo', symbol + '|' + ChartApp.config.page, 30000)) || await fetchWith401Retry('api/chart/GetChartSavedInfo?symbol=' + symbol +'&page=' + ChartApp.config.page, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                })
                if (response.status === 200) {
                    return await response.json();
                }
                return '';
            } catch (ex) {
                log.error('Error fetching chart layouts', ex);
                return '';
            }
        }
        //#endregion

        //#region Save Interval
        this.SaveInterval = function (interval) {
            log.debug(`SaveInterval api called, interval: ${interval}`)
            fetchWith401Retry('api/Chart/SaveInterval?interval=' + interval + '&page=' + chartApp.config.page, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${localStore.accessToken()}`
                }
            })
                .then(response => {
                    if (response.status === 200) {
                        return response.json();
                    }
                })
                .then(data => log.debug('Interval saved:', data))
                .catch((ex) => {
                    log.error('Error:', ex)
                })
        }
        //#endregion

        //#region Save Chart drawings properties
        this.SaveDrawingProperties = function (toolName, templateName, content) {
            log.debug(`SaveDrawingProperties api called, toolName: ${toolName}`)
            fetchWith401Retry('api/chart/SaveDrawingProperties?page=' + chartApp.config.page, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${localStore.accessToken()}`
                },
                body: JSON.stringify({toolName, templateName, content})
            }).then(res => {
                if (res.status !== 200)
                    throw new Error('SaveDrawingProperties failed, Error Code: ' + res)
                return res.json()
            }).then(data => log.debug(data))
                .catch(ex => {
                    log.error(ex)
                })
        }
        this.RemoveDrawingProperties = function (toolName, templateName) {
            log.debug(`RemoveDrawingProperties api called, toolName: ${toolName}`)
            fetchWith401Retry('api/chart/RemoveDrawingProperties?key=' + `${toolName}_${templateName}` + '&page=' + chartApp.config.page, {
                method: 'Post',
                headers: {
                    'Authorization': `Bearer ${localStore.accessToken()}`
                }
            }).then(resp => {
                if (resp.status !== 200)
                    throw new Error('RemoveDrawingProperties failed, Error Code: ' + resp.status)
                return resp.json()
            })
                .then(data => log.debug(data))
                .catch(ex => {
                    log.error(ex);
                })
        }
        this.GetChartDrawingPropertiesName = async function (toolName) {
            try {
                log.debug(`GetChartDrawingPropertiesName api called, toolName: ${toolName}`)
                let response = await fetchWith401Retry('api/chart/GetChartDrawingPropertiesName?toolName=' + toolName + '&page=' + chartApp.config.page, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                });
                if (response.status === 200) {
                    return await response.json();
                }
                return [];
            } catch (ex) {
                log.error('Error fetching GetDrawingToolNames', ex);
            }
        }
        this.GetDrawingToolContent = async function (toolName, templateName) {
            try {
                log.debug(`GetDrawingToolContent api called, toolName: ${toolName}`)
                let response = await fetchWith401Retry('api/chart/GetDrawingToolContent?key=' + `${toolName}_${templateName}` + '&page=' + chartApp.config.page, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                })
                if (response.status === 200) {
                    return await response.json();
                }
                return '';
            } catch (ex) {
                log.error('Error fetching chart Study templates', ex);
                return '';
            }
        }
        //#endregion

        //#region Save Chart drawings
        this.SaveDrawings = function (symbol, drawings) {
            log.debug(`SaveDrawings api called, symbol: ${symbol}, drawings: ${drawings}`)
            fetchWith401Retry('api/chart/SaveDrawings?page=' + chartApp.config.page, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${localStore.accessToken()}`
                },
                body: JSON.stringify({symbol, drawings})
            }).then(res => {
                if (res.status !== 200)
                    throw new Error('SaveDrawings failed, Error Code: ' + res)
                return res.json()
            }).then(data => log.debug(data))
                .catch(ex => {
                    log.error(ex)
                })
        }
        //#endregion

        //#region Save Chart drawing template
        this.SaveDrawingsTemplates = function (key, state) {
            log.debug(`SaveDrawingsTemplates api called`)
            fetchWith401Retry('api/chart/SaveDrawingsTemplates?page=' + chartApp.config.page, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${localStore.accessToken()}`
                },
                body: JSON.stringify({key, state})
            }).then(res => {
                if (res.status !== 200)
                    throw new Error('SaveDrawingsTemplate failed, Error Code: ' + res)
                return res.json()
            }).then(data => log.debug(data))
                .catch(ex => {
                    log.error(ex)
                })
        }

        this.GetDrawingsTemplates = async function (key) {
            try {
                log.debug(`GetDrawingsTemplates api called`)
                let response = await fetchWith401Retry('api/chart/GetDrawingsTemplates?key=' + key + '&page=' + chartApp.config.page, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                });
                if (response.status === 200) {
                    return await response.json();
                }
                return undefined;
            } catch (ex) {
                log.error('Error fetching Get Drawings Templates', ex);
            }
        }
        //#endregion

        //#region Save Study Properties
        this.RemoveStudyIndicator = async function (key) {
            try {
                log.debug(`RemoveStudyIndicator api called`)
                let response = await fetchWith401Retry('api/chart/RemoveStudyIndicator?key=' + encodeURIComponent(key) + '&page=' + chartApp.config.page, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                });
                if (response.status === 200) {
                    return await response.json();
                }
                return undefined;
            } catch (ex) {
                log.error('Error fetching RemoveStudyIndicator', ex);
            }
        }

        this.SaveStudyProperty = function (request) {
            log.debug(`SaveStudyProperties api called, id= ${request.id}:${request.name}`)
            fetchWith401Retry('api/Chart/SaveStudyProperty?page=' + chartApp.config.page, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${localStore.accessToken()}`
                },
                body: JSON.stringify(request)
            })
                .then(response => {
                    if (response.status === 200) {
                        return response.json();
                    }
                })
                .then(data => log.debug('study properties saved:', data))
                .catch((ex) => {
                    log.error('Error:', ex)
                })
        }

        this.GetStudyProperties = async function () {
            try {
                log.debug(`GetStudyProperties api called`)
                let response = await fetchWith401Retry('api/chart/GetStudyProperties?page=' + chartApp.config.page, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${localStore.accessToken()}`
                    }
                })
                if (response.status === 200) {
                    return await response.json();
                }
                return [];
            } catch (ex) {
                log.error('Error fetching chart Study Properties', ex);
                return [];
            }
        }

        this.ReplaceStudyPropertyId = function (oldid, newid) {
            log.debug(`ReplaceStudyProperty api called, old id : ${oldid} , new id : ${newid}`)
            fetchWith401Retry('api/Chart/ReplaceStudyPropertyId?page=' + chartApp.config.page, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${localStore.accessToken()}`
                },
                body: JSON.stringify({
                    OldId: oldid,
                    NewId: newid
                })
            })
                .then(response => {
                    if (response.status === 200) {
                        return response.json();
                    }
                })
                .then(data => log.debug('Interval saved:', data))
                .catch((ex) => {
                    log.error('Error:', ex)
                })
        }
        //#endregion
        this.SaveChartData=function(chartObject, symbol,mainSeriesData) {
            log.debug(`SaveChartData api called`)
            return fetchWith401Retry('api/chart/SaveChartData?page=' + chartApp.config.page, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${localStore.accessToken()}`
                },
                body: JSON.stringify({Element:chartObject, page: chartApp.config.page, Symbol: symbol,MainSeriesData:mainSeriesData})
            }).then(res => {
                if (res.status === 401) {
                    chartApp.LogException('401', 'POST api/chart/SaveChartData','Unauthorized access', null, null, null, null);
                    this.ShowRiseAppRefreshPagePopUpForWeb();
                }
                if (res.status !== 200)
                    throw new Error('SaveChartData failed, Error Code: ' + res)
                return res.json()
            }).then(data => log.debug(data))
                .catch(ex => {
                    log.error(ex)
                })

        }

        this.ValidateSession = async function (session,appName) {
            try {
                log.debug(`ValidateSession api called`)
                let response = await fetchWith401Retry('api/chart/ValidateSession?session=' + session+'&appName='+appName, {
                    method: 'GET'
                });

                if (response.status === 200) {
                    return await response.json();
                }
                return undefined;
            } catch (ex) {
                log.error('Error in ValidateSession api', ex);
            }
        }
        
        //#region Add Search Button
        this.AddSearchButton = function () {
            let isSymbolAdded = AddSymbolSearch();
            if (!isSymbolAdded)
                setTimeout(() => this.AddSearchButton(), 0);
        }

        this.OverrideSymbolSearchButton = function () {
            let iframe = document.getElementById(document.getElementById('tv_chart_container').querySelector('iframe').id);
            const symbolSearchButton = iframe.contentDocument.getElementById('#header-toolbar-symbol-search');
            let ticker = chartApp.tvWidget.activeChart().symbol();
            const symbolInfo = chartApp.data.symbolInfoMap.get(ticker);

            if(symbolSearchButton){
                const textDiv = symbolSearchButton.getElementsByClassName(".js-button-text");
                if (textDiv) {
                    textDiv.textContent = symbolInfo.name;
                }
            }
        }

        this.RemoveLegendHiddenClasses=function (retries = 10) {
            try {
                let iframe = document.getElementById(document.getElementById('tv_chart_container').querySelector('iframe').id);
                if (!iframe || !iframe.contentDocument) return;

                // Select the specific wrapper with all classes
                const wrapper = iframe.contentDocument.querySelector(
                    '.titleWrapper-l31H9iuA.exchangeTitle-l31H9iuA.withDot-l31H9iuA.blockHidden-e6PF69Df'
                );
                let changed=false
                if (wrapper) {
                    if (wrapper.classList.contains('blockHidden-e6PF69Df')) {
                        wrapper.classList.remove('blockHidden-e6PF69Df');
                    }
                    const titleDiv = wrapper.querySelector('.title-l31H9iuA.blockHidden-e6PF69Df');
                    if (titleDiv && titleDiv.classList.contains('blockHidden-e6PF69Df')) {
                        titleDiv.classList.remove('blockHidden-e6PF69Df');
                    }
                }
                const intervalWrapper = iframe.contentDocument.querySelector(
                    '.titleWrapper-l31H9iuA.intervalTitle-l31H9iuA.withDot-l31H9iuA.blockHidden-e6PF69Df'
                );

                if (intervalWrapper) {
                    if (intervalWrapper && intervalWrapper.classList.contains('blockHidden-e6PF69Df')) {
                        intervalWrapper.classList.remove('blockHidden-e6PF69Df');
                    }
                    const titleDiv = intervalWrapper.querySelector('.title-l31H9iuA.blockHidden-e6PF69Df');
                    if (titleDiv && titleDiv.classList.contains('blockHidden-e6PF69Df')) {
                        titleDiv.classList.remove('blockHidden-e6PF69Df');
                    }
                }
                
                if(retries>0)
                {
                    // Passes what is left: calling it with no argument started again at 10 each
                    // time, so the poll never ended (32 calls for an interval change, 133 for a
                    // symbol change, measured).
                    setTimeout(()=>this.RemoveLegendHiddenClasses(retries - 1),500);
                }
            } catch (e) {
                log.debug('RemoveLegendHiddenClasses error:', e);
            }
        }

        function AddSymbolSearch() {
            // remove default behaviour of symbol search
            let iframe = document.getElementById(document.getElementById('tv_chart_container').querySelector('iframe').id);
            const symbolSearchButton = iframe.contentDocument.querySelector('#header-toolbar-symbol-search');

            if (symbolSearchButton) {
                // Stop the default behavior on click
                symbolSearchButton.addEventListener('click', (event) => {
                    event.stopPropagation();
                    event.preventDefault();
                    let symbol;
                    let symbolInfo = chartApp.tvWidget.activeChart().symbol();

                    if (symbolInfo.startsWith("IDX"))
                        symbol = symbolInfo.split(':')[2]
                    else
                        symbol = symbolInfo.split(':')[1]

                    log.debug(`searchsymbol event triggered`)
                    window.parent.postMessage({
                        name: "searchsymbol",
                        query: symbol
                    }, '*');
                });

                return true;
            }

            return false;
        }

        //#endregion

        //#region Add Buy/Sell Button
        this.AddBuySellButton = function (isMobileApp) {
            if (isMobileApp)
                return;

            //remove spread count from the UI
            let iframe = document.getElementById(document.getElementById('tv_chart_container').querySelector('iframe').id);
            let spreads = iframe.contentDocument.getElementsByClassName('spreadQtyWrapper-hw_3o_pb');

            for (let spread of spreads) {
                if (spread && spread.style && spread.style.display !== 'none') {
                    spread.style.display = 'none';
                }
            }

            //remove briefcase from the UI
            let briefcases = iframe.contentDocument.getElementsByClassName('brokerButtonDefault-hw_3o_pb brokerButton-hw_3o_pb');

            for (let briefcase of briefcases) {
                if (briefcase && briefcase.style && briefcase.style.display !== 'none') {
                    briefcase.style.display = 'none';
                }
            }

            //Customize Buy and sell button
            SwapBuyAndSellButton(iframe);
            const isColorBlindFriendly = chartApp.config.isColorBlindFriendly === true;
            const buyButtonColor = isColorBlindFriendly ? '#14528C' : '#009B00';
            const sellButtonColor = isColorBlindFriendly ? '#8A3618' : '#C81A1A';
            applyButtonStyles(iframe, 'apply-common-tooltip button-hw_3o_pb buyButton-hw_3o_pb', 'mosl-buy-button', 'BUY', 'white', buyButtonColor);
            applyButtonStyles(iframe, 'apply-common-tooltip button-hw_3o_pb sellButton-hw_3o_pb', 'mosl-sell-button', 'SELL', 'white', sellButtonColor);

            //applyButtonStyles(iframe, 'apply-common-tooltip button-hw_3o_pb sellButton-hw_3o_pb', 'mosl-buy-button', 'BUY', '#009B00', 'white');
            //applyButtonStyles(iframe, 'apply-common-tooltip button-hw_3o_pb buyButton-hw_3o_pb', 'mosl-sell-button', 'SELL', '#C81A1A', 'white');
        }

        function SwapBuyAndSellButton(iframe) {
            const elements = iframe.contentDocument.querySelectorAll('.sellBuyButtonsContainer-hw_3o_pb');
            for (let element of elements) {
                const sellButton = element.querySelector('.sellButton-hw_3o_pb');
                const buyButton = element.querySelector('.buyButton-hw_3o_pb');

                if (sellButton && buyButton) {
                    // Swap: move buyButton before sellButton
                    element.insertBefore(buyButton, sellButton);
                }
            }
        }

        function applyButtonStyles(iframe, buttonClass, spanClass, spanText, borderColor, bgColor) {
            const buttons = iframe.contentDocument.getElementsByClassName(buttonClass);

            if (buttons.length === 0)
                return false;

            for (let button of buttons) {
                if (button === undefined)
                    return false;

                // button.dataset.tooltip = spanText;

                // Apply styles to the button
                button.style.border =  bgColor;//`2px solid ${borderColor}`;
                button.style.background = bgColor;
                // button.style.display = 'flex';
                // button.style.paddingRight = '0px';
                // button.style.alignItems = 'center';
                // button.style.height = '30px';
                //
                // // Apply styles to button text
                // let buttonTexts = iframe.contentDocument.getElementsByClassName('buttonText-hw_3o_pb');
                // for (let buttonText of buttonTexts) {
                //     buttonText.style.paddingRight = '5px';
                //     buttonText.style.color = 'black';
                //     button.style.alignItems = 'center';
                // }

                //removed default text from the button
                // let buttonTitles = iframe.contentDocument.getElementsByClassName('title-hw_3o_pb');
                // for (let buttonTitle of buttonTitles) {
                //     buttonTitle.style.display = 'none';
                // }
                // let buttonTitles = iframe.contentDocument.getElementsByClassName('title-hw_3o_pb');
                // while (buttonTitles.length > 0) {
                //     buttonTitles[0].parentNode.removeChild(buttonTitles[0]);
                // }
                //
                // // Add the span inside the button
                // let buttonChild = button.querySelector(`.${spanClass}`);
                // if (!buttonChild) {
                //     const span = document.createElement('span');
                //     span.className = spanClass;
                //     span.style.background = borderColor;
                //     span.style.display = 'flex';
                //     span.style.height = '30px';
                //     span.style.width = '50px';
                //     span.textContent = spanText;
                //     span.style.alignItems = 'center';
                //     span.style.justifyContent = 'center';
                //     button.appendChild(span);
                // }
            }
            return true;
        }

        //#endregion

        this.ShowRiseAppRefreshPagePopUpForWeb = function () {
            if (chartApp.config.ShowRefreshPagePopUp) {
                console.log(`ShowRiseAppRefreshPagePopUpForWeb called`)
                const customModal = document.getElementById('customModal');
                const refreshButton = document.getElementById('refreshButton');
                customModal.style.display = 'flex'; // Show the modal
                refreshButton.onclick = function () {
                    window.parent.postMessage({
                        name: "refreshpage",
                    }, '*');
                    customModal.style.display = 'none'; // Hide the modal
                }
            }
        }

        this.Retry401ErrorApis= function () {
            while (pending401Requests.length>0) {
                const req = pending401Requests.shift();
                if (req.options.headers) {
                    req.options.headers['Authorization'] = `Bearer ${adapter.localStore.accessToken()}`;
                }
                fetchWith401Retry(req.url, req.options)
                    .then(response => {
                        if (response.status === 401) {
                            let errorMsg='Unauthorized access : Retry401ErrorApis';
                            if(!adapter.localStore.accessToken()){
                                errorMsg='Empty access token : Retry401ErrorApis';
                            }
                            chartApp.LogException('401', `${req.options.method || 'GET'} ${req.url}`, errorMsg, null, null, null, null, null);
                        }
                        req.resolve(response);
                    })
                    .catch(req.reject);
            }
        };
        let pending401Requests = [];

       // A response the host fetched before the page asked (core/preload.js), or undefined, in which
       // case the caller makes the request itself. Never rejects.
       function preloaded(kind, key, maxAgeMs) {
            return chartApp.preload ? chartApp.preload.take(kind, key, {maxAgeMs: maxAgeMs}) : Promise.resolve(undefined);
       }
       function preloadedHistory(request) {
            return chartApp.preload ? chartApp.preload.takeHistory(request) : Promise.resolve(undefined);
       }

       function fetchWith401Retry(url, options = {}) {
            return new Promise(async (resolve, reject) => {
                // Adjust the URL to go up one directory from v3
                const adjustedUrl = url.startsWith('api/') ? `../${url}` : url;

                // adjustedUrl stays the relative form: it is what the host is told on a 401 and
                // what the retry queue stores. Only the request itself goes to the real server
                // when the page is served from the app (see core/api_base.js).
                let target;
                try {
                    target = chartApp.apiBase.resolve(adjustedUrl);
                } catch (err) {
                    reject(err);
                    return;
                }
                let response;
                try {
                    // Through net_retry: a cacheable GET that fails because the HTTP cache holds a
                    // copy without its CORS header is asked for once more, bypassing the cache.
                    response = await chartApp.netRetry.fetch(target, options);
                } catch (err) {
                    // The request itself failed (offline, DNS, TLS, blocked). Without this the throw
                    // escapes the async executor, nothing settles the promise, and every caller
                    // waits forever instead of reaching its own .catch.
                    reject(err);
                    return;
                }
                if (response.status !== 401) {
                    resolve(response);
                    return;
                }
        
                if(chartApp.config.isMobileApp){
                    chartApp.channel.sendError('refreshToken', adjustedUrl, `${response.status}`);
                }
                else{
                    window.parent.postMessage({
                        name: "refreshToken"
                    }, '*');
                    // this.ShowRiseAppRefreshPagePopUpForWeb()
                }
                pending401Requests.push({url: adjustedUrl, options, resolve, reject});
            });
        }
    }
    adapter.chartHttp = new adapter.httpAdapter('chart');
    chartApp.adapter = adapter;

    chartApp.LogException = function (status, methodUrl, errorMsg, token, resolution, ticker, from, to) {
        let model = {
            Status: status,
            MethodUrl: methodUrl,
            ErrorMsg: errorMsg,
            Token: adapter.localStore.accessToken(),
            Resolution: resolution,
            Version: chartApp.config.version,
            ticker,
            page: chartApp.config.page,
            source: chartApp.config.source,
            OldToken: adapter.localStore.oldAccessToken(),
        };
        if (ticker !== undefined) model.ticker = ticker;
        if (typeof from === 'number') model.from = from;
        if (typeof to === 'number') model.to = to;
        adapter.chartHttp.logError(model);
    };

    //Defining adminChart for admin_utility_chart.js
    chartApp.adminChart = {
        initialConfig: chartConfig,
        logger: log.getLogger("admin-chart"),
        keys: {
            ResearchChartCurrentTheme: 'rschart.user.theme',
            ResearchChartSettings: 'rschart.data.settings',
            ResearchChartSelectedInterval: 'rschart.user.selectedInterval',
            ApiKey: 'rschart.user.apikey'
        },
        data: {},
        http: new adapter.httpAdapter('adminChart'),
        localStore: adapter.localStore,
    }
})(window, document, ChartApp);