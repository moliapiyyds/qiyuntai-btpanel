#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""通用宝塔插件安装器：install_plugin(下载+解包) -> input_package(执行安装)
用法: python3 plugin_install.py <插件名> [m_version] [version]

两条路径都要照顾到（实测，2026-09-22）：
  1) 同步：install_plugin 当场把包装下来解到 temp/<插件名>，然后 input_package 执行安装。
     大部分插件走这条。
  2) 异步：面板把安装**排进任务队列**，第一步只返回
     {"status": true, "msg": "已将安装任务添加到队列!"}，temp/ 不会立刻出现 ——
     redis 就是这样。这时不能直接判失败，要等任务把插件装出来（也可以从
     logs/task.log 看进度）。等多久用环境变量 PLUGIN_WAIT 调，默认 900 秒。
"""
import sys, os, json, time
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
    # 「已安装」必须同时满足两条：install_checks 那个路径存在 **而且插件目录存在**。
    # 只按 install_checks 判断会假跳过 —— 实测（2026-09-22）redis 的 install_checks 是
    # /www/server/redis/runtest（**软件**路径，源码就在那儿但没编译），那个文件在，
    # 于是直接「已经安装过了，跳过」：插件的文件一个都没解包，
    # 面板里点开 redis 是 404，/etc/init.d/redis 也不存在，
    # 而部署脚本 step_plugins 看到「插件目录不在」会判整步失败。
    d = info.get('install_checks') or ''
    plugin_dir = os.path.join(PANEL, 'plugin', name)
    if d and os.path.exists(d) and os.path.isdir(plugin_dir):
        print('插件目录与 install_checks 都在，判为已安装，跳过'); print('PLUGIN_END'); sys.exit(0)
    if d and os.path.exists(d) and not os.path.isdir(plugin_dir):
        print('install_checks(%s) 在，但插件目录不在 —— 只装插件文件（软件那边让它自己的 install.sh 判断）' % d)

    get = public.to_dict_obj({'sName': name, 'version': mv, 'min_version': ver})
    r = p.install_plugin(get)
    print('第一步:', json.dumps(r, ensure_ascii=False)[:500] if isinstance(r, dict) else str(r)[:500])
    tmp = '/www/server/panel/temp/' + name

    if not os.path.exists(tmp):
        # 走了异步任务队列这条路（redis 就是这样）
        wait = int(os.environ.get('PLUGIN_WAIT', '900'))
        print('temp/ 还没出现 —— 面板把安装排进了任务队列，等它完成（最多 %d 秒）' % wait)
        t0 = time.time()
        while time.time() - t0 < wait:
            time.sleep(5)
            if os.path.isdir(plugin_dir):
                print('插件目录已出现（等了 %.0f 秒）' % (time.time() - t0))
                break
            if tmp and os.path.exists(tmp):
                print('temp/ 出现（等了 %.0f 秒），改走同步收尾' % (time.time() - t0))
                break
        else:
            print('!! 等超时：%s 仍不存在。看 /www/server/panel/logs/task.log 里的报错' % plugin_dir)
            print('PLUGIN_END'); sys.exit(1)
        if os.path.exists(tmp) and not os.path.isdir(plugin_dir):
            get2 = public.to_dict_obj({'tmp_path': tmp, 'plugin_name': name, 'install_opt': 'i'})
            r2 = p.input_package(get2)
            print('第二步:', json.dumps(r2, ensure_ascii=False)[:500] if isinstance(r2, dict) else str(r2)[:500])
        print('插件目录存在:', os.path.isdir(plugin_dir))
        print('PLUGIN_END'); sys.exit(0 if os.path.isdir(plugin_dir) else 1)

    get2 = public.to_dict_obj({'tmp_path': tmp, 'plugin_name': name, 'install_opt': 'i'})
    r2 = p.input_package(get2)
    print('第二步:', json.dumps(r2, ensure_ascii=False)[:500] if isinstance(r2, dict) else str(r2)[:500])
    print('插件目录存在:', os.path.isdir(plugin_dir))
    print('install_checks 存在:', os.path.exists(d) if d else '（云端没给）')
    if os.path.isdir(plugin_dir):
        print('内容:', sorted(os.listdir(plugin_dir))[:15])
print('PLUGIN_END')
