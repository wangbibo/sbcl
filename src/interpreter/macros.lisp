;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-INTERPRETER")

;;; Special form handlers are stored in the NAME slot of the #<FDEFN>
;;; of the symbol naming the operator. This is extremely fast to look up.
;;; It's about 9x faster than a hashtable, and 2x faster than the plist
;;; even with no other properties on the plist. Moreover, plists can be
;;; clobbered by users. Since nobody has reason to look at fdefns of
;;; special forms, it doesn't matter what the name is.
;;; You'll never see one in a disassembly.
(defmacro !special-form-handler (fdefn)
  (let ((thing (make-symbol "DEFN")))
    `(let ((,thing (fdefn-name ,fdefn)))
       (when (typep ,thing '(cons function))
         ,thing))))

;;; DEFSPECIAL name (destructuring-lambda-list)
;;;    [FORMS]*
;;;    :IMMEDIATE (ENV) FORMS+
;;;    :DEFERRED (&optional ENV) FORMS+
;;;
;;; Two versions of a special-form processor for NAME are defined:
;;; an immediate-mode processor which performs recursive-descent EVAL,
;;; and a deferred-mode processor which digests the form to produce
;;; a callable object that when called evaluates the form.
;;; KLUDGE: Any code preceding :IMMEDIATE or :DEFERRED is common to both,
;;; and stuffed in front of the mode-specific handler.
;;; Processors may be specified for ordinary macros; this permits
;;; treating things like AND/OR/COND as specials forms.
;;;
;;; If :IMMEDIATE code is unspecified, immediate mode generates a deferred
;;; handler, then call that. If specified as :NONE, the form is not treated
;;; as a special form in immediate mode - it must be a macro.
;;;
(defmacro defspecial (name macro-lambda-list &body body)
  (let* ((specialized-code
          (member-if (lambda (form) (member form '(:immediate :deferred)))
                     body))
         (common-code (ldiff body specialized-code))
         (immediate-code)
         (deferred-code))
    ;; allow either-order
    (ecase (car specialized-code)
      (:immediate
        (setq deferred-code (member :deferred specialized-code)
              immediate-code (ldiff specialized-code deferred-code)))
      (:deferred
       (setq immediate-code (member :immediate specialized-code)
             deferred-code (ldiff specialized-code immediate-code))))
    (pop immediate-code)
    (pop deferred-code)
    (unless deferred-code
      (error "Deferred-mode handler is mandatory"))
    (let ((form-var (gensym "FORM")))
      (flet ((gen-code (mode body)
               (when (equal body '(:none))
                 (return-from gen-code nil))
               (destructuring-bind (&optional (env (gensym "ENV")
                                                   env-supplied-p))
                   (pop body)
                 (setq body (append common-code body))
                 `(named-lambda (,mode ,name) (,form-var ,env)
                    ,@(unless env-supplied-p
                        `((declare (ignorable ,env))))
                    (block ,name
                      (macrolet ((when-lexical-var ((frame-ptr sym) &body body)
                                   `(let ((,frame-ptr
                                           (maybe-lexical-var env ,sym)))
                                      (unless ,frame-ptr (return-from ,',name))
                                      ,@body)))
                        (with-subforms ,macro-lambda-list ,form-var
                                       ,@body)))))))
        ;; KLUDGE: obfuscated so that this isn't FOPCOMPILEd.
        ;; I don't want SB-VM::%SET-FDEFN-NAME to be funcallable.
        `((lambda (name def) (sb-vm::%set-fdefn-name name def))
          (find-fdefn ',name)
          ;; If there is no immediate handler, just punt by
          ;; dispatching an ad-hoc SEXPR. It is somewhat wasteful
          ;; to cons a handler that is called once and discarded,
          ;; but probably not too objectionable.
          (cons ,(if immediate-code
                     (gen-code :imm immediate-code)
                     `#'(named-lambda (:imm ,name) (form env)
                          (dispatch (%sexpr (cons ',name form)) env)))
                ,(gen-code :def deferred-code)))))))

