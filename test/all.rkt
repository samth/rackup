#lang racket/base

;; Require the `test` submodules explicitly: requiring just the main
;; modules would skip everything wrapped in (module+ test ...).
(require (submod "checksum.rkt" test)
         (submod "copy-filtered-tree.rkt" test)
         (submod "env.rkt" test)
         (submod "install-prefix.rkt" test)
         (submod "paths.rkt" test)
         (submod "process.rkt" test)
         (submod "rebuild.rkt" test)
         (submod "remote.rkt" test)
         (submod "rktd-io.rkt" test)
         (submod "security.rkt" test)
         (submod "shell-completion.rkt" test)
         (submod "state-shims.rkt" test)
         (submod "switch-install.rkt" test)
         (submod "text.rkt" test)
         (submod "uninstall.rkt" test)
         (submod "upgrade.rkt" test)
         (submod "version.rkt" test)
         (submod "versioning.rkt" test))

(module+ main
  (void))
