```
  ______   ______   ______   ______   ______   ______   ______   ______   ______   ______   ______
 /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/


 ._.    ________                         __      __                  .___                    ._.
 | |   /  _____/_____    _____   ____   /  \    /  \_____ _______  __| _/____   ____         | |
 |_|  /   \  ___\__  \  /     \_/ __ \  \   \/\/   /\__  \\_  __ \/ __ |/ __ \ /    \        |_|
 |-|  \    \_\  \/ __ \|  Y Y  \  ___/   \        /  / __ \|  | \/ /_/ \  ___/|   |  \       |-|
 | |   \______  (____  /__|_|  /\___  >   \__/\  /  (____  /__|  \____ |\___  >___|  /       | |
 |_|          \/     \/      \/     \/         \/        \/           \/    \/     \/        |_|


  ______   ______   ______   ______   ______   ______   ______   ______   ______   ______   ______
 /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/
```
# game-warden
> Monitor screen time on macOS of games (or other processes) and kill them if the user exceeds the thresholds

This is a fork of [fatso83/game-warden](https://github.com/fatso83/game-warden) that needs **no special macOS permissions**
(no Automation, no Accessibility). Instead of sending keystrokes to the game via System Events, it shows an alert
when time is up and closes the game after a grace period. See [No special permissions needed](#no-special-permissions-needed).

# Why?
Originally, this was a a script to fix Minecraft issue [(MCL-14705)](https://bugs.mojang.com/browse/MCL/issues/MCL-14705),
which is that Apple's Screen Time feature sucks at controlling applications that are built
using Java technology. Previously it did not block them at all, and per July 2025 it
only recognises `java`, but it counts all time the process is active (even if in the background), which
defeats the entire purpose of only counting actual play time ...

This script basically works by asking macOS to keep tabs on the monitored processes
and, once we go over the daily or weekly threshold, kill them (after alerting the user to exit).

# Installation
![download zip](./screenshot-download.png)

## 1. Download the files
Most non-techies should just download the files as a zip-file and unzip it in `~/Downloads`:
[game-warden-main.zip](https://github.com/ffeast/game-warden/archive/refs/heads/main.zip)
(or on [the repo page](https://github.com/ffeast/game-warden): *Code* → *Download ZIP*).
To unzip, just double-click the file once the download has finished.

The ones that are well versed in Git can just clone the repo:
```bash
git clone https://github.com/ffeast/game-warden.git
```

If you already use the original game-warden, just install this one over it: the installer replaces the old version and
keeps your `config.plist` (the new settings are put next to it as `config.plist.new`). You can then remove the
Automation/Accessibility permissions you granted before.

## 2. Run the install script
Now you need to navigate to the folder in the `Terminal.app`. If you have opened the Terminal app, you will typically now type the following:

```bash
❯ cd ~/Downloads/game-warden-main

❯ ./install.sh
📋 Available users:
carlerik
ida
smagriser
👤 Enter comma-separated list of usernames to install for: smagriser
📦 Installing for smagriser...
🧹 Uninstalling for smagriser...
✅ Cleaned up for smagriser (leaving log files, config and state file)
✅ Uninstall complete.
✅ Installed for smagriser
```

## 3. Customise the settings
You can see the basic settings in the file `config.plist`, which you can open in any text editor. Example:
```xml
    <!-- hour:minutes -->
    <key>weeklyMax</key>
    <string>5:00</string>

    <!-- hour:minutes -->
    <key>Monday</key>
    <string>1:00</string>
    ...

    <key>processPatterns</key>
    <dict>
        <key>minecraft</key><string>java.*[m]inecraft</string>
        <key>steam-games</key><string>steamapps</string>
        ...
```
Just change the values as you see fit. This is what I found right for my 7 year old. Once you feel you have the settings right, just re-run `./install.sh`.

### What happens when time runs out
1. `warnTime` before the limit, a notification with `customExitMessage` is shown.
2. When the limit is reached, an alert with `timeoutTitle` / `timeoutMessage` is shown.
3. After `exitGraceTime`, the game process is killed and a notification with `killMessage` is shown.
   If the game is started again later that day (or week), it is killed right away.

### All settings

| Key | Format | Default | Meaning |
| --- | --- | --- | --- |
| `Monday` … `Sunday` | `h:mm` | `1:00` | Daily limit |
| `weeklyMax` | `h:mm` | `5:00` | Weekly limit |
| `warnTime` | `hh:mm:ss` | `00:02:00` | How long before the limit the warning is shown |
| `exitGraceTime` | `hh:mm:ss` | `00:02:00` | How long the child has to save and exit after the limit is reached |
| `customExitMessage` | text | `Save and exit to avoid losing work.` | Warning notification text |
| `timeoutTitle` | text | `Time's up` | Title of the alert shown when the limit is reached |
| `timeoutMessage` | text | `Save and exit. The game will close in {seconds} seconds.` | Alert text. `{seconds}` is replaced by `exitGraceTime` in seconds |
| `notificationTitle` | text | `Game Warden` | Title of all notifications |
| `killMessage` | text | `Time's up!` | Notification shown when the game is killed |
| `warnAction` | shell command | (none) | Optional command to run together with the warning |
| `processPatterns` | dict | | Regular expressions matched against `ps -f` output of the frontmost app |

All texts can be translated, for example:
```xml
    <key>timeoutTitle</key>
    <string>Время вышло</string>
    <key>timeoutMessage</key>
    <string>Сохранись и выйди. Игра закроется через {seconds} секунд.</string>
```

## No special permissions needed
The script sends no Apple events to other apps (no System Events, no Finder). It gets the frontmost app via `lsappinfo`,
shows its own alerts and notifications, and kills the game with `kill`. So there is no need to grant Automation or
Accessibility permissions, and you do not have to log in as the child to approve anything.

### Known limitation: fullscreen games
Since macOS Sonoma, a background process may not be allowed to take focus over a fullscreen app. The alert may then
appear on another space and not be visible inside the game. The notification is still shown, and the game is
killed after `exitGraceTime` either way. (Tested on macOS 26.0.1 with fullscreen Minecraft: the alert was visible.)

# Tips and tricks

## Checking the state from another machine
Put something like this in a script
```bash
REMOTE=my-remote-server
REMOTE_USER_TO_CHECK=johndoe
echo; read -s  -p "Enter remote sudo password: " REMOTE_SUDO_PW;
echo;
ssh $REMOTE cat \| sudo --prompt="" -S --  cat \"/Users/${REMOTE_USER_TO_CHECK}/Library/Application Support/game-warden/data/usage-state.dat\"  <<< $REMOTE_SUDO_PW;
unset $REMOTE_SUDO_PW

Enter remote sudo password:
01:00:25,03:59:58
```

## Resetting the config or state without re-installing
Just create the .uninstall flag to make the process quit
```bash
$ whoami
janedoe

$ cd ~johndoe/Library/Application Support/game-warden

# reset the usage db
$ sudo -u johndoe touch data/.uninstall; sudo rm data/usage-state.dat;

# to start using a changed config.plist, just make the process restart:
$ sudo -u johndoe touch data/.uninstall
```

# Development

If you want to hack on this, feel free! You might find it useful to observe these tips:

## Control logging via env vars
AppleScript is terrible at debugging, only giving you an offset in chars (?) indicating what went wrong.
Configurable logging has proven essential, to avoid commenting code in and out.

When developing and/or debugging this, I usually uninstall the program from the current user to not have weird result and then run it like this:
```bash
GW_LOG_LEVEL=TRACE GW_APPENDER=stderr osascript game-warden.applescript config.plist
```

## Figuring out where something went wrong
As mentioned, AppleScript is terrible at debugging, often just giving you an offset in characters, not lines.
To figure out what is happening at offset 5435, I usually just do this to get some context:
```bash
dd if=game-warden.applescript of=/dev/stdout bs=1 skip=5420 count=100
```
This outputs 100 bytes, starting 15 chars before the offset.

# Acknowledgements

This started as a straight up copy of user "jhopgei"'s (Jürgen, last name unknown) Applescript shared on the
[Mojang bug tracker (MCL-14705)](https://bugs.mojang.com/browse/MCL/issues/MCL-14705).
I then asked ChatGPT to translate the field names into English. Following that, I basically
I made changes to make it more easily installable, distributable and configurable
by moving all user configurable bits out of the AppleScript code.

I also made the script that is passed around uncompiled, meaning it is
simple to view and edit with a simple text editor, and of course, easily tracked in Git.
I still compile it at install time. I also added extra features, an install and uninstall script,
etc, etc and in the end made it not minecraft specific at all. Check the commit log :)

