;;; overleaf-workspace.el --- Overleaf workspace on emacs-collab  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Joy H.J. Lee
;; Version: 0.1
;; Package-Requires: ((emacs "30.1") (emacs-collab "0.1"))
;; Keywords: tex, collaboration
;; URL: https://example.invalid/overleaf-workspace

;; This file is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at your
;; option) any later version.  It is distributed WITHOUT ANY WARRANTY.

;;; Commentary:

;; The Overleaf frontend of emacs-collab.  It is thin: the bridge
;; (`overleaf_bridge') speaks Overleaf's protocol and mirrors the project
;; into a local directory; emacs-collab.el syncs the buffers; the window
;; layout and the quit come from emacs-collab-layout.el.  This file adds
;; what is Overleaf's own: a list of servers, credentials from
;; auth-source, choosing a project, the main .tex file and the local
;; latexmk PDF.
;;
;;   M-x overleaf-open-project     pick a server and a project
;;   M-x overleaf-quit             close it all (also `M-t q' in its buffers)
;;
;; See README.md for the auth-source lines and the bridge.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'auth-source)
(require 'emacs-collab)
(require 'emacs-collab-layout)
(require 'emacs-collab-mirror)

(defgroup overleaf-workspace nil
  "Overleaf workspace on emacs-collab."
  :group 'emacs-collab :prefix "overleaf-")

(defcustom overleaf-workspace-servers
  '((:name "My Overleaf CE" :url "https://overleaf.example.org" :auth password)
    (:name "overleaf.com" :url "https://www.overleaf.com" :auth cookie
           :cookie-name "overleaf_session2"))
  "Overleaf servers, as plists.
:name is shown in the picker, :url is the server's base URL, :auth is
`password' (an Overleaf CE account: auth-source :user is the email) or
`cookie' (a pasted session cookie: auth-source :user is \"cookie\").
Optional :user fixes the email for `password' servers, and :cookie-name
names the session cookie."
  :type '(repeat plist))

(defcustom overleaf-workspace-bridge-command '("overleaf_bridge")
  "The bridge: an argv list, or a string naming the executable."
  :type '(choice (repeat string) string))

(defcustom overleaf-workspace-mirror-directory nil
  "Suggested location of mirrors, as SERVER/PROJECT below this directory.
Only the suggestion shown when asking where to keep a project's local
copy (see `emacs-collab-read-mirror-dir'); nil suggests nothing, and
`emacs-collab-mirror-root' applies."
  :type 'directory)

(defcustom overleaf-workspace-layout-args '(:tree t :terminal t)
  "Extra `emacs-collab-layout-build' arguments (the PDF pane is always added)."
  :type 'plist)

(defcustom overleaf-workspace-pdf-function #'overleaf-workspace-default-pdf-file
  "Function from the main .tex file to the PDF the local build produces."
  :type 'function)

(defcustom overleaf-workspace-latexmk-command
  '("latexmk" "-pdf" "-interaction=nonstopmode" "-synctex=1")
  "Command used by `overleaf-workspace-compile' when AUCTeX has no LatexMk."
  :type '(repeat string))

(defcustom overleaf-workspace-max-auth-attempts 3
  "How many times `need_auth' is answered before giving up."
  :type 'integer)

(defcustom overleaf-workspace-unsynced-regexp
  (concat "\\(?:\\`\\|/\\)\\(?:build\\|out\\|_minted[^/]*\\)/"
          "\\|\\.\\(?:pdf\\|aux\\|log\\|out\\|toc\\|lof\\|lot\\|fls\\|fdb_latexmk"
          "\\|synctex\\(?:\\.gz\\)?\\|bbl\\|blg\\|bcf\\|run\\.xml\\|nav\\|snm\\|vrb\\)\\'")
  "Project-relative paths that are never attached for syncing.
Local build output and binary files: the PDF the local latexmk writes
into the mirror must not be sent to the bridge as a document."
  :type 'regexp)

(defvar overleaf-workspace-project-history nil
  "History of projects entered, for completion.")

;;; Sessions

(cl-defstruct (overleaf-workspace-session (:constructor overleaf-workspace--make-session)
                                          (:copier nil))
  server project mirror conn main (attempts 0) saved)

(defvar overleaf-workspace--sessions nil
  "Open sessions, newest first.")

(defun overleaf-workspace--session-for-conn (conn)
  (cl-find conn overleaf-workspace--sessions :key #'overleaf-workspace-session-conn))

(defun overleaf-workspace--session-for-file (&optional file)
  (let ((file (or file buffer-file-name default-directory)))
    (and file
         (cl-find-if (lambda (s)
                       (file-in-directory-p (file-truename file)
                                            (overleaf-workspace-session-mirror s)))
                     overleaf-workspace--sessions))))

(defun overleaf-workspace--current-session ()
  (or (overleaf-workspace--session-for-file)
      (car overleaf-workspace--sessions)
      (user-error "No Overleaf project is open")))

;;; Servers and credentials

(defun overleaf-workspace--server (name)
  "The server plist called NAME (a string, or already a plist)."
  (if (consp name) name
    (or (cl-find name overleaf-workspace-servers
                 :key (lambda (s) (plist-get s :name)) :test #'equal)
        (user-error "Unknown Overleaf server: %s" name))))

(defun overleaf-workspace--read-server ()
  (cond ((null overleaf-workspace-servers)
         (user-error "Set `overleaf-workspace-servers'"))
        ((null (cdr overleaf-workspace-servers)) (car overleaf-workspace-servers))
        (t (overleaf-workspace--server
            (completing-read "Overleaf server: "
                             (mapcar (lambda (s) (plist-get s :name))
                                     overleaf-workspace-servers)
                             nil t)))))

(defun overleaf-workspace--host+port (server)
  "(HOST . PORT) of SERVER's URL, PORT a string or nil when implicit."
  (let* ((u (url-generic-parse-url (plist-get server :url)))
         (port (url-portspec u)))
    (cons (url-host u) (and port (number-to-string port)))))

(defun overleaf-workspace--secret-value (found)
  (let ((s (plist-get found :secret)))
    (if (functionp s) (funcall s) s)))

(defun overleaf-workspace--lookup (server user)
  "Search auth-source for SERVER and USER (nil: any); return the entry plist."
  (let* ((hp (overleaf-workspace--host+port server))
         (spec (append (list :host (car hp) :max 1
                             :require (if user '(:secret) '(:user :secret)))
                       (and user (list :user user))
                       (and (cdr hp) (list :port (cdr hp))))))
    (car (apply #'auth-source-search spec))))

(defun overleaf-workspace--save (server user secret)
  "Store SECRET for USER on SERVER with auth-source (asks the backend)."
  (let* ((hp (overleaf-workspace--host+port server))
         (found (car (apply #'auth-source-search
                            :host (car hp) :user user :secret secret :max 1
                            :create t :require '(:user :secret)
                            (and (cdr hp) (list :port (cdr hp)))))))
    (when-let* ((fn (plist-get found :save-function)))
      (funcall fn))
    found))

(defun overleaf-workspace--ask-save-p (server what)
  (y-or-n-p (format "Save %s for %s in auth-source? " what (plist-get server :name))))

(defun overleaf-workspace-credentials (server &optional ask)
  "Credentials alist for SERVER, from auth-source.
Prompts, and offers to save, when the entry is missing; with ASK, prompts
even if there is one (an earlier answer was rejected).  The secret is
never logged or stored anywhere but auth-source."
  (pcase (plist-get server :auth)
    ('cookie
     (let* ((found (and (not ask) (overleaf-workspace--lookup server "cookie")))
            (cookie (or (and found (overleaf-workspace--secret-value found))
                        (let ((c (read-passwd
                                  (format "Overleaf session cookie for %s: "
                                          (plist-get server :name)))))
                          (when (and (not found) (not (string-empty-p c))
                                     (overleaf-workspace--ask-save-p server "the cookie"))
                            (overleaf-workspace--save server "cookie" c))
                          c))))
       (list (cons 'method "cookie")
             (cons 'cookie_name (or (plist-get server :cookie-name) "overleaf_session2"))
             (cons 'cookie cookie))))
    (_
     (let* ((found (and (not ask) (overleaf-workspace--lookup server (plist-get server :user))))
            (existing (or found (overleaf-workspace--lookup server (plist-get server :user))))
            (email (or (and found (plist-get found :user))
                       (plist-get server :user)
                       (and existing (plist-get existing :user))
                       (read-string (format "Overleaf email for %s: " (plist-get server :name)))))
            (password (or (and found (overleaf-workspace--secret-value found))
                          (let ((p (read-passwd (format "Overleaf password for %s <%s>: "
                                                        (plist-get server :name) email))))
                            (when (and (not existing) (not (string-empty-p p))
                                       (overleaf-workspace--ask-save-p server "the password"))
                              (overleaf-workspace--save server email p))
                            p))))
       (list (cons 'method "password") (cons 'email email) (cons 'password password))))))

(defvar overleaf-workspace--previous-need-auth nil
  "The `emacs-collab-need-auth-function' we replaced.")

(defun overleaf-workspace--need-auth (conn fields reason)
  "`emacs-collab-need-auth-function' for our connections."
  (if-let* ((s (overleaf-workspace--session-for-conn conn)))
      (if (>= (cl-incf (overleaf-workspace-session-attempts s))
              overleaf-workspace-max-auth-attempts)
          (progn (message "overleaf: giving up after %d rejected logins"
                          overleaf-workspace-max-auth-attempts)
                 nil)
        (message "overleaf: %s; asking again" (or reason "credentials rejected"))
        (let ((hp (overleaf-workspace--host+port (overleaf-workspace-session-server s))))
          (ignore-errors (auth-source-forget+ :host (car hp))))
        (overleaf-workspace-credentials (overleaf-workspace-session-server s) t))
    (when overleaf-workspace--previous-need-auth
      (funcall overleaf-workspace--previous-need-auth conn fields reason))))

;;; Projects

(defun overleaf-workspace-parse-project (string)
  "Parse STRING (a project URL, id or name) into (:id ID) or (:name NAME)."
  (let ((s (string-trim string)))
    (cond ((string-empty-p s) (user-error "No project given"))
          ((string-match "/project/\\([0-9a-f]\\{24\\}\\)" s) (list :id (match-string 1 s)))
          ((string-match-p "\\`[0-9a-f]\\{24\\}\\'" s) (list :id s))
          (t (list :name s)))))

(defun overleaf-workspace--slug (s)
  (let ((r (replace-regexp-in-string "[^[:alnum:]._-]+" "-" s)))
    (string-trim r "-+" "-+")))

(defun overleaf-workspace--mirror-dir (server project)
  "Suggested mirror of PROJECT on SERVER from the defcustom, or nil."
  (when overleaf-workspace-mirror-directory
    (file-name-as-directory
     (expand-file-name (concat (overleaf-workspace--slug (plist-get server :name)) "/"
                               (overleaf-workspace--slug
                                (or (plist-get project :name) (plist-get project :id))))
                       overleaf-workspace-mirror-directory))))

(defun overleaf-workspace--select-mirror (server project force)
  "Ask where PROJECT on SERVER is mirrored (remembered unless FORCE)."
  (emacs-collab-read-mirror-dir
   "overleaf"
   (format "%s %s" (plist-get server :url) (or (plist-get project :id) (plist-get project :name)))
   (overleaf-workspace--mirror-dir server project) force))

(defun overleaf-workspace--bridge-argv ()
  (let* ((c overleaf-workspace-bridge-command)
         (argv (if (stringp c) (list c) c))
         (exe (car argv)))
    (unless (or (executable-find exe)
                (and (file-name-absolute-p exe) (file-executable-p exe)))
      (user-error "Overleaf bridge not found: %s (see README.md)" exe))
    (cons (or (executable-find exe) exe) (cdr argv))))

;;; Main file and PDF

(defun overleaf-workspace--documentclass-p (file)
  (with-temp-buffer
    (ignore-errors (insert-file-contents file nil 0 8000))
    (goto-char (point-min))
    (re-search-forward "^[^%\n]*\\\\documentclass" nil t)))

(defun overleaf-workspace-main-file (conn)
  "Absolute path of the main .tex file of CONN's project.
The bridge's `main' if it has a \\documentclass, else the first file that has
one, else the bridge's `main', else the first .tex file."
  (let* ((root (emacs-collab-conn-root conn))
         (project (emacs-collab-conn-project conn))
         (main (alist-get 'main project))
         (files (append (alist-get 'files project) nil))
         (tex (cl-remove-if-not (lambda (f) (string-suffix-p ".tex" f)) files))
         (abs (lambda (f) (expand-file-name f root))))
    (cond ((and main (file-exists-p (funcall abs main))
                (overleaf-workspace--documentclass-p (funcall abs main)))
           (funcall abs main))
          ((cl-find-if (lambda (f) (and (file-exists-p (funcall abs f))
                                        (overleaf-workspace--documentclass-p (funcall abs f))))
                       tex)
           (funcall abs (cl-find-if (lambda (f) (and (file-exists-p (funcall abs f))
                                                     (overleaf-workspace--documentclass-p
                                                      (funcall abs f))))
                                    tex)))
          (main (funcall abs main))
          (tex (funcall abs (car tex))))))

(defvar TeX-output-dir)
(defvar TeX-after-compilation-finished-functions)

(defun overleaf-workspace-default-pdf-file (main)
  "The PDF latexmk builds from MAIN, honouring AUCTeX's `TeX-output-dir'."
  (let* ((buf (get-file-buffer main))
         (out (cond ((and buf (local-variable-p 'TeX-output-dir buf))
                     (buffer-local-value 'TeX-output-dir buf))
                    ((boundp 'TeX-output-dir) (default-value 'TeX-output-dir))))
         (dir (file-name-directory main)))
    (expand-file-name (concat (file-name-base main) ".pdf")
                      (if (stringp out) (expand-file-name out dir) dir))))

;;; Opening

;;;###autoload
(defun overleaf-open-project (&optional server project force-select)
  "Open an Overleaf PROJECT on SERVER and build the workspace.
Interactively, pick a server, then enter the project's name, id or
pasted URL.  The local copy goes where `emacs-collab-read-mirror-dir'
says: the directory chosen the first time, remembered per project; with a
prefix argument (FORCE-SELECT) choose again.  The layout is built once the
bridge reports `ready'.  Return the emacs-collab connection."
  (interactive (list nil nil current-prefix-arg))
  (let* ((server (if server (overleaf-workspace--server server)
                   (overleaf-workspace--read-server)))
         (project (cond ((consp project) project)
                        (project (overleaf-workspace-parse-project project))
                        (t (overleaf-workspace-parse-project
                            (completing-read
                             (format "Project on %s (name, id or URL): " (plist-get server :name))
                             (delete-dups (copy-sequence overleaf-workspace-project-history))
                             nil nil nil 'overleaf-workspace-project-history)))))
         (mirror (overleaf-workspace--select-mirror server project force-select))
         (argv (overleaf-workspace--bridge-argv))
         (creds (overleaf-workspace-credentials server))
         (params `((server . ,(plist-get server :url))
                   ,@(if (plist-get project :id)
                         `((project_id . ,(plist-get project :id)))
                       `((project_name . ,(plist-get project :name))))
                   (mirror_dir . ,(directory-file-name mirror)))))
    (when (cl-find mirror overleaf-workspace--sessions
                   :key #'overleaf-workspace-session-mirror :test #'equal)
      (user-error "Already open: %s" mirror))
    (overleaf-workspace--install)
    (let* ((s (overleaf-workspace--make-session :server server :project project
                                                :mirror (file-truename mirror)))
           (conn (emacs-collab-connect argv params creds)))
      (setf (overleaf-workspace-session-conn s) conn)
      (push s overleaf-workspace--sessions)
      conn)))

(defun overleaf-workspace--attach-p (_conn path)
  (not (string-match-p overleaf-workspace-unsynced-regexp path)))

(defun overleaf-workspace--install ()
  (setq emacs-collab-attach-predicate #'overleaf-workspace--attach-p)
  (add-hook 'emacs-collab-ready-functions #'overleaf-workspace--on-ready)
  (add-hook 'find-file-hook #'overleaf-workspace--find-file-hook)
  (add-hook 'TeX-after-compilation-finished-functions #'overleaf-workspace--after-compile)
  (unless (eq emacs-collab-need-auth-function #'overleaf-workspace--need-auth)
    (setq overleaf-workspace--previous-need-auth emacs-collab-need-auth-function
          emacs-collab-need-auth-function #'overleaf-workspace--need-auth)))

(defun overleaf-workspace--uninstall ()
  (when (eq emacs-collab-attach-predicate #'overleaf-workspace--attach-p)
    (setq emacs-collab-attach-predicate nil))
  (remove-hook 'emacs-collab-ready-functions #'overleaf-workspace--on-ready)
  (remove-hook 'find-file-hook #'overleaf-workspace--find-file-hook)
  (remove-hook 'TeX-after-compilation-finished-functions #'overleaf-workspace--after-compile)
  (when (eq emacs-collab-need-auth-function #'overleaf-workspace--need-auth)
    (setq emacs-collab-need-auth-function overleaf-workspace--previous-need-auth
          overleaf-workspace--previous-need-auth nil)))

(defun overleaf-workspace--on-ready (conn)
  (when-let* ((s (overleaf-workspace--session-for-conn conn)))
    (let* ((main (overleaf-workspace-main-file conn))
           (root (emacs-collab-conn-root conn)))
      (setf (overleaf-workspace-session-main s) main)
      (add-to-list 'overleaf-workspace-project-history
                   (or (plist-get (overleaf-workspace-session-project s) :name)
                       (plist-get (overleaf-workspace-session-project s) :id)))
      (apply #'emacs-collab-layout-build
             :root root :main-file main :connection conn
             :pdf (and main (lambda () (funcall overleaf-workspace-pdf-function main)))
             :on-quit (lambda (_root) (overleaf-workspace--forget s))
             (cl-loop for (k v) on overleaf-workspace-layout-args by #'cddr
                      unless (memq k '(:root :main-file :connection :pdf :on-quit))
                      append (list k v)))
      (dolist (b (buffer-list))
        (with-current-buffer b (overleaf-workspace--maybe-enable))))))

(defun overleaf-workspace--forget (s)
  (setq overleaf-workspace--sessions (delq s overleaf-workspace--sessions))
  (dolist (b (buffer-list))
    (when (buffer-local-value 'overleaf-workspace-mode b)
      (with-current-buffer b (overleaf-workspace-mode -1))))
  (unless overleaf-workspace--sessions (overleaf-workspace--uninstall)))

;;; Mode and commands

(defvar overleaf-workspace-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-t q") #'overleaf-quit)
    (define-key map (kbd "M-t r") #'overleaf-workspace-resync)
    (define-key map (kbd "M-t s") #'overleaf-workspace-status)
    (define-key map (kbd "M-t c") #'overleaf-workspace-compile)
    map)
  "Keymap of `overleaf-workspace-mode'.")

(define-minor-mode overleaf-workspace-mode
  "Keys for a buffer of an open Overleaf project.
\\{overleaf-workspace-mode-map}"
  :lighter " OL" :keymap overleaf-workspace-mode-map)

(defun overleaf-workspace--maybe-enable ()
  (when (and buffer-file-name (not overleaf-workspace-mode)
             (overleaf-workspace--session-for-file buffer-file-name))
    (overleaf-workspace-mode 1)))

(defun overleaf-workspace--find-file-hook ()
  (overleaf-workspace--maybe-enable))

;;;###autoload
(defun overleaf-quit ()
  "Close the Overleaf workspace of the current buffer and everything it started."
  (interactive)
  (let ((s (overleaf-workspace--current-session)))
    (emacs-collab-layout-quit (overleaf-workspace-session-mirror s))
    ;; A session whose layout never came up (bridge failed) has no on-quit.
    (when (memq s overleaf-workspace--sessions)
      (when-let* ((c (overleaf-workspace-session-conn s)))
        (when (memq c emacs-collab--connections) (emacs-collab-disconnect c)))
      (overleaf-workspace--forget s))))

(defun overleaf-workspace-resync ()
  "Re-attach the current buffer: fetch its text from the bridge again.
Local edits not yet acknowledged are dropped in favour of the server's."
  (interactive)
  (let ((s (overleaf-workspace--current-session)))
    (unless (and buffer-file-name (overleaf-workspace--session-for-file buffer-file-name))
      (user-error "This buffer is not in an Overleaf project"))
    (if-let* ((d (and emacs-collab-mode (emacs-collab--doc))))
        (emacs-collab--reattach (overleaf-workspace-session-conn s) d)
      (setq emacs-collab--conn (overleaf-workspace-session-conn s))
      (emacs-collab-mode 1))
    (message "overleaf: re-attaching %s" (file-name-nondirectory buffer-file-name))))

(defun overleaf-workspace-status ()
  "Show the state of the current project's connection."
  (interactive)
  (let* ((s (overleaf-workspace--current-session))
         (conn (overleaf-workspace-session-conn s)))
    (message "overleaf: %s / %s -- %s%s; mirror %s; %d document(s), %d peer(s)"
             (plist-get (overleaf-workspace-session-server s) :name)
             (or (plist-get (overleaf-workspace-session-project s) :name)
                 (plist-get (overleaf-workspace-session-project s) :id))
             (emacs-collab-conn-status conn)
             (if-let* ((x (emacs-collab-conn-status-detail conn))) (format " (%s)" x) "")
             (abbreviate-file-name (overleaf-workspace-session-mirror s))
             (hash-table-count (emacs-collab-conn-docs conn))
             (hash-table-count (emacs-collab-conn-peers conn)))))

(defvar TeX-command-list)
(declare-function TeX-command "tex-buf")
(declare-function TeX-master-file "tex")

(defun overleaf-workspace--after-compile (&optional file)
  "Show FILE, a finished PDF, in the project's PDF pane."
  (when (and (stringp file) (string-suffix-p ".pdf" file)
             (file-exists-p file))
    (when-let* ((s (overleaf-workspace--session-for-file file)))
      (emacs-collab-layout-show-pdf file (overleaf-workspace-session-mirror s)))))

;;;###autoload
(defun overleaf-workspace-compile ()
  "Build the main file locally and show the PDF.
Uses AUCTeX's LatexMk command when it has one, else runs latexmk itself."
  (interactive)
  (let* ((s (overleaf-workspace--current-session))
         (main (or (overleaf-workspace-session-main s) (user-error "No main file")))
         (pdf (funcall overleaf-workspace-pdf-function main)))
    (if (and (fboundp 'TeX-command) (boundp 'TeX-command-list)
             (assoc "LatexMk" TeX-command-list)
             (get-file-buffer main))
        (with-current-buffer (get-file-buffer main)
          (TeX-command "LatexMk" #'TeX-master-file))
      (let* ((default-directory (file-name-directory main))
             (out (file-name-directory pdf))
             (buf (get-buffer-create "*overleaf-latexmk*"))
             (proc (make-process
                    :name "overleaf-latexmk" :buffer buf :noquery t
                    :command (append overleaf-workspace-latexmk-command
                                     (unless (equal out default-directory)
                                       (list (concat "-outdir=" (directory-file-name out))))
                                     (list main))
                    :sentinel (lambda (p _e)
                                (when (and (not (process-live-p p)) (file-exists-p pdf))
                                  (emacs-collab-layout-show-pdf
                                   pdf (overleaf-workspace-session-mirror s)))))))
        (with-current-buffer buf (let ((inhibit-read-only t)) (erase-buffer)))
        (emacs-collab-layout-register-process proc (overleaf-workspace-session-mirror s))
        proc))))

(provide 'overleaf-workspace)
;;; overleaf-workspace.el ends here
