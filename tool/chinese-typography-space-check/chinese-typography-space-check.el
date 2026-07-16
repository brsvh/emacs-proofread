#!/usr/bin/env -S emacs --quick --script
;;; chinese-typography-space-check.el --- Check Chinese typography spacing  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This internal tool reports unexpected horizontal whitespace between
;; Chinese semantic units in the literal contents of one or more files.
;; It does not parse Markdown or modify its inputs.

;;; Code:

(defconst chinese-typography-space-check--horizontal-space-regexp
  "[ \t\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+"
  "Regexp matching one run of supported horizontal whitespace.")

(defconst chinese-typography-space-check--punctuation
  (concat
   "、。，．！？；：…—～〜·・‘’“”"
   "〈〉《》「」『』【】〔〕〖〗〘〙〚〛"
   "（）［］｛｝｡､"
   "\u2329\u232a\U00016FE2")
  "Chinese punctuation recognized beyond Unicode CJK punctuation.")

(defun chinese-typography-space-check--punctuation-p (character)
  "Return non-nil when CHARACTER is CJK punctuation."
  (and character
       (or
        (string-match-p
         (regexp-quote (char-to-string character))
         chinese-typography-space-check--punctuation)
        (and
         (memq
          (get-char-code-property character 'general-category)
          '(Pc Pd Pe Pf Pi Po Ps))
         (or
          (memq (aref char-script-table character)
                '(cjk-misc han kana vertical-form))
          (<= #xFE50 character #xFE6F))))))

(defun chinese-typography-space-check--semantic-unit-p (character)
  "Return non-nil when CHARACTER is Han text or CJK punctuation."
  (when character
    (let ((general-category
           (get-char-code-property character 'general-category)))
      (or
       (and
        (not (eq general-category 'Cn))
        (or (aref (char-category-set character) ?C)
            (and
             (eq (aref char-script-table character) 'han)
             (eq general-category 'Lo))))
       (chinese-typography-space-check--punctuation-p character)))))

(defun chinese-typography-space-check--code-points (text)
  "Return the Unicode code points in TEXT as a display string."
  (mapconcat
   (lambda (character)
     (format "U+%04X" character))
   (string-to-list text)
   " "))

(defun chinese-typography-space-check--report
    (file line column begin end left right)
  "Report FILE whitespace at LINE and COLUMN from BEGIN to END.
LEFT and RIGHT are the surrounding Chinese semantic units."
  (let ((whitespace (buffer-substring-no-properties begin end)))
    (princ
     (format
      (concat "%s:%d:%d: CJK horizontal-whitespace anomaly: "
              "%s between U+%04X and U+%04X\n")
      file line column
      (chinese-typography-space-check--code-points whitespace)
      left right)
     'external-debugging-output)))

(defun chinese-typography-space-check--check-buffer (file)
  "Check the current buffer and report findings for FILE."
  (save-excursion
    (goto-char (point-min))
    (let ((findings 0)
          (line 1)
          (line-begin (point-min))
          (report-cursor (point-min)))
      (while
          (re-search-forward
           chinese-typography-space-check--horizontal-space-regexp
           nil t)
        (let* ((begin (match-beginning 0))
               (end (match-end 0))
               (left (char-before begin))
               (right (char-after end)))
          (when
              (and
               (chinese-typography-space-check--semantic-unit-p left)
               (chinese-typography-space-check--semantic-unit-p right))
            (save-excursion
              (goto-char report-cursor)
              (while (search-forward "\n" begin t)
                (setq line (1+ line))
                (setq line-begin (point))))
            (setq report-cursor end)
            (setq findings (1+ findings))
            (chinese-typography-space-check--report
             file line (1+ (- begin line-begin))
             begin end left right))))
      findings)))

(defun chinese-typography-space-check--check-file (file)
  "Check FILE and return its number of typography findings."
  (cond
   ((not (file-exists-p file))
    (error "File does not exist"))
   ((not (file-regular-p file))
    (error "Not a regular file"))
   ((not (file-readable-p file))
    (error "File is not readable")))
  (with-temp-buffer
    (insert-file-contents file)
    (chinese-typography-space-check--check-buffer file)))

(defun chinese-typography-space-check-main ()
  "Check files named by the remaining command-line arguments."
  (let ((files command-line-args-left)
        (findings 0)
        (input-errors 0))
    (setq command-line-args-left nil)
    (if (null files)
        (progn
          (princ
           (concat
            "Usage: chinese-typography-space-check FILE [FILE ...]\n")
           'external-debugging-output)
          2)
      (dolist (file files)
        (condition-case error-data
            (setq findings
                  (+ findings
                     (chinese-typography-space-check--check-file file)))
          (error
           (setq input-errors (1+ input-errors))
           (princ
            (format "%s: error: %s\n"
                    file (error-message-string error-data))
            'external-debugging-output))))
      (cond
       ((> input-errors 0) 2)
       ((> findings 0) 1)
       (t 0)))))

(defun chinese-typography-space-check--script-invocation-p ()
  "Return non-nil when this file is the `--script' entry point."
  (let ((script (cadr (member "-scriptload" command-line-args))))
    (and load-file-name
         script
         (file-equal-p load-file-name script))))

(when (chinese-typography-space-check--script-invocation-p)
  (kill-emacs (chinese-typography-space-check-main)))

(provide 'chinese-typography-space-check)
;;; chinese-typography-space-check.el ends here
