# overleaf-workspace

The Overleaf frontend of [emacs-collab](../emacs-collab.el). Pick a server
and a project; Emacs gets a window layout with the project tree, the main
`.tex` file, the locally built PDF and a terminal, and every `.tex`/`.bib`
buffer syncs live with the Overleaf editor. Compiling stays local (AUCTeX,
latexmk). GPL-3.0-or-later.

The pieces:

- `overleaf_bridge`: a local program that speaks Overleaf's real-time
  protocol and mirrors the project into a directory. Emacs starts it as a
  subprocess.
- `emacs-collab.el`: buffer sync, cursors, and `emacs-collab-layout.el`
  (the layout and quit this package uses).
- `overleaf-workspace.el`: the list of servers, credentials from
  auth-source, project choice, main file and PDF location.

## Setup

Build or install the bridge so `overleaf_bridge` is on `PATH` (or set
`overleaf-workspace-bridge-command` to a path or an argv list):

    cd overleaf_bridge && cargo install --path .

Load the packages (Doom: `package!` recipes pointing at the local repos):

```elisp
(add-to-list 'load-path "~/git_shit/emacs-collab.el")
(add-to-list 'load-path "~/git_shit/overleaf-workspace")
(require 'overleaf-workspace)
```

Servers (the defaults):

```elisp
(setq overleaf-workspace-servers
      '((:name "My Overleaf CE" :url "https://overleaf.example.org" :auth password)
        (:name "overleaf.com" :url "https://www.overleaf.com" :auth cookie
         :cookie-name "overleaf_session2")))
```

## Credentials

Only auth-source is read; nothing is stored in this package or on the
bridge's disk. `:host` is the URL's host, `:port` its port if it has one.

Password servers (Overleaf CE): the login is the account's email.

    machine overleaf.example.org login you@example.org password SECRET

Cookie servers (overleaf.com): log in in a browser, copy the value of the
`overleaf_session2` cookie (developer tools, Application, Cookies) and store
it with the user name `cookie`:

    machine www.overleaf.com login cookie password s%3A....

Put them in `~/.authinfo.gpg`. If an entry is missing you are asked for the
value and offered to save it. If the bridge rejects the credentials
(`need_auth`), you are asked again, up to
`overleaf-workspace-max-auth-attempts` times; a wrong saved entry is not
rewritten, edit it by hand.

## Use

`M-x overleaf-open-project`: choose the server, then give the project as a
name, a 24-digit id or a pasted project URL (`.../project/<id>`). The
bridge has no project list, so a name must be unique in your account; ids
and URLs are exact. Projects you entered are offered again (add
`overleaf-workspace-project-history` to `savehist-additional-variables` to
keep them across sessions).

Where the local copy lives is your choice. The first time a project is
opened Emacs asks for a directory (`emacs-collab-read-mirror-dir`), created
if missing and remembered per project, so later opens go there without a
prompt; `C-u` before the command asks again, starting from the remembered
directory, and `M-x emacs-collab-forget-mirror` drops a remembered choice.
The prompt starts at `overleaf-workspace-mirror-directory`/<server>/<project>/ if you set that option
(a suggestion only; it has no default),
else `emacs-collab-mirror-root`/<service>/<project>, else the current directory. A
`.emacs-collab` marker in the directory names the project it mirrors; a
directory marked as another project is refused, a non-empty unmarked one
only draws a warning.

The layout:

| pane | content |
|---|---|
| tree | treemacs on the mirror directory |
| editor | the bridge's main file if it has `\documentclass`, else the first file that has one |
| pdf | the local build: `<main>.pdf` in `TeX-output-dir` (for example `build`) |
| terminal | a shell in the mirror directory (vterm, else `shell`) |

Keys, in buffers of the project (`overleaf-workspace-mode`):

| key | command |
|---|---|
| `M-t q` | `overleaf-quit`: save, stop everything, close the layout |
| `M-t r` | `overleaf-workspace-resync`: fetch this buffer's text from the bridge again |
| `M-t s` | `overleaf-workspace-status` |
| `M-t c` | `overleaf-workspace-compile`: AUCTeX's LatexMk if it has one, else `latexmk` |

When AUCTeX finishes a build, the PDF pane shows the new PDF. Files in
`build/` and PDFs, `.aux` and similar are never attached for syncing
(`overleaf-workspace-unsynced-regexp`).

`overleaf-quit` is `emacs-collab-layout-quit`: it offers to save the
project's files, shuts down the project's language server, disconnects the
bridge, kills the project's buffers and terminal (asking only if a command
is running) and returns to the dashboard.

Window sizes are remembered per project in `emacs-collab-layout-state-file`.

## Tests

    emacs -Q --batch -L . -L test -L ../emacs-collab.el <elpa -L dirs> \
      -l test/overleaf-workspace-test.el -f ert-run-tests-batch-and-exit

They run against the reference loopback bridge (through `test/authbridge.py`,
which asks for credentials like the real bridge). `test/overleaf-workspace-live.el`
runs the same flow against a real server with a dedicated test account; see
its header for the environment variables.
