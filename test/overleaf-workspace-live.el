;;; overleaf-workspace-live.el --- Live test against a real Overleaf CE  -*- lexical-binding: t; -*-

;; Not part of the ERT suite.  Needs, in the environment:
;;   OWS_LIVE_CREDENTIALS  JSON {server,email,password} of a dedicated TEST account
;;   OWS_LIVE_PROJECT      id of that account's throwaway project
;;   OWS_LIVE_BRIDGE       path of the overleaf_bridge binary
;; Run:  emacs -Q --batch -L . -L test -L <emacs-collab.el> ... -l test/overleaf-workspace-live.el
;; The password is only written to a temporary authinfo (mode 600), never printed.

(require 'overleaf-workspace)
(require 'json)
(require 'ert)

(defvar TeX-output-dir)

(defun ows-live--wait (pred &optional timeout what)
  (let ((deadline (+ (float-time) (or timeout 30))) r)
    (while (and (not (setq r (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (or r (error "timeout waiting for %s" (or what pred)))))

(defun ows-live--check (what ok)
  (princ (format "%s %s\n" (if ok "PASS" "FAIL") what))
  (unless ok (setq ows-live--failed t)))

(defvar ows-live--failed nil)

(let* ((creds (json-parse-string
               (with-temp-buffer (insert-file-contents (getenv "OWS_LIVE_CREDENTIALS"))
                                 (buffer-string))
               :object-type 'alist))
       (pid (getenv "OWS_LIVE_PROJECT"))
       (base (make-temp-file (expand-file-name "ows-live-" (getenv "TMPDIR")) t))
       (authfile (expand-file-name "authinfo" base))
       (url (alist-get 'server creds))
       (u (url-generic-parse-url url))
       (marker (format "%% ows-live-%d" (floor (float-time))))
       (auth-sources (list authfile))
       (auth-source-cache-expiry nil)
       (overleaf-workspace-mirror-directory (expand-file-name "mirror/" base))
       (overleaf-workspace-bridge-command (list (getenv "OWS_LIVE_BRIDGE")))
       (overleaf-workspace-servers (list (list :name "yulee-test" :url url :auth 'password)))
       (emacs-collab-layout-state-file (expand-file-name "layout.eld" base))
       (emacs-collab-layout-register-lsp nil)
       (TeX-output-dir "build")
       (unrelated (generate-new-buffer "*unrelated*")))
  (with-temp-file authfile
    (insert (format "machine %s%s login %s password %s\n" (url-host u)
                    (if (url-portspec u) (format " port %d" (url-portspec u)) "")
                    (alist-get 'email creds) (alist-get 'password creds))))
  (set-file-modes authfile #o600)
  (unwind-protect
      (progn
        ;; 1. Open.
        (let* ((conn (overleaf-open-project "yulee-test" pid))
               (mirror (overleaf-workspace-session-mirror (car overleaf-workspace--sessions))))
          (ows-live--wait (lambda () (emacs-collab-layout-project mirror)) 60 "layout")
          (ows-live--check "bridge ready and layout built" (emacs-collab-conn-ready conn))
          (ows-live--check "roles editor/terminal/pdf"
                           (and (emacs-collab-layout-window 'editor)
                                (emacs-collab-layout-window 'terminal)
                                (emacs-collab-layout-window 'pdf)))
          (ows-live--check "tree window" (and (emacs-collab-layout-window 'tree) t))
          (let* ((main (overleaf-workspace-session-main (car overleaf-workspace--sessions)))
                 (ebuf (window-buffer (emacs-collab-layout-window 'editor))))
            (ows-live--check (format "main file %s mirrored" (file-name-nondirectory main))
                             (and (file-exists-p main) (equal (buffer-file-name ebuf) main)))
            (ows-live--wait (lambda () (with-current-buffer ebuf
                                         (and emacs-collab-mode (emacs-collab-doc-synced (emacs-collab--doc)))))
                            30 "synced")
            (ows-live--check "buffer synced, mode on" (buffer-local-value 'overleaf-workspace-mode ebuf))
            ;; 2. Edit round trip (1): edit, wait for the server's ack, re-attach.
            (with-current-buffer ebuf
              (goto-char (point-max)) (insert marker "\n")
              (ows-live--wait (lambda () (null (emacs-collab-doc-pending (emacs-collab--doc)))) 30 "ack")
              (save-buffer)
              (overleaf-workspace-resync)
              (ows-live--wait (lambda () (emacs-collab-doc-synced (emacs-collab--doc))) 30 "resync")
              (ows-live--check "edit survives re-attach (server has it)"
                               (save-excursion (goto-char (point-min)) (search-forward marker nil t))))
            ;; Local build and PDF pane.
            (let ((proc (with-current-buffer ebuf (overleaf-workspace-compile))))
              (when (processp proc)
                (ows-live--wait (lambda () (not (process-live-p proc))) 120 "latexmk")))
            (let ((pdf (funcall overleaf-workspace-pdf-function main)))
              (ows-live--check (format "latexmk output %s" (file-relative-name pdf mirror))
                               (file-exists-p pdf))
              (ows-live--wait (lambda () (equal (buffer-file-name (window-buffer (emacs-collab-layout-window 'pdf)))
                                                (file-truename pdf)))
                              10 "pdf pane")
              (ows-live--check "pdf pane shows it" t))
            ;; 3. Quit, then reopen: the server kept the edit.
            (overleaf-quit)
            (ows-live--check "quit: no sessions/connections"
                             (and (null overleaf-workspace--sessions) (null emacs-collab--connections)))
            (ows-live--check "quit: unrelated buffer kept" (buffer-live-p unrelated))
            (ows-live--check "quit: project buffers gone"
                             (null (get-file-buffer main)))))
        ;; Reopen.
        (let* ((conn (overleaf-open-project "yulee-test" (format "%s/project/%s" url pid)))
               (s (car overleaf-workspace--sessions))
               (mirror (overleaf-workspace-session-mirror s)))
          (ows-live--wait (lambda () (emacs-collab-layout-project mirror)) 60 "layout 2")
          (let* ((main (overleaf-workspace-session-main s))
                 (ebuf (window-buffer (emacs-collab-layout-window 'editor))))
            (ows-live--wait (lambda () (with-current-buffer ebuf
                                         (and emacs-collab-mode (emacs-collab-doc-synced (emacs-collab--doc)))))
                            30 "synced 2")
            (ows-live--check "round trip: marker present after reopen"
                             (with-current-buffer ebuf
                               (save-excursion (goto-char (point-min)) (search-forward marker nil t))))
            ;; Clean up the marker.
            (with-current-buffer ebuf
              (goto-char (point-min))
              (when (search-forward (concat marker "\n") nil t)
                (replace-match ""))
              (ows-live--wait (lambda () (null (emacs-collab-doc-pending (emacs-collab--doc)))) 30 "ack 2")
              (save-buffer))
            (ignore main conn))
          (overleaf-quit)))
    (ignore-errors (when overleaf-workspace--sessions (overleaf-quit)))
    (kill-buffer unrelated)
    (delete-directory base t))
  (princ (if ows-live--failed "LIVE: FAIL\n" "LIVE: PASS\n"))
  (kill-emacs (if ows-live--failed 1 0)))
