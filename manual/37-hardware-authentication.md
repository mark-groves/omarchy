# Hardware authentication

### Fingerprint authentication

A lot of laptops come with a fingerprint sensor to do authentication. You can use this with Omarchy by running _Setup > Security > Fingerprint_ in the Omarchy menu (`Super + Space`).

That'll install the fingerprint package, collect your print, verify it, and you'll be set to go using your fingerprint to unlock from the lock screen (which you can trigger with `Super + Ctrl + L`), enter sudo mode, and authorize system prompts.

When your laptop lid is closed, the fingerprint prompt is automatically skipped, so you go straight to the password prompt instead of waiting on a sensor you can't reach. If you otherwise need to work on an external keyboard that doesn't have a sensor, just hit `CTRL + C`, when you're prompted for your fingerprint during `sudo`.

You can remove the fingerprint authentication under _Remove > Security > Fingerprint_ in the Omarchy menu.

### Face authentication

If Howdy is already enrolled for the lock screen, you can use the same lid camera for system prompts — `pkexec`, the 1Password system unlock, and other polkit dialogs — with _Setup > Security > Face_ in the Omarchy menu (`Super + Space`).

That adds face in front of the password on those prompts. It does not change the lock screen, `sudo`, LUKS, or login. When the lid is closed, the camera is skipped and you type the password. If face misses, the password field is still there.

You can remove it under _Remove > Security > Face_. Lock screen face and `sudo` stay as they are.

### Fido2 authentication

If you're using a Fido2 device, you can set it up for `sudo` authentication using _Setup > Security > Fido2_ in the Omarchy menu (`Super + Space`). It covers `sudo` and system authorization prompts, though, not unlocking your computer.

You can remove the fido2 authentication under _Remove > Security > Fido2_ in the Omarchy menu.
