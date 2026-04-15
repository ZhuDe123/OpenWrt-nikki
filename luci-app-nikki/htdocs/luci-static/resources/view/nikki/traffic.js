'use strict';
'require view';
'require ui';
'require poll';
'require rpc';

var callNikkiTrafficStats = rpc.declare({
    object: 'nikki',
    method: 'traffic_stats',
    params: ['period', 'date'],
    expect: { '': {} }
});

return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(callNikkiTrafficStats('day', new Date().toISOString().split('T')[0]), {})
        ]);
    },

    render: function(data) {
        var chartDiv = E('div', { 
            'id': 'traffic-chart', 
            'style': 'width: 100%; height: 400px; margin-bottom: 20px;' 
        });
        
        var tableDiv = E('div', { 
            'id': 'traffic-table',
            'style': 'overflow-x: auto;'
        });
        
        var periodSelect = E('select', { 
            'id': 'period-select',
            'class': 'cbi-input-select',
            'style': 'margin-right: 10px;'
        }, [
            E('option', { 'value': 'day' }, _('今日')),
            E('option', { 'value': 'month' }, _('本月')),
            E('option', { 'value': 'year' }, _('本年'))
        ]);
        
        var dateInput = E('input', {
            'type': 'date',
            'id': 'date-input',
            'class': 'cbi-input-text',
            'style': 'margin-right: 10px;',
            'value': new Date().toISOString().split('T')[0]
        });
        
        var refreshBtn = E('button', {
            'class': 'cbi-button cbi-button-action',
            'style': 'margin-left: 10px;',
            'click': function() { this.loadTrafficData(); }.bind(this)
        }, _('刷新'));
        
        var controls = E('div', { 'style': 'margin-bottom: 15px;' }, [
            periodSelect,
            dateInput,
            refreshBtn,
            E('span', { 'style': 'margin-left: 20px; color: #666;' }, 
                _('上次更新：') + '<span id="last-update">-</span>')
        ]);
        
        // 引入 Chart.js
        var script = E('script', { 
            'src': '/luci-static/resources/chart.umd.js',
            'type': 'text/javascript'
        });
        
        return E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('流量统计')),
            controls,
            chartDiv,
            tableDiv,
            script
        ]);
    },
    
    loadTrafficData: function() {
        var period = document.getElementById('period-select').value;
        var date = document.getElementById('date-input').value;
        
        // 获取流量数据
        return L.resolveDefault(callNikkiTrafficStats(period, date), {}).then(function(res) {
            this.updateChart(res);
            this.updateTable(res);
            document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
        }.bind(this));
    },
    
    updateChart: function(data) {
        var ctx = document.getElementById('traffic-chart');
        if (ctx.chart) {
            ctx.chart.destroy();
        }
        
        var labels = [];
        var uploadData = [];
        var downloadData = [];
        
        if (data.ip_stats && Array.isArray(data.ip_stats)) {
            data.ip_stats.forEach(function(item) {
                labels.push(item.ip_address);
                uploadData.push(item.upload);
                downloadData.push(item.download);
            });
        }
        
        var chartData = {
            labels: labels,
            datasets: [{
                label: _('上传'),
                data: uploadData,
                backgroundColor: 'rgba(54, 162, 235, 0.6)'
            }, {
                label: _('下载'),
                data: downloadData,
                backgroundColor: 'rgba(255, 99, 132, 0.6)'
            }]
        };
        
        ctx.chart = new Chart(ctx, {
            type: 'pie',
            data: chartData,
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: { position: 'bottom' },
                    tooltip: {
                        callbacks: {
                            label: function(context) {
                                var value = context.parsed;
                                return this.formatBytes(value);
                            }.bind(this)
                        }
                    }
                }
            }
        });
    },
    
    updateTable: function(data) {
        var table = E('table', { 'class': 'table' }, [
            E('tr', { 'class': 'tr table-titles' }, [
                E('th', { 'class': 'th' }, _('IP 地址')),
                E('th', { 'class': 'th' }, _('上传')),
                E('th', { 'class': 'th' }, _('下载')),
                E('th', { 'class': 'th' }, _('总计')),
                E('th', { 'class': 'th' }, _('占比'))
            ])
        ]);
        
        var total = 0;
        if (data.ip_stats && Array.isArray(data.ip_stats)) {
            data.ip_stats.forEach(function(item) {
                total += item.upload + item.download;
            });
        }
        
        if (data.ip_stats && Array.isArray(data.ip_stats)) {
            data.ip_stats.forEach(function(item) {
                var itemTotal = item.upload + item.download;
                var percentage = total > 0 ? ((itemTotal / total) * 100).toFixed(2) : 0;
                
                table.appendChild(E('tr', { 'class': 'tr' }, [
                    E('td', { 'class': 'td' }, item.ip_address || _('未知')),
                    E('td', { 'class': 'td' }, this.formatBytes(item.upload)),
                    E('td', { 'class': 'td' }, this.formatBytes(item.download)),
                    E('td', { 'class': 'td' }, this.formatBytes(itemTotal)),
                    E('td', { 'class': 'td' }, percentage + '%')
                ]));
            }.bind(this));
        }
        
        var container = document.getElementById('traffic-table');
        container.innerHTML = '';
        container.appendChild(table);
    },
    
    formatBytes: function(bytes) {
        if (bytes === 0) return '0 B';
        var k = 1024;
        var sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
        var i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    },
    
    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});