;;; Create parallel bindings for LET or a LAMBDA's required args.
;;; Use of this macro is highly confined, so no bothering with ONCE-ONLY.
;;; FRAME-INDEX is purposely exposed and SPECIAL-B is freely referenced.
;;; It would be a MACROLET in the LET special form handler,
;;; except that LAMBDA needs it too.
;;;
(defmacro with-let-bindings ; also used by LAMBDA binder
    ((value-cells count
      &key (specialp '(locally (declare (muffle-conditions compiler-note))
                       (logbitp frame-index special-b)))
           value specials)
     &rest finally)
  (if specialp ; if some bound variables are special - free specials don't count
      (let ((special-vals (make-symbol "SPECIAL-VALS")))
        (assert specials)
        `(let (,special-vals)
           ;; It is important not to access 'specials' unless some binding is
           ;; actually special, because the access in APPLY-LAMBDA is with POP
           ;; which would destroy the list for the LET*-like bindings.
           (dotimes (frame-index ,count
                     (if ,special-vals
                         (progv ,specials ,special-vals ,@finally)
                         (progn ,@finally)))
             (let ((value ,value))
               (if ,specialp
                   (push value ,special-vals)
                   (setf (svref ,value-cells frame-index) value))))))
      ;; else no variables are special
      `(dotimes (frame-index ,count (progn ,@finally))
         (setf (svref ,value-cells frame-index) ,value))))

;;; Serial binding macro strives to have roughly the syntax as WITH-LET-BINDINGS
;;; but the name is different because this only binds the binder (LET*-BIND)
;;; which must be called to start recursion over bindings.
;;; As above, the uses of this macro are sufficiently confined that the
;;; usual precautions of WITH-UNIQUE-NAMES,ONCE-ONLY are dispensed with.
;;;
(defmacro with-let*-binder ; also used by LAMBDA binder
    ((value-cells count-place
      &key (specialp '(locally (declare (muffle-conditions compiler-note))
                       (logbitp frame-index special-b)))
           value specials)
     initially &rest finally)
  `(labels
       ((let*-bind (frame-index end)
          (declare (index frame-index end))
          (if (< frame-index end)
              (let ((value ,value))
                ;; if specialp is statically nil we avoid a code deletion
                ;; note by "manually" eliding half the logic :-(
                ,@(if specialp
                      `((if ,specialp
                            (progv ,specials (list value)
                              (let*-bind (setf ,count-place (1+ frame-index))
                                         end))
                            (progn
                              (setf (svref ,value-cells frame-index) value)
                              (let*-bind (setf ,count-place (1+ frame-index))
                                         end))))
                      `((setf (svref ,value-cells frame-index) value)
                        (let*-bind (setf ,count-place (1+ frame-index)) end))))
              (progn ,@finally))))
     ,initially))

;;; Bind VAR to each declaration-specifier in INPUT, which is a list of
;;; subexpresssions whose head was DECLARE in a form accepting declarations.
;;; The list as stored is doubly-nested because each DECLARE expression
;;; is preserved separately, and within it the declarations.
;;;  e.g. (locally (declare foo) (declare bar baz)) = ((foo) (bar baz))
(defmacro do-decl-spec ((var input &optional result) &body body)
  (let ((outer (gensym))
        (inner (gensym)))
    `(dolist (,outer ,input ,result)
       (do-anonymous ((,inner ,outer (cdr ,inner))) ((endp ,inner))
         (let ((,var (car ,inner)))
           ,@body)))))

;;; Special forms that accept declarations use this macro
;;; to perform typechecks upon entry to the declaration scope.
(defmacro enforce-types (scope env)
  `(let ((typechecks (extra-typechecks ,scope)))
     (unless (eql typechecks +none+)
       (%enforce-types typechecks ,env))))

;;; When the evaluator preprocesses a form that interacts with package locking,
;;; we convert the declarations to the format that a LEXENV expects.
;;; FIXME: it would be more efficient to change the package-lock tests
;;; to understand either a compiler LEXENV or an interpreter ENV.
;;; The main difficulty is that *LEXENV* can't be bound to an interpreter env.
(defmacro with-package-lock-context ((env-var) &body body)
  ;; PROGRAM-ASSERT-SYMBOL-HOME-PACKAGE-UNLOCKED can signal EVAL-ERROR,
  ;; and it's the only thing that can, so this is the only place
  ;; that we need to handle that condition.
  `(handler-case
       (let ((sb-c:*lexenv*
              (sb-c::make-lexenv :disabled-package-locks
                                 (env-disabled-package-locks ,env-var)
                                 :default (sb-kernel:make-null-lexenv))))
         ,@body)
     (sb-impl::eval-error (condition)
       ;; Just pull the original condition out and signal that.
       (error (encapsulated-condition condition)))))