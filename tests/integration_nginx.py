"""Disposable real-systemd/nginx validation; never touches nginx.service."""
from pathlib import Path
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import time

if os.geteuid() != 0:
    sys.exit("Run this optional integration test as root on Linux with systemd.")

root = Path(tempfile.mkdtemp(prefix='vps-tune-integration-', dir='/tmp'))
root.chmod(0o755)
unit = 'vps-tune-nginx-check-' + str(root.name.rsplit('-', 1)[-1]) + '.service'
unit_path = Path('/run/systemd/system') / unit
dropin = Path(str(unit_path) + '.d') / 'zz-vps-tune-nofile.conf'
source = Path(sys.argv[1]).read_text()
code = source.split("<<'NGINX_PY'\n", 1)[1].split('\nNGINX_PY', 1)[0]
spec = importlib.util.spec_from_loader('nginx_test', loader=None)
m = importlib.util.module_from_spec(spec)
exec(compile(code, 'tune.sh:nginx', 'exec'), m.__dict__)
m.SERVICE, m.DROPIN, m.BACKUPS = unit, dropin, root / 'backups'
config = root / 'nginx.conf'
config.write_text(f'pid {root}/nginx.pid;\nerror_log {root}/error.log notice;\n'
                  'worker_processes 1;\nevents { worker_connections 512; }\n'
                  'http { access_log off; }\n')
unit_path.write_text(f'''[Service]
Type=forking
PIDFile={root}/nginx.pid
ExecStart=/usr/sbin/nginx -c {config}
ExecReload=/usr/sbin/nginx -c {config} -s reload
ExecStop=/bin/kill -QUIT $MAINPID
LimitNOFILE=1024:524288
TimeoutStopSec=10
''')
try:
    m.run('systemctl', 'daemon-reload')
    m.run('systemctl', 'start', unit)
    time.sleep(0.3)
    initial_pid = m.prop('MainPID')
    print('ISOLATED BEFORE:', initial_pid, m.process_limits(initial_pid), flush=True)
    changes, nofile, conns = m.plan_config(config, 262144, 32768)
    changes[dropin] = '[Service]\nLimitNOFILE=524288\n'
    m.apply(changes, config, nofile, 524288, False, False)
    assert m.prop('MainPID') == initial_pid, 'reload unexpectedly restarted master'
    assert min(m.process_limits(m.worker_pids(int(initial_pid))[0])) >= 262144
    count = len(list(m.BACKUPS.iterdir()))
    changes, _, _ = m.plan_config(config, 262144, 32768)
    assert not changes
    m.apply(changes, config, nofile, 524288, False, False)
    assert len(list(m.BACKUPS.iterdir())) == count
    m.apply({}, config, nofile, 524288, False, True)
    assert m.prop('MainPID') != initial_pid
    assert min(m.process_limits(m.prop('MainPID'))) >= 524288
    stable = config.read_bytes()
    try:
        m.apply({config: 'events { invalid_directive on; }'}, config, nofile, 524288, False, False)
        raise AssertionError('invalid candidate accepted')
    except subprocess.CalledProcessError:
        pass
    assert config.read_bytes() == stable
    assert m.prop('ActiveState') == 'active'
    m.run('nginx', '-t', '-c', str(config))
    print('PASS: real nginx reload, worker limits, idempotence, restart, invalid-config rollback', flush=True)
finally:
    subprocess.run(['systemctl', 'stop', unit], check=False)
    unit_path.unlink(missing_ok=True)
    shutil.rmtree(dropin.parent, ignore_errors=True)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'reset-failed', unit], check=False, capture_output=True)
    shutil.rmtree(root)
