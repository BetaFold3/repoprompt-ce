/*
 * repo_process_security.c
 *
 * Narrow C entry points for process-security calls that Swift cannot reach
 * through the Darwin module.
 */

#include "repo_process_security.h"

#include <sys/types.h>
#include <sys/ptrace.h>

#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif

int repo_ptrace_deny_attach(void)
{
    return ptrace(PT_DENY_ATTACH, 0, NULL, 0);
}
