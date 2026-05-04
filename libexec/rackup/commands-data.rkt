#lang racket/base

;; Shared data for the rackup subcommand list.  Both the runtime
;; completion code (shell.rkt) and the compile-time dispatcher macro
;; (main.rkt) read from this module, so the dispatcher and the
;; completion scripts cannot drift apart.

(provide rackup-commands
         rackup-manual-dispatch-commands)

;; Each entry: (cons name description).  Order is the order in which
;; commands appear in `rackup --help` and in completion menus.
(define rackup-commands
  '(("available"    . "List remote install specs and recent release versions")
    ("install"      . "Install a Racket toolchain")
    ("link"         . "Link an in-place/local Racket build as a managed toolchain")
    ("rebuild"      . "Rebuild a linked source toolchain in place")
    ("list"         . "List installed toolchains")
    ("default"      . "Show, set, or clear the global default toolchain")
    ("current"      . "Show the active toolchain and where it came from")
    ("which"        . "Show the real executable path for a tool")
    ("switch"       . "Switch the active toolchain in this shell")
    ("shell"        . "Emit shell code to activate/deactivate a toolchain")
    ("run"          . "Run a command using a specific toolchain")
    ("prompt"       . "Print prompt info for PS1")
    ("upgrade"      . "Upgrade channel-based toolchains to latest version")
    ("remove"       . "Remove an installed or linked toolchain")
    ("reshim"       . "Rebuild executable shims")
    ("init"         . "Install/update shell integration")
    ("uninstall"    . "Remove rackup and its data")
    ("self-upgrade" . "Upgrade rackup code")
    ("runtime"      . "Manage internal runtime")
    ("doctor"       . "Print diagnostics")
    ("version"      . "Print version info")
    ("help"         . "Show help")))

;; Commands handled by hand-written match clauses in main.rkt's
;; dispatcher rather than by the auto-generated `(list n rest ...)`
;; clause.  `help` recurses into other commands so it doesn't fit the
;; uniform pattern.
(define rackup-manual-dispatch-commands '("help"))
