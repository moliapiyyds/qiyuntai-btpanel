#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""通用宝塔插件安装器：install_plugin(下载+解包) -> input_package(执行安装)
用法: python3 plugin_install.py <插件名> [m_version] [version]
"""
import sys, os, json
PANEL = '/www/server/panel'
os.chdir(PANEL)
sys.path.insert(0, PANEL)
sys.path.insert(0, os.path.join(PANEL, 'class'))
from flask import Flask
app = Flask(__name__)
app.secret_key = 'moli-plugin-install'

name = sys.argv[1] if len(sys.argv) > 1 else 'nodejs'
mv = sys.argv[2] if len(sys.argv) > 2 else None
ver = sys.argv[3] if len(sys.argv) > 3 else None

with app.test_request_context('/'):
    import public, panelPlugin
    p = panelPlugin.panelPlugin()
    info = p.get_soft_find(name)
    if not info:
        print('插件不存在于云端列表:', name); sys.exit(1)
    v0 = info['versions'][0]
    mv = mv or v0['m_version']
    ver = ver or v0['version']
    print('插件: %s (%s) 版本 %s.%s  has_download=%s' % (
        info['title'], name, mv, ver, 'download' in v0))
    print('install_checks:', info.get('install_checks'))
    if os.path.exists(info.get('install_checks', '/nonexistent')):
        print('已经安装过了，跳过'); print('PLUGIN_END'); sys.exit(0)

    get = public.to_dict_obj({'sName': name, 'version': mv, 'min_version': ver})
    r = p.install_plugin(get)
    print('第一步:', json.dumps(r, ensure_ascii=False)[:500] if isinstance(r, dict) else str(r)[:500])
    tmp = '/www/server/panel/temp/' + name
    if not os.path.exists(tmp):
        print('临时目录不存在，安装中止'); print('PLUGIN_END'); sys.exit(1)
    get2 = public.to_dict_obj({'tmp_path': tmp, 'plugin_name': name, 'install_opt': 'i'})
    r2 = p.input_package(get2)
    print('第二步:', json.dumps(r2, ensure_ascii=False)[:500] if isinstance(r2, dict) else str(r2)[:500])
    print('目录存在:', os.path.exists(info['install_checks']))
    d = info['install_checks']
    if os.path.isdir(d):
        print('内容:', sorted(os.listdir(d))[:15])
print('PLUGIN_END')
