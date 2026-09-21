#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
栖云台 · 宝塔面板 —— 面板本地化补丁（合并版，幂等、可重复执行、失败自动回滚）
================================================================================
作者：茉莉   QQ:1265274322   官方Q群:570387739

做这些事（每条都是实测踩出来的坑）：
  1) 永久企业版：get_cloud_list() 包装 ltd=0(永久) / pro=-1(无专业版) + expire_msg 打空
     原因：宝塔 get_pd() 里 `if not ltd: ltd=-1` 再 `if ltd < 1` 会走「已过期/免费」灰标；
           -2 显示「已过期」，0 会被 `not ltd` 吞掉 → 必须配合下面的数据层补丁
  2) 响应 cookie：ltd_end=0 / pro_end=-1（老 UI 用 bt.get_cookie('ltd_end') 判定）
  3) 数据层：publicModel.main.get_pd() 固定返回 (企业版HTML, -1, 0)
             publicModel.main.get_public_config() 填 uid（决定界面显示已绑定/未绑定）
  4) 账户接口：panelSSL.panelSSL.GetUserInfo() 返回 status=True + username
  5) 免绑定：/bind 路由永久 302 回首页
  6) 去除更新：升级/修复脚本换空壳 + 清掉面板更新定时任务
  7) 前端兜底：被浏览器加载的 store 里 authType/授权时间戳/账户名默认值
  8) 刷新静态资源版本戳（宝塔 ?v= 写死，不改它浏览器永远吃缓存 → 改了前端不生效）
  9) html/js/css 下发 Cache-Control: no-store
 10) 关掉「浏览器版本过低 → 跳 /tips」（旧内核手机浏览器也能进面板）

用法（设备上 root）：
    chroot /data/openeuler /bin/bash
    /www/server/panel/pyenv/bin/python3 /path/to/moli_patch.py           # 打补丁
    /www/server/panel/pyenv/bin/python3 /path/to/moli_patch.py verify    # 只校验
    /www/server/panel/pyenv/bin/python3 /path/to/moli_patch.py revert    # 从最新备份还原成原版
                                                                        # （做预制镜像时必用）
    /etc/init.d/bt restart

备份：/www/server/panel/moli_patch/backup_<时间戳>/   回滚＝把同名文件复制回原路径后重启面板

【三道守卫】（2026-09-21 加，起因：这个补丁原来没有版本判断，是纯模式匹配）
  1) 面板版本守卫：只在本文件 PANEL_VERIFIED 里列出的版本上自动打；
     别的版本直接失败并提示"要人工核验后加 --force"。
     理由：补丁点会随宝塔版本漂移，静默打半个出来比彻底失败更坏。
  2) 已打过就跳过：moli_patch/.patched 是标记。已存在且校验全通过时跳过，
     免得在已打补丁的面板上重打 —— 那样会把"已打补丁的文件"备份成"原版"，
     回滚点就假了。
  3) 校验结果当门槛：do_verify() 统计未生效项，非 0 时本脚本退出码非 0，
     部署脚本会因此失败，而不是继续往前跑。
