;;; smerge-mode.el --- Minor mode to resolve diff3 conflicts

;; Copyright (C) 1999, 2000, 2001, 2002, 2003,
;;   2004, 2005, 2006, 2007, 2008 Free Software Foundation, Inc.

;; Author: Stefan Monnier <monnier@iro.umontreal.ca>
;; Keywords: tools revision-control merge diff3 cvs conflict

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; Provides a lightweight alternative to emerge/ediff.
;; To use it, simply add to your .emacs the following lines:
;;
;;   (autoload 'smerge-mode "smerge-mode" nil t)
;;
;; you can even have it turned on automatically with the following
;; piece of code in your .emacs:
;;
;;   (defun sm-try-smerge ()
;;     (save-excursion
;;   	 (goto-char (point-min))
;;   	 (when (re-search-forward "^<<<<<<< " nil t)
;;   	   (smerge-mode 1))))
;;   (add-hook 'find-file-hook 'sm-try-smerge t)

;;; Todo:

;; - if requested, ask the user whether he wants to call ediff right away

;;; Code:

(eval-when-compile (require 'cl))


;;; The real definition comes later.
(defvar smerge-mode)

(defgroup smerge ()
  "Minor mode to highlight and resolve diff3 conflicts."
  :group 'tools
  :prefix "smerge-")

(defcustom smerge-diff-buffer-name "*vc-diff*"
  "Buffer name to use for displaying diffs."
  :group 'smerge
  :type '(choice
	  (const "*vc-diff*")
	  (const "*cvs-diff*")
	  (const "*smerge-diff*")
	  string))

(defcustom smerge-diff-switches
  (append '("-d" "-b")
	  (if (listp diff-switches) diff-switches (list diff-switches)))
  "A list of strings specifying switches to be passed to diff.
Used in `smerge-diff-base-mine' and related functions."
  :group 'smerge
  :type '(repeat string))

(defcustom smerge-auto-leave t
  "Non-nil means to leave `smerge-mode' when the last conflict is resolved."
  :group 'smerge
  :type 'boolean)

(defcustom smerge-auto-refine t
  "Automatically highlight changes in detail as the user visits conflicts."
  :group 'smerge
  :type 'boolean)

(defface smerge-mine
  '((((min-colors 88) (background light))
     (:foreground "blue1"))
    (((background light))
     (:foreground "blue"))
    (((min-colors 88) (background dark))
     (:foreground "cyan1"))
    (((background dark))
     (:foreground "cyan")))
  "Face for your code."
  :group 'smerge)
;; backward-compatibility alias
(put 'smerge-mine-face 'face-alias 'smerge-mine)
(defvar smerge-mine-face 'smerge-mine)

(defface smerge-other
  '((((background light))
     (:foreground "darkgreen"))
    (((background dark))
     (:foreground "lightgreen")))
  "Face for the other code."
  :group 'smerge)
;; backward-compatibility alias
(put 'smerge-other-face 'face-alias 'smerge-other)
(defvar smerge-other-face 'smerge-other)

(defface smerge-base
  '((((min-colors 88) (background light))
     (:foreground "red1"))
    (((background light))
     (:foreground "red"))
    (((background dark))
     (:foreground "orange")))
  "Face for the base code."
  :group 'smerge)
;; backward-compatibility alias
(put 'smerge-base-face 'face-alias 'smerge-base)
(defvar smerge-base-face 'smerge-base)

(defface smerge-markers
  '((((background light))
     (:background "grey85"))
    (((background dark))
     (:background "grey30")))
  "Face for the conflict markers."
  :group 'smerge)
;; backward-compatibility alias
(put 'smerge-markers-face 'face-alias 'smerge-markers)
(defvar smerge-markers-face 'smerge-markers)

(defface smerge-refined-change
  '((t :background "yellow"))
  "Face used for char-based changes shown by `smerge-refine'."
  :group 'smerge)

(easy-mmode-defmap smerge-basic-map
  `(("n" . smerge-next)
    ("p" . smerge-prev)
    ("r" . smerge-resolve)
    ("a" . smerge-keep-all)
    ("b" . smerge-keep-base)
    ("o" . smerge-keep-other)
    ("m" . smerge-keep-mine)
    ("E" . smerge-ediff)
    ("C" . smerge-combine-with-next)
    ("R" . smerge-refine)
    ("\C-m" . smerge-keep-current)
    ("=" . ,(make-sparse-keymap "Diff"))
    ("=<" "base-mine" . smerge-diff-base-mine)
    ("=>" "base-other" . smerge-diff-base-other)
    ("==" "mine-other" . smerge-diff-mine-other))
  "The base keymap for `smerge-mode'.")

(defcustom smerge-command-prefix "\C-c^"
  "Prefix for `smerge-mode' commands."
  :group 'smerge
  :type '(choice (string "\e") (string "\C-c^") (string "") string))

(easy-mmode-defmap smerge-mode-map
  `((,smerge-command-prefix . ,smerge-basic-map))
  "Keymap for `smerge-mode'.")

(defvar smerge-check-cache nil)
(make-variable-buffer-local 'smerge-check-cache)
(defun smerge-check (n)
  (condition-case nil
      (let ((state (cons (point) (buffer-modified-tick))))
	(unless (equal (cdr smerge-check-cache) state)
	  (smerge-match-conflict)
	  (setq smerge-check-cache (cons (match-data) state)))
	(nth (* 2 n) (car smerge-check-cache)))
    (error nil)))

(easy-menu-define smerge-mode-menu smerge-mode-map
  "Menu for `smerge-mode'."
  '("SMerge"
    ["Next" smerge-next :help "Go to next conflict"]
    ["Previous" smerge-prev :help "Go to previous conflict"]
    "--"
    ["Keep All" smerge-keep-all :help "Keep all three versions"
     :active (smerge-check 1)]
    ["Keep Current" smerge-keep-current :help "Use current (at point) version"
     :active (and (smerge-check 1) (> (smerge-get-current) 0))]
    "--"
    ["Revert to Base" smerge-keep-base :help "Revert to base version"
     :active (smerge-check 2)]
    ["Keep Other" smerge-keep-other :help "Keep `other' version"
     :active (smerge-check 3)]
    ["Keep Yours" smerge-keep-mine :help "Keep your version"
     :active (smerge-check 1)]
    "--"
    ["Diff Base/Mine" smerge-diff-base-mine
     :help "Diff `base' and `mine' for current conflict"
     :active (smerge-check 2)]
    ["Diff Base/Other" smerge-diff-base-other
     :help "Diff `base' and `other' for current conflict"
     :active (smerge-check 2)]
    ["Diff Mine/Other" smerge-diff-mine-other
     :help "Diff `mine' and `other' for current conflict"
     :active (smerge-check 1)]
    "--"
    ["Invoke Ediff" smerge-ediff
     :help "Use Ediff to resolve the conflicts"
     :active (smerge-check 1)]
    ["Auto Resolve" smerge-resolve
     :help "Try auto-resolution heuristics"
     :active (smerge-check 1)]
    ["Combine" smerge-combine-with-next
     :help "Combine current conflict with next"
     :active (smerge-check 1)]
    ))

(easy-menu-define smerge-context-menu nil
  "Context menu for mine area in `smerge-mode'."
  '(nil
    ["Keep Current" smerge-keep-current :help "Use current (at point) version"]
    ["Kill Current" smerge-kill-current :help "Remove current (at point) version"]
    ["Keep All" smerge-keep-all :help "Keep all three versions"]
    "---"
    ["More..." (popup-menu smerge-mode-menu) :help "Show full SMerge mode menu"]
    ))

(defconst smerge-font-lock-keywords
  '((smerge-find-conflict
     (1 smerge-mine-face prepend t)
     (2 smerge-base-face prepend t)
     (3 smerge-other-face prepend t)
     ;; FIXME: `keep' doesn't work right with syntactic fontification.
     (0 smerge-markers-face keep)
     (4 nil t t)
     (5 nil t t)))
  "Font lock patterns for `smerge-mode'.")

(defconst smerge-begin-re "^<<<<<<< \\(.*\\)\n")
(defconst smerge-end-re "^>>>>>>> .*\n")
(defconst smerge-base-re "^||||||| .*\n")
(defconst smerge-other-re "^=======\n")

(defvar smerge-conflict-style nil
  "Keep track of which style of conflict is in use.
Can be nil if the style is undecided, or else:
- `diff3-E'
- `diff3-A'")

;; Compiler pacifiers
(defvar font-lock-mode)
(defvar font-lock-keywords)

;;;;
;;;; Actual code
;;;;

;; Define smerge-next and smerge-prev
(easy-mmode-define-navigation smerge smerge-begin-re "conflict" nil nil
  (if smerge-auto-refine
      (condition-case nil (smerge-refine) (error nil))))

(defconst smerge-match-names ["conflict" "mine" "base" "other"])

(defun smerge-ensure-match (n)
  (unless (match-end n)
    (error "No `%s'" (aref smerge-match-names n))))

(defun smerge-auto-leave ()
  (when (and smerge-auto-leave
	     (save-excursion (goto-char (point-min))
			     (not (re-search-forward smerge-begin-re nil t))))
    (when (and (listp buffer-undo-list) smerge-mode)
      (push (list 'apply 'smerge-mode 1) buffer-undo-list))
    (smerge-mode -1)))


(defun smerge-keep-all ()
  "Concatenate all versions."
  (interactive)
  (smerge-match-conflict)
  (let ((mb2 (or (match-beginning 2) (point-max)))
	(me2 (or (match-end 2) (point-min))))
    (delete-region (match-end 3) (match-end 0))
    (delete-region (max me2 (match-end 1)) (match-beginning 3))
    (if (and (match-end 2) (/= (match-end 1) (match-end 3)))
	(delete-region (match-end 1) (match-beginning 2)))
    (delete-region (match-beginning 0) (min (match-beginning 1) mb2))
    (smerge-auto-leave)))

(defun smerge-keep-n (n)
  (smerge-remove-props (match-beginning 0) (match-end 0))
  ;; We used to use replace-match, but that did not preserve markers so well.
  (delete-region (match-end n) (match-end 0))
  (delete-region (match-beginning 0) (match-beginning n)))

(defun smerge-combine-with-next ()
  "Combine the current conflict with the next one."
  (interactive)
  (smerge-match-conflict)
  (let ((ends nil))
    (dolist (i '(3 2 1 0))
      (push (if (match-end i) (copy-marker (match-end i) t)) ends))
    (setq ends (apply 'vector ends))
    (goto-char (aref ends 0))
    (if (not (re-search-forward smerge-begin-re nil t))
	(error "No next conflict")
      (smerge-match-conflict)
      (let ((match-data (mapcar (lambda (m) (if m (copy-marker m)))
				(match-data))))
	;; First copy the in-between text in each alternative.
	(dolist (i '(1 2 3))
	  (when (aref ends i)
	    (goto-char (aref ends i))
	    (insert-buffer-substring (current-buffer)
				     (aref ends 0) (car match-data))))
	(delete-region (aref ends 0) (car match-data))
	;; Then move the second conflict's alternatives into the first.
	(dolist (i '(1 2 3))
	  (set-match-data match-data)
	  (when (and (aref ends i) (match-end i))
	    (goto-char (aref ends i))
	    (insert-buffer-substring (current-buffer)
				     (match-beginning i) (match-end i))))
	(delete-region (car match-data) (cadr match-data))
	;; Free the markers.
	(dolist (m match-data) (if m (move-marker m nil)))
	(mapc (lambda (m) (if m (move-marker m nil))) ends)))))

(defvar smerge-resolve-function
  (lambda () (error "Don't know how to resolve"))
  "Mode-specific merge function.
The function is called with zero or one argument (non-nil if the resolution
function should only apply safe heuristics) and with the match data set
according to `smerge-match-conflict'.")
(add-to-list 'debug-ignored-errors "Don't know how to resolve")

(defvar smerge-text-properties
  `(help-echo "merge conflict: mouse-3 shows a menu"
    ;; mouse-face highlight
    keymap (keymap (down-mouse-3 . smerge-popup-context-menu))))

(defun smerge-remove-props (beg end)
  (remove-overlays beg end 'smerge 'refine)
  (remove-overlays beg end 'smerge 'conflict)
  ;; Now that we use overlays rather than text-properties, this function
  ;; does not cause refontification any more.  It can be seen very clearly
  ;; in buffers where jit-lock-contextually is not t, in which case deleting
  ;; the "<<<<<<< foobar" leading line leaves the rest of the conflict
  ;; highlighted as if it were still a valid conflict.  Note that in many
  ;; important cases (such as the previous example) we're actually called
  ;; during font-locking so inhibit-modification-hooks is non-nil, so we
  ;; can't just modify the buffer and expect font-lock to be triggered as in:
  ;; (put-text-property beg end 'smerge-force-highlighting nil)
  (let ((modified (buffer-modified-p)))
    (remove-text-properties beg end '(fontified nil))
    (restore-buffer-modified-p modified)))

(defun smerge-popup-context-menu (event)
  "Pop up the Smerge mode context menu under mouse."
  (interactive "e")
  (if (and smerge-mode
	   (save-excursion (posn-set-point (event-end event)) (smerge-check 1)))
      (progn
	(posn-set-point (event-end event))
	(smerge-match-conflict)
	(let ((i (smerge-get-current))
	      o)
	  (if (<= i 0)
	      ;; Out of range
	      (popup-menu smerge-mode-menu)
	    ;; Install overlay.
	    (setq o (make-overlay (match-beginning i) (match-end i)))
	    (unwind-protect
		(progn
		  (overlay-put o 'face 'highlight)
		  (sit-for 0)		;Display the new highlighting.
		  (popup-menu smerge-context-menu))
	      ;; Delete overlay.
	      (delete-overlay o)))))
    ;; There's no conflict at point, the text-props are just obsolete.
    (save-excursion
      (let ((beg (re-search-backward smerge-end-re nil t))
	    (end (re-search-forward smerge-begin-re nil t)))
	(smerge-remove-props (or beg (point-min)) (or end (point-max)))
	(push event unread-command-events)))))

(defun smerge-resolve (&optional safe)
  "Resolve the conflict at point intelligently.
This relies on mode-specific knowledge and thus only works in
some major modes.  Uses `smerge-resolve-function' to do the actual work."
  (interactive)
  (smerge-match-conflict)
  (smerge-remove-props (match-beginning 0) (match-end 0))
  (cond
   ;; Trivial diff3 -A non-conflicts.
   ((and (eq (match-end 1) (match-end 3))
	 (eq (match-beginning 1) (match-beginning 3)))
    (smerge-keep-n 3))
   ;; Mode-specific conflict resolution.
   ((condition-case nil
        (atomic-change-group
          (if safe
              (funcall smerge-resolve-function safe)
            (funcall smerge-resolve-function))
          t)
      (error nil))
    ;; Nothing to do: the resolution function has done it already.
    nil)
   ;; FIXME: Add "if [ diff -b MINE OTHER ]; then select OTHER; fi"
   ((and (match-end 2)
	 ;; FIXME: Add "diff -b BASE MINE | patch OTHER".
	 ;; FIXME: Add "diff -b BASE OTHER | patch MINE".
	 nil)
    )
   ((and (not (match-end 2))
	 ;; FIXME: Add "diff -b"-based refinement.
	 nil)
    )
   (t
    (error "Don't know how to resolve")))
  (smerge-auto-leave))

(defun smerge-resolve-all ()
  "Perform automatic resolution on all conflicts."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward smerge-begin-re nil t)
      (condition-case nil
          (progn
            (smerge-match-conflict)
            (smerge-resolve 'safe))
        (error nil)))))

(defun smerge-batch-resolve ()
  ;; command-line-args-left is what is left of the command line.
  (if (not noninteractive)
      (error "`smerge-batch-resolve' is to be used only with -batch"))
  (while command-line-args-left
    (let ((file (pop command-line-args-left)))
      (if (string-match "\\.rej\\'" file)
          ;; .rej files should never contain diff3 markers, on the other hand,
          ;; in Arch, .rej files are sometimes used to indicate that the
          ;; main file has diff3 markers.  So you can pass **/*.rej and
          ;; it will DTRT.
          (setq file (substring file 0 (match-beginning 0))))
      (message "Resolving conflicts in %s..." file)
      (when (file-readable-p file)
        (with-current-buffer (find-file-noselect file)
          (smerge-resolve-all)
          (save-buffer)
          (kill-buffer (current-buffer)))))))

(defun smerge-keep-base ()
  "Revert to the base version."
  (interactive)
  (smerge-match-conflict)
  (smerge-ensure-match 2)
  (smerge-keep-n 2)
  (smerge-auto-leave))

(defun smerge-keep-other ()
  "Use \"other\" version."
  (interactive)
  (smerge-match-conflict)
  ;;(smerge-ensure-match 3)
  (smerge-keep-n 3)
  (smerge-auto-leave))

(defun smerge-keep-mine ()
  "Keep your version."
  (interactive)
  (smerge-match-conflict)
  ;;(smerge-ensure-match 1)
  (smerge-keep-n 1)
  (smerge-auto-leave))

(defun smerge-get-current ()
  (let ((i 3))
    (while (or (not (match-end i))
	       (< (point) (match-beginning i))
	       (>= (point) (match-end i)))
      (decf i))
    i))

(defun smerge-keep-current ()
  "Use the current (under the cursor) version."
  (interactive)
  (smerge-match-conflict)
  (let ((i (smerge-get-current)))
    (if (<= i 0) (error "Not inside a version")
      (smerge-keep-n i)
      (smerge-auto-leave))))

(defun smerge-kill-current ()
  "Remove the current (under the cursor) version."
  (interactive)
  (smerge-match-conflict)
  (let ((i (smerge-get-current)))
    (if (<= i 0) (error "Not inside a version")
      (let ((left nil))
	(dolist (n '(3 2 1))
	  (if (and (match-end n) (/= (match-end n) (match-end i)))
	      (push n left)))
	(if (and (cdr left)
		 (/= (match-end (car left)) (match-end (cadr left))))
	    (ding)			;We don't know how to do that.
	  (smerge-keep-n (car left))
	  (smerge-auto-leave))))))

(defun smerge-diff-base-mine ()
  "Diff 'base' and 'mine' version in current conflict region."
  (interactive)
  (smerge-diff 2 1))

(defun smerge-diff-base-other ()
  "Diff 'base' and 'other' version in current conflict region."
  (interactive)
  (smerge-diff 2 3))

(defun smerge-diff-mine-other ()
  "Diff 'mine' and 'other' version in current conflict region."
  (interactive)
  (smerge-diff 1 3))

(defun smerge-match-conflict ()
  "Get info about the conflict.  Puts the info in the `match-data'.
The submatches contain:
 0:  the whole conflict.
 1:  your code.
 2:  the base code.
 3:  other code.
An error is raised if not inside a conflict."
  (save-excursion
    (condition-case nil
	(let* ((orig-point (point))

	       (_ (forward-line 1))
	       (_ (re-search-backward smerge-begin-re))

	       (start (match-beginning 0))
	       (mine-start (match-end 0))
	       (filename (or (match-string 1) ""))

	       (_ (re-search-forward smerge-end-re))
	       (_ (assert (< orig-point (match-end 0))))

	       (other-end (match-beginning 0))
	       (end (match-end 0))

	       (_ (re-search-backward smerge-other-re start))

	       (mine-end (match-beginning 0))
	       (other-start (match-end 0))

	       base-start base-end)

	  ;; handle the various conflict styles
	  (cond
	   ((save-excursion
	      (goto-char mine-start)
	      (re-search-forward smerge-begin-re end t))
	    ;; There's a nested conflict and we're after the the beginning
	    ;; of the outer one but before the beginning of the inner one.
	    ;; Of course, maybe this is not a nested conflict but in that
	    ;; case it can only be something nastier that we don't know how
	    ;; to handle, so may as well arbitrarily decide to treat it as
	    ;; a nested conflict.  --Stef
	    (error "There is a nested conflict"))

	   ((re-search-backward smerge-base-re start t)
	    ;; a 3-parts conflict
	    (set (make-local-variable 'smerge-conflict-style) 'diff3-A)
	    (setq base-end mine-end)
	    (setq mine-end (match-beginning 0))
	    (setq base-start (match-end 0)))

	   ((string= filename (file-name-nondirectory
			       (or buffer-file-name "")))
	    ;; a 2-parts conflict
	    (set (make-local-variable 'smerge-conflict-style) 'diff3-E))

	   ((and (not base-start)
		 (or (eq smerge-conflict-style 'diff3-A)
		     (equal filename "ANCESTOR")
		     (string-match "\\`[.0-9]+\\'" filename)))
	    ;; a same-diff conflict
	    (setq base-start mine-start)
	    (setq base-end   mine-end)
	    (setq mine-start other-start)
	    (setq mine-end   other-end)))

	  (store-match-data (list start end
				  mine-start mine-end
				  base-start base-end
				  other-start other-end
				  (when base-start (1- base-start)) base-start
				  (1- other-start) other-start))
	  t)
      (search-failed (error "Point not in conflict region")))))

(add-to-list 'debug-ignored-errors "Point not in conflict region")

(defun smerge-conflict-overlay (pos)
  "Return the conflict overlay at POS if any."
  (let ((ols (overlays-at pos))
        conflict)
    (dolist (ol ols)
      (if (and (eq (overlay-get ol 'smerge) 'conflict)
               (> (overlay-end ol) pos))
          (setq conflict ol)))
    conflict))

(defun smerge-find-conflict (&optional limit)
  "Find and match a conflict region.  Intended as a font-lock MATCHER.
The submatches are the same as in `smerge-match-conflict'.
Returns non-nil if a match is found between point and LIMIT.
Point is moved to the end of the conflict."
  (let ((found nil)
        (pos (point))
        conflict)
    ;; First check to see if point is already inside a conflict, using
    ;; the conflict overlays.
    (while (and (not found) (setq conflict (smerge-conflict-overlay pos)))
      ;; Check the overlay's validity and kill it if it's out of date.
      (condition-case nil
          (progn
            (goto-char (overlay-start conflict))
            (smerge-match-conflict)
            (goto-char (match-end 0))
            (if (<= (point) pos)
                (error "Matching backward!")
              (setq found t)))
        (error (smerge-remove-props
                (overlay-start conflict) (overlay-end conflict))
               (goto-char pos))))
    ;; If we're not already inside a conflict, look for the next conflict
    ;; and add/update its overlay.
    (while (and (not found) (re-search-forward smerge-begin-re limit t))
      (condition-case nil
          (progn
            (smerge-match-conflict)
            (goto-char (match-end 0))
            (let ((conflict (smerge-conflict-overlay (1- (point)))))
              (if conflict
                  ;; Update its location, just in case it got messed up.
                  (move-overlay conflict (match-beginning 0) (match-end 0))
                (setq conflict (make-overlay (match-beginning 0) (match-end 0)
                                             nil 'front-advance nil))
                (overlay-put conflict 'evaporate t)
                (overlay-put conflict 'smerge 'conflict)
                (let ((props smerge-text-properties))
                  (while props
                    (overlay-put conflict (pop props) (pop props))))))
            (setq found t))
        (error nil)))
    found))

;;; Refined change highlighting

(defvar smerge-refine-forward-function 'smerge-refine-forward
  "Function used to determine an \"atomic\" element.
You can set it to `forward-char' to get char-level granularity.
Its behavior has mainly two restrictions:
- if this function encounters a newline, it's important that it stops right
  after the newline.
  This only matters if `smerge-refine-ignore-whitespace' is nil.
- it needs to be unaffected by changes performed by the `preproc' argument
  to `smerge-refine-subst'.
  This only matters if `smerge-refine-weight-hack' is nil.")

(defvar smerge-refine-ignore-whitespace t
  "If non-nil,Indicate that smerge-refine should try to ignore change in whitespace.")

(defvar smerge-refine-weight-hack t
  "If non-nil, pass to diff as many lines as there are chars in the region.
I.e. each atomic element (e.g. word) will be copied as many times (on different
lines) as it has chars.  This has 2 advantages:
- if `diff' tries to minimize the number *lines* (rather than chars)
  added/removed, this adjust the weights so that adding/removing long
  symbols is considered correspondingly more costly.
- `smerge-refine-forward-function' only needs to be called when chopping up
  the regions, and `forward-char' can be used afterwards.
It has the following disadvantages:
- cannot use `diff -w' because the weighting causes added spaces in a line
  to be represented as added copies of some line, so `diff -w' can't do the
  right thing any more.
- may in degenerate cases take a 1KB input region and turn it into a 1MB
  file to pass to diff.")

(defun smerge-refine-forward (n)
  (let ((case-fold-search nil)
        (re "[[:upper:]]?[[:lower:]]+\\|[[:upper:]]+\\|[[:digit:]]+\\|.\\|\n"))
    (when (and smerge-refine-ignore-whitespace
               ;; smerge-refine-weight-hack causes additional spaces to
               ;; appear as additional lines as well, so even if diff ignore
               ;; whitespace changes, it'll report added/removed lines :-(
               (not smerge-refine-weight-hack))
      (setq re (concat "[ \t]*\\(?:" re "\\)")))
    (dotimes (i n)
      (unless (looking-at re) (error "Smerge refine internal error"))
      (goto-char (match-end 0)))))

(defun smerge-refine-chopup-region (beg end file &optional preproc)
  "Chopup the region into small elements, one per line.
Save the result into FILE.
If non-nil, PREPROC is called with no argument in a buffer that contains
a copy of the text, just before chopping it up.  It can be used to replace
chars to try and eliminate some spurious differences."
  ;; We used to chop up char-by-char rather than word-by-word like ediff
  ;; does.  It had the benefit of simplicity and very fine results, but it
  ;; often suffered from problem that diff would find correlations where
  ;; there aren't any, so the resulting "change" didn't make much sense.
  ;; You can still get this behavior by setting
  ;; `smerge-refine-forward-function' to `forward-char'.
  (let ((buf (current-buffer)))
    (with-temp-buffer
      (insert-buffer-substring buf beg end)
      (when preproc (goto-char (point-min)) (funcall preproc))
      (when smerge-refine-ignore-whitespace
        ;; It doesn't make much of a difference for diff-fine-highlight
        ;; because we still have the _/+/</>/! prefix anyway.  Can still be
        ;; useful in other circumstances.
        (subst-char-in-region (point-min) (point-max) ?\n ?\s))
      (goto-char (point-min))
      (while (not (eobp))
        (funcall smerge-refine-forward-function 1)
        (let ((s (if (prog2 (forward-char -1) (bolp) (forward-char 1))
                     nil
                   (buffer-substring (line-beginning-position) (point)))))
          ;; We add \n after each char except after \n, so we get
          ;; one line per text char, where each line contains
          ;; just one char, except for \n chars which are
          ;; represented by the empty line.
          (unless (eq (char-before) ?\n) (insert ?\n))
          ;; HACK ALERT!!
          (if smerge-refine-weight-hack
              (dotimes (i (1- (length s))) (insert s "\n")))))
      (unless (bolp) (error "Smerge refine internal error"))
      (let ((coding-system-for-write 'emacs-mule))
        (write-region (point-min) (point-max) file nil 'nomessage)))))

(defun smerge-refine-highlight-change (buf beg match-num1 match-num2 props)
  (with-current-buffer buf
    (goto-char beg)
    (let* ((startline (- (string-to-number match-num1) 1))
           (beg (progn (funcall (if smerge-refine-weight-hack
                                    'forward-char
                                  smerge-refine-forward-function)
                                startline)
                       (point)))
           (end (progn (funcall (if smerge-refine-weight-hack
                                    'forward-char
                                  smerge-refine-forward-function)
                          (if match-num2
                              (- (string-to-number match-num2)
                                 startline)
                            1))
                       (point))))
      (when smerge-refine-ignore-whitespace
        (skip-chars-backward " \t\n" beg) (setq end (point))
        (goto-char beg)
        (skip-chars-forward " \t\n" end)  (setq beg (point)))
      (when (> end beg)
        (let ((ol (make-overlay
                   beg end nil
                   ;; Make them tend to shrink rather than spread when editing.
                   'front-advance nil)))
          (overlay-put ol 'evaporate t)
          (dolist (x props) (overlay-put ol (car x) (cdr x)))
          ol)))))

(defun smerge-refine-subst (beg1 end1 beg2 end2 props &optional preproc)
  "Show fine differences in the two regions BEG1..END1 and BEG2..END2.
PROPS is an alist of properties to put (via overlays) on the changes.
If non-nil, PREPROC is called with no argument in a buffer that contains
a copy of a region, just before preparing it to for `diff'.  It can be used to
replace chars to try and eliminate some spurious differences."
  (let* ((buf (current-buffer))
         (pos (point))
         (file1 (make-temp-file "diff1"))
         (file2 (make-temp-file "diff2")))
    ;; Chop up regions into smaller elements and save into files.
    (smerge-refine-chopup-region beg1 end1 file1 preproc)
    (smerge-refine-chopup-region beg2 end2 file2 preproc)

    ;; Call diff on those files.
    (unwind-protect
        (with-temp-buffer
          (let ((coding-system-for-read 'emacs-mule))
            (call-process diff-command nil t nil
                          (if (and smerge-refine-ignore-whitespace
                                   (not smerge-refine-weight-hack))
                              ;; Pass -a so diff treats it as a text file even
                              ;; if it contains \0 and such.
                              ;; Pass -d so as to get the smallest change, but
                              ;; also and more importantly because otherwise it
                              ;; may happen that diff doesn't behave like
                              ;; smerge-refine-weight-hack expects it to.
                              ;; See http://thread.gmane.org/gmane.emacs.devel/82685.
                              "-awd" "-ad")
                          file1 file2))
          ;; Process diff's output.
          (goto-char (point-min))
          (let ((last1 nil)
                (last2 nil))
            (while (not (eobp))
              (if (not (looking-at "\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)?\\([acd]\\)\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)?$"))
                  (error "Unexpected patch hunk header: %s"
                         (buffer-substring (point) (line-end-position))))
              (let ((op (char-after (match-beginning 3)))
                    (m1 (match-string 1))
                    (m2 (match-string 2))
                    (m4 (match-string 4))
                    (m5 (match-string 5)))
                (when (memq op '(?d ?c))
                  (setq last1
                        (smerge-refine-highlight-change buf beg1 m1 m2 props)))
                (when (memq op '(?a ?c))
                  (setq last2
                        (smerge-refine-highlight-change buf beg2 m4 m5 props))))
              (forward-line 1)                            ;Skip hunk header.
              (and (re-search-forward "^[0-9]" nil 'move) ;Skip hunk body.
                   (goto-char (match-beginning 0))))
            ;; (assert (or (null last1) (< (overlay-start last1) end1)))
            ;; (assert (or (null last2) (< (overlay-start last2) end2)))
            (if smerge-refine-weight-hack
                (progn
                  ;; (assert (or (null last1) (<= (overlay-end last1) end1)))
                  ;; (assert (or (null last2) (<= (overlay-end last2) end2)))
                  )
              ;; smerge-refine-forward-function when calling in chopup may
              ;; have stopped because it bumped into EOB whereas in
              ;; smerge-refine-weight-hack it may go a bit further.
              (if (and last1 (> (overlay-end last1) end1))
                  (move-overlay last1 (overlay-start last1) end1))
              (if (and last2 (> (overlay-end last2) end2))
                  (move-overlay last2 (overlay-start last2) end2))
              )))
      (goto-char pos)
      (delete-file file1)
      (delete-file file2))))

(defun smerge-refine ()
  "Highlight the parts of the conflict that are different."
  (interactive)
  ;; FIXME: make it work with 3-way conflicts.
  (smerge-match-conflict)
  (remove-overlays (match-beginning 0) (match-end 0) 'smerge 'refine)
  (smerge-ensure-match 1)
  (smerge-ensure-match 3)
  (smerge-refine-subst (match-beginning 1) (match-end 1)
                       (match-beginning 3) (match-end 3)
                       '((smerge . refine)
                         (face . smerge-refined-change))))

(defun smerge-diff (n1 n2)
  (smerge-match-conflict)
  (smerge-ensure-match n1)
  (smerge-ensure-match n2)
  (let ((name1 (aref smerge-match-names n1))
	(name2 (aref smerge-match-names n2))
	;; Read them before the match-data gets clobbered.
	(beg1 (match-beginning n1))
	(end1 (match-end n1))
	(beg2 (match-beginning n2))
	(end2 (match-end n2))
	(file1 (make-temp-file "smerge1"))
	(file2 (make-temp-file "smerge2"))
	(dir default-directory)
	(file (if buffer-file-name (file-relative-name buffer-file-name)))
        ;; We would want to use `emacs-mule-unix' for read&write, but we
        ;; bump into problems with the coding-system used by diff to write
        ;; the file names and the time stamps in the header.
        ;; `buffer-file-coding-system' is not always correct either, but if
        ;; the OS/user uses only one coding-system, then it works.
	(coding-system-for-read buffer-file-coding-system))
    (write-region beg1 end1 file1 nil 'nomessage)
    (write-region beg2 end2 file2 nil 'nomessage)
    (unwind-protect
	(with-current-buffer (get-buffer-create smerge-diff-buffer-name)
	  (setq default-directory dir)
	  (let ((inhibit-read-only t))
	    (erase-buffer)
	    (let ((status
		   (apply 'call-process diff-command nil t nil
			  (append smerge-diff-switches
				  (list "-L" (concat name1 "/" file)
					"-L" (concat name2 "/" file)
					file1 file2)))))
	      (if (eq status 0) (insert "No differences found.\n"))))
	  (goto-char (point-min))
	  (diff-mode)
	  (display-buffer (current-buffer) t))
      (delete-file file1)
      (delete-file file2))))

;; compiler pacifiers
(defvar smerge-ediff-windows)
(defvar smerge-ediff-buf)
(defvar ediff-buffer-A)
(defvar ediff-buffer-B)
(defvar ediff-buffer-C)
(defvar ediff-ancestor-buffer)
(defvar ediff-quit-hook)
(declare-function ediff-cleanup-mess "ediff-util" nil)

;;;###autoload
(defun smerge-ediff (&optional name-mine name-other name-base)
  "Invoke ediff to resolve the conflicts.
NAME-MINE, NAME-OTHER, and NAME-BASE, if non-nil, are used for the
buffer names."
  (interactive)
  (let* ((buf (current-buffer))
	 (mode major-mode)
	 ;;(ediff-default-variant 'default-B)
	 (config (current-window-configuration))
	 (filename (file-name-nondirectory buffer-file-name))
	 (mine (generate-new-buffer
		(or name-mine (concat "*" filename " MINE*"))))
	 (other (generate-new-buffer
		 (or name-other (concat "*" filename " OTHER*"))))
	 base)
    (with-current-buffer mine
      (buffer-disable-undo)
      (insert-buffer-substring buf)
      (goto-char (point-min))
      (while (smerge-find-conflict)
	(when (match-beginning 2) (setq base t))
	(smerge-keep-n 1))
      (buffer-enable-undo)
      (set-buffer-modified-p nil)
      (funcall mode))

    (with-current-buffer other
      (buffer-disable-undo)
      (insert-buffer-substring buf)
      (goto-char (point-min))
      (while (smerge-find-conflict)
	(smerge-keep-n 3))
      (buffer-enable-undo)
      (set-buffer-modified-p nil)
      (funcall mode))

    (when base
      (setq base (generate-new-buffer
		  (or name-base (concat "*" filename " BASE*"))))
      (with-current-buffer base
	(buffer-disable-undo)
	(insert-buffer-substring buf)
	(goto-char (point-min))
	(while (smerge-find-conflict)
	  (if (match-end 2)
	      (smerge-keep-n 2)
	    (delete-region (match-beginning 0) (match-end 0))))
	(buffer-enable-undo)
	(set-buffer-modified-p nil)
	(funcall mode)))

    ;; the rest of the code is inspired from vc.el
    ;; Fire up ediff.
    (set-buffer
     (if base
	 (ediff-merge-buffers-with-ancestor mine other base)
	  ;; nil 'ediff-merge-revisions-with-ancestor buffer-file-name)
       (ediff-merge-buffers mine other)))
        ;; nil 'ediff-merge-revisions buffer-file-name)))

    ;; Ediff is now set up, and we are in the control buffer.
    ;; Do a few further adjustments and take precautions for exit.
    (set (make-local-variable 'smerge-ediff-windows) config)
    (set (make-local-variable 'smerge-ediff-buf) buf)
    (set (make-local-variable 'ediff-quit-hook)
	 (lambda ()
	   (let ((buffer-A ediff-buffer-A)
		 (buffer-B ediff-buffer-B)
		 (buffer-C ediff-buffer-C)
		 (buffer-Ancestor ediff-ancestor-buffer)
		 (buf smerge-ediff-buf)
		 (windows smerge-ediff-windows))
	     (ediff-cleanup-mess)
	     (with-current-buffer buf
	       (erase-buffer)
	       (insert-buffer-substring buffer-C)
	       (kill-buffer buffer-A)
	       (kill-buffer buffer-B)
	       (kill-buffer buffer-C)
	       (when (bufferp buffer-Ancestor) (kill-buffer buffer-Ancestor))
	       (set-window-configuration windows)
	       (message "Conflict resolution finished; you may save the buffer")))))
    (message "Please resolve conflicts now; exit ediff when done")))


(defconst smerge-parsep-re
  (concat smerge-begin-re "\\|" smerge-end-re "\\|"
          smerge-base-re "\\|" smerge-other-re "\\|"))

;;;###autoload
(define-minor-mode smerge-mode
  "Minor mode to simplify editing output from the diff3 program.
\\{smerge-mode-map}"
  :group 'smerge :lighter " SMerge"
  (when (and (boundp 'font-lock-mode) font-lock-mode)
    (save-excursion
      (if smerge-mode
	  (font-lock-add-keywords nil smerge-font-lock-keywords 'append)
	(font-lock-remove-keywords nil smerge-font-lock-keywords))
      (goto-char (point-min))
      (while (smerge-find-conflict)
	(save-excursion
	  (font-lock-fontify-region (match-beginning 0) (match-end 0) nil)))))
  (if (string-match (regexp-quote smerge-parsep-re) paragraph-separate)
      (unless smerge-mode
        (set (make-local-variable 'paragraph-separate)
             (replace-match "" t t paragraph-separate)))
    (when smerge-mode
        (set (make-local-variable 'paragraph-separate)
             (concat smerge-parsep-re paragraph-separate))))
  (unless smerge-mode
    (smerge-remove-props (point-min) (point-max))))

;;;###autoload
(defun smerge-auto ()
  "Turn on `smerge-mode' and move point to first conflict marker.
If no conflict maker is found, turn off `smerge-mode'."
  (smerge-mode 1)
  (condition-case nil
      (smerge-next)
    (error (smerge-auto-leave))))

(provide 'smerge-mode)

;; arch-tag: 605c8d1e-e43d-4943-a6f3-1bcc4333e690
;;; smerge-mode.el ends here
