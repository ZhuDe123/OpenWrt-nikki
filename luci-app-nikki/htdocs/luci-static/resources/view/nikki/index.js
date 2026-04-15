'use strict';
'require view';
'require form';
'require tools.widgets as widgets';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('nikki', _('Nikki'), _('A rule based proxy in Go.'));

		// 基本设置
		s = m.section(form.TypedSection, 'main', _('Basic Settings'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'log_level', _('Log Level'));
		o.value('silent');
		o.value('error');
		o.value('warning');
		o.value('info');
		o.value('debug');

		// API 设置
		s = m.section(form.TypedSection, 'mixin', _('API Settings'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Value, 'api_listen', _('API Listen'));
		o.datatype = 'string';

		o = s.option(form.Value, 'external_controller', _('External Controller'));
		o.datatype = 'string';

		// 流量统计设置
		s = m.section(form.TypedSection, 'traffic', _('Traffic Statistics'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable Traffic Statistics'));
		o.rmempty = false;
		o.description = _('Enable traffic collection and storage');

		o = s.option(form.Value, 'collect_interval', _('Collection Interval (seconds)'));
		o.datatype = 'uinteger';
		o.placeholder = '30';
		o.depends('enabled', '1');

		o = s.option(form.Value, 'retain_days', _('Data Retention Days'));
		o.datatype = 'uinteger';
		o.placeholder = '30';
		o.depends('enabled', '1');

		return m.render();
	}
});