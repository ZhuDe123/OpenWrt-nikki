'use strict';
'require view';
'require request';
'require ui';

return view.extend({
    chart: null,

    // 修复 P1: 动态字节单位转换
    formatBytes: function(bytes) {
        if (bytes === 0) return '0 B';
        let k = 1024;
        let sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
        let i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    },

    // 修复 P1: 解决 Chart.js 加载竞态条件
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
                ui.addNotification(null, E('p', _('Failed to load chart library')));
            };
            document.head.appendChild(script);
        } else {
            self._doRender(canvas, data, period);
        }
    },

    _doRender: function(canvas, data, period) {
        if (this.chart) this.chart.destroy();
        
        if (!data || data.length === 0) {
            // 显示空状态
            return;
        }
        
        let labels = data.map(d => period === 'day' ? d.datetime.split(' ')[1] : d.date);
        let upData = data.map(d => d.upload || 0);
        let downData = data.map(d => d.download || 0);

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

    // 修复 P1: 增加错误处理
    refreshData: function() {
        let p = document.getElementById('period-select').value;
        let d = document.getElementById('date-input').value;

        return L.resolveDefault(
            request.get(L.url('admin/services/nikki/traffic_stats'), { period: p, date: d })
                .then(res => res.json()),
            { hourly: [], daily: [], ip: [] }  // 默认值
        ).then(s => {
            this.renderChart(p === 'day' ? (s.hourly || []) : (s.daily || []), p);
            this.updateTable(s.ip || [], p);
        }).catch(e => {
            console.error('Failed to load traffic data:', e);
            ui.addNotification(null, E('p', _('Failed to load traffic data')));
        });
    },

    // 修复 P2: 动态更新表格标题
    updateTable: function(ipData, period) {
        let title = document.getElementById('ip-table-title');
        if (title) {
            title.textContent = period === 'day' ? 
                _('Top IP Traffic (Today)') : 
                _('Top IP Traffic (Month)');
        }
        
        let tbody = document.getElementById('ip-table-body');
        if (!tbody) return;
        
        tbody.innerHTML = '';
        
        if (!ipData || ipData.length === 0) {
            tbody.appendChild(E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td', 'colspan': '3' }, _('No data available'))
            ]));
            return;
        }
        
        ipData.forEach(row => {
            tbody.appendChild(E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td' }, row.ip || row.ip_address || _('Unknown')),
                E('td', { 'class': 'td' }, this.formatBytes(row.upload || 0)),
                E('td', { 'class': 'td' }, this.formatBytes(row.download || 0))
            ]));
        });
    },

    render: function() {
        let today = new Date().toISOString().split('T')[0];

        // 修复 P1: 完善控制面板
        let controls = E('div', { 'style': 'margin-bottom: 20px; display: flex; gap: 10px; align-items: center;' }, [
            E('label', { 'style': 'font-weight: bold;' }, _('Period') + ':'),
            E('select', { 'id': 'period-select', 'class': 'cbi-input-select', 'change': () => this.refreshData() }, [
                E('option', { value: 'day' }, _('Daily View')),
                E('option', { value: 'month' }, _('Monthly View')),
                E('option', { value: 'year' }, _('Yearly View'))
            ]),
            E('label', { 'style': 'font-weight: bold; margin-left: 10px;' }, _('Date') + ':'),
            E('input', { 'id': 'date-input', 'type': 'date', 'class': 'cbi-input-text', 'value': today, 'change': () => this.refreshData() }),
            E('button', {
                'class': 'cbi-button cbi-button-action',
                'style': 'margin-left: 10px;',
                'click': () => this.refreshData()
            }, _('Refresh'))
        ]);

        let view = E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('Traffic Statistics')),
            controls,
            E('div', { 'class': 'cbi-section', 'style': 'height: 400px; position: relative;' }, [
                E('canvas', { 'id': 'traffic-chart' })
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'id': 'ip-table-title' }, _('Top IP Traffic (Today)')),
                E('table', { 'class': 'table', 'id': 'ip-table' }, [
                    E('tr', { 'class': 'tr table-titles' }, [
                        E('th', { 'class': 'th' }, _('IP Address')),
                        E('th', { 'class': 'th' }, _('Upload')),
                        E('th', { 'class': 'th' }, _('Download'))
                    ]),
                    E('tbody', { 'id': 'ip-table-body' })
                ])
            ])
        ]);

        // 初始加载 - 使用默认数据
        window.setTimeout(() => this.refreshData(), 200);
        
        return view;
    }
});
