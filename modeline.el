;;; ui/doom-modeline/config.el -*- lexical-binding: t; -*-
(require 'all-the-icons)
(eval-when-compile (require 'subr-x))

(line-number-mode -1)

(defun doom-project-root (&optional strict-p)
  "Get the path to the root of your project."
  (let ((projectile-require-project-root strict-p))
    (ignore-errors (projectile-project-root))))

(defsubst doom--prepare-modeline-segments (segments)
  (cl-loop for seg in segments
           if (stringp seg)
           collect seg
           else
           collect (list (intern (format "doom-modeline-segment--%s" (symbol-name seg))))))

(defmacro def-modeline! (name lhs &optional rhs)
  "Defines a modeline format and byte-compiles it. NAME is a symbol to identify
it (used by `doom-modeline' for retrieval). LHS and RHS are lists of symbols of
modeline segments defined with `def-modeline-segment!'.
Example:
  (def-modeline! minimal
    (bar matches \" \" buffer-info)
    (media-info major-mode))
  (doom-set-modeline 'minimal t)"
  (let ((sym (intern (format "doom-modeline-format--%s" name)))
        (lhs-forms (doom--prepare-modeline-segments lhs))
        (rhs-forms (doom--prepare-modeline-segments rhs)))
    `(progn
       (defun ,sym ()
         (let ((lhs (list ,@lhs-forms))
               (rhs (list ,@rhs-forms)))
           (list lhs
                 (propertize
                  " " 'display
                  `((space :align-to (- (+ right right-fringe right-margin)
                                        ,(+ 1 (string-width (format-mode-line rhs)))))))
                 rhs)))
       ,(unless (bound-and-true-p byte-compile-current-file)
          `(let (byte-compile-warnings)
             (byte-compile #',sym))))))


(defun doom-modeline (key)
  "Returns a mode-line configuration associated with KEY (a symbol). Throws an
error if it doesn't exist."
  (let ((fn (intern (format "doom-modeline-format--%s" key))))
    (when (functionp fn)
      `(:eval (,fn)))))

(defun doom-set-modeline (key &optional default)
  "Set the modeline format. Does nothing if the modeline KEY doesn't exist. If
DEFAULT is non-nil, set the default mode-line for all buffers."
  (let ((modeline (doom-modeline key)))
    (when modeline
      (setf (if default
                (default-value 'mode-line-format)
              (buffer-local-value 'mode-line-format (current-buffer)))
            modeline))))

(defmacro def-modeline-segment! (name &rest forms)
  "Defines a modeline segment and byte compiles it."
  (declare (indent defun) (doc-string 2))
  (let ((sym (intern (format "doom-modeline-segment--%s" name))))
    `(progn
       (defun ,sym () ,@forms)
       ,(unless (bound-and-true-p byte-compile-current-file)
          `(let (byte-compile-warnings)
             (byte-compile #',sym))))))



(defvar doom-memoized-table (make-hash-table :test 'equal :size 10)
  "A lookup table containing memoized functions. The keys are argument lists,
and the value is the function's return value.")

;;;###autoload
(defun doom-memoize (name)
  "Memoizes an existing function. NAME is a symbol."
  (let ((func (symbol-function name)))
    (put name 'function-documentation
         (concat (documentation func) " (memoized)"))
    (fset name
          `(lambda (&rest args)
             (let ((key (cons ',name args)))
               (or (gethash key doom-memoized-table)
                   (puthash key (apply ',func args)
                            doom-memoized-table)))))))

;;;###autoload
(defmacro def-memoized! (name arglist &rest body)
  "Create a memoize'd function. NAME, ARGLIST, DOCSTRING and BODY
have the same meaning as in `defun'."
  (declare (indent defun) (doc-string 3))
  `(,(if (bound-and-true-p byte-compile-current-file)
         'with-no-warnings
       'progn)
    (defun ,name ,arglist ,@body)
    (doom-memoize ',name)))


(defmacro after! (feature &rest forms)
  "A smart wrapper around `with-eval-after-load'. Supresses warnings during
compilation."
  (declare (indent defun) (debug t))
  `(,(if (or (not (bound-and-true-p byte-compile-current-file))
             (if (symbolp feature)
                 (require feature nil :no-error)
               (load feature :no-message :no-error)))
         #'progn
       #'with-no-warnings)
    (with-eval-after-load ',feature ,@forms)))


(defun doom--resolve-hooks (hooks)
  (let ((quoted-p (eq (car-safe hooks) 'quote)))
    (when quoted-p
      (setq hooks (cadr hooks)))
    (cl-loop with hooks = (if (listp hooks) hooks (list hooks))
             for hook in hooks
             if (eq (car-safe hook) 'quote)
             collect (cadr hook)
             else if quoted-p
             collect hook
             else collect (intern (format "%s-hook" (symbol-name hook))))))

(defvar doom--transient-counter 0)

(defmacro add-transient-hook! (hook &rest forms)
  "Attaches transient forms to a HOOK.
HOOK can be a quoted hook or a sharp-quoted function (which will be advised).
These forms will be evaluated once when that function/hook is first invoked,
then it detaches itself."
  (declare (indent 1))
  (let ((append (eq (car forms) :after))
        (fn (intern (format "doom-transient-hook-%s" (cl-incf doom--transient-counter)))))
    `(when ,hook
       (fset ',fn
             (lambda (&rest _)
               ,@forms
               (cond ((functionp ,hook) (advice-remove ,hook #',fn))
                     ((symbolp ,hook)   (remove-hook ,hook #',fn)))
               (unintern ',fn nil)))
       (cond ((functionp ,hook)
              (advice-add ,hook ,(if append :after :before) #',fn))
             ((symbolp ,hook)
              (add-hook ,hook #',fn ,append))))))

(defmacro add-hook! (&rest args)
  "A convenience macro for `add-hook'. Takes, in order:
  1. Optional properties :local and/or :append, which will make the hook
     buffer-local or append to the list of hooks (respectively),
  2. The hooks: either an unquoted major mode, an unquoted list of major-modes,
     a quoted hook variable or a quoted list of hook variables. If unquoted, the
     hooks will be resolved by appending -hook to each symbol.
  3. A function, list of functions, or body forms to be wrapped in a lambda.
Examples:
    (add-hook! 'some-mode-hook 'enable-something)
    (add-hook! some-mode '(enable-something and-another))
    (add-hook! '(one-mode-hook second-mode-hook) 'enable-something)
    (add-hook! (one-mode second-mode) 'enable-something)
    (add-hook! :append (one-mode second-mode) 'enable-something)
    (add-hook! :local (one-mode second-mode) 'enable-something)
    (add-hook! (one-mode second-mode) (setq v 5) (setq a 2))
    (add-hook! :append :local (one-mode second-mode) (setq v 5) (setq a 2))
Body forms can access the hook's arguments through the let-bound variable
`args'."
  (declare (indent defun) (debug t))
  (let ((hook-fn 'add-hook)
        append-p local-p)
    (while (keywordp (car args))
      (pcase (pop args)
        (:append (setq append-p t))
        (:local  (setq local-p t))
        (:remove (setq hook-fn 'remove-hook))))
    (let ((hooks (doom--resolve-hooks (pop args)))
          (funcs
           (let ((val (car args)))
             (if (memq (car-safe val) '(quote function))
                 (if (cdr-safe (cadr val))
                     (cadr val)
                   (list (cadr val)))
               (list args))))
          forms)
      (dolist (fn funcs)
        (setq fn (if (symbolp fn)
                     `(function ,fn)
                   `(lambda (&rest _) ,@args)))
        (dolist (hook hooks)
          (push (cond ((eq hook-fn 'remove-hook)
                       `(remove-hook ',hook ,fn ,local-p))
                      (t
                       `(add-hook ',hook ,fn ,append-p ,local-p)))
                forms)))
      `(progn ,@(nreverse forms)))))

(defvar doom-disabled-packages ()
  "A list of packages that should be ignored by `def-package!'.")

(defmacro def-package! (name &rest plist)
  "A thin wrapper around `use-package'."
  (when (and (memq name doom-disabled-packages)
             (not (memq :disabled plist)))
    (setq plist (append (list :disabled t) plist)))
  `(use-package ,name ,@plist))

(def-package! eldoc-eval :demand t
  :config
  ;; Show eldoc in the mode-line with `eval-expression'
  (defun +doom-modeline--show-eldoc (input)
    "Display string STR in the mode-line next to minibuffer."
    (with-current-buffer (eldoc-current-buffer)
      (let* ((str              (and (stringp input) input))
             (mode-line-format (or (and str (or (doom-modeline 'eldoc) str))
                                   mode-line-format))
             mode-line-in-non-selected-windows)
        (force-mode-line-update)
        (sit-for eldoc-show-in-mode-line-delay))))

  (setq eldoc-in-minibuffer-show-fn #'+doom-modeline--show-eldoc)
  (eldoc-in-minibuffer-mode +1))

;; anzu and evil-anzu make it possible to display current/total in the
;; mode-line.
(def-package! evil-anzu
  :when (featurep 'evil)
  :init
  (add-transient-hook! #'evil-ex-start-search (require 'evil-anzu))
  :config
  (setq anzu-cons-mode-line-p nil
        anzu-minimum-input-length 1
        anzu-search-threshold 250)

  ;; Avoid anzu conflicts across buffers
  (mapc #'make-variable-buffer-local
        '(anzu--total-matched anzu--current-position anzu--state
          anzu--cached-count anzu--cached-positions anzu--last-command
          anzu--last-isearch-string anzu--overflow-p))

  ;; Ensure anzu state is cleared when searches & iedit are done
  (add-hook! :append '(isearch-mode-end-hook +evil-esc-hook)
    #'anzu--reset-status)
  (after! iedit
    (add-hook 'iedit-mode-end-hook #'anzu--reset-status)))


;; Keep `+doom-modeline-current-window' up-to-date
(defvar +doom-modeline-current-window (frame-selected-window))
(defun +doom-modeline|set-selected-window (&rest _)
  "Sets `+doom-modeline-current-window' appropriately"
  (let ((win (frame-selected-window)))
    (unless (minibuffer-window-active-p win)
      (setq +doom-modeline-current-window win))))

(add-hook 'window-configuration-change-hook #'+doom-modeline|set-selected-window)
(add-hook 'focus-in-hook #'+doom-modeline|set-selected-window)
(advice-add #'handle-switch-frame :after #'+doom-modeline|set-selected-window)
(advice-add #'select-window :after #'+doom-modeline|set-selected-window)



;;
;; Variables
;;

(defvar +doom-modeline-height 37
  "How tall the mode-line should be (only respected in GUI emacs).")

(defvar +doom-modeline-bar-width 3
  "How wide the mode-line bar should be (only respected in GUI emacs).")

(defvar +doom-modeline-vspc
  (propertize " " 'face 'variable-pitch)
  "TODO")

;; externs
(defvar anzu--state nil)
(defvar evil-mode nil)
(defvar evil-state nil)
(defvar evil-visual-selection nil)
(defvar iedit-mode nil)
(defvar all-the-icons-scale-factor)
(defvar all-the-icons-default-adjust)


;;
;; Custom faces
;;

(defgroup +doom-modeline nil
  ""
  :group 'doom)

(defface doom-modeline-buffer-path
  '((t (:inherit mode-line-emphasis :bold t)))
  "Face used for the dirname part of the buffer path."
  :group '+doom-modeline)

(defface doom-modeline-buffer-file
  '((t (:inherit mode-line-buffer-id)))
  "Face used for the filename part of the mode-line buffer path."
  :group '+doom-modeline)

(defface doom-modeline-buffer-modified
  '((t (:inherit error :background nil :bold t)))
  "Face used for the 'unsaved' symbol in the mode-line."
  :group '+doom-modeline)

(defface doom-modeline-buffer-major-mode
  '((t (:inherit mode-line-emphasis :bold t)))
  "Face used for the major-mode segment in the mode-line."
  :group '+doom-modeline)

(defface doom-modeline-highlight
  '((t (:inherit mode-line-emphasis)))
  "Face for bright segments of the mode-line."
  :group '+doom-modeline)

(defface doom-modeline-panel
  '((t (:inherit mode-line-highlight)))
  "Face for 'X out of Y' segments, such as `+doom-modeline--anzu', `+doom-modeline--evil-substitute' and
`iedit'"
  :group '+doom-modeline)

(defface doom-modeline-info
  `((t (:inherit success :bold t)))
  "Face for info-level messages in the modeline. Used by `*vc'."
  :group '+doom-modeline)

(defface doom-modeline-warning
  `((t (:inherit warning :bold t)))
  "Face for warnings in the modeline. Used by `*flycheck'"
  :group '+doom-modeline)

(defface doom-modeline-urgent
  `((t (:inherit error :bold t)))
  "Face for errors in the modeline. Used by `*flycheck'"
  :group '+doom-modeline)

;; Bar
(defface doom-modeline-bar '((t (:inherit highlight)))
  "The face used for the left-most bar on the mode-line of an active window."
  :group '+doom-modeline)

(defface doom-modeline-eldoc-bar '((t (:inherit shadow)))
  "The face used for the left-most bar on the mode-line when eldoc-eval is
active."
  :group '+doom-modeline)

(defface doom-modeline-inactive-bar '((t (:inherit warning :inverse-video t)))
  "The face used for the left-most bar on the mode-line of an inactive window."
  :group '+doom-modeline)


;;
;; Bootstrap
;;

;; Show version string for multi-version managers like rvm, rbenv, pyenv, etc.
(defvar-local +doom-modeline-env-version nil)
(defvar-local +doom-modeline-env-command nil)
(add-hook! '(focus-in-hook find-file-hook) #'+doom-modeline|update-env)
(defun +doom-modeline|update-env ()
  (when +doom-modeline-env-command
    (let* ((default-directory (doom-project-root))
           (s (shell-command-to-string +doom-modeline-env-command)))
      (setq +doom-modeline-env-version (if (string-match "[ \t\n\r]+\\'" s)
                                          (replace-match "" t t s)
                                        s)))))

;; Only support python and ruby for now
(add-hook! 'python-mode-hook (setq +doom-modeline-env-command "python --version 2>&1 | cut -d' ' -f2"))
(add-hook! 'ruby-mode-hook   (setq +doom-modeline-env-command "ruby   --version 2>&1 | cut -d' ' -f2"))


;;
;; Modeline helpers
;;

(defsubst active ()
  (eq (selected-window) +doom-modeline-current-window))

;; Inspired from `powerline's `pl/make-xpm'.
(def-memoized! +doom-modeline--make-xpm (color height width)
  "Create an XPM bitmap."
  (propertize
   " " 'display
   (let ((data (make-list height (make-list width 1)))
         (color (or color "None")))
     (create-image
      (concat
       (format "/* XPM */\nstatic char * percent[] = {\n\"%i %i 2 1\",\n\". c %s\",\n\"  c %s\","
               (length (car data))
               (length data)
               color
               color)
       (apply #'concat
              (cl-loop with idx = 0
                       with len = (length data)
                       for dl in data
                       do (cl-incf idx)
                       collect
                       (concat "\""
                               (cl-loop for d in dl
                                        if (= d 0) collect (string-to-char " ")
                                        else collect (string-to-char "."))
                               (if (eq idx len) "\"};" "\",\n")))))
      'xpm t :ascent 'center))))

(defsubst +doom-modeline--buffer-file ()
  "Display the base of the current buffer's filename."
  (if buffer-file-name
      (file-name-nondirectory (or buffer-file-truename (file-truename buffer-file-name)))
    "%b"))

(defsubst +doom-modeline--buffer-path ()
  "Displays the buffer's full path relative to the project root (includes the
project root). Excludes the file basename. See `doom-buffer-name' for that."
  (when buffer-file-name
    (let ((buffer-path
           (file-relative-name (file-name-directory
                                (or buffer-file-truename (file-truename buffer-file-name)))
                               (doom-project-root))))
      (unless (equal buffer-path "./")
        (let ((max-length (truncate (* (window-body-width) 0.4))))
          (if (> (length buffer-path) max-length)
              (let ((path (nreverse (split-string buffer-path "/" t)))
                    (output ""))
                (when (and path (equal "" (car path)))
                  (setq path (cdr path)))
                (while (and path (<= (length output) (- max-length 4)))
                  (setq output (concat (car path) "/" output)
                        path (cdr path)))
                (when path
                  (setq output (concat "../" output)))
                (unless (string-suffix-p "/" output)
                  (setq output (concat output "/")))
                output)
            buffer-path))))))


;;
;; Segments
;;

(def-modeline-segment! buffer-project
  "Displays `doom-project-root'. This is for special buffers like the scratch
buffer where knowing the current project directory is important."
  (let ((face (if (active) 'doom-modeline-buffer-path)))
    (concat (if (display-graphic-p) " ")
            (all-the-icons-octicon
             "file-directory"
             :face face
             :v-adjust -0.05
             :height 1.25)
            (propertize (concat " " (abbreviate-file-name (doom-project-root)))
                        'face face))))

;;
(def-modeline-segment! buffer-info
  "Combined information about the current buffer, including the current working
directory, the file name, and its state (modified, read-only or non-existent)."
  (let* ((all-the-icons-scale-factor 1.2)
         (modified-p (buffer-modified-p))
         (active (active))
         (faces (if modified-p 'doom-modeline-buffer-modified)))
    (concat (cond (buffer-read-only
                   (concat (all-the-icons-octicon
                            "lock"
                            :face 'doom-modeline-warning
                            :v-adjust -0.05)
                           " "))
                  (modified-p
                   (concat (all-the-icons-faicon
                            "floppy-o"
                            :face 'doom-modeline-buffer-modified
                            :v-adjust -0.1)
                           " "))
                  ((and buffer-file-name
                        (not (file-exists-p buffer-file-name)))
                   (concat (all-the-icons-octicon
                            "circle-slash"
                            :face 'doom-modeline-urgent
                            :v-adjust -0.05)
                           " ")))
            (when-let (dir-path (+doom-modeline--buffer-path))
              (if-let (faces (or faces (if active 'doom-modeline-buffer-path)))
                  (propertize dir-path 'face `(:inherit ,faces))
                dir-path))
            (when-let (file-path (+doom-modeline--buffer-file))
              (if-let (faces (or faces (if active 'doom-modeline-buffer-file)))
                  (propertize file-path 'face `(:inherit ,faces))
                file-path)))))

;;
(def-modeline-segment! buffer-info-simple
  "Return the current buffer name only, but with fontification."
  (propertize "%b" 'face (if (active) 'doom-modeline-buffer-file)))

;;
(def-modeline-segment! buffer-encoding
  "Displays the encoding and eol style of the buffer the same way Atom does."
  (concat (let ((eol-type (coding-system-eol-type buffer-file-coding-system)))
            (cond ((eq eol-type 0) "LF  ")
                  ((eq eol-type 1) "CRLF  ")
                  ((eq eol-type 2) "CR  ")))
          (let* ((sys (coding-system-plist buffer-file-coding-system))
                 (sys-name (plist-get sys :name))
                 (sys-cat (plist-get sys :category)))
            (cond ((memq sys-cat '(coding-category-undecided coding-category-utf-8))
                   "UTF-8")
                  (t (upcase (symbol-name sys-name)))))
          "  "))

;;
(def-modeline-segment! major-mode
  "The major mode, including process, environment and text-scale info."
  (propertize
   (concat (format-mode-line mode-name)
           (if (stringp mode-line-process) mode-line-process)
           (if +doom-modeline-env-version (concat " " +doom-modeline-env-version))
           (and (featurep 'face-remap)
                (/= text-scale-mode-amount 0)
                (format " (%+d)" text-scale-mode-amount)))
   'face (if (active) 'doom-modeline-buffer-major-mode)))

;;
(def-modeline-segment! vcs
  "Displays the current branch, colored based on its state."
  (when vc-mode
    (let ((backend (vc-backend buffer-file-name))
          (state   (vc-state buffer-file-name))
          (face    'mode-line-inactive)
          (active  (active))
          (all-the-icons-scale-factor 1.0)
          (all-the-icons-default-adjust -0.1))
      (concat "  "
              (cond ((memq state '(edited added))
                     (if active (setq face 'doom-modeline-info))
                     (all-the-icons-octicon
                      "git-compare"
                      :face face
                      :height 1.2
                      :v-adjust -0.05))
                    ((eq state 'needs-merge)
                     (if active (setq face 'doom-modeline-info))
                     (all-the-icons-octicon "git-merge" :face face))
                    ((eq state 'needs-update)
                     (if active (setq face 'doom-modeline-warning))
                     (all-the-icons-octicon "arrow-down" :face face))
                    ((memq state '(removed conflict unregistered))
                     (if active (setq face 'doom-modeline-urgent))
                     (all-the-icons-octicon "alert" :face face))
                    (t
                     (if active (setq face 'font-lock-doc-face))
                     (all-the-icons-octicon
                      "git-compare"
                      :face face
                      :height 1.2
                      :v-adjust -0.05)))
              " "
              (propertize (substring vc-mode (+ (if (eq backend 'Hg) 2 3) 2))
                          'face (if active face))
              " "))))

;;
(defun +doom-ml-icon (icon &optional text face)
  "Displays an octicon ICON with FACE, followed by TEXT. Uses
`all-the-icons-octicon' to fetch the icon."
  (concat
   (if vc-mode " " "  ")
   (when icon
     (concat
      (all-the-icons-material icon :face face :height 1.1 :v-adjust -0.25)
      ;; (all-the-icons-octicon icon :face face :height 1.0 :v-adjust 0)
      (if text +doom-modeline-vspc)))
   (when text
     (propertize text 'face face))
   (if vc-mode "  " " ")))

(def-modeline-segment! flycheck
  "Displays color-coded flycheck error status in the current buffer with pretty
icons."
  (when (boundp 'flycheck-last-status-change)
    (pcase flycheck-last-status-change
      ('finished (if flycheck-current-errors
                     (let-alist (flycheck-count-errors flycheck-current-errors)
                       (let ((sum (+ (or .error 0) (or .warning 0))))
                         ;; do-not-disturb-alt
                         (+doom-ml-icon "do_not_disturb_alt" ;; "circle-slash"
                                        (number-to-string sum)
                                        (if .error 'doom-modeline-urgent 'doom-modeline-warning))))
                   ;; check
                   (+doom-ml-icon "check" nil 'doom-modeline-info)))
      ('running     (+doom-ml-icon "access_time" nil 'font-lock-doc-face))
      ;; ('running     (+doom-ml-icon "ellipsis" "Running" 'font-lock-doc-face))
      ('no-checker  (+doom-ml-icon "sim_card_alert" "-" 'font-lock-doc-face))
      ;; ('no-checker  (+doom-ml-icon "alert" "-" 'font-lock-doc-face))
      ('errored     (+doom-ml-icon "sim_card_alert" "Error" 'doom-modeline-urgent))
      ;; ('errored     (+doom-ml-icon "alert" "Error" 'doom-modeline-urgent))
      ('interrupted (+doom-ml-icon "pause" "Interrupted" 'font-lock-doc-face)))))
      ;; ('interrupted (+doom-ml-icon "x" "Interrupted" 'font-lock-doc-face)))))

;;
(defsubst doom-column (pos)
  (save-excursion (goto-char pos)
                  (current-column)))

(def-modeline-segment! selection-info
  "Information about the current selection, such as how many characters and
lines are selected, or the NxM dimensions of a block selection."
  (when (and (active) (or mark-active (eq evil-state 'visual)))
    (let ((reg-beg (region-beginning))
          (reg-end (region-end)))
      (propertize
       (let ((lines (count-lines reg-beg (min (1+ reg-end) (point-max)))))
         (cond ((or (bound-and-true-p rectangle-mark-mode)
                    (eq 'block evil-visual-selection))
                (let ((cols (abs (- (doom-column reg-end)
                                    (doom-column reg-beg)))))
                  (format "%dx%dB" lines cols)))
               ((eq 'line evil-visual-selection)
                (format "%dL" lines))
               ((> lines 1)
                (format "%dC %dL" (- (1+ reg-end) reg-beg) lines))
               (t
                (format "%dC" (- (1+ reg-end) reg-beg)))))
       'face 'doom-modeline-highlight))))


;;
(defun +doom-modeline--macro-recording ()
  "Display current Emacs or evil macro being recorded."
  (when (and (active) (or defining-kbd-macro executing-kbd-macro))
    (let ((sep (propertize " " 'face 'doom-modeline-panel)))
      (concat sep
              (propertize (if (bound-and-true-p evil-this-macro)
                              (char-to-string evil-this-macro)
                            "Macro")
                          'face 'doom-modeline-panel)
              sep
              (all-the-icons-octicon "triangle-right"
                                     :face 'doom-modeline-panel
                                     :v-adjust -0.05)
              sep))))

(defsubst +doom-modeline--anzu ()
  "Show the match index and total number thereof. Requires `anzu', also
`evil-anzu' if using `evil-mode' for compatibility with `evil-search'."
  (when (and anzu--state (not iedit-mode))
    (propertize
     (let ((here anzu--current-position)
           (total anzu--total-matched))
       (cond ((eq anzu--state 'replace-query)
              (format " %d replace " total))
             ((eq anzu--state 'replace)
              (format " %d/%d " here total))
             (anzu--overflow-p
              (format " %s+ " total))
             (t
              (format " %s/%d " here total))))
     'face (if (active) 'doom-modeline-panel))))

(defsubst +doom-modeline--evil-substitute ()
  "Show number of :s matches in real time."
  (when (and evil-mode
             (or (assq 'evil-ex-substitute evil-ex-active-highlights-alist)
                 (assq 'evil-ex-global-match evil-ex-active-highlights-alist)
                 (assq 'evil-ex-buffer-match evil-ex-active-highlights-alist)))
    (propertize
     (let ((range (if evil-ex-range
                      (cons (car evil-ex-range) (cadr evil-ex-range))
                    (cons (line-beginning-position) (line-end-position))))
           (pattern (car-safe (evil-delimited-arguments evil-ex-argument 2))))
       (if pattern
           (format " %s matches " (how-many pattern (car range) (cdr range)))
         " ... "))
     'face (if (active) 'doom-modeline-panel))))

(defsubst +doom-modeline--iedit ()
  "Show the number of iedit regions matches + what match you're on."
  (when (and iedit-mode iedit-occurrences-overlays)
    (propertize
     (let ((this-oc (or (let ((inhibit-message t))
                          (iedit-find-current-occurrence-overlay))
                        (progn (iedit-prev-occurrence)
                               (iedit-find-current-occurrence-overlay))))
           (length (length iedit-occurrences-overlays)))
       (format " %s/%d "
               (if this-oc
                   (- length
                      (length (cdr
                               (memq this-oc (sort (append iedit-occurrences-overlays (list))
                                                   (lambda (x y) (< (overlay-start x) (overlay-start y))))))))
                 "-")
               length))
     'face (if (active) 'doom-modeline-panel))))

(def-modeline-segment! matches
  "Displays: 1. the currently recording macro, 2. A current/total for the
current search term (with anzu), 3. The number of substitutions being conducted
with `evil-ex-substitute', and/or 4. The number of active `iedit' regions."
  (let ((meta (concat (+doom-modeline--macro-recording)
                      (+doom-modeline--anzu)
                      (+doom-modeline--evil-substitute)
                      (+doom-modeline--iedit))))
     (or (and (not (string= meta "")) meta)
         (if buffer-file-name " %I "))))

;; TODO Include other information
(def-modeline-segment! media-info
  "Metadata regarding the current file, such as dimensions for images."
  (cond ((eq major-mode 'image-mode)
         (let ((size (image-size (image-get-display-property) :pixels)))
           (format "  %dx%d  " (car size) (cdr size))))))

;;
(def-modeline-segment! eldoc
  "Display eldoc documentation in the mode-line while using the minibuffer (e.g.
`eval-expression')."
  (bound-and-true-p str))

;; These bars regulate the height of the mode-line in GUI Emacs.
(def-modeline-segment! bar
  (if (display-graphic-p)
      (+doom-modeline--make-xpm
       (face-background (if (active)
                            'doom-modeline-bar
                          'doom-modeline-inactive-bar)
                        nil t)
       +doom-modeline-height
       +doom-modeline-bar-width)
    ""))

(def-modeline-segment! eldoc-bar
  "A differently colored bar, to signify an eldoc display."
  (if (display-graphic-p)
      (+doom-modeline--make-xpm
       (face-background 'doom-modeline-eldoc-bar nil t)
       +doom-modeline-height
       +doom-modeline-bar-width)
    ""))


;;
;; Mode lines
;;

(def-modeline! main
  (bar matches " " buffer-info "  %l:%c %p  " selection-info)
  (buffer-encoding major-mode vcs flycheck))

(def-modeline! eldoc
  (eldoc-bar " " eldoc)
  (media-info major-mode))

(def-modeline! minimal
  (bar matches " " buffer-info)
  (media-info major-mode))

(def-modeline! special
  (bar matches " " buffer-info-simple "  %l:%c %p  " selection-info)
  (buffer-encoding major-mode flycheck))

(def-modeline! project
  (bar buffer-project)
  (major-mode))

(def-modeline! media
  (bar " %b  ")
  (media-info major-mode))

;;
(doom-set-modeline 'main t)

;; This scratch buffer is already created, and doesn't get a modeline. For the
;; love of Emacs, someone give the man a modeline!
(with-current-buffer "*scratch*"
  (doom-set-modeline 'main))


;;
;; Hooks
;;

(defun +doom-modeline|set-special-modeline ()
  (doom-set-modeline 'special))

(defun +doom-modeline|set-media-modeline ()
  (doom-set-modeline 'media))

(add-hook 'org-src-mode-hook #'+doom-modeline|set-special-modeline)
(add-hook 'image-mode-hook #'+doom-modeline|set-media-modeline)
(add-hook 'circe-mode-hook #'+doom-modeline|set-special-modeline)
