'use strict';
'require view';
'require request';
'require ui';
'require poll';
'require dom';

return view.extend({
    chart: null,
    pollInterval: 30000,  // 30 秒刷新一次（与采集间隔一致）
    currentPeriod: 'day',  // 当前视图类型：day/month/year
    currentDate: '',  // 当前选中的日期（不依赖输入框）
    pollBound: null,  // 保存轮询函数引用，用于页面卸载时清理
    ipTableData: [],  // 保存所有 IP 数据
    currentPage: 1,  // 当前页码
    pageSize: 10,  // 每页显示 10 条
    searchTerm: '',  // 搜索关键词
    ipFilter: 'all',  // IP 过滤：all/ipv4/ipv6

    // 前端数据聚合：根据数据量自动调整时间粒度
    aggregateMinuteData: function(minuteData) {
        if (!minuteData || minuteData.length === 0) return minuteData;
        
        const dataCount = minuteData.length;
        let interval; // 聚合间隔（分钟）
        
        // 根据数据量决定聚合粒度
        if (dataCount <= 60) {
            // <= 60条（1小时内）：不聚合，保持原始数据
            return minuteData;
        } else if (dataCount <= 300) {
            // 60-300条（5小时内）：10分钟聚合
            interval = 10;
        } else if (dataCount <= 720) {
            // 300-720条（半天）：30分钟聚合
            interval = 30;
        } else {
            // > 720条（全天1440分钟）：1小时聚合
            interval = 60;
        }
        
        console.log('[Traffic] Aggregating data: ' + dataCount + ' records with ' + interval + ' min interval');
        
        // 按时间间隔聚合数据
        let aggregated = [];
        let bucket = null;
        
        for (let i = 0; i < minuteData.length; i++) {
            const item = minuteData[i];
            const timeStr = item.time || '';
            const timeParts = timeStr.split(':');
            if (timeParts.length !== 2) continue;
            
            const hour = parseInt(timeParts[0]) || 0;
            const minute = parseInt(timeParts[1]) || 0;
            
            // 计算当前数据点所属的时间桶
            const bucketMinute = Math.floor(minute / interval) * interval;
            const bucketTime = String(hour).padStart(2, '0') + ':' + String(bucketMinute).padStart(2, '0');
            
            if (!bucket || bucket.time !== bucketTime) {
                // 新的时间桶
                if (bucket) aggregated.push(bucket);
                bucket = {
                    time: bucketTime,
                    upload: item.upload || 0,
                    download: item.download || 0
                };
            } else {
                // 累加到当前桶
                bucket.upload += (item.upload || 0);
                bucket.download += (item.download || 0);
            }
        }
        
        // 添加最后一个桶
        if (bucket) aggregated.push(bucket);
        
        console.log('[Traffic] Aggregated to ' + aggregated.length + ' records');
        return aggregated;
    },

    // 页面卸载时停止轮询
    handlePageLeave: function() {
        if (this._pollTimer) {
            console.log('[Traffic] Page leave, stopping poll.');
            clearInterval(this._pollTimer);
            this._pollTimer = null;
        }
        // 销毁图表
        if (this.chart && typeof this.chart.destroy === 'function') {
            this.chart.destroy();
            this.chart = null;
        }
    },

    // 字节单位转换
    formatBytes: function(bytes) {
        if (bytes === 0) return '0 B';
        let k = 1024;
        let sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
        let i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    },

    // 加载流量数据
    loadTrafficData: function() {
        console.log('[Traffic] Loading data...');
        let _this = this;
        let period = document.getElementById('period-select')?.value || 'day';
        this.currentPeriod = period;

        // 使用本地时区日期，避免 UTC 时区问题
        const now = new Date();
        const today = now.getFullYear() + '-' + 
                      String(now.getMonth() + 1).padStart(2, '0') + '-' + 
                      String(now.getDate()).padStart(2, '0');
        const thisMonth = today.substring(0, 7);
        const thisYear = today.substring(0, 4);
        
        let date;
        if (period === 'year') {
            date = thisYear;
        } else if (period === 'month') {
            date = thisMonth;
        } else {
            date = today;  // 日视图始终使用今天
        }
        
        this.currentDate = date;
        
        // 立即同步更新输入框的值（在浏览器恢复缓存之前）
        setTimeout(() => {
            let dateInput = document.getElementById('date-input');
            if (dateInput && period === 'day') {
                dateInput.value = today;
            }
        }, 0);

        console.log('[Traffic] Request params: period=' + period + ', date=' + date);

        // 构建 URL 参数
        let baseUrl = L.url('admin/services/nikki/api/traffic_stats');
        let sep = baseUrl.indexOf('?') === -1 ? '?' : '&';
        let url = baseUrl + sep + 'period=' + encodeURIComponent(period) + '&date=' + encodeURIComponent(date);
        
        console.log('[Traffic] Request URL: ' + url);

        return request.get(url).then(function(res) {
            return res.json();
        }).then(function(data) {
            console.log('[Traffic] Response data:', data);
            _this.renderChart(data, period);
            _this.updateTable(data.ip || []);  // 更新表格（自动使用当前搜索词和过滤）
            
            // 根据视图类型显示摘要
            if (period === 'day') {
                _this.updateSummary(data.global || []);  // 日视图：显示当天总量
            } else if (period === 'month') {
                _this.updateSummary(data.monthly || []);  // 月视图：显示当月总量
            } else if (period === 'year') {
                _this.updateSummary(data.yearly || []);  // 年视图：显示当年总量
            }

            const chartEl = document.getElementById('traffic-chart');
            if (chartEl) {
                chartEl.classList.remove('hidden');
            }
        }).catch(function(e) {
            console.error('[Traffic] Failed to load traffic data:', e);
            ui.addNotification(null, E('p', _('Failed to load traffic data: ') + e));
        });
    },

    // 渲染图表
    renderChart: function(data, period) {
        const _this = this;
        const canvas = document.getElementById('traffic-chart');
        if (!canvas) return;

        if (!window.Chart) {
            let script = document.createElement('script');
            script.src = '/luci-static/resources/chart.umd.js';
            script.onload = () => _this._doRender(canvas, data, period);
            script.onerror = () => {
                console.error('Failed to load Chart.js');
            };
            document.head.appendChild(script);
        } else {
            _this._doRender(canvas, data, period);
        }
    },

    _doRender: function(canvas, data, period) {
        const _this = this;
        // 确保在创建新实例前彻底销毁旧实例
        if (this.chart && typeof this.chart.destroy === 'function') {
            this.chart.destroy();
            this.chart = null;
        }

        let labels, upData, downData, chartType;

        // 处理 API 返回的数据
        if (period === 'year') {
            // 年度视图：柱状图，显示 12 个月
            chartType = 'bar';
            console.log('[Traffic] Year view - data.monthly:', data.monthly);
            if (data.monthly && Array.isArray(data.monthly) && data.monthly.length > 0) {
                labels = data.monthly.map(d => {
                    const month = (d.month || '').split('-')[1] || '';
                    return month ? month + '月' : '';
                });
                upData = data.monthly.map(d => d.upload || 0);
                downData = data.monthly.map(d => d.download || 0);
            } else {
                console.log('[Traffic] Year view - No monthly data, using empty arrays');
                labels = [];
                upData = [];
                downData = [];
            }
        } else if (period === 'month') {
            // 月份视图：柱状图，显示每天
            chartType = 'bar';
            console.log('[Traffic] Month view - data.daily:', data.daily);
            if (data.daily && Array.isArray(data.daily) && data.daily.length > 0) {
                labels = data.daily.map(d => {
                    const day = (d.date || '').split('-')[2] || '';
                    return day ? day + '日' : '';
                });
                upData = data.daily.map(d => d.upload || 0);
                downData = data.daily.map(d => d.download || 0);
            } else {
                console.log('[Traffic] Month view - No daily data, using empty arrays');
                labels = [];
                upData = [];
                downData = [];
            }
        } else if (period === 'day') {
            // 日视图：折线图，显示每分钟（前端自动聚合）
            chartType = 'line';
            console.log('[Traffic] Day view - data.minute:', data.minute);
            if (data.minute && Array.isArray(data.minute) && data.minute.length > 0) {
                // 前端数据聚合：根据数据量自动调整时间粒度
                const aggregatedData = this.aggregateMinuteData(data.minute);
                labels = aggregatedData.map(d => d.time || '');
                upData = aggregatedData.map(d => d.upload || 0);
                downData = aggregatedData.map(d => d.download || 0);
                console.log('[Traffic] Day view aggregated: ' + data.minute.length + ' -> ' + labels.length + ' points');
            } else {
                console.log('[Traffic] Day view - No minute data, using empty arrays');
                labels = [];
                upData = [];
                downData = [];
            }
        } else {
            chartType = 'line';
            labels = [];
            upData = [];
            downData = [];
        }
        
        console.log('[Traffic] Chart data - labels:', labels.length, 'upData:', upData.length, 'downData:', downData.length);

        // 动态调整X轴刻度（聚合后数据量已经优化，直接显示）
        const dataCount = labels.length;
        let maxTicksLimit = Math.min(dataCount, 24);  // 最多显示 24 个刻度
        let autoSkip = true;

        this.chart = new Chart(canvas.getContext('2d'), {
            type: chartType,
            data: {
                labels: labels,
                datasets: [
                    {
                        label: _('Upload'),
                        data: upData,
                        backgroundColor: 'rgba(52, 152, 219, 0.9)',
                        borderColor: '#2980b9',
                        borderWidth: 1,
                        barThickness: chartType === 'bar' ? 15 : undefined,
                        maxBarThickness: chartType === 'bar' ? 20 : undefined,
                        order: 2
                    },
                    {
                        label: _('Download'),
                        data: downData,
                        backgroundColor: 'rgba(46, 204, 113, 0.9)',
                        borderColor: '#27ae60',
                        borderWidth: 1,
                        barThickness: chartType === 'bar' ? 15 : undefined,
                        maxBarThickness: chartType === 'bar' ? 20 : undefined,
                        order: 1
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                layout: {
                    padding: {
                        top: 10,
                        bottom: 10
                    }
                },
                interaction: {
                    mode: 'nearest',
                    axis: 'x',
                    intersect: false
                },
                scales: {
                    x: {
                        grid: {
                            display: chartType === 'line',
                            color: 'rgba(0, 0, 0, 0.1)'
                        },
                        ticks: {
                            maxRotation: 0,
                            minRotation: 0,
                            autoSkip: autoSkip,
                            maxTicksLimit: maxTicksLimit,
                            // 手机端字体自适应
                            font: {
                                size: window.innerWidth < 768 ? 10 : 12
                            }
                        }
                    },
                    y: {
                        beginAtZero: true,
                        grid: {
                            color: 'rgba(0, 0, 0, 0.05)'
                        },
                        ticks: {
                            callback: function(v) {
                                return _this.formatBytes(v);
                            },
                            font: {
                                size: window.innerWidth < 768 ? 10 : 12
                            }
                        }
                    }
                },
                plugins: {
                    legend: {
                        position: 'top',
                        align: 'end',
                        labels: {
                            usePointStyle: true,
                            pointStyle: 'rect',
                            padding: 15,
                            boxWidth: 12,
                            boxHeight: 12
                        }
                    },
                    tooltip: {
                        enabled: true,
                        mode: 'index',
                        intersect: false,
                        backgroundColor: 'rgba(0, 0, 0, 0.85)',
                        titleColor: '#fff',
                        bodyColor: '#fff',
                        borderColor: 'rgba(255, 255, 255, 0.3)',
                        borderWidth: 1,
                        padding: 10,
                        displayColors: true,
                        cornerRadius: 4,
                        caretSize: 8,
                        callbacks: {
                            title: function(context) {
                                const label = context[0].label;
                                return label;
                            },
                            label: function(context) {
                                const datasetLabel = context.dataset.label || '';
                                const value = context.parsed.y || 0;
                                return '  ' + datasetLabel + ': ' + _this.formatBytes(value);
                            },
                            afterBody: function(context) {
                                // 显示总计
                                let total = 0;
                                context.forEach(function(item) {
                                    total += item.parsed.y || 0;
                                });
                                return '\\n总计：' + _this.formatBytes(total);
                            }
                        }
                    }
                }
            }
        });
    },

    // 更新 IP 表格（支持搜索、分页、IPv4/IPv6 过滤、倒序排序）
    updateTable: function(ipData) {
        let _this = this;
        let tbody = document.getElementById('ip-table-body');
        if (!tbody) return;

        // 保存所有数据
        let ipArray = [];
        if (Array.isArray(ipData)) {
            ipArray = ipData;
        } else if (ipData && typeof ipData === 'object') {
            ipArray = Object.values(ipData) || [];
        }
        this.ipTableData = ipArray;

        // 1. 过滤数据（支持模糊搜索）
        let filteredArray = ipArray;
        if (this.searchTerm && this.searchTerm.trim()) {
            let term = this.searchTerm.toLowerCase().trim();
            filteredArray = ipArray.filter(row => {
                let ip = (row.ip || row.ip_address || '').toLowerCase();
                return ip.includes(term);
            });
            console.log('[Traffic] Search filter: "' + term + '", found ' + filteredArray.length + ' of ' + ipArray.length);
        }

        // 2. IPv4/IPv6 过滤
        if (this.ipFilter === 'ipv4') {
            filteredArray = filteredArray.filter(row => {
                let ip = row.ip || row.ip_address || '';
                return ip.includes(':') === false;  // 不含冒号的是 IPv4
            });
            console.log('[Traffic] IPv4 filter: ' + filteredArray.length + ' of ' + ipArray.length);
        } else if (this.ipFilter === 'ipv6') {
            filteredArray = filteredArray.filter(row => {
                let ip = row.ip || row.ip_address || '';
                return ip.includes(':') === true;  // 含冒号的是 IPv6
            });
            console.log('[Traffic] IPv6 filter: ' + filteredArray.length + ' of ' + ipArray.length);
        }

        // 3. 按总量倒序排序
        filteredArray.sort((a, b) => {
            let totalA = (a.upload || 0) + (a.download || 0);
            let totalB = (b.upload || 0) + (b.download || 0);
            return totalB - totalA;  // 倒序
        });

        // 4. 计算分页
        let totalPages = Math.ceil(filteredArray.length / this.pageSize);
        if (this.currentPage > totalPages) this.currentPage = Math.max(1, totalPages);
        if (this.currentPage < 1) this.currentPage = 1;

        let startIndex = (this.currentPage - 1) * this.pageSize;
        let endIndex = startIndex + this.pageSize;
        let pageData = filteredArray.slice(startIndex, endIndex);

        console.log('[Traffic] Page ' + this.currentPage + '/' + totalPages + ', showing ' + pageData.length + ' of ' + filteredArray.length);

        tbody.innerHTML = '';

        if (!pageData || pageData.length === 0) {
            tbody.appendChild(E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td', 'colspan': '4' }, 
                    this.searchTerm || this.ipFilter !== 'all' ? _('No matching IP found') : _('No data available'))
            ]));
        } else {
            const isMobile = window.innerWidth < 768;
            // 手机端数据单元格样式：所有IP都不换行，表格横向滚动
            const tdStyle = isMobile
                ? 'white-space: nowrap; padding: 8px; vertical-align: middle; font-size: 12px;'
                : 'padding: 8px;';

            pageData.forEach(row => {
                tbody.appendChild(E('tr', { 'class': 'tr' }, [
                    E('td', { 'class': 'td', 'style': tdStyle }, row.ip || row.ip_address || _('Unknown')),
                    E('td', { 'class': 'td', 'style': tdStyle }, this.formatBytes(row.upload || 0)),
                    E('td', { 'class': 'td', 'style': tdStyle }, this.formatBytes(row.download || 0)),
                    E('td', { 'class': 'td', 'style': tdStyle }, this.formatBytes((row.upload || 0) + (row.download || 0)))
                ]));
            });
        }

        // 更新分页控件
        this.updatePagination(totalPages);
    },

    // 更新分页控件
    updatePagination: function(totalPages) {
        let pagination = document.getElementById('ip-pagination');
        if (!pagination) return;

        pagination.innerHTML = '';

        if (totalPages <= 1) {
            pagination.style.display = 'none';
            return;
        }

        pagination.style.display = 'flex';

        // 上一页
        let prevBtn = E('button', {
            'class': 'cbi-button cbi-button-prev',
            'disabled': this.currentPage === 1 ? 'disabled' : null,
            'click': () => {
                if (this.currentPage > 1) {
                    this.currentPage--;
                    this.updateTable(this.ipTableData);
                }
            }
        }, '← ' + _('Prev'));

        // 页码显示
        let pageInfo = E('span', {
            'class': 'pagination-info',
            'style': 'margin: 0 10px; align-self: center;'
        }, this.currentPage + ' / ' + totalPages);

        // 下一页
        let nextBtn = E('button', {
            'class': 'cbi-button cbi-button-next',
            'disabled': this.currentPage === totalPages ? 'disabled' : null,
            'click': () => {
                if (this.currentPage < totalPages) {
                    this.currentPage++;
                    this.updateTable(this.ipTableData);
                }
            }
        }, _('Next') + ' →');

        pagination.appendChild(prevBtn);
        pagination.appendChild(pageInfo);
        pagination.appendChild(nextBtn);
    },

    // 设置搜索关键词并刷新表格
    setSearchTerm: function(term) {
        this.searchTerm = term;
        this.currentPage = 1;  // 重置到第一页
        this.updateTable(this.ipTableData);
    },

    // 更新摘要
    updateSummary: function(globalData) {
        let summary = document.getElementById('traffic-summary');
        if (!summary) return;

        if (!globalData || !globalData[0]) {
            summary.innerHTML = '<p>' + _('No data available') + '</p>';
            return;
        }

        let data = globalData[0];
        let upload = data.upload || 0;
        let download = data.download || 0;

        summary.innerHTML = '' +
            '<div class="cbi-value"><label class="cbi-value-title">' + _('Total Upload') + '</label>' +
            '<div class="cbi-value-field">' + this.formatBytes(upload) + '</div></div>' +
            '<div class="cbi-value"><label class="cbi-value-title">' + _('Total Download') + '</label>' +
            '<div class="cbi-value-field">' + this.formatBytes(download) + '</div></div>';
    },

    // 更新日期输入框类型（仅用于显示，不影响 currentDate）
    updateDateInput: function(period) {
        const dateInput = document.getElementById('date-input');
        if (!dateInput) return;

        // 使用本地时区日期
        const now = new Date();
        const today = now.getFullYear() + '-' + 
                      String(now.getMonth() + 1).padStart(2, '0') + '-' + 
                      String(now.getDate()).padStart(2, '0');
        const thisMonth = today.substring(0, 7);
        const thisYear = today.substring(0, 4);

        console.log('[Traffic] updateDateInput: period=' + period);

        if (period === 'day') {
            dateInput.type = 'date';
            dateInput.value = this.currentDate || today;
            console.log('[Traffic] Day input set to: ' + dateInput.value);
        } else if (period === 'month') {
            dateInput.type = 'month';
            dateInput.value = this.currentDate || thisMonth;
            console.log('[Traffic] Month input set to: ' + dateInput.value);
        } else if (period === 'year') {
            dateInput.type = 'number';
            dateInput.min = '2020';
            dateInput.max = '2030';
            dateInput.value = this.currentDate || thisYear;
            console.log('[Traffic] Year input set to: ' + dateInput.value);
        }
    },

    // 设置日期（切换视图时调用）
    setCurrentDate: function(date) {
        this.currentDate = date;
    },

    render: function() {
        const _this = this;
        
        // 检测是否为移动端设备（红米K80宽度为1080px，但浏览器视口约为400-420px）
        const isMobile = window.innerWidth < 768;
            
        // 使用本地时区日期，避免 UTC 时区问题
        const now = new Date();
        const today = now.getFullYear() + '-' + 
                      String(now.getMonth() + 1).padStart(2, '0') + '-' + 
                      String(now.getDate()).padStart(2, '0');
        const thisMonth = today.substring(0, 7);
        const thisYear = today.substring(0, 4);
            
        // 初始化 currentDate 为今天（日视图）
        this.currentDate = today;

        // 手机端优化：动态图表高度
        const chartHeight = isMobile ? 280 : 400;

        // 手机端优化：控件垂直布局 + 自适应间距
        const controlStyle = isMobile
            ? 'margin-bottom: 15px; display: flex; flex-direction: column; gap: 8px; align-items: stretch;'
            : 'margin-bottom: 20px; display: flex; gap: 10px; align-items: center; flex-wrap: wrap;';

        const labelStyle = isMobile
            ? 'font-weight: bold; margin-bottom: 4px;'
            : 'font-weight: bold;';

        const controls = E('div', { 'style': controlStyle }, [
            // 第一行：统计周期
            E('div', { 'style': isMobile ? 'display: flex; flex-direction: column;' : 'display: flex; align-items: center; gap: 8px;' }, [
                E('label', { 'style': labelStyle }, _('Period') + ': '),
                E('select', {
                    'id': 'period-select',
                    'class': 'cbi-input-select',
                    'style': isMobile ? 'min-height: 44px; padding: 8px;' : '',
                    'change': (e) => {
                        let newPeriod = e.target.value;
                        console.log('[Traffic] Period changed to: ' + newPeriod);
                        
                        // 更新日期 - 使用本地时区
                        const now = new Date();
                        const today = now.getFullYear() + '-' + 
                                      String(now.getMonth() + 1).padStart(2, '0') + '-' + 
                                      String(now.getDate()).padStart(2, '0');
                        const thisMonth = today.substring(0, 7);
                        const thisYear = today.substring(0, 4);
                        
                        if (newPeriod === 'year') _this.setCurrentDate(thisYear);
                        else if (newPeriod === 'month') _this.setCurrentDate(thisMonth);
                        else _this.setCurrentDate(today);
                        
                        _this.updateDateInput(newPeriod);
                        _this.loadTrafficData();
                    }
                }, [
                    E('option', { 'value': 'day' }, _('Daily View')),
                    E('option', { 'value': 'month' }, _('Monthly View')),
                    E('option', { 'value': 'year' }, _('Yearly View'))
                ])
            ]),
            // 第二行：日期选择 + 刷新按钮
            E('div', { 'style': isMobile ? 'display: flex; gap: 8px; align-items: flex-end;' : 'display: flex; align-items: center; gap: 10px; margin-left: 10px;' }, [
                E('label', { 'style': labelStyle }, _('Date') + ': '),
                E('input', {
                    'id': 'date-input',
                    'type': 'date',  // 默认是日视图，所以使用 date 类型
                    'class': 'cbi-input-text',
                    'style': isMobile ? 'min-height: 44px; padding: 8px; flex: 1;' : '',
                    'value': today,  // 使用今天的日期
                    'autocomplete': 'off',  // 禁用浏览器自动填充
                    'change': () => {
                        console.log('[Traffic] Date input changed');
                        let dateInput = document.getElementById('date-input');
                        if (dateInput && dateInput.value) {
                            _this.setCurrentDate(dateInput.value);
                            _this.loadTrafficData();
                        }
                    }
                }),
                E('button', {
                    'class': 'cbi-button cbi-button-action',
                    'style': isMobile ? 'min-height: 44px; min-width: 44px; padding: 8px 16px;' : '',
                    'click': () => _this.loadTrafficData()
                }, _('Refresh'))
            ])
        ]);

        let view = E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('Traffic Statistics')),
            E('div', { 'id': 'traffic-summary', 'class': 'cbi-section' }),
            controls,
            // 手机端优化：动态高度
            E('div', { 'class': 'cbi-section', 'style': `height: ${chartHeight}px; position: relative;` }, [
                E('canvas', { 'id': 'traffic-chart' })
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('div', { 'style': isMobile
                    ? 'display: flex; flex-direction: column; gap: 10px; margin-bottom: 10px;'
                    : 'display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; flex-wrap: wrap; gap: 10px;'
                }, [
                    E('h3', { 'id': 'ip-table-title', 'style': isMobile ? 'margin: 0;' : '' }, _('Top IP Traffic')),
                    E('div', { 'style': isMobile
                        ? 'display: flex; gap: 8px; align-items: stretch; width: 100%;'
                        : 'display: flex; gap: 10px; align-items: center;'
                    }, [
                        E('select', {
                            'id': 'ip-filter-select',
                            'class': 'cbi-input-select',
                            'style': isMobile ? 'min-height: 44px; flex: 1;' : '',
                            'value': this.ipFilter,
                            'change': (e) => {
                                this.ipFilter = e.target.value;
                                this.currentPage = 1;
                                this.updateTable(this.ipTableData);
                            }
                        }, [
                            E('option', { 'value': 'all' }, _('All IPs')),
                            E('option', { 'value': 'ipv4' }, 'IPv4'),
                            E('option', { 'value': 'ipv6' }, 'IPv6')
                        ]),
                        // 手机端优化：搜索框自适应宽度
                        E('input', {
                            'id': 'ip-search-input',
                            'type': 'text',
                            'class': 'cbi-input-text',
                            'placeholder': _('Search IP...'),
                            'style': isMobile
                                ? 'min-height: 44px; flex: 2; padding: 8px;'
                                : 'width: 150px; padding: 8px;',
                            'input': (e) => {
                                this.setSearchTerm(e.target.value);
                            }
                        })
                    ])
                ]),
                // 手机端优化：表格横向滚动（直接使用 tr 作为表头，不用 thead）
                E('div', { 'id': 'ip-table-wrapper', 'style': isMobile ? 'overflow-x: auto; -webkit-overflow-scrolling: touch; margin-top: 10px; background: #f8f9fa; border-radius: 4px;' : '' }, [
                    E('table', { 'class': 'table', 'id': 'ip-table', 'style': isMobile ? 'min-width: 600px; border-collapse: collapse;' : '' }, [
                        // 直接在表格第一行渲染表头（不用 thead 标签）
                        E('tr', { 
                            'class': 'tr table-titles',
                            'style': isMobile ? 'background: #e9ecef; font-weight: bold; border-bottom: 2px solid #dee2e6;' : ''
                        }, [
                            E('th', { 
                                'class': 'th', 
                                'style': isMobile ? 'padding: 12px 8px; font-size: 13px; white-space: nowrap; text-align: left; color: #495057;' : '' 
                            }, _('IP Address')),
                            E('th', { 
                                'class': 'th', 
                                'style': isMobile ? 'padding: 12px 8px; font-size: 13px; white-space: nowrap; text-align: center; color: #495057;' : '' 
                            }, _('Upload')),
                            E('th', { 
                                'class': 'th', 
                                'style': isMobile ? 'padding: 12px 8px; font-size: 13px; white-space: nowrap; text-align: center; color: #495057;' : '' 
                            }, _('Download')),
                            E('th', { 
                                'class': 'th', 
                                'style': isMobile ? 'padding: 12px 8px; font-size: 13px; white-space: nowrap; text-align: center; color: #495057;' : '' 
                            }, _('Total'))
                        ]),
                        E('tbody', { 'id': 'ip-table-body' })
                    ])
                ]),
                // 手机端优化：分页控件
                E('div', {
                    'id': 'ip-pagination',
                    'class': 'cbi-page-control',
                    'style': isMobile
                        ? 'display: flex; justify-content: center; margin-top: 10px; gap: 8px;'
                        : 'display: flex; justify-content: center; margin-top: 10px;'
                })
            ])
        ]);

        // 初始加载
        this.loadTrafficData();
        
        // 清除旧的定时器（如果存在）
        if (this._pollTimer) {
            clearInterval(this._pollTimer);
        }

        // 启动轮询（使用 setInterval 更可靠）
        console.log('[Traffic] Starting poll, interval:', this.pollInterval, 'ms');
        this._pollTimer = setInterval(function() {
            // 检查页面元素是否存在，不存在则停止
            if (!document.getElementById('traffic-chart')) {
                console.log('[Traffic] Chart element not found, stopping poll.');
                if (this._pollTimer) {
                    clearInterval(this._pollTimer);
                    this._pollTimer = null;
                }
                return;
            }
            console.log('[Traffic] Polling...');
            _this.loadTrafficData();
        }, this.pollInterval);

        // 监听页面切换事件，停止轮询
        document.addEventListener('uci:section-change', function() {
            _this.handlePageLeave();
        });

        return view;
    }
});
