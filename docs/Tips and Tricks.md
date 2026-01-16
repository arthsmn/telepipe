# Telepipe Tips and Tricks

Most Linux command-line software and workflows assume that a terminal console is being used. Naturally, this poses some problems for using a non-terminal command-line shell. This document contains advice for using specific programs from Telepipe.

# Contents

- [General Advice](#general-advice)

Specific programs:
1. [ls](#ls)
2. [ssh](#ssh)
3. [sudo](#sudo)

# General Advice

Because there have been decades of work put into making command-line programs work with specific kinds of console terminals while comparatively little time has been put into developing tools to run command-lines outside of the terminal, it can be difficult for longtime terminal users to get accustomed to Telepipe.

The single most important piece of advice is therefore to remember that **Telepipe is not a terminal**. It does not implement PTYs. It does not handle ioctls. It does not format text. It does not display text in monospace fonts. Telepipe is closer to being a command-line shell which is presented through a graphical interface instead of a terminal. This also means that keyboard shortcuts that seasoned terminal users would expect are absent—can't use Ctrl+C to quit programs as that is reserved for copying to the clipboard.

Under the hood, Telepipe executes each command using a new non-interactive instance of the user's configured shell. This means that environment variables and the like must be customized as they would for a conventional terminl-based shell: by editing profile files. Variables will not persist between commands, and shell builtin commands will fail silently without doing anything. Running `which <command>` will tell you if a command is an actual program or a builtin for your shell.

Because Telepipe uses non-interactive shells to run commands, shell aliases are generally not available. A simple alternative is to write simple shell scripts for custom commands which are executed frequently. This is especially true if making heavy use of [clipboard redirection](Clipboard Redirection.md) to edit text.

# Specific Programs

The following sections are comprised of advice for dealing with crucial programs which behave oddly or suboptimally in Telepipe.

## ls

By default, running GNU `ls` in Telepipe works flawlessly—but it leaves something to be desired. As Telepipe lacks completions, filling in filenames can be somewhat cumbersome. The intended solution to this is to use programs like `ls` to list the filenames before dragging-and-dropping ones you want to work with into the command entry. This only works for the current directory, as `ls` does not include relative paths when listing other directories. This can be easily remedied by using the `-d` flag, but it will only list the given path instead of the directory's children as would be expected from other invocations of `ls`.

The following shell script amends this by using a wildcard to `ls -d` if the listed file is a directory, otherwise it calls `ls` as normal. It will also cause `ls` to output all file names by wrapping them in quotation marks. A good name to give this script is `dir`.

```sh
#!/usr/bin/env sh

# Strip trailing slashes from directory name
DIR=`echo $1 | sed "s;/*$;;"`

if [ -z "$DIR" ]
then
	ls -Q
elif [ -d "$DIR" ]
then
	ls -dQ "$DIR"/*
else
	ls -Q "$DIR"
fi
```

## ssh

Secure Shell (`ssh`) is the gold standard for accessing other systems through a terminal. Unfortunately, its most common use case (running an interactive remote command-line shell) behaves oddly when not run in a terminal.

The recommended way to work with resources on a remote machine is to mount that machine's filesystem locally. To mount filesystems in a way that works with Telepipe, it's necessary to use a method that is compatible with GVFS. Users of GNOME can do this easily using the Files app (a.k.a. Nautilus) by accessing the "Network" resource in that app's sidebar. Once a network resource is available, navigate to it in Telepipe using the folder button to the left of the command entry.

An advantage to this approach of working with remote resources is that locally-installed apps—including scripts written for use within Telepipe—will still be available without needing to synchronize settings between systems.

If it's necessary to use software only available on a remote system, it is still possible to invoke `ssh` to run single commands in the form of `ssh user@host <command> [parameters…]`. Interactive remote commands which don't require a terminal should continue working as normal in Telepipe when executed through `ssh`.

## sudo

Normally, `sudo` requires a terminal to enter a password, making it unusable from Telepipe.

The recommended solution is to run `pkexec` from the [Polkit](https://github.com/polkit-org/polkit) package. This prompts the password using a GUI popup. Simply call `pkexec` instead of `sudo` when attempting to run a command with elevated privileges. Note that `pkexec` will not cache credentials.

If Polkit is not an option, another solution is to use `ssh-askpass`. Set the variable `SUDO_ASKPASS=/path/to/askpass` before calling `sudo`, and it should prompt for the password (you may also need to pass the `-A` flag). To make this change permanent, set the `askpass` option in `/etc/sudo.conf`,

```
Path askpass /path/to/ssh-askpass
```
