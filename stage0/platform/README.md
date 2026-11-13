# Stage 0 platform shims

> **Status:** In progress (M1): Windows and Linux shims written.

Everything OS-specific about `envoc0` itself: the executable header (PE or ELF) and eight shim routines (`sys_open`, `sys_read`, `sys_write`, `sys_close`, `sys_alloc`, `sys_free`, `sys_exit`, `sys_args`). `windows.eas` goes through kernel32 imports; `linux.eas` uses raw syscalls. Porting Stage 0 to a new OS means adding one file here.
