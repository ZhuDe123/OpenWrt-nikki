'use strict';
'require view';
'require form';
'require tools.widgets as widgets';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('nikki', _('Nikki'), _('A rule based proxy in Go.'));

		s = m.section(form.TypedSection, 'nikki', _('Settings'));
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

		o = s.option(form.Value, 'api_host', _('API Host'));
		o.datatype = 'host';

		o = s.option(form.Value, 'api_port', _('API Port'));
		o.datatype = 'port';

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