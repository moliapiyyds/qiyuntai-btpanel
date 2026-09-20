#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""核对宝塔「软件商店」里各组件的安装状态（模拟面板 check_status 判定）"""
import sys, os, json
PANEL = '/www/server/panel'
os.chdir(PANEL)
sys.path.insert(0, PANEL)
sys.path.insert(0, os.path.join(PANEL, 'class'))

from flask import Flask
app = Flask(__name__)
app.secret_key = 'moli-status-check'

WANT = ['nginx', 'mysql', 'php', 'phpmyadmin', 'fail2ban', 'redis', 'nodejs', 'java_manager', 'tomcat', 'memcached']

with app.test_request_context('/'):
    import panelPlugin
    p = panelPlugin.panelPlugin()
    try:
        r = p.get_cloud_list(None)
        lst = r.get('list', [])
        print('云端列表条数:', len(lst), ' ltd=', r.get('ltd'), ' pro=', r.get('pro'))
        print('%-14s %-8s %-10s %s' % ('名称', '已安装', '状态', 'install_checks'))
        print('-' * 90)
        for it in lst:
            if it.get('name') not in WANT:
                continue
            try:
                st = p.check_status(dict(it))
            except Exception as e:
                print('%-14s 检查异常 %s' % (it.get('name'), e))
                continue
            print('%-14s %-8s %-10s %s' % (
                it.get('name'),
                '是' if st.get('setup') else '否',
                '运行中' if st.get('status') else '已停止',
                it.get('install_checks', '')))
        # php 各版本
        print('\n--- PHP 各版本 ---')
        for it in lst:
            if it.get('name') != 'php' or it.get('version_coexist') != 1:
                continue
            for v in it.get('versions', []):
                name = it['name'] + '-' + v['m_version']
                chk = '/www/server/php/' + v['m_version'].replace('.', '') + '/bin/php'
                print('  %-10s 已安装=%s  %s' % (v['m_version'], '是' if os.path.exists(chk) else '否', chk))
    except Exception as e:
        import traceback
        traceback.print_exc()
print('STORE_CHECK_END')
