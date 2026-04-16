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

    // 页面卸载时停止轮询
    handlePageLeave: function() {
        if (this.pollBound) {
            poll.remove(this.pollBound);
            this.pollBound = null;
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
        let _this = this;
        let period = document.getElementById('period-select')?.value || 'day';
        this.currentPeriod = period;

        let date = '';
        const dateInput = document.getElementById('date-input');
        if (dateInput) {
            date = dateInput.value;
        } else {
            const today = new Date().toISOString().split('T')[0];
            const thisMonth = today.substring(0, 7);
            const thisYear = today.substring(0, 4);
            if (period === 'year') date = thisYear;
            else if (period === 'month') date = thisMonth;
            else date = today;
        }

        let url = L.url('admin/services/nikki/api/traffic_stats');
        let params = new URLSearchParams({ period: period, date: date });
        
        return L.resolveDefault(
            request.get(url + '?' + params.toString()),
            { json: () => ({ minute: [], global: [], ip: [] }) }
        ).then(res => res.json()).then(data => {
            _this.renderChart(data, period);
            _this.updateTable(data.ip || []);
            _this.updateSummary(data.global || data.monthly || data.daily || []);

            // 修复：使用 classList 代替不存在的 dom.removeClass
            const chartEl = document.getElementById('traffic-chart');
            if (chartEl) {
                chartEl.classList.remove('hidden');
            }
        }).catch(e => {
            console.error('Failed to load traffic data:', e);
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
            if (data.monthly && data.monthly.length > 0) {
                labels = data.monthly.map(d => {
                    const month = (d.month || '').split('-')[1] || '';
                    return month ? month + '月' : '';
                });
                upData = data.monthly.map(d => d.upload || 0);
                downData = data.monthly.map(d => d.download || 0);
            } else {
                labels = [];
                upData = [];
                downData = [];
            }
        } else if (period === 'month') {
            // 月份视图：柱状图，显示每天
            chartType = 'bar';
            if (data.daily && data.daily.length > 0) {
                labels = data.daily.map(d => {
                    const day = (d.date || '').split('-')[2] || '';
                    return day ? day + '日' : '';
                });
                upData = data.daily.map(d => d.upload || 0);
                downData = data.daily.map(d => d.download || 0);
            } else {
                labels = [];
                upData = [];
                downData = [];
            }
        } else if (period === 'day') {
            // 日视图：折线图，显示每分钟
            chartType = 'line';
            if (data.minute && data.minute.length > 0) {
                labels = data.minute.map(d => d.time || '');
                upData = data.minute.map(d => d.upload || 0);
                downData = data.minute.map(d => d.download || 0);
            } else {
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

    // 更新 IP 表格
    updateTable: function(ipData) {
        let tbody = document.getElementById('ip-table-body');
        if (!tbody) return;

        tbody.innerHTML = '';

        // 确保 ipData 是数组
        let ipArray = [];
        if (Array.isArray(ipData)) {
            ipArray = ipData;
        } else if (ipData && typeof ipData === 'object') {
            // 如果是对象，尝试转换为数组
            ipArray = Object.values(ipData) || [];
        }

        if (!ipArray || ipArray.length === 0) {
            tbody.appendChild(E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td', 'colspan': '4' }, _('No data available'))
            ]));
            return;
        }

        ipArray.forEach(row => {
            tbody.appendChild(E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td' }, row.ip || row.ip_address || _('Unknown')),
                E('td', { 'class': 'td' }, this.formatBytes(row.upload || 0)),
                E('td', { 'class': 'td' }, this.formatBytes(row.download || 0)),
                E('td', { 'class': 'td' }, this.formatBytes((row.upload || 0) + (row.download || 0)))
            ]));
        });
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

        if (period === 'day') {
            dateInput.type = 'date';
            dateInput.value = today;
        } else if (period === 'month') {
            dateInput.type = 'month';
            dateInput.value = thisMonth;
        } else if (period === 'year') {
            dateInput.type = 'number';
            dateInput.min = '2020';
            dateInput.max = '2030';
            dateInput.value = thisYear;
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
                    _this.loadTrafficData();
                    _this.updateDateInput(e.target.value);
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
                'change': () => _this.loadTrafficData()
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
                E('h3', { 'id': 'ip-table-title' }, _('Top IP Traffic')),
                E('table', { 'class': 'table', 'id': 'ip-table' }, [
                    E('tr', { 'class': 'tr table-titles' }, [
                        E('th', { 'class': 'th' }, _('IP Address')),
                        E('th', { 'class': 'th' }, _('Upload')),
                        E('th', { 'class': 'th' }, _('Download')),
                        E('th', { 'class': 'th' }, _('Total'))
                    ]),
                    E('tbody', { 'id': 'ip-table-body' })
                ])
            ])
        ]);

        // 初始加载
        this.loadTrafficData().then(() => {
            // 绑定轮询函数
            _this.pollBound = function() {
                // 如果页面已经不存在于 DOM 中，停止轮询
                if (!document.getElementById('traffic-chart')) {
                    return false;
                }
                return _this.loadTrafficData();
            };
            poll.add(_this.pollBound, _this.pollInterval);
        });

        // 监听页面切换事件，停止轮询
        document.addEventListener('uci:section-change', function() {
            _this.handlePageLeave();
        });

        return view;
    }
});
