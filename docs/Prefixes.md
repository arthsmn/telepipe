# Prefixes

Telepipe runs its commands using pipes and as such, many programs will behave as though they are not executed interactively even when they are. This can usually be mitigated by passing a flag into a command to explicitly mark a session as interactive, but this is often not ideal. On top of this, it is not possible to use Telepipe's [clipboard redirection](https://github.com/vtrlx/telepipe/blob/trunk/docs/Clipboard%20Redirection.md) inside an interactive command.

A common user story when using the terminal is for the user to hit the "Up" key to navigate backward in history to recall the previous command, then delete the last few parameters in order to run a slightly modified command. Often when working with certain software like Git, Docker, or any of a number of system administration tools, one will often want to invoke multiple of these commands in sequence. This generally involves a significant amount of repetition, and the manual nature of this approach leaves room for error such as too much or too little of a previous command having been removed at once.

Telepipe's solution to the problem of repetition is called **prefixes**. When a prefix is active, the current prefix will be prepended to all subsequent commands issued in the tab.

Prefixes big and small allow for more deliberate work that is less error-prone and which requires far fewer repetitive motions when compared to the same work done in a terminal.

## Usage

Activate a prefix by typing `prefix` followed by the text to be prefixed. For instance, `prefix git` will activate a Git prefix and `prefix ssh myhost` will activate a prefix for running commands on a remote host using SSH.

When active, an extra button is made visible to the left of the command entry. If multiple tabs are open, then each tab's title will begin with the first word of its current prefix in parentheses, if active.

A prefix is only active for the tab in which it was activated. However, new tabs will inherit the current selected tab's prefix, if available. Within a given tab, each prefix keeps a separate history—prior commands will be hidden upon activating a prefix, and commands run within the prefix will be hidden when switching active prefixes or deactivating the current one. Lastly, [clipboard redirection](https://github.com/vtrlx/telepipe/blob/trunk/docs/Clipboard%20Redirection.md) works correctly when a prefix is active.

The current prefix can be deactivated either by pressing the prefix button or by running the `prefix` command with no parameter.

Telepipe's built-in commands such as `cd` and `prefix` itself are unaffected by the current prefix.

## Examples

### Version Control (Git, etc.)

> `prefix git`

This prefix allows one to work in Git by directly issuing subcommands such as `fetch`, `pull`, `status`, `add -p`, `commit`, or `push`.

A similar outcome can be achieved with other version control systems using prefixes relevant to them as well, such as e.g.: `prefix fossil` or `prefix hg`.

### Secure Shell (OpenSSH)

> `prefix ssh <hostname>`

Though it is recommended to use [filesystem mounts](https://github.com/vtrlx/telepipe/blob/trunk/docs/Tips%20and%20Tricks.md#ssh) to interact with remote filesystems over SSH in Telepipe, it's still necessary to occasionally run commands on a remote system—prefixes are especially useful to facilitate this.

When an SSH prefix is active, subsequent commands will be executed on the remote machine using SSH's built-in command syntax (which is just to write the command line after the hostname). This gives the experience of running on an interactive remote shell without the downside of running an interactive shell from within Telepipe.

It is also possible to add further commands to an SSH prefix for working with specific programs on a remote host.

To make an SSH prefix more reliable in Telepipe, consider using multiplexed connections. These can be enabled by adding the following to an SSH configuration file:

```
Host *
	ControlMaster auto
	ControlPath ~/.ssh/mux-%r@%h:%p
	ControlPersist 300
```

These configuration options allow all SSH sessions to a given host to share the same underlying connection, including those which mount a file system. After the last connection to a given host is closed, the link is also preserved for 300 seconds (five minutes), allowing subsequent SSH sessions to the host to be initiated much more quickly.

If a `Host *` section already exists in SSH's configuration, add the three Control- lines to that section instead. The value of `ControlPath` here assumes that SSH configuration lives in `$HOME/.ssh`—if it lives in another directory, change the `ControlPath` value accordingly.
