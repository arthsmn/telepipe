# Clipboard Redirection

Telepipe's defining feature is its ability to redirect the clipboard's contents into commands and redirect command output into the clipboard. It is even possible to do both at once, enabling the use of command-line applications to quickly transform the contents of the clipboard. As the clipboard is nearly-universally supported, clipboard redirection grants advanced text editing capabilities to **virtually any app.**

The examples here use programs from GNU coreutils—which should be available on any Linux machine by default—unless otherwise noted.

This list is incomplete. Submit a pull request or [send an email](mailto:victoria@vtrlx.ca) to add more examples.

## Overview

Clipboard redirection is done by prefixing a command with either `>` to paste the clipboard into the given command, `<` to copy the command's output to the clipboard, or `|` to do both.

This feature makes it easy to seamlessly use the clipboard to interact with command-line applications, which unlocks many advanced text processing capabilities.

## Basic Usage

### Pasting to Input

- `>cat`
	- Outputs the clipboard's current contents.
- `>tee -a example.txt`
	- Saves the clipboard's contents into a file named `example.txt`, appending to the end of the file if it already exists.
- `>lua`
	- Executes the clipboard's current contents as a Lua program.
	- Requires [Lua](https://www.lua.org/) to be installed.

### Copying from Output

- `<cat example.txt`
	- Copies the contents of `example.txt` into the clipboard.
- `<date`
	- Copies the current date and time into the clipboard.
- `<curl example.com`
	- Copies the source of the webpage at http://example.com/ to the clipboard.
	- Requires [curl](https://curl.se/) to be installed.

### Transforming the Clipboard

- `|grep -v tomato`
	- Removes any pararaph containing the word "tomato" from the clipboard.
- `|sed s/tomato/potato/`
	- Replaces any ocurrence of the word "tomato" in the clipboard with "potato".
- `|fmt -72`
	- Formats the clipboard's contents to limit lines to a length of 72 characters.
	- Useful for certain old software which requires lines to be limited in length.
- `|pandoc -f markdown -t html`
	- Transform's the clipboard's contents from Markdown to HTML.
	- Requires [Pandoc](https://pandoc.org/) to be installed.

## Formatting Code

Many programs with embedded text editors do not support advanced text editing conventions such as selection indentation/deindentation or expansion of tabs into spaces and vice-versa. Most users will prefer to instead write text in other editors and then paste the result into the target app, but clipboard redirection makes it easier to leverage advanced text editing without needing to edit in two places at once.

### Adjusting Indentation Levels

Using literal tab or space characters, `sed` provides a simple way to indent or deindent text.

To indent,

```sh
|sed "s/^/	/"
```

To unindent,

```sh
|sed "s/^	//"`.
```

Notice the quotations in both of these examples! They are required when working with whitespace characters. These examples also use tab characters, which must be pasted into Telepipe's command entry.

Because entering tab characters into Telepipe can be tricky, it's wise to save these one-liners as scripts. Good names for them would be `i+` to add a level of indentation, and `i-` to subtract a level of indentation.

### Expanding/Unexpanding Tab Indentation

GNU coreutils includes the programs `expand` and `unexpand` to expand tab characters to spaces or unexpand spaces back into tabs.

To expand leading tabs into 4 spaces each, `|expand -i -t 4 -`. Use `|unexpand -i -t 4 -` to do the inverse.

As these flags are useful to always have, it's a good idea to save these invocations to scripts. Save the following as `t2s` (**t**abs "**to**" **s**paces):

```sh
#!/usr/bin/env sh

NUM_OF_SPACES=8
if [ $# -gt 0 ]
then
	NUM_OF_SPACES=$1
fi

expand -i -t $NUM_OF_SPACES -
```

Additionally, save its inverse as `s2t` (**s**paces "**to**" **t**tabs):

```sh
#!/usr/bin/env sh

NUM_OF_SPACES=8
if [ $# -gt 0 ]
then
	NUM_OF_SPACES=$1
fi

unexpand -i -t $NUM_OF_SPACES -
```

The two scripts should be identical save for the invocation of `expand` or `unexpand` at the end.

Run these scripts from Telepipe by calling `|t2s` to expand tabs to 8 spaces (by default) or by for instance entering `|t2s 4` to expand tabs to 4 spaces. The inverse can be done by executing `|s2t` or `|s2t 4`.

### Tying It All Together

Command pipelines are designed to compose various programs together using a simple and flexible medium: text. Telepipe is no exception in this regard—this app makes it much easier to assemble and use text processing pipelines.

Consider the 4 indentation scripts given in the previous example. If you prefer writing code using spaces instead of tabs for indentation, then the `i+` and `i-` scripts won't work properly. You could conceivably modify the scripts to handle this case, but you *already have the solution*.

To indent the clipboard's contents by 4 spaces in Telepipe using only these scripts, enter this command:

```
|s2t 4 |i+ |t2s 4
```

This pipeline will unexpand 4-space indents back into tab characters, indent the entire input by one tab, then expand the tabs back into 4-space indents—all using only the scripts that were written in the previous two sections. Of course, nothing is stopping you from writing more scripts, but it's easier to remember a small number of scripts if you have the ability to compose them to gain more advanced functionality.
