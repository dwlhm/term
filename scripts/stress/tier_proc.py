"""Tier processes of a bin/term build: find them and read their CPU and RSS.

`ps -o rss,time` needs an entitlement in the sandbox; proc_pidinfo does not.
"""
import collections
import ctypes
import subprocess

Task = collections.namedtuple("Task", "rss_mb user_s sys_s")


class _TaskInfo(ctypes.Structure):  # struct proc_taskinfo (sys/proc_info.h)
    _fields_ = [("virtual", ctypes.c_uint64), ("resident", ctypes.c_uint64),
                ("user", ctypes.c_uint64), ("system", ctypes.c_uint64), ("rest", ctypes.c_uint8 * 64)]


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
_TB = _Timebase()
ctypes.CDLL("/usr/lib/libSystem.dylib").mach_timebase_info(ctypes.byref(_TB))


def pids(term, role):
    out = subprocess.run(["pgrep", "-f", "^%s --%s" % (term, role)], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def tier_pid(term, role):
    found = pids(term, role)
    return found[0] if found else None


def task_info(pid):
    """Task of pid (zeros when it is gone); user/sys come in mach ticks."""
    ti = _TaskInfo()
    if not pid or _LIBPROC.proc_pidinfo(pid, 4, ctypes.c_uint64(0), ctypes.byref(ti), ctypes.sizeof(ti)) <= 0:
        return Task(0.0, 0.0, 0.0)
    s = _TB.numer / _TB.denom / 1e9
    return Task(ti.resident / (1 << 20), ti.user * s, ti.system * s)


def cpu_s(task):
    return task.user_s + task.sys_s
