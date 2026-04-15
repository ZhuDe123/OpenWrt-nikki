'use strict';
'require view';
'require form';
'require ui';

return view.extend({
    render: function() {
        var m, s, o;

        m = new form.Map('nikki', _('流量统计设置'));

        s = m.section(form.NamedSection, 'traffic', 'traffic', _('流量统计配置'));
        s.addremove = false;
        s.anonymous = true;

        o = s.option(form.Flag, 'enabled', _('启用流量统计'));
        o.rmempty = false;
        o.description = _('开启后将自动采集和存储流量数据，会占用少量系统资源');

        o = s.option(form.Value, 'collect_interval', _('采集间隔'));
        o.datatype = 'uinteger';
        o.placeholder = '30';
        o.depends('enabled', '1');
        o.description = _('数据采集间隔时间（秒），建议不低于 30 秒');

        o = s.option(form.Value, 'retain_days', _('数据保留天数'));
        o.datatype = 'uinteger';
        o.placeholder = '30';
        o.depends('enabled', '1');
        o.description = _('历史数据保留天数，超出的数据会自动清理');

        o = s.option(form.Value, 'db_path', _('数据库路径'));
        o.placeholder = '/tmp/nikki/traffic.db';
        o.depends('enabled', '1');
        o.description = _('SQLite 数据库文件路径，建议使用 /tmp (内存) 以保护 Flash');

        o = s.option(form.Button, '_save_apply', _('保存并应用'));
        o.inputstyle = 'apply';
        o.inputtitle = _('保存配置');
        o.onclick = function() {
            ui.changes.apply(true);
            return this.map.save(null, true);
        };

        return m.render();
    }
});