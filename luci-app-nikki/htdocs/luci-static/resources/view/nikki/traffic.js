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
    pollBound: null,  // 保存轮询函数引用，用于页面卸载时清理
    ipTableData: [],  // 保存所有 IP 数据
    currentPage: 1,  // 当前页码
    pageSize: 10,  // 每页显示 10 条
    searchTerm: '',  // 搜索关键词

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

        let date = '';
        const dateInput = document.getElementById('date-input');
        
        // 优先从日期输入框获取值
        if (dateInput && dateInput.value) {
            date = dateInput.value;
        } else {
            // 如果输入框为空，根据视图类型生成默认日期
            const today = new Date().toISOString().split('T')[0];
            const thisMonth = today.substring(0, 7);
            const thisYear = today.substring(0, 4);
            if (period === 'year') date = thisYear;
            else if (period === 'month') date = thisMonth;
            else date = today;
        }
        
        // 日视图需要完整日期格式 (YYYY-MM-DD)
        if (period === 'day' && date.length === 7) {
            // 如果日期是月份格式 (2026-04)，转换为完整日期 (2026-04-01)
            date = date + '-01';
        }

        // 获取搜索关键词
        let searchTerm = document.getElementById('ip-search-input')?.value || '';

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
            _this.updateTable(data.ip || []);  // 更新表格（自动使用当前搜索词和分页）
            _this.updateSummary(data.global || data.monthly || data.daily || []);

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
            // 日视图：折线图，显示每分钟
            chartType = 'line';
            console.log('[Traffic] Day view - data.minute:', data.minute);
            if (data.minute && Array.isArray(data.minute) && data.minute.length > 0) {
                labels = data.minute.map(d => d.time || '');
                upData = data.minute.map(d => d.upload || 0);
                downData = data.minute.map(d => d.download || 0);
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
                            autoSkip: chartType === 'line',
                            maxTicksLimit: chartType === 'line' ? 12 : undefined
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

    // 更新 IP 表格（支持搜索和分页）
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

        // 过滤数据（支持模糊搜索）
        let filteredArray = ipArray;
        if (this.searchTerm && this.searchTerm.trim()) {
            let term = this.searchTerm.toLowerCase().trim();
            filteredArray = ipArray.filter(row => {
                let ip = (row.ip || row.ip_address || '').toLowerCase();
                return ip.includes(term);
            });
            console.log('[Traffic] Search filter: "' + term + '", found ' + filteredArray.length + ' of ' + ipArray.length);
        }

        // 计算分页
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
                    this.searchTerm ? _('No matching IP found') : _('No data available'))
            ]));
        } else {
            pageData.forEach(row => {
                tbody.appendChild(E('tr', { 'class': 'tr' }, [
                    E('td', { 'class': 'td' }, row.ip || row.ip_address || _('Unknown')),
                    E('td', { 'class': 'td' }, this.formatBytes(row.upload || 0)),
                    E('td', { 'class': 'td' }, this.formatBytes(row.download || 0)),
                    E('td', { 'class': 'td' }, this.formatBytes((row.upload || 0) + (row.download || 0)))
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

    // 更新日期输入框类型
    updateDateInput: function(period) {
        const dateInput = document.getElementById('date-input');
        if (!dateInput) return;

        const today = new Date().toISOString().split('T')[0];
        const thisMonth = today.substring(0, 7);
        const thisYear = today.substring(0, 4);

        console.log('[Traffic] updateDateInput: period=' + period);

        if (period === 'day') {
            dateInput.type = 'date';
            dateInput.value = today;
            console.log('[Traffic] Day input set to: ' + today);
        } else if (period === 'month') {
            dateInput.type = 'month';
            dateInput.value = thisMonth;
            console.log('[Traffic] Month input set to: ' + thisMonth);
        } else if (period === 'year') {
            dateInput.type = 'number';
            dateInput.min = '2020';
            dateInput.max = '2030';
            dateInput.value = thisYear;
            console.log('[Traffic] Year input set to: ' + thisYear);
        }
    },

    render: function() {
        const _this = this;
        let today = new Date().toISOString().split('T')[0];
        let thisMonth = today.substring(0, 7);
        let thisYear = today.substring(0, 4);

        let controls = E('div', { 'style': 'margin-bottom: 20px; display: flex; gap: 10px; align-items: center; flex-wrap: wrap;' }, [
            E('label', { 'style': 'font-weight: bold;' }, _('Period') + ': '),
            E('select', {
                'id': 'period-select',
                'class': 'cbi-input-select',
                'change': (e) => {
                    let newPeriod = e.target.value;
                    console.log('[Traffic] Period changed to: ' + newPeriod);
                    _this.updateDateInput(newPeriod);
                    _this.loadTrafficData();
                }
            }, [
                E('option', { 'value': 'day' }, _('Daily View')),
                E('option', { 'value': 'month' }, _('Monthly View')),
                E('option', { 'value': 'year' }, _('Yearly View'))
            ]),
            E('label', { 'style': 'font-weight: bold; margin-left: 10px;' }, _('Date') + ': '),
            E('input', {
                'id': 'date-input',
                'type': 'month',
                'class': 'cbi-input-text',
                'value': thisMonth,
                'change': () => {
                    console.log('[Traffic] Date input changed');
                    _this.loadTrafficData();
                }
            }),
            E('button', {
                'class': 'cbi-button cbi-button-action',
                'style': 'margin-left: 10px;',
                'click': () => _this.loadTrafficData()
            }, _('Refresh'))
        ]);

        let view = E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('Traffic Statistics')),
            E('div', { 'id': 'traffic-summary', 'class': 'cbi-section' }),
            controls,
            E('div', { 'class': 'cbi-section', 'style': 'height: 400px; position: relative;' }, [
                E('canvas', { 'id': 'traffic-chart' })
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('div', { 'style': 'display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;' }, [
                    E('h3', { 'id': 'ip-table-title' }, _('Top IP Traffic')),
                    E('input', {
                        'id': 'ip-search-input',
                        'type': 'text',
                        'class': 'cbi-input-text',
                        'placeholder': _('Search IP...'),
                        'style': 'width: 200px;',
                        'input': (e) => {
                            _this.setSearchTerm(e.target.value);
                        }
                    })
                ]),
                E('table', { 'class': 'table', 'id': 'ip-table' }, [
                    E('tr', { 'class': 'tr table-titles' }, [
                        E('th', { 'class': 'th' }, _('IP Address')),
                        E('th', { 'class': 'th' }, _('Upload')),
                        E('th', { 'class': 'th' }, _('Download')),
                        E('th', { 'class': 'th' }, _('Total'))
                    ]),
                    E('tbody', { 'id': 'ip-table-body' })
                ]),
                E('div', {
                    'id': 'ip-pagination',
                    'class': 'cbi-page-control',
                    'style': 'display: flex; justify-content: center; margin-top: 10px;'
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
