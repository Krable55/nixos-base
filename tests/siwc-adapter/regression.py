"""Run prior gates against this candidate; never modify historical results.
Usage: isolated network namespace + Nix Python + this script [packaged-source.py].
Only .py source fixtures are copied; all credential JSON is freshly synthetic.
The sibling spikes/siwc-adapter archive intentionally remains outside this repo.
This optional historical regression runner requires that local archive; it is not
a standalone clean-checkout test. Repository-contained unit tests run separately.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SPIKE = ROOT.parent / 'spikes/siwc-adapter'
SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'packages/siwc-adapter/filtering_adapter.py'


def main():
    assert sorted(n for _, n in socket.if_nameindex()) == ['lo']
    with tempfile.TemporaryDirectory(prefix='siwc-regression-') as temp:
        target = Path(temp)
        for directory in ('tests', 'adapter', 'state'): (target / directory).mkdir()
        for directory in ('tests', 'adapter'):
            for path in (SPIKE / directory).glob('*.py'):
                if path.name == 'filtering_adapter.py': continue
                text = path.read_text().replace(str(SPIKE), str(target))
                (target / directory / path.name).write_text(text)
        (target / 'run_all.py').write_text((SPIKE / 'run_all.py').read_text())
        # Execute candidate unchanged into this module's globals so dependency
        # injection in existing tests still addresses its actual global state.
        wrapper = f'''from pathlib import Path
_entry_name = __name__
__name__ = 'production_candidate'
exec(compile(Path({str(SOURCE)!r}).read_text(), {str(SOURCE)!r}, 'exec'), globals())
__name__ = _entry_name
if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1].startswith('--'):
        main()
    else:
        # Historical gate1's 15-second stall tests a 10-second idle timeout.
        # Only this isolated test invocation uses the old timeout settings.
        IDLE_READ_TIMEOUT_SECONDS = 10
        MAX_TOTAL_SECONDS = 20
        legacy_test_harness_main()
'''
        (target / 'adapter/filtering_adapter.py').write_text(wrapper)
        template = (ROOT / 'packages/siwc-adapter/config.toml.in').read_text()
        for directory, alias, port in [('config', 'spike', 18201), ('gate2-config', 'spike2', 18301)]:
            config = target / 'state' / directory; config.mkdir()
            text = template.replace('@CAPABILITY@', 'synthetic-only-local-capability-0123456789')
            text = text.replace('127.0.0.1:18766', f'127.0.0.1:{port}').replace('[agents.pi4', f'[agents.{alias}')
            (config / 'config.toml').write_text(text); (config / 'config.toml').chmod(0o600)
        for name in ('home', 'gate2-home'): (target / 'state' / name).mkdir()
        # New contract is an additional gate, not a rewrite of spike evidence.
        shutil.copyfile(ROOT / 'tests/siwc-adapter/gate7_empty_completion.py',
                        target / 'tests/gate7_empty_completion.py')
        gates = ['gate1_filtered.py', 'gate2_toolcall.py', 'gate4_refresh_lock.py',
                 'gate5_auth_credential.py', 'gate6_acceptance.py', 'gate7_empty_completion.py']
        reports = []
        for gate in gates:
            p = subprocess.run([sys.executable, '-B', str(target / 'tests' / gate)],
                               capture_output=True, text=True, timeout=180,
                               env={'HOME': temp, 'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'})
            try: result = json.loads(p.stdout)
            except json.JSONDecodeError: result = None
            failures = (sum(r.get('verdict') == 'FAIL' for r in result) if isinstance(result, list)
                        else result.get('failures', 0) + result.get('errors', 0) if isinstance(result, dict) else 1)
            passed = p.returncode == 0 and result is not None and not failures
            count = len(result) if isinstance(result, list) else result.get('tests_run', 1) if isinstance(result, dict) else 0
            print(json.dumps({'gate': gate, 'exit': p.returncode, 'passed': passed, 'checks_or_observations': count}), flush=True)
            if not passed:
                # These fixtures contain only synthetic canaries, never live credentials.
                print(p.stderr[-3000:], file=sys.stderr)
            reports.append(passed)
        print(json.dumps({'candidate_sha256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
                          'all_gates_passed': all(reports)}))
        return 0 if all(reports) else 1


if __name__ == '__main__': raise SystemExit(main())
