;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.
  (concat "Index: \\|Prereq: \\|=\\{20,\\}\\|" ; SVN
    (save-restriction
      (widen)
      (unless (looking-at diff-file-header-re)
        (or (ignore-errors (diff-beginning-of-file))
	    (re-search-forward diff-file-header-re nil t)))
      (let ((fs (diff-hunk-file-names old)))
        (if prefix (setq fs (mapcar (lambda (f) (concat prefix f)) fs)))
        (or
         ;; use any previously used preference
         (cdr (assoc fs diff-remembered-files-alist))
         ;; try to be clever and use previous choices as an inspiration
         (cl-dolist (rf diff-remembered-files-alist)
	   (let ((newfile (diff-merge-strings (caar rf) (car fs) (cdr rf))))
	     (if (and newfile (file-exists-p newfile)) (cl-return newfile))))
         ;; look for each file in turn.  If none found, try again but
         ;; ignoring the first level of directory, ...
         (cl-do* ((files fs (delq nil (mapcar 'diff-filename-drop-dir files)))
                  (file nil nil))
	     ((or (null files)
		  (setq file (cl-do* ((files files (cdr files))
                                      (file (car files) (car files)))
			         ;; Use file-regular-p to avoid
			         ;; /dev/null, directories, etc.
			         ((or (null file) (file-regular-p file))
				  file))))
	      file))
         ;; <foo>.rej patches implicitly apply to <foo>
         (and (string-match "\\.rej\\'" (or buffer-file-name ""))
	      (let ((file (substring buffer-file-name 0 (match-beginning 0))))
	        (when (file-exists-p file) file)))
         ;; If we haven't found the file, maybe it's because we haven't paid
         ;; attention to the PCL-CVS hint.
         (and (not prefix)
	      (boundp 'cvs-pcl-cvs-dirchange-re)
	      (save-excursion
	        (re-search-backward cvs-pcl-cvs-dirchange-re nil t))
	      (diff-find-file-name old noprompt (match-string 1)))
         ;; if all else fails, ask the user
         (unless noprompt
           (let ((file (expand-file-name (or (car fs) ""))))
	     (setq file
		   (read-file-name (format "Use file %s: " file)
				   (file-name-directory file) file t
				   (file-name-nondirectory file)))
             (set (make-local-variable 'diff-remembered-files-alist)
                  (cons (cons fs file) diff-remembered-files-alist))
             file)))))))