'use strict';
'require view';
'require request';
'require ui';
'require poll';
'require dom';

return view.extend({
    chart: null,
    pollInterval: 5000,  // 5 秒刷新一次

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
        let period = document.getElementById('period-select')?.value || 'day';
        let date = document.getElementById('date-input')?.value || new Date().toISOString().split('T')[0];
        
        return L.resolveDefault(
            request.get(L.url('admin/services/nikki/traffic_stats'), { period: period, date: date }),
            { json: () => ({ global: [], ip: [] }) }
        ).then(res => res.json()).then(data => {
            this.renderChart(data, period);
            this.updateTable(data.ip || []);
            this.updateSummary(data.global || []);
            dom.removeClass(document.getElementById('traffic-chart'), 'hidden');
        }).catch(e => {
            console.error('Failed to load traffic data:', e);
            ui.addNotification(null, E('p', _('Failed to load traffic data')));
        });
    },

    // 渲染图表
    renderChart: function(data, period) {
        const self = this;
        const canvas = document.getElementById('traffic-chart');
        if (!canvas) return;

        if (!window.Chart) {
            let script = document.createElement('script');
            script.src = '/luci-static/resources/chart.umd.js';
            script.onload = () => self._doRender(canvas, data, period);
            script.onerror = () => {
                console.error('Failed to load Chart.js');
            };
            document.head.appendChild(script);
        } else {
            self._doRender(canvas, data, period);
        }
    },

    _doRender: function(canvas, data, period) {
        if (this.chart) this.chart.destroy();
        
        let chartData = { hourly: [], daily: [], ip: [] };
        if (data.global && data.global.length > 0) {
            chartData = data.global[0];
        }
        
        let labels, upData, downData;
        
        if (period === 'day' && chartData.hourly) {
            labels = chartData.hourly.map(d => d.datetime ? d.datetime.split(' ')[1] : '');
            upData = chartData.hourly.map(d => d.upload || 0);
            downData = chartData.hourly.map(d => d.download || 0);
        } else if (period === 'month' && chartData.daily) {
            labels = chartData.daily.map(d => d.date ? d.date.split(' ')[0] : '');
            upData = chartData.daily.map(d => d.upload || 0);
            downData = chartData.daily.map(d => d.download || 0);
        } else {
            labels = [];
            upData = [];
            downData = [];
        }

        this.chart = new Chart(canvas.getContext('2d'), {
            type: 'line',
            data: {
                labels: labels,
                datasets: [
                    { 
                        label: _('Upload'), 
                        data: upData, 
                        borderColor: '#3498db', 
                        backgroundColor: 'rgba(52, 152, 219, 0.1)', 
                        fill: true 
                    },
                    { 
                        label: _('Download'), 
                        data: downData, 
                        borderColor: '#2ecc71', 
                        backgroundColor: 'rgba(46, 204, 113, 0.1)', 
                        fill: true 
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                scales: {
                    y: {
                        beginAtZero: true,
                        ticks: {
                            callback: function(v) {
                                return self.formatBytes(v);
                            }
                        }
                    }
                },
                plugins: {
                    legend: { position: 'bottom' },
                    tooltip: {
                        callbacks: {
                            label: function(context) {
                                return context.dataset.label + ': ' + self.formatBytes(context.parsed.y);
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
        
        if (!ipData || ipData.length === 0) {
            tbody.appendChild(E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td', 'colspan': '4' }, _('No data available'))
            ]));
            return;
        }
        
        ipData.forEach(row => {
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
        
        summary.innerHTML = sprintf(
            '<div class="cbi-value"><label class="cbi-value-title">' + _('Total Upload') + '</label>' +
            '<div class="cbi-value-field">%s</div></div>' +
            '<div class="cbi-value"><label class="cbi-value-title">' + _('Total Download') + '</label>' +
            '<div class="cbi-value-field">%s</div></div>',
            this.formatBytes(upload),
            this.formatBytes(download)
        );
    },

    render: function() {
        let today = new Date().toISOString().split('T')[0];
        let thisMonth = today.substring(0, 7);

        let controls = E('div', { 'style': 'margin-bottom: 20px; display: flex; gap: 10px; align-items: center;' }, [
            E('label', { 'style': 'font-weight: bold;' }, _('Period') + ': '),
            E('select', { 
                'id': 'period-select', 
                'class': 'cbi-input-select', 
                'change': () => this.loadTrafficData() 
            }, [
                E('option', { 'value': 'day' }, _('Daily View')),
                E('option', { 'value': 'month' }, _('Monthly View'))
            ]),
            E('label', { 'style': 'font-weight: bold; margin-left: 10px;' }, _('Date') + ': '),
            E('input', { 
                'id': 'date-input', 
                'type': 'date', 
                'class': 'cbi-input-text', 
                'value': today, 
                'change': () => this.loadTrafficData() 
            }),
            E('button', {
                'class': 'cbi-button cbi-button-action',
                'style': 'margin-left: 10px;',
                'click': () => this.loadTrafficData()
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
            // 启动轮询
            poll.add(() => this.loadTrafficData(), this.pollInterval);
        });
        
        return view;
    }
});
