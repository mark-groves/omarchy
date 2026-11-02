"""Run one pam_authenticate against a scratch PAM directory.

Usage: pam-converse.py [--tty TTY] CONFDIR SERVICE USER ANSWER

ANSWER is "empty", "typed:<text>" or "conv_err" (the conversation fails on
the first prompt). --tty sets PAM_TTY, as sudo does when it has a terminal.
Prints one line per conversation message ("prompt", "info", "error" and its
text), then "result <code>".

libpam reads its stacks from CONFDIR alone (pam_start_confdir), so nothing
under /etc/pam.d runs. Modules still log to the journal under SERVICE, so a
test names its own services.
"""
import argparse
import ctypes

PAM_TTY = 3
PAM_CONV_ERR = 19
PROMPT_STYLES = (1, 2)  # PAM_PROMPT_ECHO_OFF, PAM_PROMPT_ECHO_ON
STYLE_NAMES = {1: "prompt", 2: "prompt", 3: "error", 4: "info"}


class Message(ctypes.Structure):
    _fields_ = [("style", ctypes.c_int), ("text", ctypes.c_char_p)]


class Response(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_void_p), ("retcode", ctypes.c_int)]


CONV_FUNC = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_int,
    ctypes.POINTER(ctypes.POINTER(Message)),
    ctypes.POINTER(ctypes.POINTER(Response)),
    ctypes.c_void_p,
)


class Conv(ctypes.Structure):
    _fields_ = [("conv", CONV_FUNC), ("appdata", ctypes.c_void_p)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tty")
    parser.add_argument("confdir")
    parser.add_argument("service")
    parser.add_argument("user")
    parser.add_argument("answer")
    args = parser.parse_args()

    pam = ctypes.CDLL("libpam.so.0")
    libc = ctypes.CDLL("libc.so.6")
    libc.calloc.restype = ctypes.c_void_p
    libc.calloc.argtypes = [ctypes.c_size_t, ctypes.c_size_t]
    libc.strdup.restype = ctypes.c_void_p
    libc.strdup.argtypes = [ctypes.c_char_p]
    libc.free.argtypes = [ctypes.c_void_p]

    def converse(count, messages, responses, _appdata):
        for i in range(count):
            message = messages[i].contents
            text = (message.text or b"").decode()
            print(STYLE_NAMES.get(message.style, "other"), text, flush=True)
            if message.style in PROMPT_STYLES and args.answer == "conv_err":
                return PAM_CONV_ERR
        # libpam frees the replies and each answer, so both come from malloc.
        replies = ctypes.cast(libc.calloc(count, ctypes.sizeof(Response)), ctypes.POINTER(Response))
        for i in range(count):
            if messages[i].contents.style in PROMPT_STYLES:
                answer = "" if args.answer == "empty" else args.answer.split(":", 1)[1]
                replies[i].resp = libc.strdup(answer.encode())
        responses[0] = replies
        return 0

    conv = Conv(CONV_FUNC(converse), None)
    handle = ctypes.c_void_p()
    pam.pam_start_confdir.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.POINTER(Conv),
        ctypes.c_char_p,
        ctypes.POINTER(ctypes.c_void_p),
    ]
    pam.pam_set_item.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
    pam.pam_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_int]
    pam.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]

    rc = pam.pam_start_confdir(
        args.service.encode(), args.user.encode(), ctypes.byref(conv), args.confdir.encode(), ctypes.byref(handle)
    )
    if rc == 0 and args.tty is not None:
        rc = pam.pam_set_item(handle, PAM_TTY, args.tty.encode())
    if rc == 0:
        rc = pam.pam_authenticate(handle, 0)
    if handle:
        pam.pam_end(handle, rc)
    print("result", rc, flush=True)


main()
