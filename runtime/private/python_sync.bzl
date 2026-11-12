# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The retry decision and exhaustion hint for a timed-out uv sync."""

visibility("//runtime/...")

def python_sync_retry(return_code, stderr, attempt, attempts, timeout):
    """Decide whether another bounded uv sync attempt is allowed.

    Args:
        return_code: The repository_ctx.execute return code.
        stderr: The repository_ctx.execute stderr.
        attempt: The one-based attempt that just finished.
        attempts: The maximum number of attempts.
        timeout: The timeout of each attempt, in seconds.

    Returns:
        A struct with retry and hint fields. Other failures stop immediately.
    """

    # Bazel 9.3.2 StarlarkExecutionResult uses 256 for both timeouts and
    # command exceptions. Only the timeout has this stderr.
    if return_code != 256 or stderr.strip() != "Timed out":
        return struct(retry = False, hint = "")
    if attempt < attempts:
        return struct(retry = True, hint = "")
    return struct(
        retry = False,
        hint = "\nuv sync timed out on all {} attempts ({} s each).\n".format(attempts, timeout),
    )
