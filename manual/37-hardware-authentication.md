# Hardware authentication

### Fingerprint authentication

A lot of laptops come with a fingerprint sensor to do authentication. You can use this with Omarchy by running _Setup > Security > Fingerprint_ in the Omarchy menu (`Super + Space`).

That'll install the fingerprint package, collect your print, verify it, and you'll be set to go using your fingerprint to unlock from the lock screen (which you can trigger with `Super + Ctrl + L`), enter sudo mode, and authorize system prompts.

Once the lock screen has turned the display off, the sensor rests to save power, so wake the screen with any key or the touchpad before touching it.

When your laptop lid is closed, the fingerprint prompt is automatically skipped, so you go straight to the password prompt instead of waiting on a sensor you can't reach. If you otherwise need to work on an external keyboard that doesn't have a sensor, just hit `CTRL + C`, when you're prompted for your fingerprint during `sudo`.

You can remove the fingerprint authentication under _Remove > Security > Fingerprint_ in the Omarchy menu.

### Face authentication

If Howdy is installed, _Setup > Security > Face_ in the Omarchy menu (`Super + Space`) adds the lid camera to the lock screen (`Super + Ctrl + L`), `sudo`, and system prompts (`pkexec`, the 1Password system unlock, and other polkit dialogs).

At `sudo` and system prompts face asks first: the password prompt comes up as usual, and pressing Enter on the empty password starts a face scan. A typed password never starts the camera. A program with no terminal cannot start a scan through `sudo`: plain `sudo` has nowhere to ask for the password, and an empty password piped into `sudo -S` stops before the camera. If face misses, type the password.

Asking first is consent, not proof that the Enter was yours. A program running as you can still answer a prompt itself, by running `sudo` inside a terminal of its own (`script -c 'sudo …'`) or by pressing Enter in a system prompt with `wtype`. Linux has no secure desktop to stop that, so treat a prompt you did not expect as a reason to stop and look.

Setup Face asks for your password through `sudo` and then changes one file at a time, testing each one as you before it moves on. For `sudo`, a run with no terminal and an empty `sudo -S` must both fail without a scan, then `sudo` asks for your password and must take it. For system prompts, a test prompt opens: it must not scan on its own, and must take your typed password. Type the password at both, rather than pressing Enter on an empty field. If a check fails, or you press Ctrl+C, that file goes back to what it was and setup stops. If a run ends before a file passes and without putting it back, after a power cut for one, the next run tests that file again before it moves on. Each change keeps a copy of the file it replaced in `/var/lib/omarchy/face-pam/`. Setup refuses to start while passwordless `sudo` is on, since `sudo` would then skip the password prompt it means to test, and while Howdy's `abort_if_lid_closed` is turned off.

It does not enroll a face. Enroll or change the model with `howdy add`. Every prompt uses that one model. It does not change LUKS or login. When the lid is closed, Howdy skips the camera and you type the password. On cameras whose infrared emitter needs a UVC control (the Bison IR camera in the Yoga Pro 9, for one), each scan switches the emitter on first, because that camera forgets the setting whenever it goes idle. Setup Face also pins Howdy's compare process to one CPU and keeps that pin across `howdy-next` upgrades, so a missed scan is not killed by the sandbox's CPU limit before the timeout.

On the lock screen the camera stays off until you ask for it: click the face in the password field, or press Space or Enter while the field is empty. The scan card appears above the field, and a recognised face unlocks as soon as the match has played. Typing a password or pressing Esc stops the scan, and a miss hands back to the face button. To have the lock screen scan on its own whenever it is up, set `"lock": { "face": "automatic" }` in `~/.config/omarchy/shell.json`.

You can remove it under _Remove > Security > Face_. That takes face off the lock screen, `sudo`, and system prompts, testing your typed password at each prompt the same way. The password still works. Howdy models stay until you remove them with howdy.

### Fido2 authentication

If you're using a Fido2 device, you can set it up for `sudo` authentication using _Setup > Security > Fido2_ in the Omarchy menu (`Super + Space`). It covers `sudo` and system authorization prompts, though, not unlocking your computer.

You can remove the fido2 authentication under _Remove > Security > Fido2_ in the Omarchy menu.
