;; rings -- rainbow indentation for Helix, after indent-rainbow /
;; indent-rainbowline.nvim: each indent level is a faintly tinted band with a
;; thin guide line at its left edge, the bands carry on across blank lines,
;; and the guide of the block the cursor is in is brighter. Named for tree
;; rings.
;;
;; Draws with the plugin overlay API (helix-overlays patch):
;; * set-overlays!  replaces the leading-space graphemes of a line: "▏" at a
;;   level's first column, " " on the rest of its band;
;; * set-inline-annotations!  inserts the bands into blank lines, which have
;;   no graphemes to replace (the cursor on such a line sits after them).
;; Helix's own guides are turned off while rings runs.
;;
;; Theme scopes, N = 1..*colors* (cycled per level):
;;   ui.virtual.indent-guide.N         guide line: fg (line) + bg (band)
;;   ui.virtual.indent-band.N          rest of the band: bg
;;   ui.virtual.indent-guide.active.N  the cursor block's guide (falls back to
;;                                     ui.virtual.indent-guide.active)
;; Without bg in the theme this degrades to plain coloured lines.
;;
;;   (require "rings/rings.scm")
;;   (rings-start!)
;;
;; Tab-indented lines get no bands.

(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/configuration.scm")
(require-builtin helix/core/text as text.)

(provide rings-start!
         rings-stop!
         rings-configure!
         rings-refresh)

;;;; configuration

(define *char* "▏")
(define *colors* 4)
(define *skip* 0) ; leading levels with no band, like indent-guides.skip-levels
(define *max-lines* 10000)
(define *max-depth* 16) ; blank-line layers kept per absolute level
(define *enabled* #f)

;;@doc
;; Configure rings: #:char (guide text, one cell), #:colors (number of
;; colours before cycling), #:skip (leading levels without a band),
;; #:max-lines (bigger files are left alone)
(define (rings-configure! #:char (ch #f) #:colors (colors #f) #:skip (skip #f) #:max-lines (max-lines #f))
  (when ch (set! *char* ch))
  (when colors (set! *colors* colors))
  (when skip (set! *skip* skip))
  (when max-lines (set! *max-lines* max-lines)))

(define (color k) (number->string (+ 1 (modulo k *colors*))))
(define (guide-scope k) (string-append "ui.virtual.indent-guide." (color k)))
(define (band-scope k) (string-append "ui.virtual.indent-band." (color k)))
(define (active-scope k) (string-append "ui.virtual.indent-guide.active." (color k)))
;; Inline layers are keyed by scope and render in creation order, so blank
;; lines get one layer per absolute level ("....guide.2.5" falls back to
;; "....guide.2" in the theme), always set in ascending order.
(define (blank-scope k)
  (if (< k *skip*)
      ;; padding for a skipped level: a scope no theme defines, so unstyled
      (string-append "rings.pad." (number->string k))
      (string-append (guide-scope k) "." (number->string k))))
;; Its twin for the cursor's block, created right after it so the two
;; share a slot in the layer order (only one holds a given blank line).
(define (blank-active-scope k)
  (string-append (active-scope k) "." (number->string k)))
;; Blank-line text for level k: the band, or plain padding for skipped levels.
(define (blank-text k width)
  (if (< k *skip*)
      (make-string width #\space)
      (string-append *char* (make-string (- width 1) #\space))))

;;;; reading the document

;; (indent . kind) for a line: kind is 'blank, 'tab (leading tab: skipped)
;; or 'text; indent counts leading spaces.
(define (line-info rope i)
  (let ([s (text.rope->string (text.rope->line rope i))])
    (let loop ([j 0])
      (cond
        [(>= j (string-length s)) (cons j 'blank)]
        [else
         (let ([c (string-ref s j)])
           (cond
             [(equal? c #\space) (loop (+ j 1))]
             [(equal? c #\tab) (cons j 'tab)]
             [(or (equal? c #\newline) (equal? c #\return)) (cons j 'blank)]
             [else (cons j 'text)]))]))))

(define (gcd2 a b) (if (= b 0) a (gcd2 b (modulo a b))))

;; Indent width of the file: the gcd of all space indents, clamped to 2..8.
(define (detect-width infos)
  (let ([g (foldl (lambda (info acc)
                    (if (and (equal? (cdr info) 'text) (> (car info) 0)) (gcd2 (car info) acc) acc))
                  0
                  infos)])
    (cond
      [(= g 0) 4]
      [(< g 2) 2]
      [(> g 8) 8]
      [else g])))

;; Depth (in levels) of every line; a blank line takes the smaller depth of
;; the text lines around it, so a band runs through it only when it
;; continues on both sides.
(define (depths info-v width)
  (let* ([n (vector-length info-v)]
         [own (lambda (i)
                (if (equal? (cdr (vector-ref info-v i)) 'text)
                    (quotient (car (vector-ref info-v i)) width)
                    #f))]
         [above (let loop ([i 0] [prev 0] [acc '()])
                  (if (= i n)
                      (list->vector (reverse acc))
                      (let ([d (own i)]) (loop (+ i 1) (or d prev) (cons prev acc)))))]
         [below (let loop ([i (- n 1)] [next 0] [acc '()])
                  (if (< i 0)
                      (list->vector acc)
                      (let ([d (own i)]) (loop (- i 1) (or d next) (cons next acc)))))])
    (let loop ([i (- n 1)] [acc '()])
      (if (< i 0)
          (list->vector acc)
          (loop (- i 1)
                (cons (or (own i)
                          (if (equal? (cdr (vector-ref info-v i)) 'blank)
                              (min (vector-ref above i) (vector-ref below i))
                              0))
                      acc))))))

;;;; drawing

(define *state* (hash)) ; doc-id usize -> (list width infos-vector depths-vector)

(define (focused-doc) (editor->doc-id (editor-focus)))

(define (push acc key value) (hash-insert acc key (cons value (or (hash-try-get acc key) '()))))

(define (draw-levels! doc)
  (let* ([rope (editor->text doc)]
         [n (text.rope-len-lines rope)])
    (if (> n *max-lines*)
        (clear-all!)
        (draw-levels-of! doc rope n))))

;; Positions for the three kinds of layer, accumulated per colour (guides,
;; bands) or per absolute level (blank lines).
(define (collect rope n width info-v depth-v)
  (let loop ([i 0] [guides (hash)] [bands (hash)] [blanks (hash)])
    (if (= i n)
        (list guides bands blanks)
        (let* ([kind (cdr (vector-ref info-v i))]
               [d (vector-ref depth-v i)]
               [start (text.rope-line->char rope i)])
          (cond
            [(equal? kind 'text)
             (let add ([k *skip*] [guides guides] [bands bands])
               (if (>= k d)
                   (loop (+ i 1) guides bands blanks)
                   (let* ([col (+ start (* k width))]
                          [ck (modulo k *colors*)]
                          [bands (let fill ([j 1] [bands bands])
                                   (if (>= j width) bands (fill (+ j 1) (push bands ck (+ col j)))))])
                     (add (+ k 1) (push guides ck col) bands))))]
            [(equal? kind 'blank)
             ;; from level 0: skipped levels still need their width of padding
             (let add ([k 0] [blanks blanks])
               (if (>= k (min d *max-depth*))
                   (loop (+ i 1) guides bands blanks)
                   (add (+ k 1) (push blanks k start))))]
            [else (loop (+ i 1) guides bands blanks)])))))

(define (draw-levels-of! doc rope n)
  (let* ([infos (let loop ([i (- n 1)] [acc '()])
                  (if (< i 0) acc (loop (- i 1) (cons (line-info rope i) acc))))]
         [width (detect-width infos)]
         [info-v (list->vector infos)]
         [depth-v (depths info-v width)]
         [buckets (collect rope n width info-v depth-v)])
    (set! *state* (hash-insert *state* (doc-id->usize doc) (list width info-v depth-v (caddr buckets))))
    (set! *active-blank* #f)
    (let each ([k 0])
      (when (< k *colors*)
        (set-overlays! (guide-scope k) *char* (or (hash-try-get (car buckets) k) '()))
        (set-overlays! (band-scope k) " " (or (hash-try-get (cadr buckets) k) '()))
        (each (+ k 1))))
    (let each ([k 0])
      (when (< k *max-depth*)
        (set-inline-annotations! (blank-scope k) (blank-text k width)
                                 (or (hash-try-get (caddr buckets) k) '()))
        (set-inline-annotations! (blank-active-scope k) (blank-text k width) '())
        (each (+ k 1))))
    (draw-active! doc)))

;; The guide enclosing the cursor: one level left of the cursor line's depth,
;; over the run of lines around it that are at least that deep (blank lines
;; included). Only text lines get the bright guide; blank lines keep theirs.
(define (draw-active! doc)
  (let ([st (hash-try-get *state* (doc-id->usize doc))])
    (when st
      (draw-active-of! doc (car st) (cadr st) (caddr st) (cadddr st)))))

;; Which blank-line level currently has lines moved to its active twin:
;; (level . positions-moved), or #f.
(define *active-blank* #f)

(define (to-set lst) (foldl (lambda (x acc) (hash-insert acc x #t)) (hash) lst))

;; Put the blank lines of `level` in the cursor's block on its active twin,
;; after giving the previously active level its blank lines back.
(define (move-active-blanks! blanks level moved width)
  (when *active-blank*
    (let ([prev (car *active-blank*)])
      (set-inline-annotations! (blank-scope prev) (blank-text prev width)
                               (or (hash-try-get blanks prev) '()))
      (set-inline-annotations! (blank-active-scope prev) (blank-text prev width) '())))
  (set! *active-blank* #f)
  (when (and level (not (null? moved)))
    (let ([gone (to-set moved)])
      (set-inline-annotations! (blank-scope level) (blank-text level width)
                               (filter (lambda (p) (not (hash-contains? gone p)))
                                       (or (hash-try-get blanks level) '())))
      (set-inline-annotations! (blank-active-scope level) (blank-text level width) moved)
      (set! *active-blank* (cons level moved)))))

(define (draw-active-of! doc width infos depths blanks)
  (let* ([n (vector-length infos)]
         [rope (editor->text doc)]
         [cursor-line (min (- n 1)
                           (text.rope-char->line rope (min (cursor-position) (text.rope-len-chars rope))))]
         [kind (lambda (i) (cdr (vector-ref infos i)))]
         [d (vector-ref depths cursor-line)])
    (clear-active!)
    (if (<= d *skip*)
      (move-active-blanks! blanks #f '() width)
      (let* ([guide (- d 1)]
             [inside? (lambda (i) (and (not (equal? (kind i) 'tab)) (>= (vector-ref depths i) d)))]
             [from (let loop ([i cursor-line]) (if (and (> i 0) (inside? (- i 1))) (loop (- i 1)) i))]
             [to (let loop ([i cursor-line]) (if (and (< i (- n 1)) (inside? (+ i 1))) (loop (+ i 1)) i))]
             [positions (let loop ([i to] [acc '()])
                          (if (< i from)
                              acc
                              (loop (- i 1)
                                    (if (equal? (kind i) 'text)
                                        (cons (+ (text.rope-line->char rope i) (* guide width)) acc)
                                        acc))))])
        (set-overlays! (active-scope guide) *char* positions)
        (move-active-blanks! blanks guide
                             (let loop ([i to] [acc '()])
                               (if (< i from)
                                   acc
                                   (loop (- i 1)
                                         (if (equal? (kind i) 'blank)
                                             (cons (text.rope-line->char rope i) acc)
                                             acc))))
                             width)))))

;; One active layer per colour, so the bright guide keeps its band's tint.
(define (clear-active!)
  (let each ([k 0])
    (when (< k *colors*)
      (set-overlays! (active-scope k) *char* '())
      (each (+ k 1)))))

(define (clear-all!)
  (let each ([k 0])
    (when (< k *colors*)
      (clear-overlays! (guide-scope k))
      (clear-overlays! (band-scope k))
      (clear-overlays! (active-scope k))
      (each (+ k 1))))
  (let each ([k 0])
    (when (< k *max-depth*)
      (clear-overlays! (blank-scope k))
      (clear-overlays! (blank-active-scope k))
      (each (+ k 1)))))

;;;; events

(define *pending* #f)

;;@doc
;; Recompute the rainbow indentation of the focused document
(define (rings-refresh)
  (when *enabled* (draw-levels! (focused-doc))))

;; Edits arrive per keystroke; redraw once they pause for a moment.
(define (schedule-refresh)
  (unless *pending*
    (set! *pending* #t)
    (enqueue-thread-local-callback-with-delay
     60
     (lambda ()
       (set! *pending* #f)
       (rings-refresh)))))

(define (on-selection _view)
  (when *enabled*
    (let ([doc (focused-doc)])
      (if (hash-try-get *state* (doc-id->usize doc))
          (draw-active! doc)
          (schedule-refresh)))))

(define *hooks-registered* #f)

;;@doc
;; Turn rings on: rainbow indentation instead of Helix's own guides
(define (rings-start!)
  (set! *enabled* #t)
  (indent-guides (ig-render #f))
  (unless *hooks-registered*
    (set! *hooks-registered* #t)
    (register-hook 'document-changed (lambda (_doc _old) (schedule-refresh)))
    (register-hook 'document-opened (lambda (_doc) (schedule-refresh)))
    (register-hook 'selection-did-change on-selection))
  (schedule-refresh))

;;@doc
;; Turn rings off and give the indent guides back to Helix
(define (rings-stop!)
  (set! *enabled* #f)
  (clear-all!)
  (set! *state* (hash))
  (indent-guides (ig-render #t)))
