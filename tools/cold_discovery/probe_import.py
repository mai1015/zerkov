#!/usr/bin/env python3
"""One fresh, isolated Linux editor invocation. No retry or installed-file edits.

Exit 0: this invocation exited normally without engine-error diagnostics.
Exit 2: crash/error/timeout recorded; NOT an expected-failure readiness pass.
Exit 1: invalid arguments or collection failure. An existing output is rejected.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
ENGINE_SHA = '8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e'
ERRORS = re.compile(rb'SCRIPT ERROR|(?m:^\s*ERROR:)')


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def prepare(godot: Path, output: Path, library: Path | None, symbol: str,
            explicit: bool, expected_engine_sha: str = ENGINE_SHA) -> tuple[list[str], dict[str, str], dict]:
    if sys.platform != 'linux' or platform.machine() != 'x86_64':
        raise ValueError('Qualified diagnostic host is Linux x86-64 only')
    if not re.fullmatch(r'[0-9a-f]{64}', expected_engine_sha):
        raise ValueError('An exact expected engine SHA-256 is required')
    if digest(godot) != expected_engine_sha:
        raise ValueError('Engine differs from expected bytes; no process started')
    if explicit and library is None:
        raise ValueError('Explicit registration requires an extension')
    if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', symbol):
        raise ValueError('Invalid native entry symbol')
    if library is not None and (not library.is_file() or library.is_symlink()):
        raise ValueError('Library must be a regular non-symlink file')
    if output.is_symlink() or output.exists():
        raise ValueError('Output must be a new directory; nothing is deleted')
    output = output.resolve()
    if output.is_relative_to(ROOT) or ROOT.is_relative_to(output):
        raise ValueError('Output must be outside the source checkout')
    output.mkdir(parents=True, exist_ok=False)
    project = output / 'project'
    project.mkdir()
    (project / 'project.godot').write_text(
        'config_version=5\n[application]\nconfig/name="Cold discovery control"\n'
        '[display]\nwindow/size/viewport_width=1920\nwindow/size/viewport_height=1080\n'
        '[rendering]\nrenderer/rendering_method="gl_compatibility"\n', encoding='utf-8')
    if library is not None:
        shutil.copyfile(library, project / 'control.so')
        (project / 'control.gdextension').write_text(
            f'[configuration]\nentry_symbol="{symbol}"\ncompatibility_minimum="4.7"\n'
            'reloadable=false\n[libraries]\nlinux.debug.x86_64="res://control.so"\n', encoding='utf-8')
    if explicit:
        (project / '.godot').mkdir()
        (project / '.godot/extension_list.cfg').write_text('res://control.gdextension\n', encoding='utf-8')
    env = dict(os.environ)
    for key, directory in [('HOME', 'home'), ('XDG_CACHE_HOME', 'cache'),
                           ('XDG_CONFIG_HOME', 'config'), ('XDG_DATA_HOME', 'data')]:
        p = output / directory
        p.mkdir()
        env[key] = str(p)
    env['GODOT_SILENCE_ROOT_WARNING'] = '1'
    command = [str(godot.resolve()), '--headless', '--resolution', '1920x1080',
               '--path', str(project), '--editor', '--import', '--quit', '--verbose']
    metadata = {'schema': 1, 'engine_sha256': expected_engine_sha,
                'library_sha256': digest(library) if library else None,
                'entry_symbol': symbol if library else None,
                'explicit_startup_registration': explicit, 'fresh_user_directories': True,
                'preseeded_script_cache': False, 'command': command,
                'promotion_approved': False, 'engine_fix_validated': False}
    return command, env, metadata


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--entry-symbol', default='discovery_probe_init')
    parser.add_argument('--explicit-startup', action='store_true')
    parser.add_argument('--expected-engine-sha256', default=ENGINE_SHA)
    args = parser.parse_args()
    try:
        command, env, report = prepare(args.godot, args.output, args.library,
            args.entry_symbol, args.explicit_startup, args.expected_engine_sha256)
        try:
            process = subprocess.run(command, env=env, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, timeout=30)
            log, code, timeout = process.stdout, process.returncode, False
        except subprocess.TimeoutExpired as error:
            log, code, timeout = error.stdout or b'', None, True
        report.update(exit_code=code, timeout=timeout, log_sha256=hashlib.sha256(log).hexdigest(),
                      engine_error=bool(ERRORS.search(log)))
        report['invocation_succeeded'] = code == 0 and not report['engine_error'] and not timeout
        (args.output / 'engine.log').write_bytes(log)
        (args.output / 'result.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print(json.dumps(report, sort_keys=True))
        return 0 if report['invocation_succeeded'] else 2
    except (OSError, ValueError) as error:
        print(f'DISCOVERY_COLLECTION_ERROR {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
