/*
 * repo_process_security.h
 *
 * Narrow C entry points for process-security calls that Swift cannot reach
 * through the Darwin module.
 */

#ifndef REPO_PROCESS_SECURITY_H
#define REPO_PROCESS_SECURITY_H

#ifdef __cplusplus
extern "C" {
#endif

/* Performs ptrace(PT_DENY_ATTACH, 0, NULL, 0) and returns its result. */
int repo_ptrace_deny_attach(void);

#ifdef __cplusplus
}
#endif

#endif /* REPO_PROCESS_SECURITY_H */