"""
import glob
import os
import re
import shutil
import subprocess
import sys
import time

PANEL = '/www/server/panel'
TS = time.strftime('%Y%m%d_%H%M%S')

# 本补丁实测适配过的面板版本。宝塔换版本时补丁点会漂移，所以这里是白名单而不是宽松判断。
PANEL_VERIFIED = ['13.0.0']
# 补丁逻辑本身的修订号，写进标记文件用
PATCH_REV = 'r1'
MARKER = os.path.join(PANEL, 'moli_patch', '.patched')


def panel_version():
    """读面板版本。宝塔没有独立版本文件，只有 class/common.py 里的 g.version。"""
    p = os.path.join(PANEL, 'class', 'common.py')
    if not os.path.exists(p):
        return ''
    m = re.search(r"g\.version\s*=\s*['\"]([^'\"]+)['\"]", rd(p))
    return m.group(1) if m else ''
BK = os.path.join(PANEL, 'moli_patch', 'backup_' + TS)


def do_revert():
    """从最新的 backup_* 目录还原成原版。

    为什么需要：tools/make_image.sh 要冻一个**未打补丁**的镜像。
    理由（重要）：
      1) 补丁是版本相关的（PANEL_VERIFIED 是按实测版本写的），冻进镜像就没法在
         不重建几个 GB 镜像的前提下更新补丁。
      2) 部署时在原版上打补丁，backup_* 里才是真原版，回滚点才成立。
      3) 补丁只改面板的 py/html/js，几秒钟的事。

    注意：只还原被 backup() 记过的文件。补丁**新建**的少数数据文件
    （如 data/initBind.pl 这类"已绑定"标记）不会被删 —— 它们是纯数据，
    部署时会再写一遍，留着不影响。
    """
    mp = os.path.join(PANEL, 'moli_patch')
    if not os.path.isdir(mp):
        say('[失败] 找不到 %s —— 没有备份可还原' % mp)
        return 1
    dirs = sorted(glob.glob(os.path.join(mp, 'backup_*')))
    if not dirs:
        say('[失败] %s 下没有 backup_* 目录' % mp)
        return 1
    bk = dirs[-1]
    say('用最新的备份目录还原：%s' % bk)
    n = 0
    skip = 0
    for name in sorted(os.listdir(bk)):
        src = os.path.join(bk, name)
        if not os.path.isfile(src):
            continue
        rel = name.replace('__', '/')
        dst = os.path.normpath(os.path.join(PANEL, rel))
        # 防目录穿越：备份名是从相对路径拍平的，但还是校验一次
        if not dst.startswith(PANEL + os.sep):
            say('  [跳过] 路径越界：%s' % name)
            skip += 1
            continue
        try:
            shutil.copy2(src, dst)
            n += 1
        except Exception as e:
            say('  [失败] 还原 %s：%s' % (rel, e))
            skip += 1
    say('已还原 %d 个文件%s' % (n, ('，跳过 %d 个' % skip) if skip else ''))
    try:
        os.remove(MARKER)
        say('已删除补丁标记 %s' % MARKER)
    except Exception:
        pass
    say('=== 已回退到原版。要再打补丁：不带参数跑一次本脚本 ===')
    return 0
LOG = []


def say(s):
    LOG.append(s)
    print(s)


def rd(p):
    with open(p, 'r', encoding='utf-8', errors='replace') as f:
        return f.read()


def wr(p, s, mode=0o600):
    with open(p, 'w', encoding='utf-8') as f:
        f.write(s)
    try:
        os.chmod(p, mode)
    except Exception:
        pass


def backup(rel):
    src = os.path.join(PANEL, rel)
    if not os.path.exists(src):
        return
    os.makedirs(BK, exist_ok=True)
    dst = os.path.join(BK, rel.replace('/', '__'))
    if not os.path.exists(dst):
        shutil.copy2(src, dst)


def py_ok_path(p):
    r = subprocess.run([os.path.join(PANEL, 'pyenv/bin/python3'), '-m', 'py_compile', p],
                       capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or '').strip()[-200:]


def py_ok_text(content):
    tmp = '/tmp/moli_patch_chk.py'
    open(tmp, 'w', encoding='utf-8').write(content)
    return py_ok_path(tmp)


def find_node():
    """找 JS 语法校验用的 node。
    为什么要有这个函数（2026-09-22 实测踩到）：新装环境里 /usr/bin/node 是**后面那步才装的**
    （依赖对齐/插件那步装 nodejs rpm），如果一上来就打补丁，subprocess.run(['node', ...])
    直接 FileNotFoundError，把 step_frontend 整个打断 —— 前面几步已经改了文件，
    后面几步一个没做，日志里只有一个 traceback，很容易被当成"补丁打完了"。
    宝塔自己装的 node 在 /www/server/nodejs/v*/bin/node，一并当候选。"""
    cands = [shutil.which('node'), '/usr/bin/node', '/usr/local/bin/node']
    cands += sorted(glob.glob('/www/server/nodejs/v*/bin/node'), reverse=True)
    for c in cands:
        if c and os.path.exists(c):
            return c
    return None


NODE_BIN = find_node()


def js_ok(content):
    """用 node --check 校验。返回 (True/False, err)；**没有 node 时返回 (None, 原因)**，
    调用方要把 None 当成「无法校验、跳过并明确报出来」，别当成通过也别崩。"""
    if not NODE_BIN:
        return None, '找不到 node，无法执行 --check'
    tmp = '/tmp/moli_patch_chk.mjs'
    open(tmp, 'w', encoding='utf-8').write(content)
    r = subprocess.run([NODE_BIN, '--check', tmp], capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or '').strip()[-160:]


def append_block(rel, block, tag):
    """补丁块追加到文件末尾（幂等）；改完先语法校验，失败就放弃不动文件"""
    p = os.path.join(PANEL, rel)
    if not os.path.exists(p):
        say('[跳过] 找不到 %s' % rel)
        return False
    s = rd(p)
    if tag in s:
        say('[已存在] %s' % rel)
        return True
    new = s.rstrip() + '\n\n' + block
    ok, err = py_ok_text(new)
    if not ok:
        say('[失败] %s 追加后语法错误，已放弃：%s' % (rel, err))
        return False
    backup(rel)
    wr(p, new)
    say('[完成] %s ← %s' % (rel, tag))
    return True


LICENSE_BLOCK = '''

# ============================ MOLI_PATCH_LICENSE ============================
# 茉莉定制：永久企业版（ltd=0 = 永久；pro=-1 = 无专业版，避免显示成「专业版」）
try:
    _moli_orig_get_cloud_list = panelPlugin.get_cloud_list

    def _moli_get_cloud_list(self, get=None):
        _res = _moli_orig_get_cloud_list(self, get)
        try:
            if isinstance(_res, dict) and 'list' in _res:
                _res['ltd'] = 0
                _res['pro'] = -1
                _res['is_force'] = 0
        except Exception:
            pass
        return _res

    panelPlugin.get_cloud_list = _moli_get_cloud_list

    def _moli_expire_msg(self, data):
        return True

    panelPlugin.expire_msg = _moli_expire_msg
    print('[MOLI] 永久企业版已生效 (ltd=0 / pro=-1)')
except Exception as _e:
    print('[MOLI] 企业版补丁失败: ' + str(_e))
# ========================== end MOLI_PATCH_LICENSE ==========================
'''

COOKIE_BLOCK = '''

# ============================ MOLI_PATCH_COOKIE ============================
# 茉莉定制：响应下发企业版 cookie（老 UI 判定用）+ 关掉静态资源缓存
try:
    @app.after_request
    def _moli_license_cookie(resp):
        try:
            resp.set_cookie('ltd_end', '0', max_age=315360000, path='/')
            resp.set_cookie('pro_end', '-1', max_age=315360000, path='/')
        except Exception:
            pass
        return resp
    print('[MOLI] 授权 cookie 已下发')
except Exception as _e:
    print('[MOLI] cookie 补丁失败: ' + str(_e))


# ============================ MOLI_PATCH_NOCACHE ============================
# 茉莉定制：html/js/css 一律 no-store（宝塔 ?v= 写死 + HTML 会 304，
# 不改这个就会出现「明明改了前端却一直不生效」）
try:
    @app.after_request
    def _moli_no_cache(resp):
        try:
            _ct = (resp.headers.get('Content-Type') or '').lower()
            _p = (request.path or '').lower()
            if ('text/html' in _ct) or _p.endswith(('.js', '.css', '.mjs')):
                resp.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
                resp.headers['Pragma'] = 'no-cache'
                resp.headers.pop('Expires', None)
        except Exception:
            pass
        return resp
    print('[MOLI] no-store 已生效')
except Exception as _e:
    print('[MOLI] no-store 补丁失败: ' + str(_e))


# ============================ MOLI_PATCH_BINDVIEW ============================
# 茉莉定制：/bind 直接回首页（不再出现「请先绑定宝塔帐号」页）
try:
    app.view_functions['bind'] = lambda *a, **k: redirect('/', 302)
    print('[MOLI] /bind 已改为回首页')
except Exception as _e:
    print('[MOLI] bind 补丁失败: ' + str(_e))
# ========================== end MOLI_PATCH_BINDVIEW =========================
'''

DATA_BLOCK = '''

# ============================ MOLI_PATCH_DATA ============================
# 茉莉定制（数据层，浏览器就算用旧 JS 也生效）：
#   get_pd() 返回 (HTML标签, pro时间戳, ltd时间戳)，前端靠它算 authType
#   get_public_config() 的 uid 决定界面显示「已绑定 / 未绑定」
try:
    _moli_pd = main.get_pd

    def _moli_get_pd(self, get=None):
        try:
            _moli_pd(self, get)
        except Exception:
            pass
        return ('<span class="btltd">到期时间：<span style="color: #fc6d26;font-weight: bold;">永久授权</span></span>', -1, 0)

    main.get_pd = _moli_get_pd

    _moli_gpc = main.get_public_config

    def _moli_get_public_config(self, args=None):
        _d = _moli_gpc(self, args)
        try:
            if isinstance(_d, dict):
                _d['uid'] = 10086
                _d['bind_user'] = '茉莉'
                _d['nickname'] = '茉莉'
                _d['user'] = {'username': '茉莉'}
        except Exception:
            pass
        return _d

    main.get_public_config = _moli_get_public_config
    print('[MOLI] 数据层补丁已生效（企业版 + 账户已绑定）')
except Exception as _e:
    print('[MOLI] 数据层补丁失败: ' + str(_e))
# ========================== end MOLI_PATCH_DATA ==========================
'''

ACCT_BLOCK = '''

# ============================ MOLI_PATCH_ACCOUNT ============================
# 茉莉定制：账户控件数据源（前端 store 里 getUserInfo() 解构 {status, data:{username}}）
try:
    _moli_ssl_user = {'username': '茉莉', 'nickname': '茉莉', 'avatar': '', 'id': 10086}

    def _moli_GetUserInfo(self, get=None):
        return {'status': True, 'msg': dict(_moli_ssl_user), 'data': dict(_moli_ssl_user)}

    panelSSL.GetUserInfo = _moli_GetUserInfo
    print('[MOLI] 账户显示已生效')
except Exception as _e:
    print('[MOLI] 账户补丁失败: ' + str(_e))
# ========================== end MOLI_PATCH_ACCOUNT ==========================
'''

NOUPDATE_STUB = '''#!/bin/bash
# ============================ MOLI_PATCH_NOUPDATE ============================
# 茉莉定制：面板更新/修复脚本已被替换为空壳（去除更新）
# 原文件备份在 /www/server/panel/moli_patch/backup_*/
# ========================== end MOLI_PATCH_NOUPDATE ==========================
echo "[MOLI] 面板更新功能已关闭（茉莉定制版）"
exit 0
'''

JS_RULES = [
    ('authType:`free`', 'authType:`ltd`/*MOLI_PATCH*/'),
    ('authExpirationTime:-1', 'authExpirationTime:0/*MOLI_PATCH*/'),
    ('authType=`free`', 'authType=`ltd`/*MOLI_PATCH*/'),
    ('authExpirationTime=-1', 'authExpirationTime=0/*MOLI_PATCH*/'),
    ('bindUser:``', 'bindUser:`茉莉`/*MOLI_PATCH*/'),
    ("bt.get_cookie('ltd_end') || -1", "bt.get_cookie('ltd_end') || 0/*MOLI_PATCH*/"),
    ("bt.get_cookie('pro_end') || -1", "bt.get_cookie('pro_end') || 0/*MOLI_PATCH*/"),
]


def step_backend():
    say('--- 1) 后端补丁 ---')
    append_block('class/panelPlugin.py', LICENSE_BLOCK, 'MOLI_PATCH_LICENSE')
    append_block('BTPanel/__init__.py', COOKIE_BLOCK, 'MOLI_PATCH_NOCACHE')
    append_block('class/panelModel/publicModel.py', DATA_BLOCK, 'MOLI_PATCH_DATA')
    append_block('class/panelSSL.py', ACCT_BLOCK, 'MOLI_PATCH_ACCOUNT')


def step_noupdate():
    say('--- 2) 去除更新 ---')
    for rel in ('script/upgrade_panel.py', 'script/upgrade_panel_optimized.py',
                'script/polkit_upgrade.py', 'update.sh'):
        p = os.path.join(PANEL, rel)
        if not os.path.exists(p):
            say('[跳过] 不存在 %s' % rel)
            continue
        if 'MOLI_PATCH_NOUPDATE' in rd(p):
            say('[已存在] %s' % rel)
            continue
        backup(rel)
        wr(p, NOUPDATE_STUB, 0o755)
        say('[完成] %s 已换空壳' % rel)
    db = os.path.join(PANEL, 'data/default.db')
    if os.path.exists(db):
        try:
            import sqlite3
            con = sqlite3.connect(db)
            cur = con.cursor()
            killed = []
            for r in list(cur.execute('select id,name,type,where1,echo from crontab')):
                blob = ' '.join(str(x) for x in r[1:])
                if 'panel_update' in blob or '面板更新' in blob or 'upgrade_panel' in blob:
                    cur.execute('delete from crontab where id=?', (r[0],))
                    killed.append(r[1])
            if killed:
                con.commit()
                say('[完成] 已删除更新定时任务: %s' % killed)
            con.close()
        except Exception as e:
            say('[警告] 定时任务检查失败: %s' % e)


def step_frontend():
    say('--- 3) 前端：授权默认值 / 账户兜底 ---')
    skipped_no_node = False
    for p in glob.glob(os.path.join(PANEL, 'BTPanel/static/js/*.js')) + \
             glob.glob(os.path.join(PANEL, 'BTPanel/static/panel-platform/assets/*.js')):
        try:
            s = rd(p)
        except Exception:
            continue
        if 'MOLI_PATCH' in s:
            continue
        orig = s
        hits = []
        for a, b in JS_RULES:
            n = s.count(a)
            if n:
                s = s.replace(a, b)
                hits.append('%s x%d' % (a[:30], n))
        if s == orig:
            continue
        ok, err = js_ok(s)
        if ok is None:
            # 没有 node：不能改前端（改了没法校验，坏一个 JS 就能把面板 UI 打死），
            # 也不崩 —— 明确说清楚「这几条没做」，verify 会显示成「未生效」
            say('[警告] %s：%s —— 跳过所有前端 JS 补丁' % (os.path.basename(p), err))
            skipped_no_node = True
            break
        if not ok:
            say('[跳过] %s 改动后语法错误：%s' % (os.path.basename(p), err))
            continue
        backup(os.path.relpath(p, PANEL))
        wr(p, s, 0o755)
        say('[完成] %s   %s' % (os.path.relpath(p, PANEL), '; '.join(hits)))
    if skipped_no_node:
        say('')
        say('！前端 JS 补丁没做（缺 node）。补法二选一：')
        say('    1) 装 node 后重跑本脚本：dnf install -y nodejs && 再执行一次 moli_patch.py')
        say('    2) 用仓库的 install/qiyuntai-install.sh patch —— 那一步之前会先对齐依赖')
        say('  注意后端那几条已经打上了，重跑是幂等的。')


def step_stamp():
    say('--- 4) 刷新静态资源版本戳 ---')
    new = str(int(time.time()))
    for rel in ('BTPanel/templates/default/index.html', 'BTPanel/templates/default/login.html'):
        p = os.path.join(PANEL, rel)
        if not os.path.exists(p):
            continue
        s = rd(p)
        olds = set(re.findall(r'\?v=(\d{9,11})', s))
        if not olds:
            say('[跳过] %s 没找到版本戳' % rel)
            continue
        backup(rel)
        for o in olds:
            s = s.replace(o, new)
        wr(p, s)
        say('[完成] %s: %s -> %s' % (rel, ','.join(sorted(olds)), new))
    n = 0
    for p in glob.glob(os.path.join(PANEL, 'BTPanel/static/**/*.js'), recursive=True):
        try:
            s = rd(p)
        except Exception:
            continue
        olds = set(re.findall(r'\?v=(17\d{8})', s))
        if not olds:
            continue
        ns = s
        for o in olds:
            ns = ns.replace(o, new)
        ok, _ = js_ok(ns)
        if not ok:
            continue
        backup(os.path.relpath(p, PANEL))
        wr(p, ns, 0o755)
        n += 1
    say('[完成] JS 内版本戳更新 %d 个文件，统一为 %s' % (n, new))


def step_browser_gate():
    say('--- 5) 关闭「浏览器版本过低跳 /tips」---')
    for rel in ('BTPanel/templates/default/index.html', 'BTPanel/templates/default/login.html'):
        p = os.path.join(PANEL, rel)
        if not os.path.exists(p):
            continue
        s = rd(p)
        if 'MOLI_GATE' in s:
            say('[已存在] %s' % rel)
            continue
        orig = s
        s = s.replace('||isLowerSupportedBrowser()?(', '||!1/*MOLI_GATE*/?(')
        s = s.replace('|| isLowerSupportedBrowser()) {', '|| false /*MOLI_GATE*/) {')
        if s == orig:
            say('[跳过] %s 没匹配到版本检测' % rel)
            continue
        bad = []
        for i, m in enumerate(re.finditer(r'<script([^>]*)>(.*?)</script>', s, re.S)):
            attrs, code = m.group(1), m.group(2)
            if 'src=' in attrs or not code.strip():
                continue
            is_mod = 'module' in attrs
            tmp = '/tmp/moli_gate_%d.%s' % (i, 'mjs' if is_mod else 'js')
            open(tmp, 'w', encoding='utf-8').write(code)
            if not NODE_BIN:
                # 没有 node 就没法校验内联脚本 —— 不能硬改（改坏了面板直接打不开）
                continue
            r = subprocess.run([NODE_BIN, '--check', tmp], capture_output=True, text=True)
            if r.returncode != 0 and 'import.meta' not in code:
                bad.append(i)
        if not NODE_BIN:
            say('[警告] 找不到 node，无法校验内联脚本 —— 跳过「关闭浏览器版本检测」（这条会显示为「未生效」）')
            continue
        if bad:
            say('[失败] %s 内联脚本校验不过，放弃（脚本号 %s）' % (rel, bad))
            continue
        backup(rel)
        wr(p, s)
        say('[完成] %s 版本检测已关闭' % rel)


def step_files():
    say('--- 6) 宝塔脚本依赖的前置文件 ---')
    try:
        if not os.path.exists('/var/bt_setupPath.conf'):
            wr('/var/bt_setupPath.conf', '/www', 0o644)
            say('[完成] /var/bt_setupPath.conf')
        if not os.path.exists('/etc/redhat-release'):
            wr('/etc/redhat-release', 'openEuler release 24.03 (LTS-SP3)', 0o644)
            say('[完成] /etc/redhat-release')
    except Exception as e:
        say('[警告] %s' % e)


def do_verify():
    say('=== 校验 ===')
    checks = []
    for rel, tag, name in (
        ('class/panelPlugin.py', 'MOLI_PATCH_LICENSE', '永久企业版'),
        ('BTPanel/__init__.py', 'MOLI_PATCH_NOCACHE', 'no-store 缓存'),
        ('BTPanel/__init__.py', 'MOLI_PATCH_BINDVIEW', '免绑定视图'),
        ('class/panelModel/publicModel.py', 'MOLI_PATCH_DATA', '数据层(企业版+uid)'),
        ('class/panelSSL.py', 'MOLI_PATCH_ACCOUNT', '账户接口'),
        ('update.sh', 'MOLI_PATCH_NOUPDATE', '去除更新'),
    ):
        p = os.path.join(PANEL, rel)
        ok = os.path.exists(p) and tag in rd(p)
        checks.append((name, ok))
    n_js = len([f for f in glob.glob(os.path.join(PANEL, 'BTPanel/static/**/*.js'), recursive=True)
                if 'MOLI_PATCH' in rd(f)])
    checks.append(('前端授权兜底(%d 个文件)' % n_js, n_js > 0))
    ngate = 0
    for rel in ('BTPanel/templates/default/index.html', 'BTPanel/templates/default/login.html'):
        p = os.path.join(PANEL, rel)
        if os.path.exists(p) and 'MOLI_GATE' in rd(p):
            ngate += 1
    checks.append(('浏览器版本检测已关(%d 个页面)' % ngate, ngate > 0))
    bad = 0
    for name, ok in checks:
        say('  %-28s %s' % (name, '正常' if ok else '未生效'))
        if not ok:
            bad += 1
    say('--- 语法复核 ---')
    for rel in ('class/panelPlugin.py', 'BTPanel/__init__.py',
                'class/panelModel/publicModel.py', 'class/panelSSL.py'):
        p = os.path.join(PANEL, rel)
        if os.path.exists(p):
            ok, err = py_ok_path(p)
            say('  %-38s %s' % (rel, 'OK' if ok else ('语法错误! ' + err)))
            if not ok:
                bad += 1
    say('=== 校验结束 ===')
    # 返回「未生效项数」：调用方拿它当门槛。
    # 为什么需要：打补丁是按「文件路径 + 函数名 + 代码片段」匹配的，
    # 宝塔换版本时任何一处挪动都会让某几条**静默跳过**（原来只打一行 [跳过] 就继续），
    # 结果是装出个四不像（比如企业版显出来了、但关闭更新没生效）。
    return bad


def main():
    args = sys.argv[1:]
    if args and args[0] == 'verify':
        return do_verify()
    if args and args[0] == 'revert':
        return do_revert()
    force = '--force' in args

    say('=== 栖云台面板补丁 开始 %s ===' % time.strftime('%Y-%m-%d %H:%M:%S'))
    if not os.path.isdir(PANEL):
        say('[失败] 找不到 %s' % PANEL)
        return 1

    # ---- 守卫 1：面板版本 ----
    ver = panel_version()
    say('面板版本：%s' % (ver or '（读不到）'))
    if ver not in PANEL_VERIFIED and not force:
        say('')
        say('[失败] 本补丁只在本机实测适配过：%s' % ', '.join(PANEL_VERIFIED))
        say('        当前面板是「%s」。' % (ver or '未知'))
        say('        为什么不自动继续：补丁按「文件路径 + 函数名 + 代码片段」打，')
        say('        宝塔换版本时任何一处挪动都会让某几条**静默失效**，')
        say('        装出来是个四不像（企业版显出来了、关闭更新却没生效）。')
        say('        人工核验过再继续：加 --force')
        return 2

    # ---- 守卫 2：已打过就跳过 ----
    if not force and os.path.exists(MARKER):
        say('检测到已打过补丁的标记：%s' % MARKER)
        bad = do_verify()
        if bad == 0:
            say('校验全部正常 —— 跳过重复打补丁（保持回滚点是原版）。要强制重打加 --force。')
            return 0
        say('但校验有 %d 项未生效，继续补打。' % bad)

    step_backend()
    step_noupdate()
    step_frontend()
    step_stamp()
    step_browser_gate()
    step_files()
    say('=== 备份目录：%s ===' % BK)
    bad = do_verify()

    try:
        os.makedirs(os.path.join(PANEL, 'moli_patch'), exist_ok=True)
        with open(os.path.join(PANEL, 'moli_patch', 'last_run.log'), 'w') as f:
            f.write('\n'.join(LOG))
    except Exception:
        pass

    # ---- 守卫 3：未生效项当门槛 ----
    if bad:
        say('[失败] 有 %d 项补丁未生效（见上面标「未生效」的行）。' % bad)
        say('        不会写"已打好"标记，部署脚本也会因此失败。')
        return 3

    try:
        with open(MARKER, 'w') as f:
            f.write('panel=%s\npatch=%s\ntime=%s\n'
                    % (ver, PATCH_REV, time.strftime('%Y-%m-%d %H:%M:%S')))
    except Exception:
        pass
    say('=== 完成，重启面板生效： /etc/init.d/bt restart ===')
    return 0


if __name__ == '__main__':
    sys.exit(main())
