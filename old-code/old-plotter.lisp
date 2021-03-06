;; plotter.lsp -- Plotting support for Lisp
;; DM 02/07
;;
;; The basic notions are as follows:
;;
;; For Mac OS/X we want to utilize Display PDF to the max. We can do that by drawing
;; directly in the pane. Making a backing store image of the screen looks good only while
;; viewing the screen. Making such a backing image interferes with nice PDF file output, or
;; copy/paste. So for those times, we avoid constructing an image of the screen to allow the
;; full PDF elegance to shine through.
;;
;; OS/X Cocoa cannot perform XOR image combination in PDF space. So for full cross-hairs
;; that follow the cursor position, we resort to a fast(!!) copying of the backing store
;; image to the screen followed by overdrawing of the crosshairs.

;; For Win/XP the output does not look as nice since Win/XP is limited to bitmapped
;; graphics. Furthermore, it is necessary to draw initially in an off-screen compatible
;; pixmap, then create an image of that pixmap for backing store and for direct transfer
;; the output screen. Only in this way is it possible to produce backing images unmolested
;; by overlapping windows. In general Win/XP is severely limited. E.g., it cannot use
;; fractional line widths or coordinates. Bad things happen if you try. So we intercept
;; those possibilities and produce corrected requests on behalf of the caller.
;;
;; Win/XP can produce output with XOR combination, so we don't have to use the heavy-handed
;; approach of constantly refreshing the image on the screen for full crosshair cursors. We
;; just need to use the overall BG-complement of the desired cursor color in XOR draw mode.
;;
;; So, to accommodate both kinds of drawing needs with one body of source code, most of
;; the drawing primitive routines take two arguments - pane and port -- in addition to
;; other specializing arguments. The pane refers to the <plotter-pane> object described
;; below, which contains all of the plotting specific information. The port object is
;; that used by the GP primitives for the actual drawing operations. On OS/X the pane and the
;; port point to the same underlying object. But for Win/XP the pane is the <plotter-pane>
;; and the port is a temporary off-screen pixmap port.
;;
;; Until the backing store image of the screen exists, both systems utilze an ordered
;; collection of lambda closures representing the various plotting commands needed to build
;; up the whole image. Once those commands have executed we can grab a copy of the
;; screen image for use as a fast-copy backing store.
;;
;; ------------------------------------------
;; All of the plotting commands now require a keyword PANE argument
;; so that our plotting routines are multiprocessing safe, and can operate on
;; an embedded <plotter-pane> or some subclass thereof...
;; There is no longer any notion of a "current plotting window".
;;

(in-package "PLOTTER")

