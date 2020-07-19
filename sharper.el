;;; sharper.el --- dotnet CLI wrapper, using Transient.  -*- lexical-binding: t; -*-

;; Copyright (C) 2020 Sebastian Monia
;;
;; Author: Sebastian Monia <smonia@outlook.com>
;; URL: https://github.com/sebasmonia/sharper
;; Package-Requires: ((emacs "25"))
;; Version: 1.0
;; Keywords: maint tool

;; This file is not part of GNU Emacs.

;;; License: MIT

;;; Commentary:

;; This package aims to be a complete package for dotnet tasks that aren't part
;; of the languages but needed for any project: Solution management, nuget, etc.
;;
;; Steps to setup:
;;   1. Place sharper.el in your load-path.  Or install from MELPA.
;;   2. Add a binding to start sharper's transient:
;;       (require 'sharper)
;;       (global-set-key (kbd "C-c n") 'sharper-main-transient) ;; For "n" for "dot NET"
;;
;; For a detailed user manual see:
;; https://github.com/sebasmonia/sharper/blob/master/README.md

;;; Code:


;;------------------Package infrastructure----------------------------------------

(require 'transient)
(require 'cl-lib)
(require 'cl-extra)
(require 'project)

(defun sharper--message (text)
  "Show a TEXT as a message and log it, if 'panda-less-messages' log only."
  (message "Sharper: %s" text)
  (sharper--log "Package message:" text "\n"))

(defun sharper--log (&rest to-log)
  "Append TO-LOG to the log buffer.  Intended for internal use only."
  (let ((log-buffer (get-buffer-create "*sharper-log*"))
        (text (cl-reduce (lambda (accum elem) (concat accum " " (prin1-to-string elem t))) to-log)))
    (with-current-buffer log-buffer
      (goto-char (point-max))
      (insert text)
      (insert "\n"))))


;;------------------Customization options-----------------------------------------

(defgroup sharper nil
  "dotnet CLI wrapper, using Transient."
  :group 'extensions)

(defcustom sharper-project-extensions '("csproj" "fsproj")
  "Valid extensions for project files."
  :type 'list)

;; (defcustom panda-open-status-after-build 'ask
;;   "Open the build status for the corresponding branch after requesting a build.
;; If yes, automatically open it.  No to never ask.  Set to 'ask (default) to be prompted each time."
;;   :type '(choice (const :tag "No" nil)
;;                  (const :tag "Yes" t)
;;                  (const :tag "Ask" ask)))


;; Legend for the templates below:
;; %t = TARGET
;; %o = OPTIONS
;; %s = SOLUTION
;; %p = PROJECT
;; %k = PACKAGE NAME
;; %r = RUNTIME SETTINGS (dotnet test only)
(defvar sharper--build-template "dotnet build %t %o" "Template for \"dotnet build\" invocations.")
(defvar sharper--test-template "dotnet test %t %o %r" "Template for \"dotnet test\" invocations.")
(defvar sharper--clean-template "dotnet clean %t %o" "Template for \"dotnet clean\" invocations.")

(defvar sharper--last-build nil "Last command used for a build")
(defvar sharper--last-test nil "Last command used to run tests")

;;------------------Main transient------------------------------------------------

(define-transient-command sharper-main-transient ()
  "dotnet Menu"
  ["Build commands"
   ("B" "build" sharper-transient-build)
   ("b" "repeat last build" sharper--run-last-build)]
  ["Test commands"
   ("T" "test" sharper-transient-test)
   ("t" "repeat last test run" sharper--run-last-test)]
  ["Misc commands"
   ("c" "clean" sharper-transient-clean)
   ("q" "quit" transient-quit-all)])


(defun sharper--run-last-build (&optional transient-params)
  "Run \"dotnet build\" using TRANSIENT-PARAMS as arguments & options."
  (interactive
   (list (transient-args 'sharper-transient-build)))
  (transient-set)
  (if sharper--last-build
      (progn
        (sharper--log "Compilation command\n" sharper--last-build "\n")
        (compile sharper--last-build))
    (sharper-transient-build)))

(defun sharper--run-last-test (&optional transient-params)
  "Run \"dotnet test\" using TRANSIENT-PARAMS as arguments & options."
  (interactive
   (list (transient-args 'sharper-transient-build)))
  (transient-set)
  (sharper--log "Test command\n" sharper--last-test "\n")
  (if sharper--last-test
      (progn
        (sharper--log "Test command\n" sharper--last-test "\n")
        (compile sharper--last-test))
    (sharper-transient-test)))

;; TODO: REMOVE IN FINAL PACKAGE
(define-key hoagie-keymap (kbd "n") 'sharper-main-transient)
;; TODO: REMOVE IN FINAL PACKAGE


;;------------------Argument parsing----------------------------------------------

(defun sharper--get-target (transient-params)
  "Extract & shell-quote from TRANSIENT-PARAMS the \"TARGET\" argument."
  (sharper--get-argument "<TARGET>=" transient-params))

(defun sharper--get-argument (marker transient-params)
  "Extract & shell-quote from TRANSIENT-PARAMS the argument with  MARKER."
  (let ((target (cl-some
                 (lambda (an-arg) (when (string-prefix-p marker an-arg)
                                    (replace-regexp-in-string marker
                                                              ""
                                                              an-arg)))
                 transient-params)))
    (if target
        (shell-quote-argument target)
      target)))

(defun shaper--option-split-quote (an-option)
  (let* ((equal-char-index (string-match "=" an-option))
         (name (substring an-option 0 equal-char-index)))
    (if equal-char-index
        (cons name (shell-quote-argument
                    (substring an-option (+ 1 equal-char-index))))
      name)))

(defun shaper--only-options (transient-params)
  "Extract from TRANSIENT-PARAMS the options (ie, start with -)."
  (mapcar #'shaper--option-split-quote
          (cl-remove-if-not (lambda (arg) (string-prefix-p "-" arg))
                            transient-params)))

(defun sharper--option-alist-to-string (options)
  "Converts the OPTIONS as parsed by `sharper--only-options' to a string."
  ;; Right now the alist intermediate step seems useless. But I think the alist
  ;; is a good idea in case we ever need to massage the parameters :)
  (mapconcat (lambda (str-or-pair)
               (if (consp str-or-pair)
                   (concat (car str-or-pair) " " (cdr str-or-pair))
                 str-or-pair))
             options
             " "))

;;------------------dotnet common-------------------------------------------------

(defun sharper--project-dir (&optional path)
  "Get the project rootfrom optional PATH or `default-directory'."
  (project-root (project-current nil
                                 (or path
                                     default-directory))))

(defun sharper--filename-proj-or-sln-p (filename)
  "Return non-nil if FILENAME is a project or solution."
  (let ((extension (file-name-extension filename)))
    (or
     (string= "sln" extension)
     (member extension sharper-project-extensions))))

(defun sharper--filename-proj-p (filename)
  "Return non-nil if FILENAME is a project."
  (let ((extension (file-name-extension filename)))
    (member extension sharper-project-extensions)))

(defun sharper--read-solution-or-project ()
  "Offer completion for project or solution files under the current project's root."
  (let ((all-files (project-files (project-current t))))
    (completing-read "Select project or solution: "
                     all-files
                     #'sharper--filename-proj-or-sln-p)))

(defun sharper--read--project ()
  "Offer completion for project files under the current project's root."
  (let ((all-files (project-files (project-current t))))
    (completing-read "Select project or solution: "
                     all-files
                     #'sharper--filename-proj-p)))

(defun sharper--read-solution-or-project ()
  "Offer completion for project or solution files under the current project's root."
  (let ((all-files (project-files (project-current t))))
    (completing-read "Select project or solution: "
                     all-files
                     #'sharper--filename-proj-or-sln-p)))

(define-infix-argument sharper--option-target-projsln ()
  :description "<PROJECT>|<SOLUTION>"
  :class 'transient-option
  :shortarg "T"
  :argument "<TARGET>="
  :reader (lambda (_prompt _initial-input _history)
            (sharper--read-solution-or-project)))

;;------------------dotnet build--------------------------------------------------

(defun sharper--build (&optional transient-params)
  "Run \"dotnet build\" using TRANSIENT-PARAMS as arguments & options."
  (interactive
   (list (transient-args 'sharper-transient-build)))
  (transient-set)
  (let* ((target (sharper--get-target transient-params))
         (options (shaper--only-options transient-params))
         ;; We want *compilation* to happen at the root directory
         ;; of the selected project/solution
         (default-directory (sharper--project-dir target)))
    (unless target ;; it is possible to build without a target :shrug:
      (sharper--message "No TARGET provided, will build in default directory."))
    (let ((command (format-spec sharper--build-template
                                (format-spec-make ?t (or target "")
                                                  ?o (sharper--option-alist-to-string options)))))
      (setq sharper--last-build command)
      (sharper--run-last-build))))

(define-transient-command sharper-transient-build ()
  "dotnet build menu"
  :value '("--configuration=Debug" "--verbosity=minimal")
  ["Common Arguments"
   (sharper--option-target-projsln)
   ("-c" "Configuration" "--configuration=")
   ("-v" "Verbosity" "--verbosity=")]
  ["Other Arguments"
   ("-w" "Framework" "--framework=")
   ("-o" "Output" "--output=")
   ("-ni" "No incremental" "--no-incremental")
   ("-nd" "No dependencies" "--no-dependencies")
   ("-r" "Target runtime" "--runtime=")
   ("-s" "NuGet Package source URI" "--source")
   ("-es" "Version suffix" "--version-suffix=")]
  ["Actions"
   ("b" "build" sharper--build)
   ("q" "quit" transient-quit-all)])

;;------------------dotnet test---------------------------------------------------

(defun sharper--test (&optional transient-params)
  "Run \"dotnet test\" using TRANSIENT-PARAMS as arguments & options."
  (interactive
   (list (transient-args 'sharper-transient-test)))
  (transient-set)
  (let* ((target (sharper--get-target transient-params))
         (options (shaper--only-options transient-params))
         (runtime-settings (sharper--get-argument "<RunSettings>=" transient-params))
         ;; We want *compilation* to happen at the root directory
         ;; of the selected project/solution
         (default-directory (sharper--project-dir target)))
    (unless target ;; it is possible to test without a target :shrug:
      (sharper--message "No TARGET provided, will run tests in default directory."))
    (let ((command (format-spec sharper--test-template
                                (format-spec-make ?t (or target "")
                                                  ?o (sharper--option-alist-to-string options)
                                                  ?r (if runtime-settings
                                                         (concat "-- " runtime-settings)
                                                       "")))))
      (setq sharper--last-test command)
      (sharper--run-last-test))))

;; dotnet test [<PROJECT> | <SOLUTION> | <DIRECTORY> | <DLL>]
;;     [-a|--test-adapter-path <PATH_TO_ADAPTER>] [--blame]
;;     [-c|--configuration <CONFIGURATION>]
;;     [--collect <DATA_COLLECTOR_FRIENDLY_NAME>]
;;     [-d|--diag <PATH_TO_DIAGNOSTICS_FILE>] [-f|--framework <FRAMEWORK>]
;;     [--filter <EXPRESSION>] [--interactive]
;;     [-l|--logger <LOGGER_URI/FRIENDLY_NAME>] [--no-build]
;;     [--nologo] [--no-restore] [-o|--output <OUTPUT_DIRECTORY>]
;;     [-r|--results-directory <PATH>] [--runtime <RUNTIME_IDENTIFIER>]
;;     [-s|--settings <SETTINGS_FILE>] [-t|--list-tests]
;;     [-v|--verbosity <LEVEL>] [[--] <RunSettings arguments>]

(define-infix-argument sharper--option-test-runsettings ()
  :description "<RunSettings>"
  :class 'transient-option
  :shortarg "RS"
  :argument "<RunSettings>="
  :reader (lambda (_prompt _initial-input _history)
            (read-string "RunSettings arguments: ")))

(define-transient-command sharper-transient-test ()
  "dotnet test menu"
  :value '("--configuration=Debug" "--verbosity=minimal")
  ["Common Arguments"
   (sharper--option-target-projsln)
   ("-c" "Configuration" "--configuration=")
   ("-v" "Verbosity" "--verbosity=")
   ("-f" "Filter" "--filter=")
   ("-l" "Logger" "--logger=")
   ("-t" "List tests discovered""--list-tests")
   ("-nb" "No build" "--no-build")]
  ["Other Arguments"
   ("-b" "Blame" "--blame")
   ("-a" "Test adapter path" "--test-adapter-path=")
   ("-w" "Framework" "--framework=")
   ("-b" "Blame" "--blame")
   ("-o" "Output" "--output=")
   ("-O" "Data collector name" "--collect")
   ("-d" "Diagnostics file" "--diag=")
   ("-nr" "No restore" "--no-restore")
   ("-r" "Target runtime" "--runtime=")
   ("-R" "Results directory" "--results-directory=")
   ("-s" "Settings" "--settings=")
   ("-es" "Version suffix" "--version-suffix=")
   (sharper--option-test-runsettings)]
  ["Actions"
   ("t" "test" sharper--test)
   ("q" "quit" transient-quit-all)])

;;------------------dotnet clean--------------------------------------------------

(defun sharper--clean (&optional transient-params)
  "Run \"dotnet clean\" using TRANSIENT-PARAMS as arguments & options."
  (interactive
   (list (transient-args 'sharper-transient-clean)))
  (transient-set)
  (let* ((target (sharper--get-target transient-params))
         (options (shaper--only-options transient-params))
         ;; We want *compilation* to happen at the root directory
         ;; of the selected project/solution
         (default-directory (sharper--project-dir target)))
    (unless target ;; it is possible to build without a target :shrug:
      (sharper--message "No TARGET provided, will run clean in default directory."))
    (let ((command (format-spec sharper--clean-template
                                (format-spec-make ?t (or target "")
                                                  ?o (sharper--option-alist-to-string options)))))
      (sharper--log "Clean command\n" command "\n")
      (async-shell-command command "*sharper - clean output*"))))

(define-transient-command sharper-transient-clean ()
  "dotnet clean menu"
  :value '("--configuration=Debug" "--verbosity=normal")
  ["Common Arguments"
   (sharper--option-target-projsln)
   ("-c" "Configuration" "--configuration=")
   ("-v" "Verbosity" "--verbosity=")]
  ["Other Arguments"
   ("-w" "Framework" "--framework=")
   ("-o" "Output" "--output=")
   ("-r" "Target runtime" "--runtime=")]
  ["Actions"
   ("c" "clean" sharper--clean)
   ("q" "quit" transient-quit-all)])

(provide 'sharper)
;;; sharper.el ends here
