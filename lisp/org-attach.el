;;; org-attach.el --- Manage file attachments to org-mode tasks

;; Copyright (C) 2008 Free Software Foundation, Inc.

;; Author: John Wiegley <johnw@newartisans.com>
;; Keywords: org data task
;; Version: 6.08-pre01

;; This file is part of GNU Emacs.
;;
;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; See the Org-mode manual for information on how to use it.
;;
;; Attachments are managed in a special directory called "data", which
;; lives in the directory given by `org-directory'.  If this data
;; directory is initialized as a Git repository, then org-attach will
;; automatically commit changes when it sees them.
;;
;; Attachment directories are identified using a UUID generated for the
;; task which has the attachments.  These are added as property to the
;; task when necessary, and should not be deleted or changed by the
;; user, ever.  UUIDs are generated by a mechanism defined in the variable
;; `org-id-method'.

;; Ideas:  Store region or kill as an attachment.
;;         Support drag-and-drop 

(eval-when-compile
  (require 'cl))
(require 'org-id)
(require 'org)

(defgroup org-attach nil
  "Options concerning entry attachments in Org-mode."
  :tag "Org Remember"
  :group 'org)

(defcustom org-attach-directory "data/"
  "The directory where attachments are stored.
If this is a relative path, it will be interpreted relative to the directory
where the Org file lives."
  :group 'org-attach
  :type 'direcory)

(defcustom org-attach-expert nil
  "Non-nil means do not show the splash buffer with the attach dispatcher."
  :group 'org-attach
  :type 'boolean)

;;;###autoload
(defun org-attach ()
  "The dispatcher for attachment commands.
Shows a list of commands and prompts for another key to execute a command."
  (interactive)
  (let (c marker)
    (when (eq major-mode 'org-agenda-mode)
      (setq marker (or (get-text-property (point) 'org-hd-marker)
		       (get-text-property (point) 'org-marker)))
      (unless marker
	(error "No task in current line")))
    (save-excursion
      (when marker
	(set-buffer (marker-buffer marker))
	(goto-char marker))
      (org-back-to-heading t)
      (save-excursion
	(save-window-excursion
	  (unless org-attach-expert
	    (with-output-to-temp-buffer "*Org Attach*"
	      (princ "Select an Attachment Command:

a    Select a file and move it into the task's attachment  directory.
c    Create a new attachment, as an Emacs buffer.
z    Synchronize the current task with its attachment
     directory, in case you added attachments yourself.

o    Open current task's attachments.
O    Like \"o\", but force opening in Emacs.
f    Open current task's attachment directory.
F    Like \"f\", but force using dired in Emacs.

D    Delete all of a task's attachments.  A safer way is
     to open the directory in dired and delete from there.")))
	  (shrink-window-if-larger-than-buffer (get-buffer-window "*Org Attach*"))
	  (message "Select command: [azoOfFD^a]")
	  (setq c (read-char-exclusive))
	  (and (get-buffer "*Org Attach*") (kill-buffer "*Org Attach*"))))
      (cond
       ((memq c '(?a ?\C-a)) (call-interactively 'org-attach-attach))
       ((memq c '(?c ?\C-c)) (call-interactively 'org-attach-new))
       ((memq c '(?z ?\C-z)) (call-interactively 'org-attach-sync))
       ((memq c '(?o ?\C-o)) (call-interactively 'org-attach-open))
       ((eq c ?O)            (call-interactively 'org-attach-open-in-emacs))
       ((memq c '(?f ?\C-f)) (call-interactively 'org-attach-reveal))
       ((memq c '(?F))       (call-interactively 'org-attach-reveal-in-emacs))
       ((eq c ?D)            (call-interactively 'org-attach-delete))
       (t (error "No such attachment command %c" c))))))

(defun org-attach-dir (&optional create-if-not-exists-p)
  "Return the directory associated with the current entry.
If the directory does not exist and CREATE-IF-NOT-EXISTS-P is non-nil,
the directory and the corresponding ID will be created."
  (let ((uuid (org-id-get (point) create-if-not-exists-p)))
    (when (or uuid create-if-not-exists-p)
      (unless uuid
	(let ((uuid-string (shell-command-to-string "uuidgen")))
	  (setf uuid-string
		(substring uuid-string 0 (1- (length uuid-string))))
	  (org-entry-put (point) "ID" uuid-string)
	  (setf uuid uuid-string)))
      (let ((attach-dir (expand-file-name
			 (format "%s/%s"
				 (substring uuid 0 2)
				 (substring uuid 2))
			 (expand-file-name org-attach-directory))))
	(if (and create-if-not-exists-p
		 (not (file-directory-p attach-dir)))
	    (make-directory attach-dir t))
	(and (file-exists-p attach-dir)
	     attach-dir)))))

(defun org-attach-commit ()
  "Commit changes to git if available."
  (let ((dir (expand-file-name org-attach-directory)))
    (if (file-exists-p (expand-file-name ".git" dir))
	(shell-command
	 (concat "(cd " dir "; "
		 " git add .; "
		 " git ls-files --deleted -z | xargs -0 git rm; "
		 " git commit -m 'Synchronized attachments')")))))
  
(defun org-attach-attach (file &optional visit-dir)
  "Move FILE into the attachment directory of the current task.
If VISIT-DIR is non-nil, visit the direcory with dired."
  (interactive "fFile to keep as an attachment: \nP")
  (let ((basename (file-name-nondirectory file)))
    (org-entry-add-to-multivalued-property (point) "Attachments"
					   basename)
    (let ((attach-dir (org-attach-dir t)))
      (rename-file file (expand-file-name basename attach-dir))
      (org-attach-commit)
      (if visit-dir
	  (dired attach-dir)
	(message "File \"%s\" is now a task attachment." basename)))))

(defun org-attach-new (file)
  "Create a new attachment FILE for the current task.
The attachment is created as an Emacs buffer."
  (interactive "sCreate attachment named: ")
  (org-entry-add-to-multivalued-property (point) "Attachments"
					 file)
  (let ((attach-dir (org-attach-dir t)))
    (find-file (expand-file-name file attach-dir))
    (message "New attachment %s" file)))

(defun org-attach-delete ()
  "Delete all attachments from the current task.
A safer way is to open the directory in dired and delete from there."
  (interactive)
  (org-entry-delete (point) "Attachments")
  (let ((attach-dir (org-attach-dir)))
    (if attach-dir
	(shell-command (format "rm -fr %s" attach-dir))))
  (org-attach-commit))

(defun org-attach-sync ()
  "Synchonize the current tasks with its attachments.
This can be used after files have been added externally."
  (interactive)
  (org-attach-commit)
  (org-entry-delete (point) "Attachments")
  (let ((attach-dir (org-attach-dir)))
    (when attach-dir
      (let ((files (directory-files attach-dir)))
	(dolist (file files)
	  (unless (string-match "^\\." file)
	    (org-entry-add-to-multivalued-property
	     (point) "Attachments" file)))))))

(defun org-attach-reveal ()
  "Show the attachment directory of the current task in dired."
  (interactive)
  (let ((attach-dir (org-attach-dir t)))
    (org-open-file attach-dir)))

(defun org-attach-reveal-in-emacs ()
  "Show the attachment directory of the current task.
This will attempt to use an external program to show the directory."
  (interactive)
  (let ((attach-dir (org-attach-dir t)))
    (dired attach-dir)))

(defun org-attach-open (&optional in-emacs)
  "Open an attachment of the current task.
If there are more than one attachment, you will be prompted for the file name.
This command will open the file using the settings in `org-file-apps'
and in the system-specific variants of this variable.
If IN-EMACS is non-nil, force opening in Emacs."
  (interactive "P")
  (let* ((attach-dir (org-attach-dir t))
	 (files (org-entry-get-multivalued-property (point) "Attachments"))
	 (file (if (= (length files) 1)
		   (car files)
		 (completing-read "Attachment: " (mapcar 'list files) nil t))))
    (org-open-file (expand-file-name file attach-dir) in-emacs)))

(defun org-attach-open-in-emacs ()
  "Open attachment, force opening in Emacs.
See `org-attach-open'."
  (org-attach-open 'in-emacs))


(defun org-attach-open-single-attachment (&optional in-emacs)
  (interactive)
  (let* ((attach-dir (org-attach-dir t))
	 (file (read-file-name "Attachment: " attach-dir nil t)))
    (org-open-file file in-emacs)))
  

(provide 'org-attach)

;;; org-attach.el ends here
