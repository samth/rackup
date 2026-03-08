#lang racket/base

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/path
         racket/port
         racket/string
         racket/system
         "docker-e2e.rkt")

(define image-tag "rackup-e2e:present-ubuntu-24.04-native")
(define artifacts-dir "/tmp/rackup-legacy-artifacts")
(define home-root "/tmp/rackup-legacy-home")
(define src-copy #f)
(define keep-src-copy? #f)
(define versions '("202" "209" "352"))
(define custom-versions? #f)

(define (artifact-ext-for-version ver)
  (if (member ver '("053" "102" "103" "103p1" "200" "201" "202" "205")) "tgz" "sh"))

(command-line
 #:program "docker-check-legacy-artifacts"
 #:multi ["--version"
          ver
          "Legacy version to check (repeatable)"
          (unless custom-versions?
            (set! versions '())
            (set! custom-versions? #t))
          (set! versions (append versions (list ver)))]
 #:once-each ["--image" tag "Docker image to use" (set! image-tag tag)]
 ["--artifacts-dir" dir "Directory containing legacy installers" (set! artifacts-dir dir)]
 ["--home-root" dir "Container-side root for RACKUP_HOME" (set! home-root dir)]
 ["--src-copy" dir "Reuse/create filtered source copy" (set! src-copy dir) (set! keep-src-copy? #t)]
 ["--keep-src-copy" "Keep the temporary filtered source copy" (set! keep-src-copy? #t)])

;; Validate
(unless (directory-exists? artifacts-dir)
  (raise-user-error "artifacts directory not found: ~a" artifacts-dir))

(define image-exists?
  (parameterize ([current-output-port (open-output-nowhere)]
                 [current-error-port (open-output-nowhere)])
    (system* "docker" "image" "inspect" image-tag)))
(unless image-exists?
  (raise-user-error "docker image not found: ~a" image-tag))

;; Prepare filtered source copy
(define own-src-copy? (not src-copy))
(unless src-copy
  (set! src-copy (path->string (make-temporary-directory "rackup-legacy-src~a"))))

(make-directory* src-copy)
(run/check (path->string (build-path root-dir "scripts" "copy-filtered-tree.sh"))
           (path->string root-dir)
           src-copy)

;; Validate artifacts exist
(for ([ver (in-list versions)])
  (define ext (artifact-ext-for-version ver))
  (define artifact (build-path artifacts-dir (format "plt-~a-bin-i386-linux.~a" ver ext)))
  (unless (file-exists? artifact)
    (raise-user-error "missing artifact for ~a: ~a" ver (path->string artifact))))

(define versions-csv (csv-join versions))

(printf "Using Docker image: ~a\n" image-tag)
(printf "Using artifacts dir: ~a\n" artifacts-dir)
(printf "Using filtered source copy: ~a\n" src-copy)
(printf "Versions: ~a\n" versions-csv)

(define ok?
  (docker-run-container
   #:image image-tag
   #:home home-root
   #:volumes (list (format "~a:/work" src-copy) (format "~a:/artifacts:ro" artifacts-dir))
   #:env-vars (list (cons "RACKUP_LEGACY_VERSIONS" versions-csv))
   #:command
   (list
    "bash"
    "-lc"
    (string-join
     '("set -euo pipefail"
       ""
       "artifact_ext_for_version() {"
       "  case \"$1\" in"
       "    053|102|103|103p1|200|201|202|205)"
       "      printf 'tgz\\n'"
       "      ;;"
       "    *)"
       "      printf 'sh\\n'"
       "      ;;"
       "  esac"
       "}"
       ""
       "loader_present() {"
       "  for p in /lib/ld-linux.so.2 \\"
       "           /lib32/ld-linux.so.2 \\"
       "           /lib/i386-linux-gnu/ld-linux.so.2 \\"
       "           /lib/i686-linux-gnu/ld-linux.so.2 \\"
       "           /usr/i386-linux-gnu/lib/ld-linux.so.2; do"
       "    if [[ -e \"$p\" ]]; then"
       "      printf 'yes\\n'"
       "      return 0"
       "    fi"
       "  done"
       "  printf 'no\\n'"
       "}"
       ""
       "mkdir -p \"$HOME\""
       "printf 'loader_present=%s\\n' \"$(loader_present)\""
       ""
       "IFS=\",\" read -r -a versions <<< \"$RACKUP_LEGACY_VERSIONS\""
       "for ver in \"${versions[@]}\"; do"
       "  [[ -n \"$ver\" ]] || continue"
       "  ext=\"$(artifact_ext_for_version \"$ver\")\""
       "  artifact=\"/artifacts/plt-$ver-bin-i386-linux.$ext\""
       "  export RACKUP_HOME=\"$HOME/$ver\""
       "  rm -rf \"$RACKUP_HOME\""
       "  mkdir -p \"$RACKUP_HOME/cache/downloads\""
       "  cp \"$artifact\" \"$RACKUP_HOME/cache/downloads/\""
       ""
       "  printf '== install %s ==\\n' \"$ver\""
       "  if racket /work/libexec/rackup-core.rkt install --arch i386 \"$ver\" >/tmp/install-\"$ver\".out 2>/tmp/install-\"$ver\".err; then"
       "    printf 'install_status=ok\\n'"
       "    cat /tmp/install-\"$ver\".out"
       "  else"
       "    printf 'install_status=fail\\n'"
       "    cat /tmp/install-\"$ver\".err"
       "  fi"
       ""
       "  printf '== run %s ==\\n' \"$ver\""
       "  if \"$RACKUP_HOME/shims/mzscheme\" -v >/tmp/run-\"$ver\".out 2>/tmp/run-\"$ver\".err; then"
       "    printf 'run_status=ok\\n'"
       "    cat /tmp/run-\"$ver\".out"
       "  else"
       "    printf 'run_status=fail\\n'"
       "    cat /tmp/run-\"$ver\".err"
       "  fi"
       "done")
     "\n"))))

;; Cleanup
(when (and own-src-copy? (not keep-src-copy?))
  (delete-directory/files src-copy #:must-exist? #f))

(unless ok?
  (error 'docker-check-legacy-artifacts "container run failed"))
