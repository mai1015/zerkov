#!/usr/bin/env python3
"""Exact-binary Linux x86-64 ptrace experiment on one newly spawned test process.

Never attaches to an existing process or edits a binary file. --skip-null makes
one explicitly recorded causal intervention in child memory; it is NOT a fixed
engine build, a loader workaround to ship, or a package-acceptance invocation.
"""
from __future__ import annotations
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import signal
import sys
import time
from probe_import import ENGINE_SHA, prepare

# Source-correlated disassembly addresses in the exact non-PIE official ELF.
DOC, GENERATE, RESET = 0x9012880, 0x1c84e60, 0x1ac6b88
MASK = (1 << 64) - 1
libc = C.CDLL(None, use_errno=True)
libc.ptrace.restype = C.c_long
FIELDS = 'r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi orig_rax rip cs eflags rsp ss fs_base gs_base ds es fs gs'.split()


class Registers(C.Structure):
    _fields_ = [(name, C.c_ulonglong) for name in FIELDS]


def ptrace(request: int, pid: int, address: int = 0, data=0) -> int:
    C.set_errno(0)
    value = libc.ptrace(C.c_uint(request), C.c_uint(pid), C.c_void_p(address),
                        data if isinstance(data, C.c_void_p) else C.c_void_p(data))
    error = C.get_errno()
    if value == -1 and error:
        raise OSError(error, os.strerror(error))
    return value & MASK


def registers(pid: int) -> Registers:
    r = Registers()
    ptrace(12, pid, 0, C.cast(C.byref(r), C.c_void_p))
    return r


def set_registers(pid: int, r: Registers) -> None:
    ptrace(13, pid, 0, C.cast(C.byref(r), C.c_void_p))


def wait(pid: int, deadline: float) -> int:
    while time.monotonic() < deadline:
        child, status = os.waitpid(pid, os.WNOHANG)
        if child:
            return status
        time.sleep(0.005)
    raise TimeoutError('Debugger exceeded its 30-second collection deadline')


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--godot', type=Path, required=True)
    p.add_argument('--library', type=Path, required=True, help='One-class probe, not a game project')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--skip-null', action='store_true')
    args = p.parse_args()
    command, env, report = prepare(args.godot, args.output, args.library,
                                  'discovery_probe_init', False, ENGINE_SHA)
    binary = args.godot.read_bytes()
    offset = GENERATE - 0x400000
    if binary[offset:offset + 17].hex() != '4883ec08488b3d15da3807be03000000e8':
        # The signature is 17 bytes: prologue, doc load, flags and CALL opcode.
        raise ValueError('Unexpected generation-entry instructions')
    offset = RESET - 0x400000
    instruction = binary[offset:offset + 11]
    if (instruction[:3] != bytes.fromhex('48c705') or instruction[7:] != b'\0' * 4
            or RESET + 11 + int.from_bytes(instruction[3:7], 'little', signed=True) != DOC):
        raise ValueError('Unexpected documentation-reset instruction')
    command.insert(1, '--disable-crash-handler')
    report.update(command=command, intervention=args.skip_null, binary_files_modified=False,
                  diagnostic_only=True, events=[], exit_code=None)
    pid = 0
    exited = False
    try:
        with (args.output / 'engine.log').open('wb') as log:
            pid = os.fork()
            if pid == 0:
                try:
                    os.dup2(log.fileno(), 1)
                    os.dup2(log.fileno(), 2)
                    ptrace(0, 0)  # TRACEME, then exec stops this child only.
                    os.execve(command[0], command, env)
                except BaseException:
                    os._exit(127)
            deadline = time.monotonic() + 30
            status = wait(pid, deadline)
            if not os.WIFSTOPPED(status) or os.WSTOPSIG(status) != signal.SIGTRAP:
                exited = os.WIFEXITED(status) or os.WIFSIGNALED(status)
                raise RuntimeError('Child did not reach its initial exec stop')
            ptrace(0x4200, pid, 0, 0x100000)  # EXITKILL if tracer unexpectedly dies.
            saved = {address: ptrace(2, pid, address) for address in (GENERATE, RESET)}
            for address, word in saved.items():
                ptrace(5, pid, address, (word & ~255) | 0xcc)
            ptrace(7, pid)
            while True:
                status = wait(pid, deadline)
                if os.WIFEXITED(status) or os.WIFSIGNALED(status):
                    exited = True
                    report['exit_code'] = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
                    break
                r, sig = registers(pid), os.WSTOPSIG(status)
                address = r.rip - 1
                if sig == signal.SIGTRAP and address in saved:
                    doc = ptrace(2, pid, DOC)
                    report['events'].append({'event': 'doc_reset' if address == RESET else 'deferred_extension_docs',
                                             'rip': hex(address), 'doc': hex(doc)})
                    if address == GENERATE and doc == 0 and args.skip_null:
                        r.rip, r.rsp = ptrace(2, pid, r.rsp), r.rsp + 8
                        set_registers(pid, r)
                        report['events'].append({'event': 'debugger_skipped_null_callback'})
                        ptrace(7, pid)
                        continue
                    ptrace(5, pid, address, saved[address])
                    r.rip = address
                    set_registers(pid, r)
                    ptrace(9, pid)  # Single-step original instruction, then re-arm.
                    step = wait(pid, deadline)
                    if not os.WIFSTOPPED(step) or os.WSTOPSIG(step) != signal.SIGTRAP:
                        exited = os.WIFEXITED(step) or os.WIFSIGNALED(step)
                        raise RuntimeError('Unexpected single-step result')
                    ptrace(5, pid, address, (saved[address] & ~255) | 0xcc)
                    ptrace(7, pid)
                else:
                    if sig == signal.SIGSEGV:
                        report['events'].append({'event': 'SIGSEGV', 'rip': hex(r.rip),
                                                 'rbx': hex(r.rbx), 'doc': hex(ptrace(2, pid, DOC))})
                    ptrace(7, pid, 0, sig)  # Propagate faults; observation never suppresses them.
    except (OSError, RuntimeError, TimeoutError) as error:
        report['collection_error'] = str(error)
    finally:
        if pid > 0 and not exited:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except ProcessLookupError:
                pass
        (args.output / 'trace.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))
    if 'collection_error' in report:
        return 1
    return 0 if report['exit_code'] == 0 else 2


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f'DISCOVERY_TRACE_ERROR {error}', file=sys.stderr)
        raise SystemExit(1)