(defclass <plotter-pane> (capi:output-pane)
  ;; stuff used by 2-D plot scaling and plotting
  ((xlog      :accessor plotter-xlog           :initform nil)
   (xmin      :accessor plotter-xmin           :initform 0.0d0)
   (xmax      :accessor plotter-xmax           :initform 1.0d0)

   (ylog      :accessor plotter-ylog           :initform nil)
   (ymin      :accessor plotter-ymin           :initform 0.0d0)
   (ymax      :accessor plotter-ymax           :initform 1.0d0)
   
   (box       :accessor plotter-box)
   (xform     :accessor plotter-xform          :initform '(1 0 0 1 0 0))
   (inv-xform :accessor plotter-inv-xform      :initform '(1 0 0 1 0 0))
   (dlist     :accessor plotter-display-list   :initform (um:make-mpsafe-monitored-collector))
   (timer     :accessor plotter-resize-timer   :initform nil)
   (delayed   :accessor plotter-delayed-update :initform 0)
   
   ;; stuff for paramplot
   (trange    :accessor plotter-trange)
   (xsf       :accessor plotter-xsf)
   (ysf       :accessor plotter-ysf)
   (tprepfns  :accessor plotter-tprepfns)
   (xprepfns  :accessor plotter-xprepfns)
   (yprepfns  :accessor plotter-yprepfns)

   ;; info for nice looking zooming
   (title     :accessor plotter-base-title     :initarg :base-title     :initform "Plot")
   (def-wd    :accessor plotter-nominal-width  :initarg :nominal-width  :initform nil)
   (def-ht    :accessor plotter-nominal-height :initarg :nominal-height :initform nil)

   (sf        :accessor plotter-sf    :initform 1)
   (magn      :accessor plotter-magn  :initform 1)

   (legend    :accessor plotter-legend-info        :initform (um:make-collector))
   (legend-x  :accessor plotter-legend-x           :initform '(:frac 0.75))
   (legend-y  :accessor plotter-legend-y           :initform '(:frac 0.9))
   (legend-anchor :accessor plotter-legend-anchor  :initform :nw)
   
   (full-crosshair  :accessor plotter-full-crosshair :initform nil)
   (prev-x          :accessor plotter-prev-x         :initform nil)
   (prev-y          :accessor plotter-prev-y         :initform nil)
   
   (x-ro-hook :accessor plotter-x-readout-hook     :initform #'identity)
   (y-ro-hook :accessor plotter-y-readout-hook     :initform #'identity)

   (delay-backing  :accessor plotter-delay-backing :initform nil)
   (backing        :accessor plotter-backing       :initform nil)

   (capi::destroy-callback
                   :initform   'discard-backing-image
                   :allocation :class)
   ))

;; ------------------------------------------
(defstruct legend-info
  color        ; line or filled-symbol interior color
  thick        ; line or symbol border thickness
  linedashing  ; line dashing of lines
  symbol       ; plotting symbol
  plot-joined  ; whether symbols are joined by lines
  border-color ; border color for filled symbols
  text)        ; actual text of legend entry

;; ------------------------------------------
(defconstant $tiny-times-font-size
  #+:COCOA 10
  #+:WIN32  8)

(defconstant $normal-times-font-size
  #+:COCOA 12
  #+:WIN32  9)

(defconstant $big-times-font-size
  #+:COCOA 14
  #+:WIN32 10)
  
;; ------------------------------------------
#+:WIN32
(defun adjust-linewidth (wd)
  ;; Win/XP can't handle fractional linewidths
  (max 1 (round wd)))

#+:COCOA
(defun adjust-linewidth (wd)
  ;; ... but Display PDF can...
  wd)

;; ------------------------------------------
;; infinitep true if non-zero numeric arg with zero reciprocal
(defun infinitep (v)
  (and (not (zerop v))
       (zerop (/ v))))

;; nanp true if numeric v not equal to itself
(defun nanp (v)
  (/= v v))

(defun inf-nan-p (v)
  (or (infinitep v)
      (nanp v)))

;; ------------------------------------------
(defun background-color (pane)
  (gp:graphics-state-background
   (gp:get-graphics-state pane)))

(defun foreground-color (pane)
  (gp:graphics-state-foreground
   (gp:get-graphics-state pane)))

#+:WIN32
(defun adjust-color (pane color alpha)
  ;; Win/XP can't handle true alpha blending. So we use a make-pretend system
  ;; that assumes the color will be blending with the background color. That only
  ;; works properly as long as the drawing is actually over that background color.
  (let* ((bg (color:get-color-spec (background-color pane)))
         (c  (color:get-color-spec color))
         (alpha (or alpha
                    (color:color-alpha c)))
         (1malpha (- 1.0 alpha)))
    (labels ((mix (fn)
               (+ (* 1malpha (funcall fn bg)) (* alpha (funcall fn c)))))
      (color:make-rgb
       (mix #'color:color-red)
       (mix #'color:color-green)
       (mix #'color:color-blue))
      )))
      
#+:COCOA
(defun adjust-color (pane color alpha)
  ;; Mac OS/X Cocoa can do real alpha blending. Here we take the user's
  ;; requested color, and a possibly separate alpha level to produce a color
  ;; that will be properly alpha blended over a varying background.
  (declare (ignore pane))
  (let* ((c (color:get-color-spec color))
         (alpha (or alpha
                    (color:color-alpha c))))
    (color:make-rgb
     (color:color-red   c)
     (color:color-green c)
     (color:color-blue  c)
     alpha)
    ))

#+:WIN32
(defun complementary-color (color background)
  ;; produce a color such that XOR mode of that color against the background
  ;; will produce the requested color...
  (let* ((c  (color:get-color-spec color))
         (bg (color:get-color-spec background)))
    (labels ((color-xor (compon1 compon2)
               (let ((icompon1  (round (* 255 compon1)))
                     (icompon2  (round (* 255 compon2))))
                 (/ (logxor icompon1 icompon2) 255.0))))
      (color:make-rgb
       (color-xor (color:color-red   c) (color:color-red   bg))
       (color-xor (color:color-green c) (color:color-green bg))
       (color-xor (color:color-blue  c) (color:color-blue  bg)))
      )))

;; ------------------------------------------
#+:WIN32
(defun adjust-box (box)
  ;; Win/XP can't handle fractional box coords
  (mapcar #'round box))

#+:COCOA
(defun adjust-box (box)
  ;; ... but OS/X Cocoa can...
  box)

;; ---------------------------------------------------------

(defmethod plotter-pane-of ((pane <plotter-pane>))
  pane)

;; ---------------------------------------------
;; Define some safe image access macros...
;;
(defmacro with-image ((port (image imgexpr)) &body body)
  ;; returned value will be that of the body
  `(let ((,image ,imgexpr))
     (unwind-protect
         (progn
           ,@body)
       (gp:free-image ,port ,image))
     ))

(defmacro with-image-access ((acc access-expr) &body body)
  ;; returned value will be that of the body
  `(let ((,acc ,access-expr))
     (unwind-protect
         (progn
           ,@body)
       (gp:free-image-access ,acc))
     ))

;; ------------------------------------------
;; We can use WITH-DELAYED-UPDATE to ward off immediate and slowing
;; direct drawing operations. Delayed sections can be nested. Meanwhile,
;; within a delayed section we are simply building up a display list of
;; parameterized lambda closures that collectively will produce the sum
;; of all delayed operations, once the delay goes back to zero.
;;

(defun sync-with-capi-interface (intf fn &rest args)
  ;; use a mailbox to synchronize with an interface process executing a function for us.
  ;; we wait until that function execution completes.
  (let ((mbox (mp:make-mailbox)))
    (capi:execute-with-interface intf
                                 (lambda ()
                                   (apply fn args)
                                   (mp:mailbox-send mbox :done)))
    (mp:mailbox-read mbox)))

(defun sync-with-capi-pane (pane fn &rest args)
  ;; use a mailbox to synchronize with a pane process executing a function for us.
  ;; we wait until that function execution completes.
  (let ((mbox (mp:make-mailbox)))
    (capi:apply-in-pane-process pane
                                (lambda ()
                                  (apply fn args)
                                  (mp:mailbox-send mbox :done)))
    (mp:mailbox-read mbox)))

;; ------------------------------------------
(defun do-with-delayed-update (pane fn)
  (let* ((pane (plotter-pane-of pane)) ;; could be called by user with symbolic name for pane
         (ct   (plotter-delayed-update pane)))
    (incf (plotter-delayed-update pane))
    (when (zerop ct) ;; asking if changed resets the changed indiction
      (um:changed-p (plotter-display-list pane)))
    (unwind-protect
        (progn
          (funcall fn)
          (when (and (zerop ct)
                     (um:changed-p (plotter-display-list pane)))
            (sync-with-capi-pane pane
                                 (lambda ()
                                   (discard-backing-image pane)
                                   (gp:invalidate-rectangle pane))
                                 )))
      (decf (plotter-delayed-update pane))
      )))

;; user callable macro
(defmacro with-delayed-update ((pane) &body body)
  `(do-with-delayed-update ,pane
    (lambda ()
      ,@body)))

(defun append-display-list (pane item)
  (um:collector-append-item (plotter-display-list pane) item))

(defun discard-display-list (pane)
  (um:collector-discard-contents (plotter-display-list pane))
  (um:collector-discard-contents (plotter-legend-info pane)))

(defun display-list-items (pane &key discard)
  (um:collector-contents (plotter-display-list pane) :discard discard))

(defun display-list-empty-p (pane)
  (um:collector-empty-p (plotter-display-list pane)))


(defun append-legend (pane item)
  (um:collector-append-item (plotter-legend-info pane) item))

(defun all-legends (pane)
  (um:collector-contents (plotter-legend-info pane)))

;; ------------------------------------------

(defun log10 (x)
  (if (not (plusp x))
      -300
    (log x 10.0d0)))

(defun pow10 (x)
  (expt 10.0d0 x))

;; ------------------------------------------
(defun inset-box-sides (box dxleft dytop 
                            &optional (dxright dxleft)
                                      (dybottom dytop))
  (list (+ (gp:rectangle-left   box) dxleft)
        (+ (gp:rectangle-top    box) dytop)
        (- (gp:rectangle-right  box) dxright)
        (- (gp:rectangle-bottom box) dybottom)))

(defmacro box-left (box)
  `(gp:rectangle-left ,box))

(defmacro box-top (box)
  `(gp:rectangle-top ,box))

(defmacro box-right (box)
  `(gp:rectangle-right ,box))

(defmacro box-bottom (box)
  `(gp:rectangle-bottom ,box))

(defmacro box-width (box)
  `(gp:rectangle-width ,box))

(defmacro box-height (box)
  `(gp:rectangle-height ,box))

(defmacro box-top-left (box)
  (let ((gbx (gensym)))
    `(let ((,gbx ,box))
       (list (box-left ,gbx) (box-top ,gbx)))))

(defmacro box-top-right (box)
  (let ((gbx (gensym)))
    `(let ((,gbx ,box))
       (list (box-right ,gbx) (box-top ,gbx)))))

(defmacro box-bottom-left (box)
  (let ((gbx (gensym)))
    `(let ((,gbx ,box))
       (list (box-left ,gbx) (box-bottom ,gbx)))))

(defmacro box-bottom-right (box)
  (let ((gbx (gensym)))
    `(let ((,gbx ,box))
       (list (box-right ,gbx) (box-bottom ,gbx)))))

;; ------------------------------------------
(defun qrange (rng &optional (default 0.1))
  (if (zerop rng)
      default
    rng))

(defun qdiv (a b &optional (default 0.1))
  (/ a (qrange b default)))

;; ------------------------------------------
;; generalized operators to accommodate <carrays> and others
;;

;;---------
(defmethod length-of (arg)
  (length arg))

(defmethod length-of ((arg array))
  (array-total-size arg))

(defmethod length-of ((arg ca:<carray>))
  (ca:carray-total-size arg))

;;---------
(defmethod vmax-of (arg)
  (vmax arg))

(defmethod vmax-of ((arg array))
  (loop for ix from 0 below (array-total-size arg)
        maximize (row-major-aref arg ix)))

(defmethod vmax-of ((arg ca:<carray>))
  (loop for ix from 0 below (ca:carray-total-size arg)
        maximize (ca:row-major-caref arg ix)))

;;---------
(defmethod vmin-of (arg)
  (vmin arg))

(defmethod vmin-of ((arg array))
  (loop for ix from 0 below (array-total-size arg)
        minimize (row-major-aref arg ix)))

(defmethod vmin-of ((arg ca:<carray>))
  (loop for ix from 0 below (ca:carray-total-size arg)
        minimize (ca:row-major-caref arg ix)))

;;---------
(defmethod array-total-size-of (arg)
  (array-total-size arg))

(defmethod array-total-size-of ((arg ca:<carray>))
  (ca:carray-total-size arg))

;;---------
(defmethod array-dimension-of (arg n)
  (array-dimension arg n))

(defmethod array-dimension-of ((arg ca:<carray>) n)
  (ca:carray-dimension arg n))

;;---------
(defmethod aref-of (arg &rest indices)
  (apply #'aref arg indices))

(defmethod aref-of ((arg ca:<carray>) &rest indices)
  (apply #'ca:caref arg indices))

;;---------
(defmethod subseq-of (arg start &optional end)
  (subseq arg start end))

(defmethod subseq-of ((arg array) start &optional end)
  (let* ((limit (array-total-size arg))
         (nel   (- (or end limit) start))
         (ans   (make-array nel :element-type (array-element-type arg))))
    (loop for ix from start below (or end limit)
          for jx from 0
          do
          (setf (aref ans jx) (row-major-aref arg ix)))
    ans))

(defmethod subseq-of ((arg ca:<carray>) start &optional end)
  (let* ((limit  (ca:carray-total-size arg))
         (nel    (- (or end limit) start))
         (ans    (make-array nel
                             :element-type
                             (cond ((ca:is-float-array  arg) 'single-float)
                                   ((ca:is-double-array arg) 'double-float)
                                   (t 'bignum))
                             )))
    (loop for ix from start below (or end limit)
          for jx from 0
          do
          (setf (aref ans jx) (ca:caref arg ix)))
    ans))
          
;;---------

;; ------------------------------------------
(defun get-range (range v islog)
  (or range
      (and (plusp (length-of v))
           (list (vmin-of v) (vmax-of v)))
      (list (if islog 0.1 0) 1)))

(defconstant $largest-permissible-value
  (/ least-positive-normalized-single-float))

(defmethod pw-init-xv-yv ((cpw <plotter-pane>) xv yv
                          &key xrange yrange box xlog ylog aspect
                          &allow-other-keys)
  ;; initialize basic plotting parameters -- log scale axes, axis ranges,
  ;; plotting interior region (the box), and the graphic transforms to/from
  ;; data space to "pixel" space.  Pixel in quotes because they are real pixels
  ;; on Win/XP, but something altogether different on OS/X Display PDF.
  (let* ((_box (or box
                   (inset-box-sides (list 0 0
                                          (plotter-nominal-width  cpw)
                                          (plotter-nominal-height cpw))
                                    30 20 10 30)
                   )))
    (destructuring-bind (_xmin _xmax)
        (if xv
            (get-range xrange xv xlog)
          (get-range xrange (list 0 (1- (length-of yv))) xlog))
      (destructuring-bind (_ymin _ymax) (get-range yrange yv ylog)

        (if xlog
            (setf _xmin (log10 _xmin)
                  _xmax (log10 _xmax)))
        (if ylog
            (setf _ymin (log10 _ymin)
                  _ymax (log10 _ymax)))
        
        (unless yrange
          (let ((dy (/ (qrange (- _ymax _ymin)) 18)))
            (setf _ymin (max (- _ymin dy) (- $largest-permissible-value)))
            (setf _ymax (min (+ _ymax dy) $largest-permissible-value))
            ))
        
        (unless xrange
          (let ((dx (/ (qrange (- _xmax _xmin)) 18)))
            (setf _xmin (max (- _xmin dx) (- $largest-permissible-value)))
            (setf _xmax (min (+ _xmax dx) $largest-permissible-value))
            ))
        
        (setf (plotter-box  cpw) _box
              (plotter-xmin cpw) _xmin
              (plotter-xmax cpw) _xmax
              (plotter-ymin cpw) _ymin
              (plotter-ymax cpw) _ymax
              (plotter-xlog cpw) xlog
              (plotter-ylog cpw) ylog)
        
        (let ((xscale (qdiv (- (box-right _box) (box-left _box))
                            (- _xmax _xmin)))
              (yscale (qdiv (- (box-bottom _box) (box-top _box))
                            (- _ymax _ymin))))
          
          (if (and (numberp aspect)
                   (plusp aspect))
              
              (let* ((x-squeeze (<= aspect 1))
                     (scale     (if x-squeeze
                                    (min xscale yscale)
                                  (max xscale yscale))))
                (setf xscale (if x-squeeze
                                 (* aspect scale)
                               scale)
                      yscale (if x-squeeze
                                 scale
                               (/ scale aspect)))
                ))
          
          (let ((xform     (gp:make-transform))
                (inv-xform (gp:make-transform)))
            (gp:apply-translation xform (- _xmin) (- _ymin))
            (gp:apply-scale xform xscale (- yscale))
            (gp:apply-translation xform (box-left _box) (box-bottom _box))
            (gp:invert-transform xform inv-xform)
            (setf (plotter-xform     cpw) xform
                  (plotter-inv-xform cpw) inv-xform)
            )))
      )))

;; ---------------------------------------------------------

(defun vector-group-min (yvecs)
  (reduce #'min (mapcar #'vmin-of yvecs)))

(defun vector-group-max (yvecs)
  (reduce #'max (mapcar #'vmax-of yvecs)))

(defun pw-init-bars-xv-yv (cpw xvec yvecs &rest args)
  ;; just run the usual scaling initialization
  ;; but against a y-vector that contains those values
  ;; from the multiple vectors which have the largest absolute values
  (apply #'pw-init-xv-yv cpw
         (or (and xvec
                  (list (vmin-of xvec) (vmax-of xvec)))
             (and yvecs
                  (list 0 (1- (length-of (first yvecs))))
                  ))
         (and yvecs
              (list (vector-group-min yvecs)
                    (vector-group-max yvecs)))
         args))

;; ------------------------------------------
(defun draw-path (port &rest positions)
  (gp:draw-polygon port
                   (mapcan #'append positions)))

(defun bounds-overlap-p (bounds1 bounds2)
  (labels ((overlaps-p (bounds1 bounds2)
             (destructuring-bind (left1 right1) bounds1
               (destructuring-bind (left2 right2) bounds2
                 (declare (ignore right2))
                 (<= left1 left2 right1))
               )))
    (or (overlaps-p bounds1 bounds2)
        (overlaps-p bounds2 bounds1))
    ))

(defun expand-bounds (bounds dx)
  (list (- (first bounds) dx)
        (+ (second bounds) dx)))

;; ------------------------------------------
;; Convenience macros

(defmacro with-color ((pane color) &body body)
  `(gp:with-graphics-state
       (,pane
        :foreground ,color)
     ,@body))
  
(defmacro with-mask ((pane mask) &body body)
  `(gp:with-graphics-state
       (,pane
        :mask ,mask)
     ,@body))

;; ------------------------------------------
(defun draw-string-x-y (pane port string x y
                             &key 
                             (x-alignment :left) 
                             (y-alignment :baseline)
                             prev-bounds
                             font
                             (margin 2)
                             (transparent t)
                             (color :black)
                             clip
                             &allow-other-keys)
  ;; Draw a string at some location, unless the bounds of the new string
  ;; overlap the previous bounds. This is used to avoid placing axis labels
  ;; too closely together along the grid.
  (multiple-value-bind (left top right bottom)
      (gp:get-string-extent port string font)
    (let* ((dx (ecase x-alignment
                 (:left     0)
                 (:right    (- left right))
                 (:center   (floor (- left right) 2))
                 ))
           (dy (ecase y-alignment
                 (:top      (- top))
                 (:bottom   0)
                 (:center   (- (floor (- top bottom) 2) top))
                 (:baseline 0)))
           (new-bounds (list (+ x left dx) (+ x right dx))))
      
      (if (and prev-bounds
               (bounds-overlap-p (expand-bounds prev-bounds margin) new-bounds))
          prev-bounds

        (with-color (port color)
          (with-mask (port (and clip
                                (adjust-box (plotter-box pane))))
              (gp:draw-string port string (+ x dx) (+ y dy)
                              :font font
                              :block (not transparent))
            new-bounds
            )))
      )))

;; ------------------------------------------
#+:COCOA
(defun draw-vert-string-x-y (port string x y
                                  &key
                                  (x-alignment :left)
                                  (y-alignment :baseline)
                                  font
                                  prev-bounds
                                  (margin 2)
                                  (color :black)
                                  ;;(transparent t)
                                  )
  ;;
  ;; draw vertical string by appealing directly to Cocoa
  ;;
  (multiple-value-bind (lf tp rt bt)
      (gp:get-string-extent port string font)
    (declare (ignore bt tp))

    (let* ((wd (- rt lf -1))
           (dx (ecase x-alignment
                 (:right    0)
                 (:left     (- wd))
                 (:center   (- (floor wd 2)))
                 ))
           (new-bounds (list (+ y lf dx) (+ y rt dx)))
           (font-attrs (gp:font-description-attributes (gp:font-description font)))
           (font-size  (getf font-attrs :size))
           (font-name  (getf font-attrs :name)))

      (if (and prev-bounds
               (bounds-overlap-p (expand-bounds prev-bounds margin) new-bounds))

          prev-bounds

        (progn
          (add-label port string x  y
                     :font      font-name
                     :font-size font-size
                     :color     color
                     :alpha     1.0
                     :x-alignment x-alignment
                     :y-alignment y-alignment
                     :angle     90.0)
          new-bounds)
        ))))

#+:WIN32
(defun draw-vert-string-x-y (port string x y
                                  &key
                                  (x-alignment :left)
                                  (y-alignment :baseline)
                                  font
                                  prev-bounds
                                  (margin 2)
                                  (color :black)
                                  (transparent t))
  ;;
  ;; draw vertical string by rotating bitmap of horizontal string
  ;;
  (multiple-value-bind (lf tp rt bt)
      (gp:get-string-extent port string font)

    (let* ((wd (- rt lf -1))
           (ht (- bt tp -1))
           (dy (ecase y-alignment
                 (:top      0)
                 (:bottom   (- ht))
                 (:baseline tp)
                 (:center   (floor tp 2))
                 ))
           (dx (ecase x-alignment
                 (:right    0)
                 (:left     (- wd))
                 (:center   (- (floor wd 2)))
                 ))
           (new-bounds (list (+ y lf dx) (+ y rt dx))))
      
      (if (and prev-bounds
               (bounds-overlap-p (expand-bounds prev-bounds margin) new-bounds))

          prev-bounds
        
        (gp:with-pixmap-graphics-port (ph port wd ht
                                          :clear t)
          (with-color (ph color)
            (gp:draw-string ph string
                            0 (- tp)
                            :font font
                            :block (not transparent)))
          
          (with-image (port (v-image #+:COCOA (gp:make-image port ht wd)
                                     #+:WIN32 (gp:make-image port ht wd :alpha nil)
                                     ))
             (with-image (ph (h-image (gp:make-image-from-port ph)))
                 (with-image-access (ha (gp:make-image-access ph h-image))
                    (with-image-access (va (gp:make-image-access port v-image))
                      (gp:image-access-transfer-from-image ha)
                      (loop for ix from 0 below wd do
                            (loop for iy from 0 below ht do
                                  (setf (gp:image-access-pixel va iy (- wd ix 1))
                                        (gp:image-access-pixel ha ix iy))
                                  ))
                      (gp:image-access-transfer-to-image va)
                      )))
             (gp:draw-image port v-image (+ x dy) (+ y dx)))
          new-bounds
          ))
      )))

;;-------------------------------------------------------------------
;; Abstract superclass <scanner> represent objects that respond to the NEXT-ITEM method
;;

(defclass <scanner> ()
  ())

(defclass <limited-scanner> (<scanner>)
  ((limit  :accessor scanner-limit    :initarg :limit)
   (pos    :accessor scanner-position :initform 0)))

(defclass <counting-scanner> (<limited-scanner>)
  ())

(defclass <vector-scanner> (<limited-scanner>)
  ((vec  :accessor scanner-vector :initarg :vector)))

(defclass <list-scanner> (<limited-scanner>)
  ((lst        :accessor scanner-list :initarg :list)
   (lst-backup :accessor scanner-list-backup)))

(defclass <array-scanner> (<limited-scanner>)
  ((arr  :accessor scanner-array :initarg :array)))

(defclass <carray-scanner> (<limited-scanner>)
  ((arr  :accessor scanner-array :initarg :array)))

;; ===============
(defmethod make-scanner ((limit integer) &key (max-items limit))
  (make-instance '<counting-scanner>
                 :limit (min limit max-items)))

(defmethod make-scanner ((vec vector) &key (max-items (length vec)))
  (make-instance '<vector-scanner>
                 :limit   (min (length vec) max-items)
                 :vector  vec))

(defmethod make-scanner ((lst list) &key (max-items (length lst)))
  (make-instance '<list-scanner>
                 :list  lst
                 :limit (min (length lst) max-items)))

(defmethod initialize-instance :after ((self <list-scanner>)
                                       &rest args &key &allow-other-keys)
  (setf (scanner-list-backup self) (scanner-list self)))

(defmethod make-scanner ((arr array) &key (max-items (array-total-size arr)))
  (make-instance '<array-scanner>
                 :array  arr
                 :limit  (min (array-total-size arr) max-items)))

(defmethod make-scanner ((arr ca:<carray>) &key (max-items (ca:carray-total-size arr)))
  (make-instance '<carray-scanner>
                 :array  arr
                 :limit  (min (ca:carray-total-size arr) max-items)))

;; ===============
;; All scanners pass through NIL as the terminal value
(defmethod next-item ((cscanner <counting-scanner>))
  (with-accessors ((position   scanner-position)
                   (limit      scanner-limit   )) cscanner
    (let ((ans position))
      (when (< ans limit)
        (incf position)
        ans)
      )))

(defmethod next-item ((lscanner <list-scanner>))
  (with-accessors ((limit    scanner-limit   )
                   (position scanner-position)
                   (its-list scanner-list    )) lscanner
    (when (< position limit)
      (incf position)
      (pop its-list))
    ))

(defmethod next-item ((vscanner <vector-scanner>))
  (with-accessors ((position   scanner-position)
                   (limit      scanner-limit   )
                   (its-vector scanner-vector  )) vscanner
  
  (when (< position limit)
    (let ((ans (aref its-vector position)))
      (incf position)
      ans))
  ))

(defmethod next-item ((ascanner <array-scanner>))
  (with-accessors ((position  scanner-position)
                   (limit     scanner-limit   )
                   (its-array scanner-array   )) ascanner
    (when (< position limit)
      (let ((ans (row-major-aref its-array position)))
        (incf position)
        ans))
    ))

(defmethod next-item ((cascanner <carray-scanner>))
  (with-accessors ((position  scanner-position)
                   (limit     scanner-limit   )
                   (its-array scanner-array   )) cascanner
    (when (< position limit)
      (let ((ans (ca:row-major-caref its-array position)))
        (incf position)
        ans))
    ))

;; ===============
(defmethod reset-scanner ((scanner <limited-scanner>))
  (setf (scanner-position scanner) 0))

(defmethod reset-scanner :after ((scanner <list-scanner>))
  (setf (scanner-list scanner) (scanner-list-backup scanner)))

;; ===============
(defclass <transformer> (<scanner>)
  ((src   :accessor transformer-source  :initarg :source)
   (xform :accessor transformer-xform   :initarg :xform)))

(defmethod make-transformer ((src <scanner>) (xform function))
  (make-instance '<transformer>
                 :source src
                 :xform  xform))

(defmethod next-item ((xf <transformer>))
  ;; pass along NIL as a terminal value
  (with-accessors  ((source   transformer-source)
                    (xform    transformer-xform )) xf
    (let ((item (next-item source)))
      (when item
        (funcall xform item)))
    ))

(defmethod reset-scanner ((xf <transformer>))
  (reset-scanner (transformer-source xf)))

;; ===============
(defclass <pair-scanner> (<scanner>)
  ((xsrc   :accessor pair-scanner-xsrc   :initarg :xsrc)
   (ysrc   :accessor pair-scanner-ysrc   :initarg :ysrc)
   (pair   :accessor pair-scanner-values :initform (make-array 2))
   ))

(defmethod make-pair-scanner ((xs <scanner>) (ys <scanner>))
  (make-instance '<pair-scanner>
                 :xsrc  xs
                 :ysrc  ys
                 ))

(defmethod next-item ((pairs <pair-scanner>))
  (with-accessors ((xs    pair-scanner-xsrc  )
                   (ys    pair-scanner-ysrc  )
                   (pair  pair-scanner-values)) pairs
    (let* ((x (next-item xs))
           (y (next-item ys)))
      (when (and x y)
        (setf (aref pair 0) x
              (aref pair 1) y)
        pair))
    ))

(defmethod reset-scanner ((pairs <pair-scanner>))
  (reset-scanner (pair-scanner-xsrc pairs))
  (reset-scanner (pair-scanner-ysrc pairs)))

;; ------------------------------------------
#|
(defun zip (&rest seqs)
  (apply #'map 'list #'list seqs))

(defun staircase (xv yv)
  (let ((pairs (zip xv yv)))
    (um:foldl
     (lambda (ans pair)
       (destructuring-bind (x y) pair
         (destructuring-bind (xprev yprev &rest _) ans
           (declare (ignore _))
           (let ((xmid (* 0.5 (+ x xprev))))
             (nconc (list x y xmid y xmid yprev) ans)
             ))))
     (first pairs)
     (rest pairs)
     )))

(defun make-bars (xv yv)
  (let ((pairs (zip xv yv)))
    (um:foldl
     (lambda (ans pair)
       (destructuring-bind (x y) pair
         (destructuring-bind (xprev &rest _) ans
           (declare (ignore _))
           (let ((xmid (* 0.5 (+ x xprev))))
             (nconc (list x y xmid y) ans)
             ))))
     (first pairs)
     (rest pairs)
     )))

(defun interleave (&rest seqs)
  (mapcan #'nconc (apply #'zip seqs)))

|#
;; -------------------------------------------------------
(defmethod draw-vertical-bars (port (bars <pair-scanner>))
  (let* (xprev
         yprev
         last-x
         (wd   (* 0.1 (gp:port-width port))) ;; default if only one data point
         (wd/2 (* 0.5 wd)))
    (loop for pair = (next-item bars)
          while pair
          do
          (destructure-vector (x y) pair
            (when xprev
              (setf wd   (abs (- x xprev))
                    wd/2 (* 0.5 wd))
              (unless (= y yprev)
                (let ((next-x (+ xprev wd/2))
                      (prev-x (or last-x
                                  (- xprev wd/2))
                              ))
                  (gp:draw-rectangle port prev-x 0 (- next-x prev-x) yprev :filled t)
                  (setf last-x next-x)
                  )))
            (setf xprev x
                  yprev y))
          finally
          (when xprev
            ;; use the last known width
            (let ((next-x (+ xprev wd/2))
                  (prev-x (or last-x
                              (- xprev wd/2))
                          ))
              (gp:draw-rectangle port prev-x 0 (- next-x prev-x) yprev :filled t)
              ))
          )))
                             
(defmethod draw-horizontal-bars (port (bars <pair-scanner>))
  (let* (xprev
         yprev
         last-y
         (wd   (* 0.1 (gp:port-height port))) ;; default if only one data point
         (wd/2 (* 0.5 wd)))
    (loop for pair = (next-item bars)
          while pair
          do
          (destructure-vector (x y) pair
            (when yprev
              (setf wd   (abs (- y yprev))
                    wd/2 (* 0.5 wd))
              (unless (= x xprev)
                (let ((next-y (+ yprev wd/2))
                      (prev-y (or last-y
                                  (- yprev wd/2))
                              ))
                  (gp:draw-rectangle port 0 prev-y xprev (- next-y prev-y) :filled t)
                  (setf last-y next-y)
                  )))
            (setf xprev x
                  yprev y))
          finally
          (when xprev
            ;; use the last known width
            (let ((next-y (+ yprev wd/2))
                  (prev-y (or last-y
                              (- yprev wd/2))
                          ))
              (gp:draw-rectangle port 0 prev-y xprev (- next-y prev-y) :filled t)
              ))
          )))

(defmethod draw-staircase (port (pairs <pair-scanner>))
  (let* (xprev
         yprev
         last-x
         (wd    (* 0.1 (gp:port-width port)))     ;; default for only one data point
         (wd/2  (* 0.5 wd)))
    (loop for pair = (next-item pairs)
          while pair
          do
          (destructure-vector (x y) pair
            (when xprev
              (setf wd   (abs (- x xprev))
                    wd/2 (* 0.5 wd))
              (unless (= y yprev)
                (let ((next-x (- x wd/2)))
                  (gp:draw-polygon port
                                   (list (or last-x (- xprev wd/2)) yprev
                                         next-x yprev
                                         next-x y)
                                   :closed nil)
                  (setf last-x next-x)
                  )))
            (setf xprev x
                  yprev y))
          finally
          (when xprev
            (gp:draw-line port
                          (or last-x (- xprev wd/2)) yprev
                          (+ xprev wd/2) yprev))
          )))

(defmethod draw-polyline (port (pairs <pair-scanner>))
  (let (xprev yprev)
    (loop for pair = (next-item pairs)
          while pair
          do
          (destructure-vector (x y) pair
            (when xprev
              (unless (or (and (= x xprev)
                               (= y yprev))
                          (inf-nan-p x)
                          (inf-nan-p y))
                (gp:draw-line port xprev yprev x y)))
            (setf xprev x
                  yprev y))
          )))
  
;; ----------------------------------------------------------  
(defun get-symbol-plotfn (port symbol border-color)
  (labels ((translucent+frame (fn)
             #+:COCOA
             (with-color (port #.(color:make-gray 1.0 0.25))
               ;; translucent interior
               (funcall fn t))
             ;; solid frame
             (funcall fn))
           
           (solid+frame (fn)
             (funcall fn t)
             (with-color (port (or border-color
                                   (foreground-color port)))
               (funcall fn))))
    
    (ecase symbol
      (:cross     (lambda (x y)
                    (gp:draw-line port (- x 3) y (+ x 3) y)
                    (gp:draw-line port x (- y 3) x (+ y 3))
                    ))
      
      (:circle
       (lambda (x y)
         (labels ((draw-circle (&optional filled)
                    (gp:draw-circle port
                                    x 
                                    #+:COCOA (- y 0.5)
                                    #+:WIN32 y
                                    3
                                    :filled filled)))
           (translucent+frame #'draw-circle)
           )))
      
      (:filled-circle
       (lambda (x y)
         (labels ((draw-circle (&optional filled)
                    (gp:draw-circle port
                                    (if filled (1+ x) x)
                                    (1- y) 3
                                    :filled filled)))
           (solid+frame #'draw-circle)
           )))
      
      ((:box :square)
       (lambda (x y)
         (labels ((draw-rectangle (&optional filled)
                    (gp:draw-rectangle port (- x 3) (- y 3) 6 6
                                       :filled filled)))
           (translucent+frame #'draw-rectangle)
           )))
      
      ((:filled-box :filled-square)
       (lambda (x y)
         (labels ((draw-rectangle (&optional filled)
                    (gp:draw-rectangle port (- x 3) (- y 3) 6 6
                                       :filled filled)))
           (solid+frame #'draw-rectangle)
           )))
      
      ((:triangle :up-triangle)
       (lambda (x y)
         (labels ((draw-triangle (&optional filled)
                    (gp:draw-polygon port
                                     (list (- x 3) (+ y 3)
                                           x (- y 4)
                                           (+ x 3) (+ y 3))
                                     :closed t
                                     :filled filled)))
           (translucent+frame #'draw-triangle)
           )))
      
      (:down-triangle
       (lambda (x y)
         (labels ((draw-triangle (&optional filled)
                    (gp:draw-polygon port
                                     (list (- x 3) (- y 3)
                                           x (+ y 4)
                                           (+ x 3) (- y 3))
                                     :closed t
                                     :filled filled)))
           (translucent+frame #'draw-triangle)
           )))
      
      ((:filled-triangle :filled-up-triangle)
       (lambda (x y)
         (labels ((draw-triangle (&optional filled)
                    (gp:draw-polygon port
                                     (list (- x 3) (+ y 3)
                                           x (- y 4)
                                           (+ x 3) (+ y 3))
                                     :closed t
                                     :filled filled)))
           (solid+frame #'draw-triangle)
           )))
      
      (:filled-down-triangle
       (lambda (x y)
         (labels ((draw-triangle (&optional filled)
                    (gp:draw-polygon port
                                     (list (- x 3) (- y 3)
                                           x (+ y 4)
                                           (+ x 3) (- y 3))
                                     :closed t
                                     :filled filled)))
           (solid+frame #'draw-triangle)
           )))
      
      (:dot
       (lambda (x y)
         (gp:draw-circle port x (1- y) 0.5)
         ))
      )))

(defmethod pw-plot-xv-yv ((cpw <plotter-pane>) port xvector yvector 
                          &key
                          (color #.(color:make-rgb 0.0 0.5 0.0))
                          alpha
                          thick
                          (linewidth (or thick 1))
                          linedashing
                          symbol
                          plot-joined
                          legend
                          legend-x
                          legend-y
                          legend-anchor
                          border-color
                          barwidth
                          bar-offset
                          &allow-other-keys)
  ;; this is the base plotting routine
  ;; called only from within the pane process
  (let* ((sf        (plotter-sf  cpw))
         (box       (let ((box (plotter-box cpw)))
                      (adjust-box
                       (list (1+ (* sf (box-left box)))
                             (* sf (box-top box))
                             (1- (* sf (box-width box)))
                             (* sf (box-height box))))
                      ))
         (xform     (plotter-xform cpw))
         (color     (adjust-color cpw color alpha))
         (linewidth (adjust-linewidth (* sf linewidth)))

         (nel       (if xvector
                        (min (length-of xvector) (length-of yvector))
                      (length-of yvector)))

         (xs         (let ((scanner (make-scanner (or xvector
                                                      nel))
                                    ))
                       (if (plotter-xlog cpw)
                           (make-transformer scanner #'log10)
                         scanner)))

         (ys         (let ((scanner (make-scanner yvector)))
                       (if (plotter-ylog cpw)
                           (make-transformer scanner #'log10)
                         scanner)))
         (pairs     (make-pair-scanner xs ys)))

    (when legend
      (append-legend cpw
                     (make-legend-info
                      :color        color
                      :thick        linewidth
                      :linedashing  linedashing
                      :symbol       symbol
                      :border-color border-color
                      :plot-joined  plot-joined
                      :text         legend)))

    (when legend-x
      (setf (plotter-legend-x cpw) legend-x))
    (when legend-y
      (setf (plotter-legend-y cpw) legend-y))
    (when legend-anchor
      (setf (plotter-legend-anchor cpw) legend-anchor))
    
    (gp:with-graphics-state (port
                             :thickness  linewidth
                             :dashed     (not (null linedashing))
                             :dash       (mapcar (um:expanded-curry (v) #'* sf) linedashing)
                             :foreground color
                             :line-end-style   :butt
                             :line-joint-style :miter
                             :mask       box)

      (gp:with-graphics-scale (port sf sf)
        
        (case symbol
          (:steps
           (gp:with-graphics-transform (port xform)
             (draw-staircase port pairs)))
          
          (:vbars
           (if barwidth
               (let* ((wd   (get-x-width cpw barwidth))
                      (wd/2 (* 0.5 wd))
                      (off  (if bar-offset
                                (get-x-width cpw bar-offset)
                              0)))
                 (loop for pair = (next-item pairs)
                       while pair
                       do
                       (destructure-vector (x y) pair
                         (multiple-value-bind (xx yy)
                             (gp:transform-point xform x y)
                           (multiple-value-bind (_ yy0)
                               (gp:transform-point xform x 0)
                             (declare (ignore _))
                             (gp:draw-rectangle port
                                                (+ off (- xx wd/2)) yy0
                                                wd (- yy yy0)
                                                :filled t)
                             )))
                       ))
             (gp:with-graphics-transform (port xform)
               (draw-vertical-bars port pairs))
             ))
          
          (:hbars
           (if barwidth
               (let* ((wd   (get-y-width cpw barwidth))
                      (wd/2 (* 0.5 wd))
                      (off  (if bar-offset
                                (get-y-width cpw bar-offset)
                              0)))
                 (loop for pair = (next-item pairs)
                       while pair
                       do
                       (destructure-vector (x y) pair
                         (multiple-value-bind (xx yy)
                             (gp:transform-point xform x y)
                           (multiple-value-bind (xx0 _)
                               (gp:transform-point xform 0 y)
                             (declare (ignore _))
                             (gp:draw-rectangle port
                                                xx0 (+ off (- yy wd/2))
                                                (- xx xx0) wd
                                                :filled t)
                             )))
                       ))
             (gp:with-graphics-transform (port xform)
               (draw-horizontal-bars port pairs))
             ))

          (:sampled-data
           (let ((dotfn (get-symbol-plotfn port :filled-circle border-color)))
             (loop for pair = (next-item pairs)
                   while pair
                   do
                   (destructure-vector (x y) pair
                     (multiple-value-bind (xx yy)
                         (gp:transform-point xform x y)
                       (multiple-value-bind (_ yy0)
                           (gp:transform-point xform x 0)
                         (declare (ignore _))
                         (gp:draw-line port xx yy0 xx yy)
                         (funcall dotfn xx yy))
                       ))
                   )))
          
          (otherwise
           (when (or (not symbol)
                     plot-joined)
             (gp:with-graphics-transform (port xform)
               (draw-polyline port pairs))
             (when symbol
               (reset-scanner pairs)))
           
           (when symbol
             (let ((plotfn (get-symbol-plotfn port symbol border-color)))
               (loop for pair = (next-item pairs)
                     while pair
                     do
                     (destructure-vector (x y) pair
                       (multiple-value-bind (xx yy)
                           (gp:transform-point xform x y)
                         (funcall plotfn xx yy)
                         )))
               ))
           ))
        ))
    ))

(defun get-bar-symbol-plotfn (port symbol color neg-color bar-width testfn)
  ;; bear in mind that the y values at this point are absolute screen
  ;; coords and are inverted with respect to data ordering
  (ecase symbol
    (:sigma
     (lambda (x ys)
       (destructure-vector (ymin ymax) ys
         (gp:draw-line port x ymin x ymax)
         (gp:draw-line port (- x (/ bar-width 2)) ymin (+ x (/ bar-width 2)) ymin)
         (gp:draw-line port (- x (/ bar-width 2)) ymax (+ x (/ bar-width 2)) ymax)
         )))

    (:hl-bar
     (lambda (x ys)
       (destructure-vector (ymin ymax) ys
         (gp:draw-line port x ymin x ymax)
         )))
    
    (:hlc-bar
     (lambda (x ys)
       (destructure-vector (h l c) ys
         (gp:draw-line port x l x h)
         (gp:draw-line port x c (+ x (/ bar-width 2)) c)
         )))
    
    (:ohlc-bar
     (lambda (x ys)
       (destructure-vector (o h l c) ys
         (with-color (port (if (funcall testfn c o) neg-color color))
           (gp:draw-line port x l x h)
           (gp:draw-line port (- x (/ bar-width 2)) o x o)
           (gp:draw-line port x c (+ x (/ bar-width 2)) c)
           ))))
    
    (:candlestick
     (lambda (x ys)
       (destructure-vector (o h l c) ys
         (if (funcall testfn c o)
             (with-color (port neg-color)
               (gp:draw-line port x l x h)
               (gp:draw-rectangle port (- x (/ bar-width 2)) o bar-width (- c o)
                                  :filled t))
           (progn
             (with-color (port :black)
               (gp:draw-line port x l x h))
             (with-color (port color)
               (gp:draw-rectangle port (- x (/ bar-width 2)) o bar-width (- c o)
                                  :filled t))
             (with-color (port :black)
               (gp:draw-rectangle port (- x (/ bar-width 2)) o bar-width (- c o)))
             ))
         )))
    ))

;;-------------------------------------------------------------------
(defmethod pw-plot-bars-xv-yv ((cpw <plotter-pane>) port xvector yvectors 
                          &key
                          (color #.(color:make-rgb 0.0 0.5 0.0))
                          (neg-color color)
                          alpha
                          thick
                          (linewidth (or thick 1))
                          (bar-width 6)
                          (symbol (ecase (length yvectors)
                                    (2 :sigma)
                                    (3 :hlc-bar)
                                    (4 :ohlc-bar)))
                          &allow-other-keys)
  ;; this is the base bar-plotting routine
  ;; called only from within the pane process
  (let* ((sf        (plotter-sf  cpw))
         (box       (let ((box (plotter-box cpw)))
                      (adjust-box
                       (list (1+ (* sf (box-left box)))
                             (* sf (box-top box))
                             (1- (* sf (box-width box)))
                             (* sf (box-height box))))
                      ))
         (xform     (plotter-xform cpw))
         (color     (adjust-color cpw color alpha))
         (neg-color (adjust-color cpw neg-color alpha))
         (linewidth (adjust-linewidth (* sf linewidth)))

         (nel       (let ((nely (reduce #'min (mapcar #'length-of yvectors))))
                      (if xvector
                          (min (length-of xvector) nely)
                        nely)))
         
         (xs        (let* ((xform   (lambda (x)
                                      (gp:transform-point xform x 0)))
                           (scanner (make-scanner (or xvector
                                                      nel)
                                                  :max-items nel)))
                      (make-transformer scanner
                                        (if (plotter-xlog cpw)
                                            (um:compose xform #'log10)
                                          xform))
                      ))

         (xform-y   (lambda (y)
                      (second (multiple-value-list
                               (gp:transform-point xform 0 y)))
                      ))

         (ys        (let* ((scanners (mapcar #'make-scanner yvectors)))
                      (mapcar (um:rcurry #'make-transformer
                                         (if (plotter-ylog cpw)
                                             (um:compose xform-y #'log10)
                                           xform-y))
                              scanners)
                      ))
         (c<o-testfn (let ((y1 (funcall xform-y 0))
                           (y2 (funcall xform-y 1)))
                       (if (< y2 y1)
                           #'>
                         #'<)))
         (plotfn (get-bar-symbol-plotfn port symbol
                                        color neg-color bar-width
                                        c<o-testfn))
         (tmp       (make-array (length ys))))
    
    (gp:with-graphics-state (port
                             :thickness  linewidth
                             :foreground color
                             :line-end-style   :butt
                             :line-joint-style :miter
                             :mask       box)
      
      (gp:with-graphics-scale (port sf sf)
        (loop for x = (next-item xs)
              while x
              do
              (map-into tmp #'next-item ys)
              (funcall plotfn x tmp)))
      )))

;; ============================================================
(defun plt-draw-shape (pane port shape x0 y0 x1 y1
                          &key
                          color alpha filled
                          border-thick border-color border-alpha
                          start-angle sweep-angle)
  ;; for rectangles: shape = :rect, (x0,y0) and (x1,y1) are opposite corners
  ;; for ellipses:   shape = :ellipse, (x0,y0) is ctr (x1,y1) are radii
  (let* ((x0        (if (plotter-xlog pane)
                        (log10 x0)
                      x0))
         (x1        (if (plotter-xlog pane)
                        (log10 x1)
                      x1))
         (y0        (if (plotter-ylog pane)
                        (log10 y0)
                      y0))
         (y1        (if (plotter-ylog pane)
                        (log10 y1)
                      y1))
         (wd        (- x1 x0))
         (ht        (- y1 y0))
         (sf        (plotter-sf  pane))
         (box       (let ((box (plotter-box pane)))
                      (adjust-box
                       (list (1+ (* sf (box-left box)))
                             (* sf (box-top box))
                             (1- (* sf (box-width box)))
                             (* sf (box-height box))))
                      ))
         (xform     (plotter-xform pane))
         (color     (adjust-color pane color alpha))
         (bcolor    (adjust-color pane border-color border-alpha))
         (linewidth (adjust-linewidth (* sf (or border-thick 0)))))
    
    (gp:with-graphics-state (port
                             :thickness  linewidth
                             :foreground color
                             :line-end-style   :butt
                             :line-joint-style :miter
                             :mask       box)

      (gp:with-graphics-scale (port sf sf)

        (gp:with-graphics-transform (port xform)
          (when filled
            (ecase shape
              (:rect
               (gp:draw-rectangle port
                                  x0 y0 wd ht
                                  :filled t))
              (:ellipse
               (gp:draw-ellipse port
                                x0 y0 x1 y1
                                :filled t))
              
              (:arc
               (gp:draw-arc port
                            x0 y0 wd ht
                            start-angle sweep-angle
                            :filled t))
              ))
          
          (when border-thick
            (with-color (port bcolor)
              (case shape
                (:rect
                 (gp:draw-rectangle port
                                    x0 y0 wd ht
                                    :filled nil))
                (:ellipse
                 (gp:draw-ellipse port
                                  x0 y0 x1 y1
                                  :filled nil))

                (:arc
                 (gp:draw-arc port
                              x0 y0 wd ht
                              start-angle sweep-angle
                              :filled nil))
                )))
          )))
    ))


;; ------------------------------------------
(defun calc-start-delta (vmin vmax)
  ;; compute a good axis increment and starting value
  ;; these are considered good if the increment is a multiple of 1, 2, or 5.
  ;; The starting value must be the largest whole part of the axis values:
  ;; e.g.,
  ;; if the axis ranges from 1.23 to 3.28, then the largest whole part will be 2.00.
  ;; That will be our starting label, and we then number by (non-overlapping strings)
  ;; at increment spacings on either side of that largest whole part.
  ;;
  ;; This avoid bizarre labels like 1.23 ... 1.37 ... 2.45 ...
  ;; giving instead, someting like  1.2 .. 1.6 .. 2.0 .. 2.4 ...
  ;; which is enormously more readable than what most plotting packages produce.
  ;; (This is the way a human would chart the axes)
  ;;
  (destructuring-bind (sf c)
      (loop for sf = (/ (pow10
                         (ceiling (log10 (max (abs vmin)
                                              (abs vmax))
                                         ))
                         ))
            then (* 10.0d0 sf)
            do
            ;;
            ;; this loop finds the scale factor sf and minimum integer value c such that
            ;; the scaled min and max values span a range greater than 1
            ;; and c is no further from the scaled min value than that range.
            ;; It is the case that a <= c <= b, where a and b are the scaled min and max values,
            ;; and abs(c) is some integer multiple (positive, zero, or negative) of 10.
            ;;
            (let* ((a   (* sf vmin))
                   (b   (* sf vmax))
                   (rng (abs (- b a)))
                   (c   (* 10.0d0 (ceiling (min a b) 10.0d0))))
              (if (and (> rng 1.0d0)
                       (<= (abs (- c a)) rng))
                  (return (list sf c)))
              ))
    (loop for sf2 = 1.0d0 then (* 0.1d0 sf2)
          do
          (let* ((a   (* sf sf2 vmin))
                 (b   (* sf sf2 vmax))
                 (c   (* sf2 c))
                 (rng (abs (- b a))))
            
            (if (<= rng 10.0d0)
                (let* ((dv  (cond ((> rng 5.0d0) 1.0d0)
                                  ((> rng 2.0d0) 0.5d0)
                                  (t             0.2d0)))
                       (nl  (floor (abs (- c a)) dv))
                       (nu  (floor (abs (- b c)) dv))
                       (v0  (if (not (plusp (* a b)))
                                0.0d0
                              (/ c sf sf2)))
                       (dv  (/ dv sf sf2)))
                  (return (list v0 dv nl nu)))
              ))
          )))

;; ------------------------------------------
(defparameter *ext-logo*
  (ignore-errors
    (gp:read-external-image
     (translate-logical-pathname
      #+:COCOA "PROJECTS:DYLIB;Logo75Img-Alpha25y.pdf"
      #+:WIN32 "PROJECTS:DYLIB;Logo75Img-Alpha25y.bmp")
     )))

(defun stamp-logo (pane port)
  (when *ext-logo*
    (let ((box (plotter-box pane))
          (sf  (plotter-sf  pane)))
      (with-image (port
                   (logo (gp:convert-external-image pane *ext-logo*)))
        (let* ((top  (+ (box-top box)
                        (* 0.5
                           (- (box-height box)
                              (gp:image-height logo))
                           )))
               (left (+ (box-left box)
                        (* 0.5 (- (box-width box)
                                  (gp:image-width logo))
                           ))))
          (gp:with-graphics-scale (port sf sf)
            (gp:draw-image port logo left top))
          ))
      )))

(defun find-best-font (pane &key
                            (family "Times")
                            size
                            (weight :normal)
                            (slant :roman))
  (gp:find-best-font pane
                     (gp:make-font-description
                      :family family
                      :size   size
                      :weight weight
                      :slant  slant)))

(defun watermark (pane port)
  (let* ((box     (plotter-box pane))
         (sf      (plotter-sf  pane))
         (cright1 "Copyright (c) 2006-2007 by Refined Audiometrics Laboratory, LLC")
         (cright2 "All rights reserved.")
         (font2   (find-best-font pane
                                  :size   (* sf $tiny-times-font-size)))
         (color2  #.(color:make-gray 0.7)))
    
    (stamp-logo pane port)
    
    (let* ((left   (+ (box-left   box) 10))
           (bottom (- (box-bottom box) 14)))
      (draw-string-x-y pane port cright1
                       (* sf left)
                       (* sf (- bottom 11))
                       :x-alignment :left
                       :y-alignment :top
                       :font  font2
                       :color color2)
      (draw-string-x-y pane port cright2
                       (* sf left)
                       (* sf bottom)
                       :x-alignment :left
                       :y-alignment :top
                       :font  font2
                       :color color2)
      )))

;; ------------------------------------------
(defparameter *log-subdivs*
  (mapcar #'log10
          '(0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9
                2 3 4 5 6 7 8 9)))

(defmethod pw-axes ((cpw <plotter-pane>) port
                    &key
                    (fullgrid t)
                    (xtitle "X")
                    (ytitle "Y")
                    (title  "Plot")
                    (watermarkfn #'watermark)
                    &allow-other-keys)
  (let* ((box   (plotter-box cpw))
         (sf    (plotter-sf cpw))
         (font  (find-best-font cpw
                                :size (* (plotter-sf cpw) $normal-times-font-size)))
         (xlog  (plotter-xlog cpw))
         (ylog  (plotter-ylog cpw)))
    
    (labels
        ((qxlog (x)
           (if xlog (log10 x) x))
         (qylog (y)
           (if ylog (log10 y) y))
         (iqxlog (x)
           (if xlog (pow10 x) x))
         (iqylog (y)
           (if ylog (pow10 y) y))
         (trim-mantissa (v)
           (string-right-trim
            "."
            (string-right-trim
             "0" v)))
         (plabel (val)
           (if (or (zerop val)
                   (and (<= 0.01 (abs val))
                        (< (abs val) 10000)))
               (trim-mantissa (format nil "~,3F" (float val 1.0)))
             (destructuring-bind (mant expon)
                 (um:split-string (format nil "~,2E" (float val 1.0))
                                  :delims "E")
               (um:mkstr (trim-mantissa mant) "e" (remove #\+ expon)))
             )))

      (gp:clear-graphics-port port)
      (if watermarkfn
          (funcall watermarkfn cpw port))

      (when title
        (draw-string-x-y cpw port title
                         (floor (* sf (+ (box-left box) (box-right box))) 2)
                         0
                         :x-alignment :center
                         :y-alignment :top
                         :font        (find-best-font cpw
                                                      :size (* (plotter-sf cpw)
                                                               $big-times-font-size))
                         ))

      (gp:with-graphics-scale (port sf sf)
        (gp:with-graphics-state (port :scale-thickness t)
          (draw-path port
                     (box-top-left     box)
                     (box-bottom-left  box)
                     (box-bottom-right box)
                     )))
        
      (pw-plot-xv-yv cpw port
                     (vector (iqxlog (plotter-xmin cpw))
                             (iqxlog (plotter-xmax cpw)))
                     (vector (iqylog 0) (iqylog 0))
                     :color #.(color:make-gray 0.5))
        
      (pw-plot-xv-yv cpw port
                     (vector (iqxlog 0) (iqxlog 0))
                     (vector (iqylog (plotter-ymin cpw))
                             (iqylog (plotter-ymax cpw)))
                     :color #.(color:make-gray 0.5))

      (when xtitle
        (draw-string-x-y cpw port xtitle
                         (floor (* sf (+ (box-left box) (box-right box))) 2)
                         (* sf (+ (box-bottom box) 26))
                         :font font
                         :x-alignment :center
                         :y-alignment :bottom)
          
        (let* ((_xmin (plotter-xmin cpw))
               (_xmax (plotter-xmax cpw))
               (_xlast nil)
               (_xstart nil))
          (destructuring-bind (x0 dx nl nu) (calc-start-delta _xmin _xmax)
            (declare (ignore nl nu))
            (if xlog
                (setf dx 1))
            (labels ((xwork (xval xprev)
                       (let* ((xpos  (gp:transform-point (plotter-xform cpw)
                                                         xval 0))
                              (xlast (draw-string-x-y
                                      cpw port (plabel (iqxlog xval))
                                      (* sf xpos)
                                      (* sf (+ 4 (box-bottom box)))
                                      :prev-bounds xprev
                                      :margin (* 2 sf)
                                      :x-alignment :center
                                      :y-alignment :top
                                      :font font)))
                           
                         (gp:with-graphics-scale (port sf sf)
                           (gp:with-graphics-state
                               (port
                                :scale-thickness t)
                             (when fullgrid
                               (when xlog
                                 (with-color (port #.(color:make-gray 0.75))
                                   (let ((xscale (first (plotter-xform cpw))))
                                     (loop for ix in *log-subdivs* do
                                           (let ((x (+ xpos (* xscale ix))))
                                             (if (< (box-left box) x
                                                    (box-right box))
                                                 (gp:draw-line
                                                  port
                                                  x (box-top box)
                                                  x (box-bottom box))
                                               )))
                                     )))
                               (unless (zerop xval)
                                 (with-color (port (if (vectorp fullgrid)
                                                       fullgrid
                                                     (color:make-gray
                                                      (if xlog 0.5 0.75))))
                                   (gp:draw-line port
                                                 xpos (box-top box)
                                                 xpos (box-bottom box))
                                   )))
                               
                             (gp:draw-line port
                                           xpos (- (box-bottom box) 2)
                                           xpos (+ (box-bottom box) 3))))
                           
                         xlast)))
                
                
              (loop for xval = x0 then (- xval dx)
                    until (< xval (if (> _xmax _xmin) _xmin _xmax))
                    do
                    (setf _xlast (xwork xval _xlast))
                    (unless _xstart
                      (setf _xstart _xlast)))
                
              (setf _xlast _xstart)
                
              (loop for xval = (+ x0 dx) then (+ xval dx)
                    until (> xval (if (< _xmin _xmax) _xmax _xmin))
                    do
                    (setf _xlast (xwork xval _xlast)))
              ))))
        
      (when ytitle
        (draw-vert-string-x-y port ytitle
                              #+:WIN32 0 #+:COCOA (* sf 3)
                              (floor (* sf (+ (box-top box)
                                              (box-bottom box))) 2)
                              :font  font
                              :x-alignment :center
                              :y-alignment :top)
        (let* ((_ymin (plotter-ymin cpw))
               (_ymax (plotter-ymax cpw))
               (_ylast  nil)
               (_ystart nil))
          (destructuring-bind (y0 dy nl nu) (calc-start-delta _ymin _ymax)
            (declare (ignore nl nu))
            (if ylog
                (setf dy 1))
            (labels ((ywork (yval yprev)
                       (multiple-value-bind (xpos ypos)
                           (gp:transform-point (plotter-xform cpw) 0 yval)
                         (declare (ignore xpos))
                           
                         (let ((ylast (draw-vert-string-x-y
                                       port
                                       (plabel (iqylog yval))
                                       (* sf (- (box-left box) #+:WIN32 1 #+:COCOA 3))
                                       (* sf ypos)
                                       :prev-bounds yprev
                                       :margin (* 2 sf)
                                       :x-alignment :center
                                       :y-alignment :bottom
                                       :font font)))
                             
                           (gp:with-graphics-scale (port sf sf)
                             (gp:with-graphics-state
                                 (port :scale-thickness t)
                               (when fullgrid
                                 (when ylog
                                   (with-color (port #.(color:make-gray 0.75))
                                     (let ((yscale (fourth (plotter-xform cpw))))
                                       (loop for ix in *log-subdivs* do
                                             (let ((y (+ ypos (* yscale ix))))
                                               (if (> (box-bottom box) y
                                                      (box-top box))
                                                   (gp:draw-line
                                                    port
                                                    (1+ (box-left box)) y
                                                    (box-right box) y)
                                                 ))))
                                     ))
                                 (unless (zerop yval)
                                   (with-color (port (if (vectorp fullgrid)
                                                         fullgrid
                                                       (color:make-gray
                                                        (if ylog 0.5 0.75))))
                                     (gp:draw-line port
                                                   (1+ (box-left box))  ypos
                                                   (box-right box) ypos)
                                     )))
                                 
                               (gp:draw-line port
                                             (- (box-left box) 2) ypos
                                             (+ (box-left box) 3) ypos)))
                           ylast))))
                
              (loop for yval = y0 then (- yval dy)
                    until (< yval (if (> _ymax _ymin) _ymin _ymax))
                    do
                    (setf _ylast (ywork yval _ylast))
                    (unless _ystart
                      (setf _ystart _ylast)))
                
              (setf _ylast _ystart)
                
              (loop for yval = (+ y0 dy) then (+ yval dy)
                    until (> yval (if (< _ymin _ymax) _ymax _ymin))
                    do
                    (setf _ylast (ywork yval _ylast)))
              )))
        ))
    ))

;; ----------------------------------------------------------------
;; pane location decoding for strings and legends
;;
(defun parse-location (sym pane)
  ;; BEWARE:: '1.2d+3p means (:pixel 1200) NOT (:data 1.2 +3)
  ;; be sure to disambiguate the "d" as in '1.2data+3p
  (let* ((s    (if (stringp sym)
                   sym
                 (symbol-name sym)))
         (slen (length s)))
    
    (labels ((iter (state ix ans)
               (ecase state
                 (:initial
                  (cond ((>= ix slen)
                         ;; have been all number constituents
                         ;;assume we have pixels specified
                         (list :pixel (read-from-string s) 0))
                        
                        ((digit-char-p (char s ix))
                         ;; still have number constituent
                         (iter :initial (1+ ix) nil))
                        
                        ((char= #\. (char s ix))
                         ;; still have number constituent
                         (iter :initial (1+ ix) nil))
                        
                        ((char-equal #\d (char s ix))
                         ;; might be part of an exponential notation
                         ;; or it might be a frac or data specifier
                         (iter :check-for-exponent (1+ ix) nil))
                        
                        ((char-equal #\t (char s ix))
                         ;; 't' for top
                         (iter :scan-to-plus-or-minus (1+ ix)
                               (list :pixel (plotter-nominal-height pane))
                               ))
                        
                        ((char-equal #\r (char s ix))
                         ;; 'r' for right
                         (iter :scan-to-plus-or-minus (1+ ix)
                               (list :pixel (plotter-nominal-width pane))
                               ))

                        ((or (char-equal #\b (char s ix))
                             (char-equal #\l (char s ix)))
                         ;; 'b' for bottom, 'l' for left
                         (iter :scan-to-plus-or-minus (1+ ix)
                               (list :pixel 0)
                               ))
                        
                        (t
                         (iter :get-units ix (read-from-string s t :eof :end ix)))
                        ))
                 
                 (:check-for-exponent
                  (cond ((>= ix slen)
                         ;; we had a D so it must have been (:data nn.nnn)
                         (list :data
                               (read-from-string s t :eof :end (1- ix))
                               ))
                        
                        ((alpha-char-p (char s ix))
                         ;; can't be a +/- sign, so must have been (:data nn.nn)
                         (iter :scan-to-plus-or-minus (1+ ix)
                               (list :data
                                     (read-from-string s t :eof :end (1- ix))
                                     )))
                        
                        (t ;; assume we have a +/- sign and continue with number scan
                           (iter :initial (1+ ix) nil))
                        ))
                  
                 (:get-units
                  (ecase (char-upcase (char s ix))
                    (#\P  (iter :scan-to-plus-or-minus (1+ ix) (list :pixel ans)))
                    (#\D  (iter :scan-to-plus-or-minus (1+ ix) (list :data  ans)))
                    (#\F  (iter :scan-to-plus-or-minus (1+ ix) (list :frac  ans)))))
                 
                 (:scan-to-plus-or-minus
                  (cond ((>= ix slen)
                         ;; no offset, we a finished
                         ans)
                        
                        ((or (char= #\+ (char s ix))
                             (char= #\- (char s ix)))
                         (let ((end (position-if #'alpha-char-p s :start ix)))
                           ;; read the offset and return
                           (list (first ans)  ;; type
                                 (second ans) ;; value
                                 (read-from-string s t :eof :start ix :end end) ;; offset
                                 )))
                        
                        (t ;; keep looking
                           (iter :scan-to-plus-or-minus (1+ ix) ans))
                        ))
                 )))
      
      (iter :initial 0 nil)
      )))

(defun get-location (pane pos-expr axis &key scale)
  (cond
   
   ((consp pos-expr)
    (let* ((sym (um:mkstr (first pos-expr)))
           (val (second pos-expr)))
      (ecase (char-upcase (char sym 0))
        ;; accommodates :DATA :DAT :D :DATUM, :FRAC :F :FRACTION, :PIXEL :P :PIX :PIXELS, etc.
        (#\F  ;; pane fraction  0 = left, bottom;  1 = right, top
              (ecase axis
                (:x  (* val (plotter-nominal-width pane)))

                ;; port y axis is inverted, top at 0
                (:y  (* (- 1 val) (plotter-nominal-height pane)))
                ))
        
        (#\D  ;; data coordinates
              (ecase axis
                (:x
                 (let ((ans (gp:transform-point (plotter-xform pane)
                                                (if (plotter-xlog pane)
                                                    (log10 val)
                                                  val)
                                                0)))
                   (if scale
                       (- ans (gp:transform-point (plotter-xform pane) 0 0))
                     ans)))
                                                  
                (:y
                 (let ((ans (multiple-value-bind (xx yy)
                                (gp:transform-point (plotter-xform pane)
                                                    0
                                                    (if (plotter-ylog pane)
                                                        (log10 val)
                                                      val))
                              (declare (ignore xx))
                              yy)))
                   (if scale
                       (- ans (second (multiple-value-list
                                       (gp:transform-point (plotter-xform pane)
                                                           0 0))))
                     ans)))
                ))
        
        (#\P  ;; direct pixel positioning
              (ecase axis
                (:x val)

                ;; port y axis is inverted, top at 0
                (:y (- (plotter-nominal-height pane) val 1))
                ))
        )))

   ((numberp pos-expr) ;; assume :DATA
    (get-location pane (list :data pos-expr) axis :scale scale))

   (t ;; else, expect a parsable symbol or string '1.2data+3pix
      (destructuring-bind (vtype v &optional (dv 0)) (parse-location pos-expr pane)
        (+ (get-location pane (list vtype v) axis :scale scale)
           (ecase axis
             (:x dv)
             (:y (- dv))  ;; port y axis is inverted, top at 0
             ))))
   ))
  
(defun get-x-location (pane x)
  (get-location pane x :x))

(defun get-y-location (pane y)
  (get-location pane y :y))

(defun get-x-width (pane wd)
  (get-location pane wd :x :scale t))

(defun get-y-width (pane wd)
  (get-location pane wd :y :scale t))

;; ----------------------------------------------------------------
(defun draw-legend (pane port)
  (let ((items (all-legends pane)))
    (when items
      (let* ((sf   (plotter-sf pane))
             (font (find-best-font port
                                   :size (* sf $tiny-times-font-size)))
             (nitems (length items)))
        
        (multiple-value-bind (txtwd txtht txtbase)
            (let ((maxwd   0)
                  (maxht   0)
                  (maxbase 0))
              (loop for item in items do
                    (multiple-value-bind (lf tp rt bt)
                        (gp:get-string-extent port (legend-info-text item) font)
                      (setf maxwd   (max maxwd (- rt lf))
                            maxht   (max maxht (- bt tp))
                            maxbase (max maxbase tp))))
              (values maxwd maxht maxbase))
          
          (declare (ignore txtbase))
          (let* ((totwd (+ txtwd  (* sf 40)))
                 (totht (* nitems (+ txtht 0)))
                 (effwd (/ totwd sf))
                 (effht (/ totht sf))
                 (effht1 (/ txtht sf))
                 (x     (let ((x (get-x-location pane (plotter-legend-x pane))))
                          (ecase (plotter-legend-anchor pane)
                            ((:nw :w :sw)  x)
                            ((:ne :e :se)  (- x effwd))
                            ((:n  :ctr :s) (- x (/ effwd 2)))
                            )))
                 (y     (let ((y (get-y-location pane (plotter-legend-y pane))))
                          (case (plotter-legend-anchor pane)
                            ((:nw :n :ne)  y)
                            ((:sw :s :sw)  (- y effht))
                            ((:w  :ctr :e) (- y (/ effht 2)))
                            ))))
            
            (gp:with-graphics-scale (port sf sf)
              
              (with-color (port (color:make-rgb 1 1 1 0.55))
                (gp:draw-rectangle port x y effwd effht
                                   :filled t))
              
              (gp:with-graphics-state (port :thickness (round sf))
                (gp:draw-rectangle  port x y effwd effht))
              
              (loop for item in items
                    for y from (+ y effht1) by effht1
                    do
                    (gp:with-graphics-state
                        (port
                         :foreground (legend-info-color item)
                         :thickness  (legend-info-thick item)
                         :dashed     (not (null (legend-info-linedashing item)))
                         :dash       (legend-info-linedashing item))

                      (when (member (legend-info-symbol item) '(:vbars :hbars))
                        (gp:with-graphics-state
                            (port
                             :thickness 5)
                          (let ((y (floor (- y (/ effht1 2)))))
                            (gp:draw-line port
                                          (+ x  3) y
                                          (+ x 33) y)
                            )))
                      
                      (when (or (null (legend-info-symbol item))
                                (eq (legend-info-symbol item) :steps)
                                (legend-info-plot-joined item))
                        (let ((y (floor (- y (/ effht1 2)))))
                          (gp:draw-line port
                                        (+ x  3) y
                                        (+ x 33) y)
                          ))
                      
                      (when (and (legend-info-symbol item)
                                 (not (member (legend-info-symbol item)
                                              '(:steps :vbars :hbars))))
                        (funcall (get-symbol-plotfn port (legend-info-symbol item)
                                                    (legend-info-border-color item))
                                 (+ x 18) (- y (/ effht1 2))
                                 )))
                    (gp:draw-string port (legend-info-text item) (+ x 36) (- y 3)
                                    :font font))
              
              )))
        ))
    ))
                 
                 
                 
    
    
;; ----------------------------------------------------------------
#|
(defun filter-nans (x y)
  (let ((vals 
         (loop for xv across x and
               yv across y keep-unless
               (or (nanp xv) (nanp yv)))))
    (values (apply 'vector (mapcar 'first  vals))
            (apply 'vector (mapcar 'second vals)))
    ))
|#

(defun do-plot (cpw port xvector yvector
                    &rest args)
  (apply #'pw-init-xv-yv cpw xvector yvector args)
  (apply #'pw-axes cpw port args)
  ;;
  ;; Now plot the data points
  ;; 
  (apply #'pw-plot-xv-yv cpw port xvector yvector args))

(defun do-plot-bars (cpw port xvector yvectors
                         &rest args)
  (apply #'pw-init-bars-xv-yv cpw xvector yvectors args)
  (apply #'pw-axes cpw port args)
  ;;
  ;; Now plot the data points
  ;; 
  (apply #'pw-plot-bars-xv-yv cpw port xvector yvectors args))

;; -------------------------------------------------------------------
#|
(defmethod coerce-to-vector ((v vector))
  v)

(defmethod coerce-to-vector ((lst list))
  (coerce lst 'vector))

(defmethod coerce-to-vector ((cv c-arrays:<carray>))
  (c-arrays:convert-to-lisp-object cv))
|#
;; -------------------------------------------------------------------

(defun draw-shape (shape pane x0 y0 x1 y1
                     &key
                     (color :darkgreen)
                     (filled t)
                     (alpha 1)
                     border-thick
                     (border-color :black)
                     (border-alpha 1)
                     start-angle  ;; for arc
                     sweep-angle  ;; for arc
                     )
  (let ((pane (plotter-pane-of pane)))
    (with-delayed-update (pane)
      (append-display-list pane
                           #'(lambda (pane port x y width height)
                               (declare (ignore x y width height))
                               (plt-draw-shape pane port shape
                                               x0 y0 x1 y1
                                               :color  color
                                               :alpha  alpha
                                               :filled filled
                                               :border-thick border-thick
                                               :border-color border-color
                                               :border-alpha border-alpha
                                               :start-angle  start-angle
                                               :sweep-angle  sweep-angle))
                           ))))

;; user callable function
(defun draw-rect (&rest args)
  (apply #'draw-shape :rect args))

;; user callable function
(defun draw-ellipse (&rest args)
  (apply #'draw-shape :ellipse args))

;; user callable function
(defun draw-arc (&rest args)
  (apply #'draw-shape :arc args))


(defun oplot2 (pane xv yv 
                  &rest args
                  &key
                  clear
                  ;;draw-axes
                  ;;(color :darkgreen)
                  thick
                  (linewidth (or thick 1))
                  ;;(fullgrid t)
                  &allow-other-keys)
  (let ((pane (plotter-pane-of pane)))
    (with-delayed-update (pane)
      (if (or clear
              (display-list-empty-p pane))
          (progn
            #|
                (setf (plotter-x-readout-hook pane) #'identity
                      (plotter-y-readout-hook pane) #'identity)
                |#
            (discard-display-list pane)
            (append-display-list pane
                                 #'(lambda (pane port x y width height)
                                     (declare (ignore x y width height))
                                     (apply #'do-plot pane port xv yv
                                            ;; :color     color
                                            :linewidth linewidth
                                            ;; :fullgrid  fullgrid
                                            args))))
        (append-display-list pane
                             #'(lambda (pane port x y width height)
                                 (declare (ignore x y width height))
                                 (apply #'pw-plot-xv-yv pane port xv yv 
                                        ;; :color color
                                        args))
                             ))
      )))

(defun oplot-bars2 (pane xv yvs
                       &rest args
                       &key
                       ;; draw-axes
                       clear
                       (color     :black)
                       (neg-color color)
                       thick
                       (linewidth (or thick 1))
                       ;; (fullgrid t)
                       &allow-other-keys)
  (let ((pane (plotter-pane-of pane)))
    (with-delayed-update (pane)
      (if (or clear
              (display-list-empty-p pane))
          (progn
            #|
                (setf (plotter-x-readout-hook pane) #'identity
                      (plotter-y-readout-hook pane) #'identity)
                |#
            (discard-display-list pane)
            (append-display-list pane
                                 #'(lambda (pane port x y width height)
                                     (declare (ignore x y width height))
                                     (apply #'do-plot-bars pane port xv yvs
                                            :color     color
                                            :neg-color neg-color
                                            :linewidth linewidth
                                            ;; :fullgrid  fullgrid
                                            args))))
        (append-display-list pane
                             #'(lambda (pane port x y width height)
                                 (declare (ignore x y width height))
                                 (apply #'pw-plot-bars-xv-yv pane port xv yvs 
                                        :color color
                                        :neg-color neg-color
                                        args))
                             ))
      )))

;; ------------------------------------------
(defun find-x-y-parms (args)
  (let* ((nargs (or (position-if #'keywordp args)
                    (length args))))
    (case nargs
      (0   (list nil nil args))
      (1   (list nil (first args) (rest args)))
      (2   (list (first args) (second args) (rest (rest args))))
      (otherwise (error "Too many arguments"))
      )))

(defun vector-to-plotfn (fn pane args)
  (destructuring-bind (xs ys parms) (find-x-y-parms args)
    (apply fn pane xs ys parms)))

;; user callable function
(defun plot (pane &rest args)
  (vector-to-plotfn #'oplot2 pane args))

;; user callable function
(defun plot-bars (pane &rest args)
  (vector-to-plotfn #'oplot-bars2 pane args))

;; ------------------------------------------

;; user callable function
(defun clear (pane)
  (let ((pane (plotter-pane-of pane)))
    (with-delayed-update (pane)
      (discard-display-list pane))))

(defun axes2 (pane xvector yvectors &rest args &key xrange &allow-other-keys)
  ;; allow a list of yvectors to be given
  ;; so that we can find the best fitting autoscale that accommodates all of them
  (destructuring-bind (xv yv)
      (let ((ylist (um:mklist yvectors)))
        (list (or (and xvector
                       (vector (vmin-of xvector) (vmax-of xvector)))
                  (and (null xrange)
                       ylist
                       (vector 0 (1- (length-of (first ylist))))
                       ))
              (and ylist
                   (vector (vector-group-min ylist)
                           (vector-group-max ylist)))
              ))
    (let ((pane (plotter-pane-of pane)))
      (with-delayed-update (pane)
        #|
    (setf (plotter-x-readout-hook pane) #'identity
          (plotter-y-readout-hook pane) #'identity)
    |#
        (clear pane)
        (append-display-list pane 
                             #'(lambda (pane port x y width height)
                                 (declare (ignore x y width height))
                                 (apply #'pw-init-xv-yv pane
                                        xv yv args)
                                 (apply #'pw-axes pane port args))
                             ))
      )))

;; user callable function
(defun axes (pane &rest args)
  (vector-to-plotfn #'axes2 pane args))

;; ------------------------------------------
;; these callbacks are only called from the capi process
;;
;; For COCOA the backing store is a pixmap image
;; For Win32 the backing store is a pixmap

#+:COCOA
(defun save-backing-image (pane port)
  (with-accessors ((backing-image  plotter-backing       )
                   (sf             plotter-sf            )
                   (nominal-width  plotter-nominal-width )
                   (nominal-height plotter-nominal-height)) pane
    (setf backing-image
          (gp:make-image-from-port port
                                 0 0
                                 (* sf nominal-width)
                                 (* sf nominal-height)))
    ))

#+:WIN32
(defun save-backing-image (pane port)
  (with-accessors ((backing-image  plotter-backing )) pane
    (setf backing-image port)))

#+:COCOA
(defun discard-backing-image (pane)
  (with-accessors ((backing-image  plotter-backing)) pane
    (when backing-image
      (gp:free-image pane backing-image)
      (setf backing-image nil))
    ))

#+:WIN32
(defun discard-backing-image (pane)
  (with-accessors ((backing-image plotter-backing)) pane
    (when backing-image
      (gp:destroy-pixmap-port backing-image)
      (setf backing-image nil))
    ))


;; --------------------------------------------------
#+:WIN32
(defun draw-crosshair-lines (pane color x y)
  (when (and x y)
    (gp:with-graphics-state
        (pane
         :foreground color
         :operation  boole-xor)
      (gp:draw-line pane x 0 x (gp:port-height pane))
      (gp:draw-line pane 0 y (gp:port-width  pane) y))
    ))

#+:COCOA
(defun draw-crosshair-lines (pane color x y)
  (when (and x y)
    (with-color (pane color)
      (gp:draw-line pane x 0 x (gp:port-height pane))
      (gp:draw-line pane 0 y (gp:port-width pane) y)
      )))

(defmethod display-callback ((pane <plotter-pane>) x y width height)
  (with-accessors ((nominal-width   plotter-nominal-width )
                   (nominal-height  plotter-nominal-height)
                   (sf              plotter-sf            )
                   (magn            plotter-magn          )
                   (xform           plotter-xform         )
                   (port-width      gp:port-width         )
                   (port-height     gp:port-height        )
                   (backing-image   plotter-backing       )
                   #+:COCOA
                   (delay-backing   plotter-delay-backing )
                   (full-crosshair  plotter-full-crosshair)
                   (prev-x          plotter-prev-x        )
                   (prev-y          plotter-prev-y        )) pane

    (unless nominal-width
      (setf nominal-width  width
            nominal-height height))
    
    (gp:clear-graphics-port-state pane)
    
    (setf xform '(1 0 0 1 0 0)
          magn  1
          sf    (min (/ port-height nominal-height)
                     (/ port-width  nominal-width)))


    #|
    (print (list x y width height sf
                 nominal-width port-width
                 nominal-height port-height))
    |#

    #+:COCOA
    (if backing-image
        (gp:draw-image pane backing-image 0 0
                       :from-width  (gp:image-width  backing-image)
                       :from-height (gp:image-height backing-image)
                       :to-width    (* sf nominal-width)
                       :to-height   (* sf nominal-height))
      (progn
        (dolist (item (display-list-items pane))
          (funcall item pane pane x y width height))
        (draw-legend pane pane)
        
        (unless delay-backing
          (save-backing-image pane pane))))

    #+:WIN32
    (progn
      (unless backing-image
        (let* ((gs   (gp:get-graphics-state pane))
               (fg   (gp:graphics-state-foreground gs))
               (bg   (gp:graphics-state-background gs))
               (port (gp:create-pixmap-port pane port-width port-height
                                            :background bg
                                            :foreground fg
                                            :clear      t)))
          (dolist (item (display-list-items pane))
            (funcall item pane port x y width height))
          (draw-legend pane port)
          (save-backing-image pane port)))
    
      (gp:copy-pixels pane backing-image 0 0 port-width port-height 0 0))
    
    
    (when full-crosshair
      (draw-crosshair-lines pane full-crosshair prev-x prev-y))
    ))
    
(defun resize-callback (pane x y width height)
  (declare (ignore x y width height))
  (with-accessors ((resize-timer  plotter-resize-timer)) pane
    (unless resize-timer
      (setf resize-timer
            (mp:make-timer
             (lambda ()
               (discard-backing-image pane)
               (capi:apply-in-pane-process pane
                                           #'gp:invalidate-rectangle
                                           pane)))
            ))
    (mp:schedule-timer-relative-milliseconds resize-timer 100)
    ))

(defun real-eval-with-nans (fn &rest args)
  (handler-case
      (let ((v (apply fn args)))
        (if (and (numberp v)
                 (or (complexp  v)
                     (infinitep v)
                     (nanp      v)))
            :nan
          v))
    (error (err)
      (declare (ignore err))
      :nan)))

(defun compute-x-y-at-cursor (pane x y)
  (with-accessors  ((sf         plotter-sf                 )
                    (magn       plotter-magn               )
                    (inv-xform  plotter-inv-xform          )
                    (xlog       plotter-xlog               )
                    (ylog       plotter-ylog               )
                    (x-readout-hook  plotter-x-readout-hook)
                    (y-readout-hook  plotter-y-readout-hook)) pane
    (let ((eff-sf (* sf magn)))
      (multiple-value-bind (xx yy)
          (gp:transform-point inv-xform (/ x eff-sf) (/ y eff-sf))
        (list (real-eval-with-nans
               (if xlog
                   (um:compose x-readout-hook #'pow10)
                 x-readout-hook)
               xx)
              (real-eval-with-nans
               (if ylog
                   (um:compose y-readout-hook #'pow10)
                 y-readout-hook)
               yy)
              ))
      )))
  
(defun mouse-move (pane x y &rest args)
  (declare (ignore args))
  (let ((intf (capi:top-level-interface pane)))
    (destructuring-bind (xx yy) (compute-x-y-at-cursor pane x y)
      (setf (capi:interface-title intf)
            (format nil "~A  x = ~,5g  y = ~,5g"
                    (plotter-base-title pane) xx yy))

      (let ((full-crosshair  (plotter-full-crosshair pane)))
        (when full-crosshair
          (with-accessors ((prev-x   plotter-prev-x)
                           (prev-y   plotter-prev-y)) pane
            #+:WIN32
            (progn
              (draw-crosshair-lines pane full-crosshair prev-x prev-y)
              (draw-crosshair-lines pane full-crosshair x      y)
              
              (setf prev-x x
                    prev-y y))
            
            #+:COCOA
            (let ((xx (shiftf prev-x x))
                  (yy (shiftf prev-y y)))
              (if (plotter-backing pane)
                  (let ((wd (gp:port-width pane))
                        (ht (gp:port-height pane)))
                    (gp:invalidate-rectangle pane xx 0 1 ht)
                    (gp:invalidate-rectangle pane 0 yy wd 1)
                    (gp:invalidate-rectangle pane x 0 1 ht)
                    (gp:invalidate-rectangle pane 0 y wd 1))
                (gp:invalidate-rectangle pane)
                ))
            )))
      )))

(defun show-x-y-at-cursor (pane x y &rest _)
  (declare (ignore _))
  (destructuring-bind (xx yy) (compute-x-y-at-cursor pane x y)
    (let ((xstr (format nil "~,5g" xx))
          (ystr (format nil "~,5g" yy)))
      (capi:display-tooltip pane
                            :x  (+ x 10)
                            :y  (+ y 10)
                            :text (format nil "(~A, ~A)"
                                          (string-trim " " xstr)
                                          (string-trim " " ystr))
                            ))))

;; user callable function
(defun set-x-readout-hook (pane fn)
  (let ((pane (plotter-pane-of pane)))
    (setf (plotter-x-readout-hook pane) fn)))

;; user callable function
(defun set-y-readout-hook (pane fn)
  (let ((pane (plotter-pane-of pane)))
    (setf (plotter-y-readout-hook pane) fn)))

;; -----------------------------------------------------------
#+:WIN32
(defun draw-nominal-image (pane port)
  (with-accessors ((nominal-width   plotter-nominal-width )
                   (nominal-height  plotter-nominal-height)
                   (sf              plotter-sf            )
                   (magn            plotter-magn          )
                   (xform           plotter-xform         )
                   (display-list    plotter-display-list  )) pane

    (let ((save-xform  xform)
          (save-magn   magn)
          (save-sf     sf))
      (unwind-protect
          (progn
            (gp:clear-graphics-port-state pane)
            
            (setf xform '(1 0 0 1 0 0)
                  magn  1
                  sf    1)

            (dolist (item (display-list-items pane))
              (funcall item pane port 0 0 nominal-width nominal-height))
            (draw-legend pane port))
        
        (progn
          (setf sf    save-sf
                magn  save-magn
                xform save-xform))
        ))))

#+:WIN32
(defun get-nominal-image (pane)
  ;; should only be called by the capi process
  (let* ((xpane (gp:create-pixmap-port pane
                                       (plotter-nominal-width pane)
                                       (plotter-nominal-height pane)
                                       :background (background-color pane)
                                       :foreground (foreground-color pane)
                                       :clear      t)))
    ;; this avoids image artifacts due to image shrinkage or expansion
    ;; just draw at original (nominal) scale
    (draw-nominal-image pane xpane)
    
    #|
  (let* ((sf (/ (plotter-sf pane))))
    
    (if (plotter-backing pane)
        (gp:with-graphics-scale (xpane sf sf)
          (gp:draw-image xpane (plotter-backing pane) 0 0))
      
      (with-image (pane (img (gp:make-image-from-port pane)))
        (gp:with-graphics-scale (xpane sf sf)
          (gp:draw-image xpane img 0 0)
          ))))
    |#
    
    (values xpane (gp:make-image-from-port xpane))
    ))

#+:WIN32
(defmacro with-nominal-image ((pane img) &body body)
  ;; should only be used by functions called by the capi process
  (um:with-gensyms (xpane)
    `(multiple-value-bind (,xpane ,img)
         (get-nominal-image ,pane)
       (unwind-protect
           (progn
             ,@body)
         (progn
           (gp:free-image ,xpane ,img)
           (gp:destroy-pixmap-port ,xpane))))
    ))

;; ----------------------------------------------------------
;;
#+:COCOA
(defun delay-backing-store (pane)
  (capi:apply-in-pane-process pane
                              (lambda ()
                                (discard-backing-image pane)
                                (setf (plotter-delay-backing pane) t)
                                (gp:invalidate-rectangle pane))))

#+:COCOA
(defun undelay-backing-store (pane)
  (setf (plotter-delay-backing pane) nil))

#+:COCOA
(defmacro with-bare-pdf-image ((pane) &body body)
  (let ((save-hair (gensym))
        (save-sf   (gensym)))
    `(let ((,save-hair (shiftf (plotter-full-crosshair ,pane) nil))
           (,save-sf   (shiftf (plotter-sf ,pane) 1)))
       (delay-backing-store ,pane)
       (unwind-protect
           (progn
             ,@body)
         (progn
           (undelay-backing-store ,pane)
           (setf (plotter-full-crosshair ,pane) ,save-hair
                 (plotter-sf ,pane) ,save-sf))
         ))
    ))

;; user callable function
(defun save-image (pane file &key &allow-other-keys)
  ;; can be called from anywhere
  (let ((dest (or file
                  (capi:prompt-for-file
                   "Write Image to File"
                   :operation :save
                   :filter #+:COCOA "*.pdf"
                           #+:WIN32 "*.bmp"))))
    (when dest
      (let ((pane (plotter-pane-of pane)))
        (sync-with-capi-pane pane
                             #+:COCOA
                             (lambda ()
                               (with-bare-pdf-image (pane)
                                 (save-pdf-plot pane (namestring dest))))
                             #+:WIN32
                             (lambda ()
                               (with-nominal-image (pane img)
                                                   (let ((eimg (gp:externalize-image pane img)))
                                                     (gp:write-external-image eimg dest
                                                                              :if-exists :supersede)
                                                     )))
                             )))
    ))

;; user callable function
(defun save-plot (&rest args)
  (apply #'save-image args))

(defun save-image-from-menu (pane &rest args)
  ;; called only in the pane's process
  (declare (ignore args))
  (let ((dest (capi:prompt-for-file
               "Write Image to File"
               :operation :save
               :filter #+:COCOA "*.pdf"
                       #+:WIN32 "*.bmp")))
    (when dest
      #+:COCOA (with-bare-pdf-image (pane)
                 (save-pdf-plot pane (namestring dest)))
      #+:WIN32 (save-image (namestring dest) :pane pane))
    ))

(defun copy-image-to-clipboard (pane &rest args)
  ;; called only as a callback in the capi process
  (declare (ignore args))
  #+:COCOA
  (with-bare-pdf-image (pane)
     (copy-pdf-plot pane))
  #+:WIN32
  (with-nominal-image (pane img)
    (capi:set-clipboard pane nil nil (list :image img)))
  )

(defun print-plotter-pane (pane &rest args)
  (declare (ignore args))
  ;; executed in the process of the capi pane
  #+:COCOA
  (with-bare-pdf-image (pane)
     (capi:simple-print-port pane
                             :interactive t))
  #+:WIN32
  (with-nominal-image (pane img)
    (capi:simple-print-port pane
                            :interactive t))
  )

(defparameter *cross-cursor*
  (ignore-errors
    (capi:load-cursor
     '((:win32 "c:/projects/lib/crosshair.cur")
       (:cocoa "/usr/local/lib/crosshair.gif"
        :x-hot 7
        :y-hot 7))
     )))

;; user callable function
(defun set-full-crosshair (pane full-crosshair)
  (let ((pane (plotter-pane-of pane)))
    (sync-with-capi-pane pane
                         (lambda ()
                           (setf (plotter-full-crosshair pane)
                                 #+:COCOA full-crosshair
                                 #+:WIN32
                                 (and full-crosshair
                                      (complementary-color full-crosshair
                                                           (background-color pane))
                                      ))
                           (when (null full-crosshair)
                             (setf (plotter-prev-x pane) nil
                                   (plotter-prev-y pane) nil))
                           
                           (gp:invalidate-rectangle pane))
                         )))

;; called only from the plotter-window menu (CAPI process)
(defun toggle-full-crosshair (pane &rest args)
  (declare (ignore args))
  (setf (plotter-full-crosshair pane)
        (if (plotter-full-crosshair pane)
            (setf (plotter-prev-x pane) nil
                  (plotter-prev-y pane) nil)
          #+:COCOA :red
          #+:WIN32 (complementary-color :red
                                        (background-color pane))))
  (gp:invalidate-rectangle pane))
                                        
;; ------------------------------------------
(capi:define-interface plotter-window ()
  ((name :accessor plotter-window-name :initarg :name))
  (:panes (drawing-area <plotter-pane>
                        :display-callback 'display-callback
                        :resize-callback  'resize-callback
                        :input-model      '((:motion mouse-move)
                                            ((:button-1 :press) show-x-y-at-cursor)
                                            ((:gesture-spec "Control-c")
                                             copy-image-to-clipboard)
                                            ((:gesture-spec "Control-p")
                                             print-plotter-pane)
                                            ((:gesture-spec "Control-s")
                                             save-image-from-menu)
                                            ((:gesture-spec "C")
                                             toggle-full-crosshair)
                                            ((:gesture-spec "c")
                                             toggle-full-crosshair)
                                            )
                        :cursor   (or *cross-cursor*
                                      :crosshair)
                        :accessor drawing-area))
  
  (:layouts (default-layout
             capi:simple-layout
             '(drawing-area)))
  
  (:menus (pane-menu "Pane"
                     (("Copy"
                       :callback      'copy-image-to-clipboard
                       :accelerator   "accelerator-c")
                      ("Save as..."
                       :callback      'save-image-from-menu
                       :accelerator   "accelerator-s")
                      ("Print..."
                       :callback      'print-plotter-pane
                       :accelerator   "accelerator-p"))
                     :callback-type :data
                     :callback-data  drawing-area))
  
  (:menu-bar pane-menu)
  
  (:default-initargs
   :layout              'default-layout
   :window-styles       '(:internal-borderless)
   ))

(defmethod capi:interface-match-p ((intf plotter-window) &rest initargs
                              &key name &allow-other-keys)
  (declare (ignore initargs))
  (equalp name (plotter-window-name intf)))

(defmethod capi:interface-reuse-p ((intf plotter-window) &rest initargs
                                   &key &allow-other-keys)
  ;; called only if capi cannot find the window specified by name 
  ;; with the above capi:interface-match-p function
  nil)

;; ---------------------------------------------------------------
(defmethod plotter-pane-of ((intf plotter-window))
  (drawing-area intf))

(defmethod plotter-pane-of (name)
  ;; allow for symbolic names in place of plotter-windows or <plotter-pane>s
  ;; names must match under EQUALP (i.e., case insensitive strings, symbols, numbers, etc.)
  (wset name))
    
(defun find-named-plotter-pane (name)
  ;; locate the named plotter window and return its <plotter-pane> object
  (let ((win (capi:locate-interface 'plotter-window :name name)))
    (and win
         (plotter-pane-of win))))

;; ---------------------------------------------------------------
(defun make-plotter-window (&key
                            (name       0)
                            (title      "Plot")
                            (fg         :black)
                            (bg         :white)
                            (foreground fg)
                            (background bg)
                            (xsize      400)
                            (ysize      300)
                            xpos
                            ypos
                            (best-width         xsize)
                            (best-height        ysize)
                            (best-x             xpos)
                            (best-y             ypos)
                            (visible-min-width  (/ xsize 2))
                            (visible-min-height (/ ysize 2))
                            (visible-max-width  (* xsize 2))
                            (visible-max-height (* ysize 2))
                            full-crosshair)
  (let* ((intf (make-instance 'plotter-window
                              :name                name
                              :title               title
                              :best-width          best-width
                              :best-height         best-height
                              :visible-min-width   visible-min-width
                              :visible-min-height  visible-min-height
                              :visible-max-width   visible-max-width
                              :visible-max-height  visible-max-height
                              :best-x              best-x
                              :best-y              best-y
                              :background          background
                              :foreground          foreground))
         (pane (drawing-area intf)))
    
    (setf (capi:simple-pane-background pane) background
          (capi:simple-pane-foreground pane) foreground
          (plotter-nominal-width  pane)      best-width
          (plotter-nominal-height pane)      best-height
          (plotter-base-title     pane)      title
          (plotter-full-crosshair pane)      #+:COCOA full-crosshair
                                             #+:WIN32 (and full-crosshair
                                                           (complementary-color
                                                            full-crosshair background)))
    intf))

;; ------------------------------------------
(defun window (name &rest args &key
                    (title      (format nil "Plotter:~A" name))
                    (background #.(color:make-gray 1))
                    (foreground #.(color:make-gray 0))
                    (xsize      400)
                    (ysize      300)
                    xpos
                    ypos
                    (best-width         xsize)
                    (best-height        ysize)
                    (best-x             xpos)
                    (best-y             ypos)
                    (visible-min-width  (/ xsize 2))
                    (visible-min-height (/ ysize 2))
                    (visible-max-width  (* xsize 2))
                    (visible-max-height (* ysize 2))
                    full-crosshair)

  (let ((pane (find-named-plotter-pane name)))
    (when (or args
              (null pane))

      (when pane
        (wclose name))
      
      (let ((intf (make-plotter-window
                   :name                name
                   :title               title
                   :best-width          best-width
                   :best-height         best-height
                   :visible-min-width   visible-min-width
                   :visible-min-height  visible-min-height
                   :visible-max-width   visible-max-width
                   :visible-max-height  visible-max-height
                   :best-x              best-x
                   :best-y              best-y
                   :background          background
                   :foreground          foreground
                   :full-crosshair      full-crosshair)))
        
        (setf pane (drawing-area intf))
        (capi:display intf)
        ))
    pane))

;; ------------------------------------------
(defun wset (name &key clear)
  ;; If window exists don't raise it to the top.
  ;; If window does not exist then create it with default parameters.
  ;; Return the plotting pane object
  (let ((pane (window name))) ;; locate existing or create anew
    (when clear
      (clear pane))
    pane))

;; ------------------------------------------
(defun wshow (name)
  ;; If window exists then raise it to the top.
  ;; If window does not exist then create it with default parameters
  (let* ((pane (window name))  ;; locate existing or create anew
         (intf (capi:top-level-interface pane)))
    (capi:execute-with-interface intf
                                 #'capi:raise-interface intf)
    ))

;; ------------------------------------------
(defun wclose (name)
  ;; if window exists then ask it to commit suicide and disappear
  (let ((intf (capi:locate-interface 'plotter-window :name name)))
    (when intf
      (capi:execute-with-interface intf #'capi:destroy intf))
    ))

;; ------------------------------------------
;; ------------------------------------------
(defun outsxy (pane x y str
                  &rest args
                  &key
                  (font-size $normal-times-font-size)
                  (font "Times")
                  anchor
                  (align :w)
                  (offset-x 0) ;; pixel offsets
                  (offset-y 0)
                  clip
                  (color :black)
                  alpha
                  &allow-other-keys)
  (let ((pane (plotter-pane-of pane)))
    (with-delayed-update (pane)
      (append-display-list pane
                           #'(lambda (pane port xarg yarg width height)
                               (declare (ignore xarg yarg width height))
                               (let* ((xx (+ offset-x (get-x-location pane x)))
                                      (yy (+ offset-y (get-y-location pane y)))
                                      (font (find-best-font pane
                                                            :family font
                                                            :size   (* (plotter-sf pane) font-size)))
                                      (x-align (ecase (or anchor align)
                                                 ((:nw :w :sw) :left)
                                                 ((:n :s :ctr) :center)
                                                 ((:ne :e :se) :right)))
                                      (y-align (ecase (or anchor align)
                                                 ((:nw :n :ne) :top)
                                                 ((:w :ctr :e) :center)
                                                 ((:sw :s :se) :baseline)))
                                      (sf   (plotter-sf pane))
                                      (mask (and clip
                                                 (adjust-box
                                                  (mapcar (um:expanded-curry (v) #'* sf)
                                                          (plotter-box pane))
                                                  )))
                                      (color (adjust-color pane color alpha)))
                                 
                                 #+:WIN32
                                 (with-mask (port mask)
                                     (apply #'draw-string-x-y pane port str
                                            (* sf xx) (* sf yy)
                                            :font font
                                            :x-alignment x-align
                                            :y-alignment y-align
                                            :color       color
                                            args))
                                 #+:COCOA
                                 (let* ((font-attrs (gp:font-description-attributes
                                                     (gp:font-description font)))
                                        (font-name  (getf font-attrs :name))
                                        (font-size  (getf font-attrs :size)))
                                   (apply #'add-label port str (* sf xx) (* sf yy)
                                          :font        font-name
                                          :font-size   font-size
                                          :color       color
                                          :x-alignment x-align
                                          :y-alignment y-align
                                          :box         mask
                                          args))
                                 
                                 ))))
    ))

;; ---------------------------------------------------------
;; org can be a list of (type xorg yorg), e.g., '(:frac 0.9 0.96)
;; or a pair of typed values ((type xorg) (type yorg)), e.g., '((:frac 0.9) (:data 14.3))
;;
;; convert to a list of typed pairs, e.g., '((:frac 0.9) (:data 14.3))
;;
(defun get-xy-orgs (org)
  (if (= 3 (length org))
      (list (list (first org) (second org))
            (list (first org) (third org)))
    org))

(defun draw-text (pane str org &rest args)
  (destructuring-bind (xorg yorg) (get-xy-orgs org)
    (apply #'outsxy pane xorg yorg str args)))

;; ------------------------------------------
(defun plot-histogram (pane v &rest args
                            &key min max range nbins binwidth
                            ylog cum norm
                            (symbol :steps)
                            &allow-other-keys)
  (multiple-value-bind (x h)
      (vm:histogram v
                    :min      min
                    :max      max
                    :range    range
                    :nbins    nbins
                    :binwidth binwidth)
    (let (tot minnz)
      (when norm
        (setf tot (vsum h))
        (loop for v across h
              for ix from 0
              do
              (setf (aref h ix) (/ v tot))
              ))
      (when cum
        (loop for v across h
              for ix from 0
              for sum = v then (+ sum v)
              do
              (setf (aref h ix) sum)
              (unless (or minnz
                          (zerop sum))
                (setf minnz sum))
              ))
      (when ylog
        (let ((zlim (cond (cum  minnz)
                          (norm (/ 0.9 tot))
                          (t     0.9)
                          )))
          (loop for v across h
                for ix from 0
                do
                (when (zerop v)
                  (setf (aref h ix) zlim)))
          ))
      (apply #'plot pane x h :symbol symbol args)
      )))

;; -----------------------------------------------------------------
;; Functional plotting with adaptive gridding
;; DM/RAL 12/06
;; ----------------------------------------------------------------------------------------
;; Parametric Plotting with adaptive gridding
;;
(defun nan-or-infinite-p (v)
  (or (eq v :nan)
      (nanp v)
      (infinitep v)))

(defun filter-x-y-nans-and-infinities (xs ys)
  (let ((pairs (loop for x in xs
                     for y in ys
                     unless (or (nan-or-infinite-p x)
                                (nan-or-infinite-p y))
                     collect (list x y))))
    (list (mapcar #'first pairs) (mapcar #'second pairs))
    ))

(defun filter-nans-and-infinities (xs)
  (remove-if #'nan-or-infinite-p xs))

(defun do-param-plotting (plotfn pane xfn yfn npts args)
  (destructuring-bind (tmin tmax) (plotter-trange pane)
    (destructuring-bind (tprepfn itprepfn) (plotter-tprepfns pane)
      (declare (ignore tprepfn))
      (destructuring-bind (xprepfn ixprepfn) (plotter-xprepfns pane)
        (destructuring-bind (yprepfn iyprepfn) (plotter-yprepfns pane)
          (let* ((xsf (plotter-xsf pane))
                 (ysf (plotter-ysf pane))
                 (ts  (if npts
                          (loop for ix from 0 to npts collect
                                (+ tmin (* ix (/ (- tmax tmin) npts))))
                        (loop for ix from 0 to 16 collect
                              (+ tmin (* ix 0.0625 (- tmax tmin))))))
                 (xfn (um:expanded-compose (tval) xprepfn xfn itprepfn))
                 (yfn (um:expanded-compose (tval) yprepfn yfn itprepfn))
                 (xs  (mapcar (lambda (tval)
                                (real-eval-with-nans xfn tval))
                              ts))
                 (ys  (mapcar (lambda (tval)
                                (real-eval-with-nans yfn tval))
                              ts)))
            
            (labels ((split-interval (lvl t0 t1 x0 x1 y0 y1 new-xs new-ys)
                       (if (> lvl 9)
                           
                           (list (cons x0 new-xs)
                                 (cons y0 new-ys))
                         
                         (let* ((tmid (* 0.5 (+ t0 t1)))
                                (xmid (if (or (nan-or-infinite-p x0)
                                              (nan-or-infinite-p x1))
                                          :nan
                                        (* 0.5 (+ x0 x1))))
                                (ymid (if (or (nan-or-infinite-p y0)
                                              (nan-or-infinite-p y1))
                                          :nan
                                        (* 0.5 (+ y0 y1))))
                                (xmv  (real-eval-with-nans xfn tmid))
                                (ymv  (real-eval-with-nans yfn tmid)))
                           
                           (if (or (nan-or-infinite-p xmv)
                                   (nan-or-infinite-p xmid)
                                   (nan-or-infinite-p ymv)
                                   (nan-or-infinite-p ymid)
                                   (> (abs (* xsf (- xmv xmid))) 0.5)
                                   (> (abs (* ysf (- ymv ymid))) 0.5))
                               
                               (destructuring-bind (new-xs new-ys)
                                   (split-interval (1+ lvl)
                                                   t0 tmid x0 xmv y0 ymv
                                                   new-xs new-ys)
                                 
                                 (split-interval (1+ lvl)
                                                 tmid t1 xmv x1 ymv y1
                                                 new-xs new-ys))
                             
                             (list (cons x0 new-xs)
                                   (cons y0 new-ys))))
                         ))
                     
                     (iter-points (ts xs ys new-xs new-ys)
                       (if (endp (rest ts))
                           
                           (list (cons (first xs) new-xs)
                                 (cons (first ys) new-ys))
                         
                         (destructuring-bind (t0 t1 &rest _) ts
                           (declare (ignore _))
                           (destructuring-bind (x0 x1 &rest _) xs
                             (declare (ignore _))
                             (destructuring-bind (y0 y1 &rest _) ys
                               (declare (ignore _))
                               
                               (destructuring-bind (new-xs new-ys)
                                   (split-interval 0 t0 t1 x0 x1 y0 y1
                                                   new-xs new-ys)
                                 
                                 (iter-points (rest ts) (rest xs) (rest ys)
                                              new-xs new-ys)
                                 ))))
                         )))
              
              (destructuring-bind (xs ys)
                  (if npts
                      (list xs ys)
                    (iter-points ts xs ys nil nil))
                (let ((xs (if ixprepfn
                              (mapcar (lambda (xval)
                                        (real-eval-with-nans ixprepfn xval))
                                      xs)
                            xs))
                      (ys (if iyprepfn
                              (mapcar (lambda (yval)
                                        (real-eval-with-nans iyprepfn yval))
                                      ys)
                            ys)))
                  (destructuring-bind (xsn ysn)
                      (filter-x-y-nans-and-infinities xs ys)
                    (apply plotfn pane xsn ysn args)
                    (list (length xsn) xsn ysn)
                    )))
              )))
        ))))

;; ------------------------------------------
(defun paramplot (pane domain xfn yfn &rest args
                         &key tlog xlog ylog xrange yrange npts
                         &allow-other-keys)
  (labels ((get-prepfns (islog)
             (if islog
                 (list #'log10 #'pow10)
               (list #'identity #'identity)))
           (get-minmax (est-minmax req-minmax prepfn)
             (destructuring-bind (est-min est-max) est-minmax
               (destructuring-bind (req-min req-max) req-minmax
                 (if (= req-min req-max)
                     (if (= est-min est-max)
                         (let* ((vmin (funcall prepfn est-min))
                                (vmax (if (zerop vmin) 0.1 (* 1.1 vmin))))
                           (list vmin vmax))
                       (list (funcall prepfn est-min)
                             (funcall prepfn est-max)))
                   (list (funcall prepfn req-min)
                         (funcall prepfn req-max)))
                 ))))
    (destructuring-bind (tprepfn itprepfn) (get-prepfns tlog)
      (destructuring-bind (xprepfn ixprepfn) (get-prepfns xlog)
        (destructuring-bind (yprepfn iyprepfn) (get-prepfns ylog)
          (destructuring-bind (tmin tmax) (get-minmax '(0 0) domain tprepfn)
            (let* ((ts (loop for ix from 0 to 16 collect
                             (+ tmin (* ix 0.0625 (- tmax tmin)))))
                   (xfnn (um:expanded-compose (tval) xfn itprepfn))
                   (yfnn (um:expanded-compose (tval) yfn itprepfn))
                   (xs (mapcar (lambda (tval)
                                 (real-eval-with-nans xfnn tval))
                               ts))
                   (ys (mapcar (lambda (tval)
                                 (real-eval-with-nans yfnn tval))
                               ts)))
              (destructuring-bind (xmin xmax) (get-minmax
                                               (let ((xsn (filter-nans-and-infinities xs)))
                                                 (list (vmin xsn)
                                                       (vmax xsn)))
                                               (or xrange '(0 0)) xprepfn)
                (destructuring-bind (ymin ymax) (get-minmax
                                                 (let ((ysn (filter-nans-and-infinities ys)))
                                                   (list (vmin ysn)
                                                         (vmax ysn)))
                                                 (or yrange '(0 0)) yprepfn)
                  (let ((pane (plotter-pane-of pane)))
                    (setf (plotter-trange pane)   (list tmin tmax)
                          (plotter-xsf pane)      (qdiv (plotter-nominal-width pane)
                                                        (- xmax xmin))
                          (plotter-ysf pane)      (qdiv (plotter-nominal-height pane)
                                                        (- ymax ymin))
                          (plotter-tprepfns pane) (list tprepfn itprepfn)
                          (plotter-xprepfns pane) (list xprepfn (and xlog ixprepfn))
                          (plotter-yprepfns pane) (list yprepfn (and ylog iyprepfn)))
                    (do-param-plotting #'plot pane xfn yfn npts args))
                  )))
            )))
      )))

(defun fplot (pane domain fn &rest args)
  (apply #'paramplot pane domain #'identity fn args))

;; ------------------------------------------
(defconstant $gray-colormap
  (let ((map (make-array 256)))
    (loop for ix from 0 to 255 do
          (setf (aref map ix) (color:make-gray (/ (float ix) 255.0))
                ))
    map))

(defconstant $heat-colormap
  (let ((map (make-array 256)))
    (labels ((clip (v)
               (max 0.0 (min 1.0 (/ v 255)))))
      (loop for ix from 0 to 255 do
            (setf (aref map ix)
                  (color:make-rgb
                   (clip (/ (* 255 ix) 176))
                   (clip (/ (* 255 (- ix 120)) 135))
                   (clip (/ (* 255 (- ix 190)) 65)))
                  )))
    map))

(defparameter *current-colormap* $heat-colormap) ;;$gray-colormap

(defparameter *tst-img*
  (let ((img (make-array '(64 64))))
    (loop for row from 0 below 64 do
          (loop for col from 0 below 64 do
                (setf (aref img row col) (* row col))
                ))
    img))

(defun tvscl (pane arr
              &key (magn 1)
              (colormap *current-colormap*)
              &allow-other-keys)
  (let ((pane (plotter-pane-of pane)))
    (with-delayed-update (pane)
      (append-display-list
       pane
       #'(lambda (pane port x y width height)
           (declare (ignore x y width height))
           (let* ((wd   (array-dimension-of arr 1))
                  (ht   (array-dimension-of arr 0))
                  (mn   (vmin-of arr))
                  (mx   (vmax-of arr))
                  (sf   (/ 255 (- mx mn))))
             
             (with-image (port (img #+:COCOA (gp:make-image port wd ht)
                                    #+:WIN32 (gp:make-image port wd ht :alpha nil)
                                    ))
               (with-image-access (acc (gp:make-image-access port img))
                 (loop for row from 0 below ht do
                       (loop for col from 0 below wd do
                             (setf (gp:image-access-pixel acc row col)
                                   (color:convert-color
                                    pane
                                    (aref colormap
                                          (round (* sf (- (aref-of arr row col) mn)))))
                                   )))
                 (gp:image-access-transfer-to-image acc))
               
               (let ((sf (* magn (plotter-sf pane))))
                 (gp:with-graphics-scale (port sf sf)
                   (gp:draw-image port img 0 0))
                 ))
             (setf (plotter-magn pane) magn)
             )))
      )))

(defun render-image (pane ext-img
                     &key
                     (magn 1)
                     (to-x 0)
                     (to-y 0)
                     (from-x 0)
                     (from-y 0)
                     to-width
                     to-height
                     from-width
                     from-height
                     transform
                     global-alpha
                     &allow-other-keys)
  (let ((pane (plotter-pane-of pane)))
    (with-delayed-update (pane)
      (append-display-list
       pane
       #'(lambda (pane port x y wd ht)
           (declare (ignore x y wd ht))
           (let ((sf (* magn (plotter-sf pane))))
             (with-image (port (img (gp:convert-external-image port ext-img)))
               (gp:with-graphics-scale (port sf sf)
                 (gp:draw-image port img to-x to-y
                                :transform    transform
                                :from-x       from-x
                                :from-y       from-y
                                :to-width     to-width
                                :to-height    to-height
                                :from-width   from-width
                                :from-height  from-height
                                :global-alpha global-alpha)
                 ))
             (setf (plotter-magn pane) magn)
             )))
      )))

(defun read-image (&optional file)
  (gp:read-external-image (or file
                              (capi:prompt-for-file
                               "Select Image File"
                               :filter "*.*"))
                          ))

(defun dump-hex (arr &key (nlines 10))
  (loop for ix from 0 below (array-total-size-of arr) by 16
        for line from 0 below nlines
        do
        (format t "~%~4,'0x: ~{~{~2,'0x ~} ~} ~A"
                ix
                (loop for jx from 0 below 16 by 4
                      collect
                      (coerce (subseq-of arr (+ ix jx) (+ ix jx 4)) 'list))
                (let ((s (make-string 16)))
                  (loop for jx from 0 below 16 do
                        (setf (aref s jx)
                              (let ((v (code-char (aref-of arr (+ ix jx)))))
                                (if (graphic-char-p v)
                                    v
                                  #\.))
                              ))
                  s))
        ))

(defun sinc (x)
  (/ (sin x) x))

#|
(window 2)
(fplot '(0.001 10) (lambda (x) (/ (sin x) x)))
(tvscl *tst-img* :magn 4)
|#

;; ------------------------------------------
#| Test code...

(let (x y)
  (defun ramp (min max npts)
    (let ((val (make-array npts))
          (rate (/ (- max min) npts)))
      (dotimes (ix npts val)
        (setf (aref val ix) (+ min (* ix rate))))
      ))
  
  (setf x (ramp -10 10 100))
  (defun sinc (val)
    (if (zerop val)
        1.0
      (/ (sin val) val)))
  (setf y (map 'vector 'sinc x))
  
  (window 0 :xsize 400 :ysize 300)
  (plot x y 
        :color (color:make-rgb 1.0 0.0 0.0 0.25) ;;:red
        :thick 2
        :title "Sinc(x)"
        :xtitle "X Values"
        :ytitle "Y Values")

  ;;  (window 1 :background :black :foreground :yellow :xsize 400 :ysize 300)
  ;;  (plot x y 
  ;;        :color (color:make-rgb 1.0 0.0 1.0 0.25) ;;:magenta
  ;;        :linewidth 2
  ;;        :fullgrid (color:make-gray 0.25)
  ;;        :title "Sinc(x)"
  ;;        :xtitle "X Values"
  ;;        :ytitle "Y Values")
  )
|#


;; *eof* ;;
