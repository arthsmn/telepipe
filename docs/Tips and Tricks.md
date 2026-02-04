# Telepipe Tips and Tricks

Most Linux command-line software and workflows assume that a terminal console is being used. Naturally, this poses some problems for using a non-terminal command-line shell. This document contains advice for using specific programs from Telepipe.

## General Advice

Because there have been decades of work put into making command-line programs work with specific kinds of console terminals while comparatively little time has been put into developing tools to run command-lines outside of the terminal, it can be difficult for longtime terminal users to get accustomed to Telepipe.

**This list is not comprehensive!** If you use Telepipe and find interesting workarounds for your problems, consider submitting a change to this document.

### Not a Terminal

The single most important piece of advice is therefore to remember that **Telepipe is not a terminal**. It does not implement PTYs. It does not handle ioctls. It does not colorize or decorate text. It does not use monospace fonts. Telepipe is closer to being a command-line shell that is presented through a graphical interface instead of a terminal. This also means that keyboard shortcuts that seasoned terminal users would expect are absent—Ctrl+C will copy selected text instead of aborting the running program, and Ctrl+D will open the file manager in the current working directory instead of sending an end-of-transmission signal. Other shortcuts are provided for these functions instead.

Under the hood, Telepipe executes each command using a new non-interactive instance of the user's configured shell. This means that environment variables and the like must be customized as they would for a conventional terminal-based shell: by editing profile files. Shell builtin commands will fail silently without doing anything. Running `which <command>` will tell you if a command is an actual program or a builtin for your shell.

Because Telepipe uses non-interactive shells to run commands, shell aliases are likely to be unavailable. A simple alternative is to write simple shell scripts for custom commands which are executed frequently. This is especially useful if making heavy use of [clipboard redirection](https://github.com/vtrlx/telepipe/blob/trunk/docs/Clipboard%20Redirection.md) to edit text.

Do not expect Telepipe to replace the terminal—expect to need to dip back into a terminal emulator for work which specifically requires it.

### A Mouse is Recommended

Telepipe is built with the assumption that the user will have a mouse available, and many tasks in Telepipe are more efficient with the mouse than using only a keyboard.

Telepipe allows certain usage patterns not possible in a conventional terminal, such as:
- Using a mouse to point the cursor to and edit specific parts of a command-line before it is sent
- Dragging-and-dropping command output text back into the command entry
- Dragging-and-dropping files from a file manager to insert file paths to a command-line
- Quickly highlighting and deleting irrelevant command output

### Filename Completions

Telepipe does not support automatic file completion using the tab key when entering commands. This decision was made intentionally under the belief that tab completion habits promote compulsive use of the tab key when entering any file name, eventually leading to repetitive strain injury.

Telepipe instead offers the ability to use the system file picker to insert a file name into the command entry at the current cursor's position. The file picker can be opened by pressing Ctrl+O, and can be operated using only a keyboard. Unlike tab completion, the file picker can also search other locations and will even match files by content instead of only by name.

### Programs Broken in Telepipe

By default, many command-line programs will work flawlessly in Telepipe. This is because most well-behaved command-line applications will detect that they are not running inside a terminal, and will adjust their outputs accordingly.

Some commands will work in Telepipe, but in ways which are unintuitive. In these cases, workarounds are likely present. For instance, shells will default to running in non-interactive mode, but can be made interactive by passing a flag—usually `-i`. Shells forced to be interactive may emit error messages when started, but should otherwise work as expected.

Certain commands which depend explicitly on terminal support (like `vim`) fail to exit when executed in a non-terminal environment. These programs need to be stopped manually from Telepipe.

## Specific Programs

The following sections consist of advice for dealing with crucial programs which behave oddly or suboptimally in Telepipe.

### clear

The program `clear` does not work in Telepipe, and Telepipe intentionally provides no alternative.

The suggested method of completely clearing the command output view is to focus it, select all text (either by secondary-clicking and choosing "Select All", typing Ctrl+A, or using the select all button on a touchscreen cursor), then delete the selection.

Telepipe omits a `clear` builtin in an effort to break users' preexisting habits of compulsively clearing terminal output. If the goal is to remove irrelevant command output from a session, Telepipe allows one to do exactly that without deleting everything else. One must simply select the region to delete as one normally would in a text editor, then delete it. This allows important text such as file names emitted by previous commands to be preserved without needing to constantly redo those commands to generate the same outputs.

### ls

GNU `ls` in works flawlessly in Telepipe, but it leaves something to be desired. As Telepipe lacks completions, filling in filenames can be somewhat cumbersome. The intended solution to this is to use programs like `ls` to list the filenames before dragging-and-dropping ones you want to work with back into the command entry. This only works for the current directory, as `ls` does not include relative paths when listing other directories. This can be easily remedied by using the `-d` flag, but it will only list the given path instead of the directory's children as would be expected from other invocations of `ls`. One would normally need to call `ls -d <directory>/*` to list files from other directories with full relative paths, which can be frustrating to remember.

The following shell script resolves this by using a wildcard to `ls -d` if the given file is a directory, otherwise it calls `ls` as normal. It will also cause `ls` to output all file names by wrapping them in quotation marks. A good name to give this script is `dir`.

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

An alternative solution is to use `ls` from the [Plan 9 Port](https://github.com/9fans/plan9port), which is well-behaved in Telepipe.

### ssh

Secure Shell (SSH) is the gold standard for accessing other systems through a terminal. Unfortunately, its most common use case (running an interactive remote command-line shell) behaves oddly when not run in a terminal.

The recommended way to work with resources on a remote machine is to mount that machine's filesystem locally. To mount filesystems in a way that works with Telepipe, it's necessary to use a method that is compatible with GVFS. Users of GNOME can do this easily using the Files app (a.k.a. Nautilus) by accessing the "Network" resource in that app's sidebar. Once a network resource is available, navigate to it in Telepipe using the folder button to the left of the command entry. If not using GNOME and Nautilus is not available, one can alternatively use GLib's `gio mount` command instead (e.g: `gio mount sftp://<user>@<server>` or `gio mount sftp://<server>`).

An advantage to this approach of working with remote resources is that locally-installed apps—including scripts written for use within Telepipe—will still be usable on remote files without needing to install and configure them on the remote machine.

If it's necessary to use software only available on a remote system, it is still possible to invoke SSH to run single commands in the form of `ssh user@host <command> [parameters…]`. Interactive remote commands which don't require a terminal should continue working as normal in Telepipe when executed directly from SSH.

### sudo

Normally, `sudo` requires a terminal to enter a password, making it unusable from Telepipe.

The recommended solution is to run `pkexec` from the [Polkit](https://github.com/polkit-org/polkit) package. This prompts the password using a GUI popup. Simply call `pkexec` instead of `sudo` when attempting to run a command with elevated privileges. `pkexec` differs from `sudo` in a few way; First, it will not stay in the current directory unless the `--keep-cwd` flag is passed to `pkexec` and second is that `pkexec` does not cache credentials, meaning that authentication is required on each invocation. Consider using an alternate method of authentication such as a fingerprint reader or a PKI token.

If Polkit is not an option, another solution is to use `ssh-askpass`. Set the variable `SUDO_ASKPASS=/path/to/askpass` before calling `sudo`, and it should prompt for the password (you may also need to pass the `-A` flag). To make this change permanent, set the `askpass` option in `/etc/sudo.conf`,

```
Path askpass /path/to/ssh-askpass
```
