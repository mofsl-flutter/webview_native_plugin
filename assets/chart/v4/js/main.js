(function (window, document, chartApp) {
    const localStore = chartApp.adapter.localStore;
    const httpAdapter = chartApp.adapter.chartHttp;

    //#region FullChart Implementation
    chartApp.FullChart = function () {
        const logger = log.getLogger("full-chart");
        const disabledFeatures = ["header_fullscreen_button", "legend_inplace_edit", "symbol_search_hot_key", "trading_account_manager", "right_toolbar", "trading_notifications", "chart_property_page_trading"]
        const enabledFeatures = ["saveload_separate_drawings_storage", "study_templates", "header_widget", "always_show_legend_values_on_mobile","seconds_resolution"]

        //#region saveLoadAdapter
        const saveLoadAdapter = {
            layouts: {
                saveData: function (data) {
                    httpAdapter.saveLayouts(data).then(data => {
                        log.info('layout saved')
                    }).catch(err => {
                        log.error('Save layout failed. ' + err)
                    })
                }
            },
            //#region Save charts layout
            getAllCharts: async function () {
                return await httpAdapter.getAllLayouts()
            },
            removeChart: function (chartId) {
                log.debug('removed chart layout id:' + chartId)
                return httpAdapter.removeChart(chartId)
            },
            saveChart: function (chartData) {
                log.debug('chart layout saved')
                if (!chartData.id) {
                    chartData.id = Math.random().toString();
                }
                chartData.timestamp = new Date().valueOf();
                this.layouts.saveData(chartData)
                return Promise.resolve(chartData.id);
            },
            getChartContent: async function (chartId) {
                log.debug('fetched chart content id: ' + chartId)
                return await httpAdapter.getChartContent(chartId)
            },
            //#endregion Save charts layout

            //#region Save indicators templates
            templates: {
                saveData: function (data) {
                    httpAdapter.saveStudyTemplate(data).then(data => {
                        log.info('StudyTemplate saved')
                    }).catch(err => {
                        log.error('Save StudyTemplate failed. ' + err)
                    })
                }
            },
            removeStudyTemplate: function (studyTemplateData) {
                return httpAdapter.removeStudyTemplate(studyTemplateData.name)
            },
            getStudyTemplateContent: async function (studyTemplateData) {
                log.debug('fetched all indicators')
                return await httpAdapter.getStudyTemplateContent(studyTemplateData.name)
            },
            saveStudyTemplate: function (studyTemplateData) {
                log.debug(studyTemplateData.name + ' indicator saved')
                this.templates.saveData(studyTemplateData);
                return Promise.resolve();
            },
            getAllStudyTemplates: async function () {
                log.debug('fetched all indicators')
                return await httpAdapter.getAllStudyTemplates()
            },
            //#endregion Save indicators templates

            //#region Save Drawings Properties
            removeDrawingTemplate: function (toolName, templateName) {
                return httpAdapter.RemoveDrawingProperties(toolName, templateName)
            },
            loadDrawingTemplate: function (toolName, templateName) {
                return httpAdapter.GetDrawingToolContent(toolName, templateName)
            },
            saveDrawingTemplate: function (toolName, templateName, content) {
                return httpAdapter.SaveDrawingProperties(toolName, templateName, content)
            },
            getDrawingTemplates: function (toolName) {
                return httpAdapter.GetChartDrawingPropertiesName(toolName)
            },
            //#endregion

            //#region Save Drawings
            drawingTemplates: {},
            saveLineToolsAndGroups: function (layoutId, chartId, state) {
                const drawings = state.sources;
                const drawingKey = this._getDrawingKey(layoutId, chartId);
                
                if (!this.drawingTemplates[drawingKey]) {
                    this.drawingTemplates[drawingKey] = {}
                }
                
                for (let [key, state] of drawings) {
                    if (state === null) {
                        delete this.drawingTemplates[drawingKey][key];
                    } else {
                        if (state.symbol.includes("UNDEFINED"))
                            state.symbol = tvWidget.activeChart().symbol()
                        this.drawingTemplates[drawingKey][key] = state;
                    }
                }
                
                httpAdapter.SaveDrawingsTemplates(drawingKey, JSON.stringify(this.drawingTemplates))
            },
            loadLineToolsAndGroups: async function (layoutId, chartId, requestType, requestContext) {
                const sources = new Map();
                if (!layoutId || layoutId.includes('undefined')) {
                    return {sources};
                }
                const drawingKey = this._getDrawingKey(layoutId, chartId);
                let drawingTemplates = await httpAdapter.GetDrawingsTemplates(drawingKey);
                if (drawingTemplates) {
                    let lineTools = JSON.parse(drawingTemplates) || {}
                    this.drawingTemplates = lineTools;
                    const rawSources = lineTools[drawingKey];
                    if (!rawSources) return {sources};
                    for (let [key, state] of Object.entries(rawSources)) {
                        sources.set(key, state);
                    }
                    return {sources};
                }
                return {sources};
            },
            _getDrawingKey(layoutId, chartId) {
                return `${layoutId}/${chartId}`
            },
            //#endregion Save Drawings
        };
        //#endregion

        //#region custom functions for chart
        let currentChartTheme;
        let themeButton;

        function showThemeSwitcher(currentTheme, isMobileApp) {
            if (themeButton !== undefined)
                return;

            themeButton = tvWidget.createButton();
            let themeName;
            if (currentTheme === 'light') {
                themeName = 'Dark'
            } else {
                themeName = 'White'
            }

            themeButton.setAttribute('title', `${themeName} Theme`)
            themeButton.textContent = `${themeName} Theme`
            themeButton.addEventListener('click', () => {
                let theme;
                if (themeButton.textContent === 'Dark Theme') {
                    themeButton.setAttribute('title', 'White Theme');
                    themeButton.textContent = 'White Theme';
                    theme = 'dark';
                } else {
                    themeButton.setAttribute('title', 'Dark Theme');
                    themeButton.textContent = 'Dark Theme';
                    theme = 'light';
                }
                localStore.saveTheme(theme);
                tvWidget.changeTheme(theme)
                if (!isMobileApp) {
                    ShowFullAndExitScreenSwitcher(theme, true)
                    ShowMarketDepthIcon(theme, true)
                }
                else{
                    AddRotateIcon(theme, true)
                    AddHardRefreshIcon(theme, true)
                }
            })
        }
        let themeIconButton;
        function showIconThemeSwitcher(currentTheme) {
            if (themeIconButton === undefined) {
                themeIconButton = tvWidget.createButton({
                    align: 'right'
                });

                if (currentTheme === 'light')
                    themeIconButton.innerHTML = '<img src="../../../Icons/Moon.png"  alt="DarkTheme" height="20" width="20">';
                else
                    themeIconButton.innerHTML = '<img src="../../../Icons/Sun.png" alt="WhiteTheme" height="20" width="20">';

                themeIconButton.style.width = '25px';
                themeIconButton.style.height = '25px';
                themeIconButton.style.display = 'flex';
                themeIconButton.style.alignItems = 'center';
                themeIconButton.style.justifyContent = 'center';
                themeIconButton.style.border = 'none';
                themeIconButton.style.background = 'none';

                themeIconButton.addEventListener('mouseover', () => {
                    CustomButtonMouseOver(themeIconButton, changedTheme)
                });

                themeIconButton.addEventListener('mouseout', () => {
                    CustomButtonMouseOut(themeIconButton)
                });

                themeIconButton.addEventListener('click', () => {
                    let theme;
                    if (themeIconButton.Value === 'Dark Theme') {
                        themeIconButton.innerHTML = '<img src="../../../Icons/Sun.png"  alt="DarkTheme" height="20" width="20">';
                        themeIconButton.setAttribute('title', 'White Theme');
                        themeIconButton.Value = 'White Theme';
                        theme = 'dark';
                        currentChartTheme = theme;
                    } else {
                        themeIconButton.innerHTML = '<img src="../../../Icons/Moon.png"  alt="DarkTheme" height="20" width="20">';
                        themeIconButton.setAttribute('title', 'Dark Theme');
                        themeIconButton.Value = 'Dark Theme';
                        theme = 'light';
                        currentChartTheme = theme;
                    }
                    localStore.saveTheme(theme);
                    tvWidget.changeTheme(theme)
                    ShowFullAndExitScreenSwitcher(theme, true)
                    ShowMarketDepthIcon(theme, true)
                })
            }
            let themeName;
            if (currentTheme === 'light') {
                themeIconButton.innerHTML = '<img src="../../../Icons/Moon.png"  alt="DarkTheme" height="20" width="20">';
                themeName = 'Dark'
            } else {
                themeIconButton.innerHTML = '<img src="../../../Icons/Sun.png" alt="WhiteTheme" height="20" width="20">';
                themeName = 'White'
            }

            themeIconButton.setAttribute('title', `${themeName} Theme`)
            themeIconButton.Value = `${themeName} Theme`
        }

        let fullScreenButton;
        let changedTheme;
        let marketDepthButton;
        let rotateButton;
        let hardRefreshButton;


        function ShowFullAndExitScreenSwitcher(theme, isThemeChange) {
            changedTheme = theme;
            if (fullScreenButton === undefined) {
                fullScreenButton = tvWidget.createButton({
                    align: 'right'
                });

                if (theme === 'dark')
                    fullScreenButton.innerHTML = '<img src="../../../Icons/Light/FullScreen.png"  alt="Full screen" height="20" width="20">';
                else
                    fullScreenButton.innerHTML = '<img src="../../../Icons/Dark/FullScreen.png" alt="Full screen" height="20" width="20">';

                fullScreenButton.setAttribute('title', 'Full Screen');
                fullScreenButton.value = "startfullscreen"
                fullScreenButton.style.width = '25px';
                fullScreenButton.style.height = '25px';
                fullScreenButton.style.display = 'flex';
                fullScreenButton.style.alignItems = 'center';
                fullScreenButton.style.justifyContent = 'center';
                fullScreenButton.style.border = 'none';
                fullScreenButton.style.background = 'none';

                fullScreenButton.addEventListener('mouseover', () => {
                    CustomButtonMouseOver(fullScreenButton, changedTheme)
                });

                fullScreenButton.addEventListener('mouseout', () => {
                    CustomButtonMouseOut(fullScreenButton)
                });

                fullScreenButton.addEventListener('click', () => {
                    SetStartOrExitScreenIcon(changedTheme, false)
                });
            }
            if (isThemeChange) {
                SetStartOrExitScreenIcon(theme, isThemeChange)
            }
        }

        function SetStartOrExitScreenIcon(theme, isThemeChange, showOnlyIcons) {

            //set the icon based on the theme if only user change just theme
            if (isThemeChange) {
                if (fullScreenButton.value === "startfullscreen") {
                    if (theme === 'dark')
                        fullScreenButton.innerHTML = '<img src="../../../Icons/Light/FullScreen.png"  alt="Full screen" height="20" width="20">';
                    else
                        fullScreenButton.innerHTML = '<img src="../../../Icons/Dark/FullScreen.png" alt="Full screen" height="20" width="20">';

                } else {
                    if (theme === 'dark')
                        fullScreenButton.innerHTML = '<img src="../../../Icons/Light/ExitFullScreen.png"  alt="Full screen" height="20" width="20">';
                    else
                        fullScreenButton.innerHTML = '<img src="../../../Icons/Dark/ExitFullScreen.png" alt="Full screen" height="20" width="20">';
                }
                return;
            }

            //change the icon and send the call back when user clicked on button
            if (fullScreenButton.value === "startfullscreen") {
                if (theme === 'dark')
                    fullScreenButton.innerHTML = '<img src="../../../Icons/Light/ExitFullScreen.png"  alt="Full screen" height="20" width="20">';
                else
                    fullScreenButton.innerHTML = '<img src="../../../Icons/Dark/ExitFullScreen.png" alt="Full screen" height="20" width="20">';
                fullScreenButton.setAttribute('title', 'Exit FullScreen');
                if (!showOnlyIcons) {
                    log.debug(`startfullscreen event triggered`)
                    window.parent.postMessage({
                        name: "startfullscreen"
                    }, '*');
                }
                fullScreenButton.value = "exitfullscreen"
            } else {
                if (theme === 'dark')
                    fullScreenButton.innerHTML = '<img src="../../../Icons/Light/FullScreen.png"  alt="Full screen" height="20" width="20">';
                else
                    fullScreenButton.innerHTML = '<img src="../../../Icons/Dark/FullScreen.png" alt="Full screen" height="20" width="20">';
                fullScreenButton.setAttribute('title', 'Full Screen');
                if (!showOnlyIcons) {
                    log.debug(`exitfullscreen event triggered`)
                    window.parent.postMessage({
                        name: "exitfullscreen"
                    }, '*');
                }
                fullScreenButton.value = "startfullscreen"
            }
        }

        function ShowMarketDepthIcon(theme, isThemeChange) {

            if (chartApp.config.page === 'RiseApp_indices_Chart.html')
                return;
            
            if(ChartApp.config.disableMarketDepth)
                return;

            changedTheme = theme;
            if (marketDepthButton === undefined) {
                marketDepthButton = tvWidget.createButton({
                    align: 'left'
                });

                if (theme === 'dark')
                    marketDepthButton.innerHTML = '<img src="../../../Icons/Light/MarketDepth.png" alt="MarketDepth" height="20" width="20">';
                else
                    marketDepthButton.innerHTML = '<img src="../../../Icons/Dark/MarketDepth.png" alt="MarketDepth" height="20" width="20">';

                marketDepthButton.setAttribute('title', 'Market Depth');

                marketDepthButton.style.width = '25px';
                marketDepthButton.style.height = '25px';
                marketDepthButton.style.display = 'flex';
                marketDepthButton.style.alignItems = 'center';
                marketDepthButton.style.justifyContent = 'center';
                marketDepthButton.style.border = 'none';
                marketDepthButton.style.background = 'none';
                marketDepthButton.style.cursor = 'pointer';
                marketDepthButton.style.borderRadius = '4px';
                marketDepthButton.style.transition = 'background-color 0.2s ease-in-out';

                marketDepthButton.addEventListener('mouseover', () => {
                    CustomButtonMouseOver(marketDepthButton, changedTheme)
                });

                marketDepthButton.addEventListener('mouseout', () => {
                    CustomButtonMouseOut(marketDepthButton)
                });

                marketDepthButton.addEventListener('click', () => {
                    ShowMarketDepthIconBasedOnTheme(changedTheme, false);
                });
            }
            if (isThemeChange) {
                ShowMarketDepthIconBasedOnTheme(theme, isThemeChange)
            }
        }

        function ShowMarketDepthIconBasedOnTheme(theme, isThemeChange) {
            if (isThemeChange) {
                if (theme === 'dark')
                    marketDepthButton.innerHTML = '<img src="../../../Icons/Light/MarketDepth.png"  alt="MarketDepth" height="20" width="20">';
                else
                    marketDepthButton.innerHTML = '<img src="../../../Icons/Dark/MarketDepth.png" alt="MarketDepth" height="20" width="20">';
                return;
            }

            let symbolInfo = chartApp.data.symbolInfoMap.get(tvWidget.activeChart().symbol());

            window.parent.postMessage({
                name: 'showMarketDepth',
                scripCode: symbolInfo.scripCode,
                exchangeCode: symbolInfo.exchangeCode,
                tradeSymbol: symbolInfo.name,
                description: symbolInfo.description
            }, '*')
        }

        function CustomButtonMouseOver(customButton, theme) {
            //Change the background color based on the theme
            if (theme === 'dark') {
                customButton.style.backgroundColor = 'rgba(255, 255, 255, 0.1)'; // Darker overlay on hover
            } else {
                customButton.style.backgroundColor = 'rgba(0, 0, 0, 0.06)';
            }
        }

        function CustomButtonMouseOut(customButton) {
            customButton.style.backgroundColor = 'transparent'; // Reset background
        }

        function AddRotateIcon(theme, isThemeChange,isSymbolChanged) {
            changedTheme = theme;
            if(isSymbolChanged){
                rotateButton.value = "landscape"
            }
            
            if (rotateButton === undefined) {
                rotateButton = tvWidget.createButton({
                    align: 'left'
                });

                if (theme === 'dark')
                    rotateButton.innerHTML = '<img src="../../../../Icons/Light/Rotate.png"  alt="Rotate Chart" height="20" width="20">';
                else
                    rotateButton.innerHTML = '<img src="../../../../Icons/Dark/Rotate.png" alt="Rotate Chart" height="20" width="20">';

                rotateButton.setAttribute('title', 'Rotate Chart');
                rotateButton.value = "landscape"
                rotateButton.style.width = '25px';
                rotateButton.style.height = '25px';
                rotateButton.style.display = 'flex';
                rotateButton.style.alignItems = 'center';
                rotateButton.style.justifyContent = 'center';
                rotateButton.style.border = 'none';
                rotateButton.style.background = 'none';

                rotateButton.addEventListener('mouseover', () => {
                    CustomButtonMouseOver(rotateButton, changedTheme)
                });

                rotateButton.addEventListener('mouseout', () => {
                    CustomButtonMouseOut(rotateButton)
                });

                rotateButton.addEventListener('click', () => {
                    if(rotateButton.value === "vertical"){
                        chartApp.channel.sendMobileEvents('rotateChart', {
                            value:rotateButton.value 
                        });
                        rotateButton.value = "landscape"
                    }
                    else{
                        chartApp.channel.sendMobileEvents('rotateChart', {
                            value:rotateButton.value 
                        });
                        rotateButton.value = "vertical"
                    }
                });
            }
            if (isThemeChange) {
                if (theme === 'dark')
                    rotateButton.innerHTML = '<img src="../../../../Icons/Light/Rotate.png"  alt="Rotate Chart" height="20" width="20">';
                else
                    rotateButton.innerHTML = '<img src="../../../../Icons/Dark/Rotate.png" alt="Rotate Chart" height="20" width="20">';          
            }
        }

        function AddHardRefreshIcon(theme, isThemeChange) {
            changedTheme = theme;
            if (hardRefreshButton === undefined) {
                hardRefreshButton = tvWidget.createButton({
                    align: 'right'
                });

                if (theme === 'dark')
                    hardRefreshButton.innerHTML = '<img src="../../../../Icons/Light/HardRefresh.png"  alt="HardRefresh" height="20" width="20">';
                else
                    hardRefreshButton.innerHTML = '<img src="../../../../Icons/Dark/HardRefresh.png" alt="HardRefresh" height="20" width="20">';

                hardRefreshButton.setAttribute('title', 'Hard Refresh');
                hardRefreshButton.value = "vertical"
                hardRefreshButton.style.width = '25px';
                hardRefreshButton.style.height = '25px';
                hardRefreshButton.style.display = 'flex';
                hardRefreshButton.style.alignItems = 'center';
                hardRefreshButton.style.justifyContent = 'center';
                hardRefreshButton.style.border = 'none';
                hardRefreshButton.style.background = 'none';

                hardRefreshButton.addEventListener('mouseover', () => {
                    CustomButtonMouseOver(rotateButton, changedTheme)
                });

                hardRefreshButton.addEventListener('mouseout', () => {
                    CustomButtonMouseOut(rotateButton)
                });

                hardRefreshButton.addEventListener('click', () => {
                    chartApp.channel.sendMobileEvents('hardRefresh', {
                        value:"hardRefresh"
                    });
                });
            }
            if (isThemeChange) {
                if (theme === 'dark')
                    hardRefreshButton.innerHTML = '<img src="../../../../Icons/Light/HardRefresh.png"  alt="HardRefresh" height="20" width="20">';
                else
                    hardRefreshButton.innerHTML = '<img src="../../../../Icons/Dark/HardRefresh.png" alt="HardRefresh" height="20" width="20">';
            }
        }
        
        function ValidateSavedChartObject(savedData){
            // Sanitize saved data to remove corrupted drawings
            if (savedData) {
                try {
                    const parsedData = JSON.parse(savedData);
                    if (parsedData && parsedData.charts) {
                        parsedData.charts.forEach(chart => {
                            if (chart.panes) {
                                chart.panes.forEach(pane => {
                                    if (pane.sources) {
                                        pane.sources = pane.sources.filter(source => {
                                            if (source.points===undefined) {
                                                return true;
                                            }
                                            const hasInvalidPrice = source.points.some(p => !p || p.price === undefined || p.price === null);
                                            if (hasInvalidPrice) {
                                                log.warn(`Removed corrupted ${source.type}`);
                                                return false;
                                            }
                                            return true;
                                        });
                                    }
                                });
                            }
                        });
                    }
                    return JSON.stringify(parsedData);
                } catch (err) {
                    log.error('Failed to sanitize saved data: ' + err);
                    return  null;
                }
            }
            
            return null;
        }
        //#endregion custom functions for chart
        
        let tvWidget;
        let chartReady = false;
        let isChartLoadFirstTime;
        let isSymbolChanged = false;

        return {
            LoadChart: async function (symbol, theme, isMobileApp) {
                // const studyMap = new Map();
                // let SavedIndicatorPropertiesCount = 0;
                // let isSavedIndicatorPropertiesApplied = false;
                logger.debug("LoadChart for", symbol, theme, isMobileApp);
                chartApp.config.source = isMobileApp ? 'Mobile' : 'Web';
                chartApp.config.isMobileApp = isMobileApp
                let savedChartInfo = await httpAdapter.GetChartSavedInfo(symbol)
                chartApp.saveData=savedChartInfo.saveData;
                chartApp.mainSeries=savedChartInfo.mainSeries;
                //#region Change symbol
                if (!savedChartInfo.refreshTvWidget && tvWidget) {
                    isSymbolChanged=true;
                    chartReady = false;
                    
                    tvWidget.activeChart().setSymbol(symbol, {
                        dataReady: function () {
                            chartApp.channel.SendPageReadySymbols();
                            chartApp.channel.sendChartStatus('changeSymbol', symbol, theme);
                            // loadLineToolsState(savedChartInfo.state)
                            setTimeout(()=>ApplyPriceScalePanePropeties(),500)
                            if (!isMobileApp) {
                                httpAdapter.OverrideSymbolSearchButton();
                            }
                            else{
                                httpAdapter.RemoveLegendHiddenClasses()
                            }
                            setTimeout(()=>isSymbolChanged=false,500)
                            setTimeout(()=>chartReady = true, 1000)
                        }
                    });
                    if (!isMobileApp) {
                        showIconThemeSwitcher(theme)
                        ShowFullAndExitScreenSwitcher(theme, true)
                        ShowMarketDepthIcon(theme, true)
                        httpAdapter.AddBuySellButton(isMobileApp)
                    }
                    else{
                        AddRotateIcon(theme,false,true)
                    }
                    // await applySavedIndicatorProperties()
                    // tvWidget.changeTheme(theme)
                    tvWidget.closePopupsAndDialogs();
                    return;
                }
                //#endregion Change symbol


                //#region Initialize Chart
                if (isMobileApp)
                    disabledFeatures.push("header_screenshot", "header_compare", "header_symbol_search");

                if (chartApp.config.page === 'RiseApp_Mobile.html') {
                    // The library's internal "Chart by TradingView" branding source (CustomSourceBase)
                    // checks l.enabled("logo_without_link") in its hitTest() and returns null (no click
                    // target) when enabled, while draw() still paints it normally - so this keeps the
                    // mark visible but non-interactive, instead of removing it outright via "widget_logo".
                    // Confirmed by reading v1/Libraries/Paid_libraries/TT_v29_1_0/bundles/library.*.js.
                    enabledFeatures.push("logo_without_link");
                }

                //#region initialSettings Chart info
                currentChartTheme = theme
                isChartLoadFirstTime = true;
                let interval = savedChartInfo.interval || '1';
                let initialSettings = {
                    'trading.chart.proterty': JSON.stringify({
                        noConfirmEnabled: 1,
                        orderExecutedSoundParams: '{"enabled":1}'
                    }),
                };

                if (savedChartInfo.intialSettings) {
                    for (let setting of savedChartInfo.intialSettings) {
                        initialSettings[`${setting.key}`] = setting.value
                    }
                }
                //#endregion initialSettings Chart info

                let savedData = savedChartInfo.saveData || null;
                savedData=ValidateSavedChartObject(savedData);
                //#region Load Chart for web
                if (chartApp.config.showBuySellButton && !isMobileApp) {
                    tvWidget = new TradingView.widget({
                        debug: chartApp.config.tvDebug,
                        fullscreen: true,
                        symbol: symbol,
                        interval: interval,
                        container: "tv_chart_container",
                        timezone: "Asia/Kolkata",
                        autosize: true,
                        datafeed: chartApp.datafeed,
                        library_path: chartApp.config.libPath,
                        pinch_scale: true,
                        locale: "en",
                        header_widget_buttons_mode: 'adaptive',
                        disabled_features: disabledFeatures,
                        enabled_features: enabledFeatures,
                        client_id: 'tradingview.com',
                        user_id: 'public_user_id',
                        saved_data: JSON.parse(savedData),
                        auto_save_delay: 1,
                        favorites: {
                            intervals: ["1", "3", "5", 'D'],
                            chartTypes: ["Candles"]
                        },
                        time_frames: [
                            {text: "1D", resolution: "1", description: "1 day"},
                            {text: "5D", resolution: "5", description: "5 days"},
                            {text: "1M", resolution: "30", description: "1 Month"},
                            {text: "3M", resolution: "60", description: "3 Months"},
                            {text: "6M", resolution: "1D", description: "6 Months"},
                            {text: "12M", resolution: "1D", description: "Year To Date", title: "YTD"},
                            {text: "5Y", resolution: "1W", description: "5 Years"},
                            {text: "20Y", resolution: "1M", description: "All", title: "All"},
                        ],
                        save_load_adapter: saveLoadAdapter,
                        theme: theme,
                        settings_adapter: {
                            initialSettings: initialSettings,
                            setValue: function (key, value) {
                                log.debug('save the settings key: ' + key + ' ,Value' + value)
                                if (tvWidget._ready && key !== 'current_theme.name') {
                                    httpAdapter.saveSettings(key, value)
                                }
                            },
                            removeValue: function (key) {
                                log.debug('Remove the settings key: ' + key)
                                if (tvWidget._ready) {
                                    httpAdapter.RemoveSettings(key)
                                }
                            },
                        },
                        broker_factory: function (host) {
                            return new Brokers.BrokerSample(host);
                        }
                    });
                } 
                //#endregion Load Chart for web
                //#region Load Chart for mobile  
                else {
                    tvWidget = new TradingView.widget({
                        debug: chartApp.config.tvDebug,
                        fullscreen: true,
                        symbol: symbol,
                        interval: interval,
                        container: "tv_chart_container",
                        timezone: "Asia/Kolkata",
                        autosize: true,
                        datafeed: chartApp.datafeed,
                        library_path: chartApp.config.libPath,
                        pinch_scale: true,
                        locale: "en",
                        header_widget_buttons_mode: 'adaptive',
                        disabled_features: disabledFeatures,
                        enabled_features: enabledFeatures,
                        client_id: 'tradingview.com',
                        user_id: 'public_user_id',
                        auto_save_delay: 1,
                        saved_data: JSON.parse(savedData),
                        favorites: {
                            intervals: ["1", "3", "5", 'D'],
                            chartTypes: ["Candles"]
                        },
                        time_frames: [
                            {text: "1D", resolution: "1", description: "1 day"},
                            {text: "5D", resolution: "5", description: "5 days"},
                            {text: "1M", resolution: "30", description: "1 Month"},
                            {text: "3M", resolution: "60", description: "3 Months"},
                            {text: "6M", resolution: "1D", description: "6 Months"},
                            {text: "12M", resolution: "1D", description: "Year To Date", title: "YTD"},
                            {text: "5Y", resolution: "1W", description: "5 Years"},
                            {text: "20Y", resolution: "1M", description: "All", title: "All"},
                        ],
                        save_load_adapter: saveLoadAdapter,
                        theme: theme,
                        settings_adapter: {
                            initialSettings: initialSettings,
                            setValue: function (key, value) {
                                log.debug('save the settings key: ' + key + ' ,Value' + value)
                                if (tvWidget._ready && key !== 'current_theme.name') {
                                    httpAdapter.saveSettings(key, value)
                                }
                            },
                            removeValue: function (key) {
                                log.debug('Remove the settings key: ' + key)
                                if (tvWidget._ready) {
                                    httpAdapter.RemoveSettings(key)
                                }
                            },
                        }
                    });
                }
                //#endregion Load Chart for mobile

                chartApp.tvWidget = tvWidget;

                //#region on chartready event
                tvWidget.onChartReady(async () => {
                    chartApp.channel.SendPageReadySymbols();
                    logger.debug("onChartReady triggered");
                    isChartLoadFirstTime = false;
                    chartApp.channel.sendChartStatus('initialLoad', symbol, theme);

                    const chart = tvWidget.chart();
                    //save the interval in local storage
                    chart.onIntervalChanged()
                        .subscribe(null, async (interval, timeframeobj) => {
                            logger.debug("onIntervalChanged :", interval);
                            httpAdapter.AddBuySellButton(isMobileApp)
                            await httpAdapter.SaveInterval(interval)
                            chartApp.quote.reRenderLastQuote(chart.symbol(), interval);
                            httpAdapter.RemoveLegendHiddenClasses();
                        })
                    if (!isMobileApp) {
                        httpAdapter.OverrideSymbolSearchButton();
                        httpAdapter.AddBuySellButton(isMobileApp)
                    }
                    SubscribeToEvents()
                    tvWidget.changeTheme(tvWidget.getTheme())
                    setTimeout(()=>chartReady = true, 1000)
                })
                //#endregion onchartready event

                function saveChartData(){
                    setTimeout(()=>tvWidget.save((chartObject) => {
                        const symbol = tvWidget.activeChart().symbol();
                        const mainSeriesData = chartObject.charts[0]?.panes[0]?.rightAxisesState[0];
                        httpAdapter.SaveChartData(chartObject, symbol,mainSeriesData);
                    }),1000)
                }
                function SubscribeToEvents(){

                    //#region Buy and sell buttons events
                    tvWidget.subscribe('[sell/buy_buttons] sell', (category, label, value) => {
                        let symbolInfo = chartApp.data.symbolInfoMap.get(tvWidget.activeChart().symbol());
                        log.debug(`buy event triggered`)
                        window.parent.postMessage({
                            name: 'sell',
                            scripCode: symbolInfo.scripCode,
                            exchangeCode: symbolInfo.exchangeCode
                        }, '*')
                    })

                    tvWidget.subscribe('[sell/buy_buttons] buy', (category, label, value) => {
                        let symbolInfo = chartApp.data.symbolInfoMap.get(tvWidget.activeChart().symbol());
                        log.debug(`sell event triggered`)
                        window.parent.postMessage({
                            name: 'buy',
                            scripCode: symbolInfo.scripCode,
                            exchangeCode: symbolInfo.exchangeCode
                        }, '*')
                    })

                    tvWidget.subscribe('[shortcut]_sell market', (category, label, value) => {
                        let symbolInfo = chartApp.data.symbolInfoMap.get(tvWidget.activeChart().symbol());
                        log.debug(`buy event triggered`)
                        window.parent.postMessage({
                            name: 'sell',
                            scripCode: symbolInfo.scripCode,
                            exchangeCode: symbolInfo.exchangeCode
                        }, '*')
                    })

                    tvWidget.subscribe('[shortcut]_buy market', (category, label, value) => {
                        let symbolInfo = chartApp.data.symbolInfoMap.get(tvWidget.activeChart().symbol());
                        log.debug(`sell event triggered`)
                        window.parent.postMessage({
                            name: 'buy',
                            scripCode: symbolInfo.scripCode,
                            exchangeCode: symbolInfo.exchangeCode
                        }, '*')
                    })
                    //#endregion Buy and sell buttons events

                    tvWidget.subscribe('panes_order_changed', (e) => {
                        httpAdapter.AddBuySellButton(isMobileApp)
                        tvWidget.changeTheme(tvWidget.getTheme())

                        let chartCount = ChartApp.tvWidget.chartsCount();
                        for (let i = 0; i < chartCount; i++) {
                            try {
                                let chart = chartApp.tvWidget.chart(i);
                                chart.onVisibleRangeChanged().subscribe(null, () => {
                                    logger.debug('Chart range changed, saving chart data');
                                    if(!isSymbolChanged){
                                        saveChartData()
                                    }
                                });
                            } catch (err) {
                                log.warn(`Error getting symbol for chart ${i}:`, err);
                            }
                        }
                    })

                    //#region onAutoSaveNeeded event
                    //this event helps to auto save all the drawing,studies&intervals so on
                    tvWidget.subscribe('onAutoSaveNeeded', () => {
                        logger.debug('onAutoSaveNeeded triggered')
                        const chart = tvWidget.chart();
                      
                        if(!chartReady)
                            return;
                        saveChartData()
                    })
                    //#endregion onAutoSaveNeeded event

                    //#region Study  events
                    //this event helps to close indicator dialog box when user clicked on studies
                    tvWidget.subscribe('study', (e) => {
                        tvWidget.closePopupsAndDialogs();
                    })

                    tvWidget.activeChart().onSymbolChanged().subscribe(null, () => {
                        isSymbolChanged=true;
                    });

                    setTimeout(()=>ApplyPriceScalePanePropeties(),500)
                }

                function ApplyPriceScalePanePropeties(){
                    if (!chartApp.saveData) return;
                    const savedData = JSON.parse(chartApp.saveData);
                    if (!savedData || !savedData.charts) return;

                    savedData.charts.forEach((chart, chartIndex) => {
                        if (!chart.panes) 
                            return;
                        
                        chart.panes.forEach((pane, paneIndex) => {
                            if(pane.rightAxisesState[0].state.m_isAutoScale===false&&pane.rightAxisesState[0].state.m_isLog===false
                                &&pane.rightAxisesState[0].state.m_isPercentage===false){
                                const currentSymbol = ChartApp.tvWidget.chart(chartIndex).symbol();
                                const savedSymbol = pane.sources.find(x=>x.type==="MainSeries").state.symbol;
                                if (currentSymbol === savedSymbol) {
                                    const mainseries =pane.rightAxisesState[0];
                                    let priceRange;
                                    if (paneIndex === 0 && mainseries &&mainseries.state && mainseries.state.m_priceRange) {
                                        priceRange = mainseries.state.m_priceRange;
                                    } else if (paneIndex !== 0&&pane.rightAxisesState && pane.rightAxisesState[0] && pane.rightAxisesState[0].state.m_priceRange) {
                                        priceRange = pane.rightAxisesState[0].state.m_priceRange;
                                    }
                                    if (priceRange) {
                                        const priceScale = ChartApp.tvWidget.chart(chartIndex).getPanes()[paneIndex].getRightPriceScales()[0];
                                        priceScale.setVisiblePriceRange({
                                            "from": priceRange.m_minValue,
                                            "to": priceRange.m_maxValue
                                        });
                                    }
                                }
                            }
                        });
                    });
                }
                //#region header ready event
                tvWidget.headerReady().then(() => {
                    if (isMobileApp) {
                        AddRotateIcon(theme, false)
                        let toolButton = tvWidget.createButton();
                        toolButton.setAttribute('Tools', `Drawing Tools`)
                        toolButton.textContent = 'Tools'
                        toolButton.addEventListener('click', () => {
                            //it helps to open&close drawing tool bar
                            tvWidget.chart().executeActionById('drawingToolbarAction')
                        })
                        if(!chartApp.config.disableThemeButton){
                            showThemeSwitcher(theme, isMobileApp);
                        }
                        AddHardRefreshIcon(theme, false)
                    } else {
                        showIconThemeSwitcher(theme)
                        ShowMarketDepthIcon(theme, false)
                        ShowFullAndExitScreenSwitcher(theme, false)
                        httpAdapter.AddSearchButton();
                    }
                })
                //#endregion header ready event
                //#endregion Initialize Chart
            },

            ChangeChartTheme: function (theme){
                tvWidget.changeTheme(theme)
                if(ChartApp.config.isMobileApp){
                    AddRotateIcon(theme,true)
                    AddHardRefreshIcon(theme,true)
                }
            },
            //#region AppendLiveTick & UpdateAskAndBidValues on real time
            AppendLiveTick: function (ticker, ltp, close, volume, tradeTime) {
                if (!tvWidget) {
                    logger.warn(`AppendLiveTick(${ticker}) called before chart init, Ignored...`);
                    return;
                }
                if (!chartReady) {
                    logger.warn(`AppendLiveTick(${ticker}) called before chartReady, Ignored...`);
                    return;
                }
                logger.debug("AppendLiveTick:", ticker, ltp, close, volume, tradeTime);
                let resolution = tvWidget.chart().resolution();
                if (resolution === '1W' || resolution === '1M') {
                    resolution = '1D';
                }
                try {
                    chartApp.stream.onTickReceived(ticker, resolution, ltp, close, volume, tradeTime)
                } catch (err) {
                    logger.error("AppendLiveTick method error: " + err)
                }
            },

            UpdateAskAndBidValues: function (ticker, ask, bid) {
                chartApp.stream.UpdateAskAndBidValues(ticker, ask, bid)
            },
            //#endregion AppendLiveTick & UpdateAskAndBidValues on real time

            //#region web events
            ChartEvents: function (name) {
                switch (name) {
                    case "startfullscreen":
                        fullScreenButton.value = "exitfullscreen"
                        SetStartOrExitScreenIcon(changedTheme, false)
                        break;
                    case  "exitfullscreen":
                        fullScreenButton.value = "startfullscreen"
                        SetStartOrExitScreenIcon(changedTheme, false)
                        break;
                    case "showfullscreenicon":
                        fullScreenButton.value = "exitfullscreen"
                        SetStartOrExitScreenIcon(changedTheme, false, true)
                        break;
                    case "showexitfullscreenicon":
                        fullScreenButton.value = "startfullscreen"
                        SetStartOrExitScreenIcon(changedTheme, false, true)
                        break;
                }
            }
            //#endregion web events
        }
    }
    //#endregion FullChart Implementation

    //#region ResearchChart Implementation
    chartApp.ResearchChart = function () {
        let tvWidget;
        const logger = log.getLogger("research-chart"),
            disabledFeatures = ["left_toolbar", "header_widget", "timeframes_toolbar", "header_symbol_search", "context_menus", "header_compare", "trading_account_manager", "right_toolbar"],
            enabledFeatures = ["always_show_legend_values_on_mobile"];

        return {
            LoadChart: function (interval, chartObject, theme, isMobileApp) {
                logger.debug("LoadChart :", interval, chartObject, theme, isMobileApp);
                chartApp.config.source = isMobileApp ? 'Mobile' : 'Web';
                chartApp.config.isMobileApp = isMobileApp


                if (tvWidget) {
                    tvWidget.remove();
                }

                tvWidget = new TradingView.widget({
                    debug: chartApp.config.tvDebug,
                    fullscreen: true,
                    container: "tv_chart_container",
                    interval: interval,
                    autosize: true,
                    datafeed: chartApp.datafeed,
                    library_path: chartApp.config.libPath,
                    pinch_scale: true,
                    locale: "en",
                    header_widget_buttons_mode: 'adaptive',
                    disabled_features: disabledFeatures,
                    enabled_features: enabledFeatures,
                    client_id: 'tradingview.com',
                    user_id: 'public_user_id',
                    saved_data: JSON.parse(chartObject),
                })

                chartApp.tvWidget = tvWidget;

                tvWidget.subscribe('panes_order_changed', (e) => {
                    log.info('panes_order_changed executed')
                    tvWidget.changeTheme(tvWidget.getTheme())
                })

                tvWidget.onChartReady(() => {
                    logger.debug("onChartReady triggered");
                    const chart = tvWidget.chart();
                    chartApp.channel.sendChartStatus('initialLoad', chart.symbol(), theme);

                    chart.onIntervalChanged()
                        .subscribe(null, (interval, timeframeobj) => {
                            logger.debug("onIntervalChanged :", interval);
                            chartApp.quote.reRenderLastQuote(chart.symbol(), interval);
                        })
                })
                this.tvWidget = tvWidget;
            }
        }
    }
    //#endregion ResearchChart Implementation

    //#region CompactChart Implementation
    chartApp.CompactChart = function () {
        const logger = log.getLogger("compact-chart");
        const disabledFeatures = ["left_toolbar", "header_widget", "timeframes_toolbar", "header_symbol_search", "header_compare", "trading_account_manager", "right_toolbar"]
        const enabledFeatures = ["always_show_legend_values_on_mobile"]

        let tvWidget;
        let chartReady = false;

        function getIntervalAndDuration(timeFrame) {
            let interval;
            let duration;
            switch (timeFrame) {
                case "1D":
                case "D": {
                    interval = "1"
                    duration = "1D"
                    break;
                }
                case "5D": {
                    interval = "5"
                    duration = "5D"
                    break;
                }
                case "1M":
                case "M": {
                    interval = "30"
                    duration = "1M"
                    break;
                }
                case "6M": {
                    interval = "1D"
                    duration = "6M"
                    break;
                }
                case "1Y":
                case "Y": {
                    interval = "1D"
                    duration = "12M"
                    break;
                }
                case "5Y": {
                    interval = "1W"
                    duration = "60M"//5 years
                    break;
                }
                case "All": {
                    interval = "1M"
                    duration = "240M"//20year
                    break;
                }
                default: {
                    interval = "1"
                    duration = "1D"
                    break;
                }
            }
            return {interval, duration};
        }

        return {
            LoadChart: function (symbol, theme, isMobileApp) {
                logger.debug("LoadChart for", symbol, theme, isMobileApp);
                chartApp.config.source = isMobileApp ? 'Mobile' : 'Web';
                chartApp.config.isMobileApp = isMobileApp

                if (tvWidget) {
                    const chart = tvWidget.chart();
                    chart.setSymbol(symbol, {
                        dataReady: function () {
                            chartApp.channel.sendChartStatus('changeSymbol', symbol, theme);
                        }
                    });
                    chart.setTimeFrame({
                        val: {type: 'period-back', value: '1D'},
                        res: 1,
                    })
                    tvWidget.changeTheme(theme)
                    return;
                }

                tvWidget = new TradingView.widget({
                    debug: chartApp.config.tvDebug,
                    fullscreen: true,
                    symbol: symbol,
                    interval: '1',
                    container: "tv_chart_container",
                    timezone: "Asia/Kolkata",
                    autosize: true,
                    datafeed: chartApp.datafeed,
                    library_path: chartApp.config.libPath,
                    pinch_scale: true,
                    locale: "en",
                    header_widget_buttons_mode: 'adaptive',
                    disabled_features: disabledFeatures,
                    enabled_features: enabledFeatures,
                    client_id: 'tradingview.com',
                    user_id: 'public_user_id',
                })
                chartApp.tvWidget = tvWidget;

                tvWidget.subscribe('panes_order_changed', (e) => {
                    log.info('panes_order_changed executed')
                    tvWidget.changeTheme(tvWidget.getTheme())
                })

                tvWidget.onChartReady(() => {
                    logger.debug("onChartReady triggered");
                    chartReady = true;
                    chartApp.channel.sendChartStatus('initialLoad', symbol, theme);

                    const chart = tvWidget.chart();
                    chart.onIntervalChanged()
                        .subscribe(null, (interval, timeframeobj) => {
                            logger.debug("onIntervalChanged :", interval);
                            chartApp.quote.reRenderLastQuote(chart.symbol(), interval);
                        })
                })
            },
            AppendLiveTick: function (ticker, ltp, close, volume, tradeTime) {
                if (!tvWidget) {
                    logger.warn(`AppendLiveTick(${ticker}) called before chart init, Ignored...`);
                    return;
                }
                if (!chartReady) {
                    logger.warn(`AppendLiveTick(${ticker}) called before chartReady, Ignored...`);
                    return;
                }
                logger.debug("AppendLiveTick:", ticker, ltp, close, volume, tradeTime);

                let resolution = tvWidget.chart().resolution();
                //adding this condition because we don't have appendlivetick handler for Week & Months
                if (resolution === '1W' || resolution === '1M') {
                    resolution = '1D'
                }

                try {
                    chartApp.stream.onTickReceived(ticker, resolution, ltp, close, volume, tradeTime)
                } catch (err) {
                    logger.error("AppendLiveTick method error: " + err)
                }
            },
            SetTimeFrame: function (timeFrame) {
                if (!tvWidget) {
                    logger.warn(`SetTimeFrame(${timeFrame}) called before chart init, Ignored...`);
                    return;
                }
                logger.debug("SetTimeFrame :", timeFrame);
                let {interval, duration} = getIntervalAndDuration(timeFrame);
                tvWidget.onChartReady(() => {
                    logger.debug("onChartReady:SetTimeFrame :", timeFrame, interval, duration);
                    tvWidget.setTimeFrame({
                        val: {type: 'period-back', value: duration},
                        res: interval,
                    });
                });
            },
            ChangeChartType: function (chartTypeId) {
                if (!tvWidget) {
                    logger.warn(`ChangeChartType(${chartTypeId}) called before chart init, Ignored...`);
                    return;
                }
                logger.debug("ChangeChartType :", chartTypeId);
                tvWidget.onChartReady(() => {
                    logger.debug("onChartReady:ChangeChartType :", chartTypeId);
                    tvWidget.chart()
                        .setChartType(parseInt(chartTypeId))
                });
            }
        }
    };
    //#endregion CompactChart Implementation

    const logger = log.getLogger("main");
    const researchChart = new chartApp.ResearchChart();
    const fullChart = new chartApp.FullChart();
    const compactChart = new chartApp.CompactChart();

    //#region Global Functions
    async function Authorize(token) {
        logger.debug("Authorize :", token);
        localStore.saveOldToken(localStore.accessToken());
        if (chartApp.config.ValidateSession) {
            token = await httpAdapter.ValidateSession(token, chartApp.config.AppName);
        }
        localStore.saveToken(token);
        if (token) {
            httpAdapter.Retry401ErrorApis();
            return;
        }
        chartApp.LogException("401", "Main/Authorize", "Invalid Token", token);
    }

    let currentChartMode;

    function LoadChart(symbol, chartMode, rsChartInterval, rsChartData, isMobileApp, theme, isColorBlindFriendly) {
        chartMode = chartMode || 'FullChart';
        logger.debug("LoadChart :", symbol, chartMode, isMobileApp);
        if (currentChartMode && currentChartMode !== chartMode) {
            logger.error(`Chart initialised with '${currentChartMode}', can't be changed to '${chartMode}'`);
            return;
        }
        currentChartMode = chartMode;

        //SEBI requirement: alternate buy/sell button colors for color-blind users, read by AddBuySellButton in static_config.js.
        chartApp.config.isColorBlindFriendly = isColorBlindFriendly === true;

        const url = new URL(location.href)
        const params = new URLSearchParams(url.search);
        symbol = symbol || params.get("symbol");
        theme = theme || localStore.theme() || params.get("theme") || 'dark';

        if (chartMode === 'ResearchChart') {
            researchChart.LoadChart(rsChartInterval, rsChartData, theme, isMobileApp)
            return;
        }

        if (!symbol) {
            chartApp.showError('tv_chart_container', `Please pass a valid symbol`);
        }

        chartApp.adapter.chartHttp.symbolInfo(symbol).then(data => {
            _LoadChart(data.ticker, theme, chartMode, isMobileApp)
        }).catch(err => {
            logger.error('symbolInfo failed: ' + err + ' for symbol: ' + symbol)
            _LoadChart(symbol, theme, chartMode, isMobileApp)
        });
    }

    function _LoadChart(symbol, theme, chartMode, isMobileApp) {
        if (chartMode === 'LightWeightChart') {
            compactChart.LoadChart(symbol, theme, isMobileApp)
        } else {
            fullChart.LoadChart(symbol, theme, isMobileApp)
        }
    }

    function AppendLiveTick(symbol, ltp, close, volume, tradeTime) {
        logger.debug("AppendLiveTick :", symbol, ltp, close, volume, tradeTime);
        const symbolInfo = chartApp.data.symbolInfoMap.get(symbol);
        if (!symbolInfo) return;
        if (close === 0 || ltp === 0) {
            //Commenting as this creating noise in SEQ, This should reduce 90% of events in SEQ
            //chartApp.LogException('', `${currentChartMode}/AppendLiveTick`,
            //    `close price is 0 symbol: ${symbol}, ltp: ${ltp}, close: ${close}, volume: ${volume}, tradeTime: ${tradeTime}`)
            return;
        }
        //Convert tradeTime to ms.
        tradeTime = tradeTime * 1000;
        if (currentChartMode === 'LightWeightChart') {
            compactChart.AppendLiveTick(symbolInfo.ticker, parseFloat(ltp), parseFloat(close), parseInt(volume), tradeTime);
        } else {
            fullChart.AppendLiveTick(symbolInfo.ticker, parseFloat(ltp), parseFloat(close), parseInt(volume), tradeTime);
        }
    }

    function UpdateAskAndBidValues(symbol, ask, bid) {
        const symbolInfo = chartApp.data.symbolInfoMap.get(symbol);
        if (!symbolInfo) return;
        fullChart.UpdateAskAndBidValues(symbolInfo.ticker, ask, bid)
    }

    function SetTimeFrame(resolution) {
        logger.debug("SetTimeFrame :", resolution);
        compactChart.SetTimeFrame(resolution)
    }

    function ChangeChartType(chartTypeId) {
        logger.debug("ChangeChartType :", chartTypeId);
        compactChart.ChangeChartType(chartTypeId)
    }

    function ChangeTheme(theme) {
        if (theme === 'dark' || theme === 'light') {
            localStore.saveTheme(theme);
            fullChart.ChangeChartTheme(theme)
        }
    }

    function ChartEvents(name) {
        fullChart.ChartEvents(name)
    }
    //#endregion Global Functions

    //#region exposed functions for loading chart
    document.addEventListener('DOMContentLoaded', async () => {
        logger.info(chartApp.config.libPath);

        //for mobile application (backward compatible)
        window.Authorize = Authorize;
        window.LoadChart = function (symbol, chartMode, rsChartInterval, rsChartData, isMobileApp, isColorBlindFriendly) {
            if (typeof isMobileApp !== "boolean" && !isMobileApp) {
                isMobileApp = true
            }
            LoadChart(symbol, chartMode, rsChartInterval, rsChartData, isMobileApp, undefined, isColorBlindFriendly);
        }
        //Sequence of params is intentionally different.
        window.AppendLiveTickV2 = function (symbol, close, ltp, volume, tradeTime) {
            AppendLiveTick(symbol, ltp, close, volume, tradeTime);
        }
        window.SetTimeFrame = SetTimeFrame;
        window.ChangeChartType = ChangeChartType;
        window.ChartEvents = ChartEvents;
        window.UpdateAskAndBidValues = UpdateAskAndBidValues;

        //V1 api for Charts @lalkishor - 20th Oct 2023
        const v1 = {};
        v1.authorize = Authorize;
        v1.loadChart = function (symbol, chartMode, theme, isMobileApp, isColorBlindFriendly) {
            if (typeof isMobileApp !== "boolean" && !isMobileApp) {
                isMobileApp = true
            }
            LoadChart(symbol, chartMode, undefined, undefined, isMobileApp, theme, isColorBlindFriendly);
        }
        v1.loadResearchChart = function (interval, chartData, theme, isMobileApp) {
            if (typeof isMobileApp !== "boolean" && !isMobileApp) {
                isMobileApp = true
            }
            LoadChart(undefined, 'ResearchChart', interval, chartData, isMobileApp, theme);
        }
        v1.appendLiveTick = function (symbol, ltp, close, volume, tradeTime) {
            AppendLiveTick(symbol, ltp, close, volume, tradeTime);
        }
        v1.setTimeFrame = SetTimeFrame;
        v1.changeTheme = ChangeTheme;
        v1.ChartEvents = ChartEvents;

        chartApp.v1 = v1;

        //Send Page Ready Event.
        chartApp.channel.sendPageReady(chartApp.config.version);

        //for web 
        window.addEventListener('message', receiveMessage);

        function receiveMessage(event) {
            let data = event.data
            if (data.method === 'Authorize') {
                Authorize(data.token)
            } else if (data.method === 'LoadChart') {
                LoadChart(data.symbol, data.chartName, data.interval, data.chartObject, false, undefined, data.isColorBlindFriendly)
            } else if (data.method === 'AppendLiveTickV2') {
                AppendLiveTick(data.symbol, data.ltp, data.close, data.volume, data.tradeTime)
            } else if (data.method === 'UpdateAskAndBidValues') {
                /* as per the chart first button is ask but we have override the design to make it as bid hence here we are passing bid price to ask and ask to bid*/
                UpdateAskAndBidValues(data.symbol, data.bid, data.ask)
            } else if (data.method === 'SetTimeFrame') {
                SetTimeFrame(data.timeFrame)
            } else if (data.method === 'ChangeChartType') {
                ChangeChartType(data.chartTypeId)
            } else if (data.method === 'ChartEvent') {
                ChartEvents(data.name)
            }
        }
    })
    //#endregion exposed functions for loading chart

})(window, document, ChartApp);