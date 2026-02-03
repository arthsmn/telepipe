# Prefixes

Telepipe runs its commands using pipes and as such, many programs will behave as though they are not executed interactively even when they are. This can usually be mitigated by passing a flag into a command to explicitly mark a session as interactive, but this is often not ideal. On top of this, it is not possible to use Telepipe's [clipboard redirection](https://github.com/vtrlx/telepipe/blob/trunk/docs/Clipboard%20Redirection.md) inside an interactive command.

A common user story when using the terminal is for the user to hit the "Up" key to navigate backward in history to recall the previous command, then delete the last few parameters in order to run a slightly modified command. Often when working with certain software like Git, Docker, or any of a number of system administration tools, one will often want to invoke multiple of these commands in sequence. This generally involves a significant amount of repetition, and the manual nature of this approach leaves room for error such as too much or too little of a previous command having been removed at once.

Telepipe's solution to the problem of repetition is called **prefixes**. When a prefix is active, the current prefix will be prepended to all subsequent commands issued in the tab.

Prefixes big and small allow for more deliberate work that is less error-prone and which requires far fewer repetitive motions when compared to the same work done in a terminal.

## Overview

Activate a prefix by typing `prefix` followed by the text to be prefixed. For instance, `prefix git` will activate a Git prefix and `prefix ssh myhost` will activate a prefix for running commands on a remote host using SSH.

When active, an extra button is made visible to the left of the command entry. If multiple tabs are open, then each tab's title will begin with the first word of its current prefix in parentheses, if active.

As the prefix is prominently displayed just before the command entry, there is never any confusion as to whether a shell command or a subcommand should be entered. A prefix can thus be seen as a way to create ad-hoc command-line shells for any arbitrary command or script.

A prefix is only active for the tab in which it was activated. However, new tabs will inherit the current selected tab's prefix, if available. Within a given tab, each prefix keeps a separate history—prior commands will be hidden upon activating a prefix, and commands run within the prefix will be hidden when switching active prefixes or deactivating the current one. Lastly, [clipboard redirection](https://github.com/vtrlx/telepipe/blob/trunk/docs/Clipboard%20Redirection.md) works correctly when a prefix is active.

The current prefix can be deactivated either by pressing the prefix button or by running the `prefix` command with no parameter.

Telepipe's built-in commands such as `cd` and `prefix` itself are unaffected by the current prefix.

## Basic Usage

The simplest form of prefix is for general use of a specific shell command by simply setting the prefix to the name of the program.

```
prefix git
prefix fossil
prefix hg
```

Prefixes like these allow for a Telepipe tab to become dedicated to using the given version control software (e.g.: Git, Fossil, Mercurial) without needing to always retype the program name.

## Advanced Examples

### Secure Shell (OpenSSH)

```
prefix ssh <hostname>
```

Though it is recommended to use [filesystem mounts](https://github.com/vtrlx/telepipe/blob/trunk/docs/Tips%20and%20Tricks.md#ssh) to interact with remote filesystems over SSH in Telepipe, it's still necessary to occasionally run commands on a remote system—prefixes are especially useful to facilitate this.

When an SSH prefix is active, subsequent commands will be executed on the remote machine using SSH's built-in command syntax (which is just to write the command line after the hostname). This gives the experience of running on an interactive remote shell without the downside of running an interactive shell from within Telepipe.

It is also possible to add further commands to an SSH prefix for working with specific programs on a remote host, as one would do on their local host.

To make an SSH prefix more reliable in Telepipe, consider using multiplexed connections. These can be enabled by adding the following to an SSH configuration file:

```
Host *
	ControlMaster auto
	ControlPath ~/.ssh/mux-%r@%h:%p
	ControlPersist 300
```

These configuration options allow all SSH sessions to a given host to share the same underlying connection, including those which mount a file system. After the last connection to a given host is closed, the link is also preserved for 300 seconds (five minutes), allowing subsequent SSH sessions to the host to be initiated much more quickly.

If a `Host *` section already exists in SSH's configuration, add the three Control- lines to that section instead. The value of `ControlPath` here assumes that SSH configuration lives in `$HOME/.ssh`—if it lives in another directory, change the `ControlPath` value accordingly.

### Nix Shell

For many programs which allow the execution of shell commands, one can simply pass the subcommand and its arguments as parameters to the parent command, which will handle everything on its own. Certain programs do not allow this, requiring instead that subcommands be passed as a single parameter, usually in quotation marks. This makes the use of prefixes somewhat difficult for the use of programs like nix-shell—which requires a `--run` parameter followed by a quoted command-line—but not impossible.

Save the following bash shell script as `quote-to`:

```sh
#!/bin/bash

if [ "$#" -eq "0" ]
then
	printf "usage: quote-to <command> [params...] -- [params...]\n"
	printf "The quote-to script will wrap arguments after the double-dash in quotes as a single parameter to the end of the given command.\n"
	exit 1
fi

COMMAND=""

while true
do
	if [ "$#" -eq "0" ]
	then
		printf "can't run; no '--' parameter specified\n"
		exit 1
	elif [ "$1" == "--" ]
	then
		break
	else
		COMMAND="$COMMAND $1"
	fi
	shift 1
done

shift 1

echo $COMMAND '"'"$@"'"'
$COMMAND "$@"
```

This script will send parameters passed after a double-dash as a single quoted parameter to the program specified. To use this script to run `command` in a specific nix-shell without needing quotes:

```
quote-to nix-shell -p <packages...> --run -- command [params...]
```

This is thus usable in Telepipe by setting it as a prefix:

```
prefix quote-to nix-shell -p <packages...> --run --
```

Then, all subsequent commands executed within this Telepipe prefix will be executed through nix-shell as a single quoted parameter to the `--run` flag, without needing to remember to quote every single command when entering them.

To get the prefix shown in Telepipe's tabs to show something more specific than "(quote-to)" so as to disambiguate from other prefixes using the same script, consider creating a new script that calls `quote-to nix-shell $@` and give it a name specific to nix-shell.
