#!/usr/bin/ucode
'use strict';

import { readfile, writefile } from 'fs';

function fail(message) {
	print({ ok: false, error: message }, '\n');
	exit(1);
}

function load_json(path) {
	let content = readfile(path);

	if (content == null)
		fail('unable to read Xray configuration');

	try {
		return json(content);
	}
	catch (e) {
		fail('Xray configuration is not valid JSON');
	}
}

function is_string_array(value) {
	if (type(value) != 'array')
		return false;

	for (let item in value)
		if (type(item) != 'string')
			return false;

	return true;
}

function eligible_rule(rule, key) {
	if (type(rule) != 'object' || rule.type != 'field' ||
	    rule.outboundTag != 'direct' || !is_string_array(rule[key]))
		return false;

	for (let name in rule)
		if (name != 'type' && name != 'outboundTag' && name != key)
			return false;

	return true;
}

function inspect(config) {
	let rules = config?.routing?.rules;
	let domains = [];
	let ips = [];
	let warnings = [];

	if (type(rules) != 'array')
		fail('Xray routing.rules is missing or is not an array');

	for (let i = 0; i < length(rules); i++) {
		if (eligible_rule(rules[i], 'domain'))
			push(domains, i);
		if (eligible_rule(rules[i], 'ip'))
			push(ips, i);
	}

	if (length(domains) != 1)
		fail(sprintf('expected exactly one isolated direct domain array, found %d', length(domains)));
	if (length(ips) != 1)
		fail(sprintf('expected exactly one isolated direct IP array, found %d', length(ips)));
	if (domains[0] == ips[0])
		fail('domain and IP selectors unexpectedly resolve to the same rule');

	if (config?.routing?.domainStrategy == 'AsIs')
		push(warnings, 'routing.domainStrategy AsIs will be preserved');

	return {
		ok: true,
		domain_rule_index: domains[0],
		ip_rule_index: ips[0],
		domain_count: length(rules[domains[0]].domain),
		ip_count: length(rules[ips[0]].ip),
		warnings: warnings
	};
}

function read_list(path) {
	let content = readfile(path);
	let values = [];
	let seen = {};

	if (content == null)
		fail('unable to read a normalized managed rule list');

	for (let line in split(content, /\n/)) {
		line = trim(line);
		if (!length(line) || substr(line, 0, 1) == '#')
			continue;
		if (!exists(seen, line)) {
			seen[line] = true;
			push(values, line);
		}
	}

	return values;
}

function deep_equal_except(a, b, path, excluded) {
	if (exists(excluded, path))
		return true;
	if (type(a) != type(b))
		return false;

	if (type(a) == 'array') {
		if (length(a) != length(b))
			return false;
		for (let i = 0; i < length(a); i++)
			if (!deep_equal_except(a[i], b[i], sprintf('%s[%d]', path, i), excluded))
				return false;
		return true;
	}

	if (type(a) == 'object') {
		let acount = 0;
		let bcount = 0;
		for (let key in a) {
			acount++;
			if (!exists(b, key) ||
			    !deep_equal_except(a[key], b[key], path + '.' + key, excluded))
				return false;
		}
		for (let key in b)
			bcount++;
		return acount == bcount;
	}

	return a === b;
}

let command = ARGV[0];
let config_path = ARGV[1];

if (!command || !config_path)
	fail('usage: xray-overlay.uc inspect|extract|patch CONFIG ...');

let source = load_json(config_path);
let details = inspect(source);

if (command == 'inspect') {
	print(details, '\n');
	exit(0);
}

if (command == 'extract') {
	let domain_index = +ARGV[2];
	let ip_index = +ARGV[3];
	let domain_output = ARGV[4];
	let ip_output = ARGV[5];

	if (domain_index != details.domain_rule_index || ip_index != details.ip_rule_index)
		fail('adopted selectors no longer identify the unique managed arrays');

	if (writefile(domain_output, join('\n', source.routing.rules[domain_index].domain) + '\n') == null ||
	    writefile(ip_output, join('\n', source.routing.rules[ip_index].ip) + '\n') == null)
		fail('unable to export adopted rule arrays');

	print(details, '\n');
	exit(0);
}

if (command == 'patch') {
	let domain_index = +ARGV[2];
	let ip_index = +ARGV[3];
	let domain_input = ARGV[4];
	let ip_input = ARGV[5];
	let output = ARGV[6];

	if (domain_index != details.domain_rule_index || ip_index != details.ip_rule_index)
		fail('adopted selectors no longer identify the unique managed arrays');

	let candidate = json(readfile(config_path));
	candidate.routing.rules[domain_index].domain = read_list(domain_input);
	candidate.routing.rules[ip_index].ip = read_list(ip_input);

	let excluded = {};
	excluded[sprintf('$.routing.rules[%d].domain', domain_index)] = true;
	excluded[sprintf('$.routing.rules[%d].ip', ip_index)] = true;
	if (!deep_equal_except(source, candidate, '$', excluded))
		fail('non-managed Xray JSON semantics changed');

	if (writefile(output, candidate) == null)
		fail('unable to write the Xray candidate configuration');

	print({
		ok: true,
		non_managed_semantics_unchanged: true,
		domain_rule_index: domain_index,
		ip_rule_index: ip_index,
		domain_count: length(candidate.routing.rules[domain_index].domain),
		ip_count: length(candidate.routing.rules[ip_index].ip)
	}, '\n');
	exit(0);
}

fail('unknown structural overlay command');
