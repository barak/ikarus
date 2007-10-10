
(module (alt-cogen)
;;; input to cogen is <Program>:
;;;  <Expr> ::= (constant x)
;;;           | (var)
;;;           | (primref name)
;;;           | (bind var* <Expr>* <Expr>)
;;;           | (fix var* <FixRhs>* <Expr>)
;;;           | (conditional <Expr> <Expr> <Expr>)
;;;           | (seq <Expr> <Expr>)
;;;           | (closure <codeloc> <var>*)  ; thunk special case
;;;           | (forcall "name" <Expr>*)
;;;           | (funcall <Expr> <Expr>*)
;;;           | (jmpcall <label> <Expr> <Expr>*)
;;;           | (mvcall <Expr> <clambda>)
;;;  <codeloc> ::= (code-loc <label>)
;;;  <clambda> ::= (clambda <label> <case>* <free var>*) 
;;;  <case>    ::= (clambda-case <info> <body>)
;;;  <info>    ::= (clambda-info label <arg var>* proper)
;;;  <Program> ::= (codes <clambda>* <Expr>)





(define (introduce-primcalls x)
  ;;;
  (define who 'introduce-primcalls)
  ;;;
  (define (check-gensym x)
    (unless (gensym? x)
      (error who "invalid gensym ~s" x)))
  ;;;
  (define (check-label x)
    (record-case x
      [(code-loc label)
       (check-gensym label)]
      [else (error who "invalid label ~s" x)]))
  ;;;
  (define (check-var x)
    (record-case x 
      [(var) (void)]
      [else (error who "invalid var ~s" x)]))
  ;;;
  (define (check-closure x)
    (record-case x
      [(closure label free*)
       (check-label label)
       (for-each check-var free*)]
      [else (error who "invalid closure ~s" x)]))
  ;;;
  (define (mkfuncall op arg*)
    (import primops)
    (record-case op
      [(primref name)
       (cond
         [(primop? name)
          (make-primcall name arg*)]
         [else (make-funcall op arg*)])]
      [else (make-funcall op arg*)]))
  ;;;
  (define (Expr x)
    (record-case x
      [(constant) x]
      [(var)      x]
      [(primref)  x]
      [(bind lhs* rhs* body)
       (make-bind lhs* (map Expr rhs*) (Expr body))]
      [(fix lhs* rhs* body)
       (make-fix lhs* rhs* (Expr body))]
      [(conditional e0 e1 e2) 
       (make-conditional (Expr e0) (Expr e1) (Expr e2))]
      [(seq e0 e1)
       (make-seq (Expr e0) (Expr e1))]
      [(closure) x]
      [(forcall op arg*)
       (make-forcall op (map Expr arg*))]
      [(funcall rator arg*)
       (mkfuncall (Expr rator) (map Expr arg*))]
      [(jmpcall label rator arg*)
       (make-jmpcall label (Expr rator) (map Expr arg*))]
      [(mvcall rator k)
       (make-mvcall (Expr rator) (Clambda k))]
      [else (error who "invalid expr ~s" x)]))
  ;;;
  (define (ClambdaCase x)
    (record-case x
      [(clambda-case info body)
       (make-clambda-case info (Expr body))]
      [else (error who "invalid clambda-case ~s" x)]))
  ;;;
  (define (Clambda x)
    (record-case x
      [(clambda label case* free* name)
       (make-clambda label (map ClambdaCase case*) free* name)]
      [else (error who "invalid clambda ~s" x)]))
  ;;;
  (define (Program x)
    (record-case x 
      [(codes code* body)
       (make-codes (map Clambda code*) (Expr body))]
      [else (error who "invalid program ~s" x)]))
  ;;;
  (Program x))



(define (eliminate-fix x)
  ;;;
  (define who 'eliminate-fix)
  ;;;
  (define (Expr cpvar free*)
    ;;;
    (define (Var x)
      (let f ([free* free*] [i 0])
        (cond
          [(null? free*) x]
          [(eq? x (car free*))
           (make-primcall '$cpref (list cpvar (make-constant i)))]
          [else (f (cdr free*) (fxadd1 i))])))
    (define (do-fix lhs* rhs* body)
      (define (handle-closure x)
        (record-case x
          [(closure code free*) 
           (make-closure code (map Var free*))]))
      (make-fix lhs* (map handle-closure rhs*) body))
    (define (Expr x)
      (record-case x
        [(constant) x]
        [(var)      (Var x)]
        [(primref)  x]
        [(bind lhs* rhs* body)
         (make-bind lhs* (map Expr rhs*) (Expr body))]
        [(fix lhs* rhs* body)
         (do-fix lhs* rhs* (Expr body))]
        [(conditional e0 e1 e2) 
         (make-conditional (Expr e0) (Expr e1) (Expr e2))]
        [(seq e0 e1)
         (make-seq (Expr e0) (Expr e1))]
        [(closure)
         (let ([t (unique-var 'tmp)])
           (Expr (make-fix (list t) (list x) t)))]
        [(primcall op arg*)
         (make-primcall op (map Expr arg*))]
        [(forcall op arg*)
         (make-forcall op (map Expr arg*))]
        [(funcall rator arg*)
         (make-funcall (Expr rator) (map Expr arg*))]
        [(jmpcall label rator arg*)
         (make-jmpcall label (Expr rator) (map Expr arg*))]
        [(mvcall rator k)
         (make-mvcall (Expr rator) (Clambda k))]
        [else (error who "invalid expr ~s" x)]))
    Expr)
  ;;;
  (define (ClambdaCase free*)
    (lambda (x)
      (record-case x
        [(clambda-case info body)
         (record-case info
           [(case-info label args proper)
            (let ([cp (unique-var 'cp)])
              (make-clambda-case 
                (make-case-info label (cons cp args) proper)
                ((Expr cp free*) body)))])]
        [else (error who "invalid clambda-case ~s" x)])))
  ;;;
  (define (Clambda x)
    (record-case x
      [(clambda label case* free* name)
       (make-clambda label (map (ClambdaCase free*) case*) 
                     free* name)]
      [else (error who "invalid clambda ~s" x)]))
  ;;;
  (define (Program x)
    (record-case x 
      [(codes code* body)
       (make-codes (map Clambda code*) ((Expr #f '()) body))]
      [else (error who "invalid program ~s" x)]))
  ;;;
  (Program x))



(define-syntax seq*
  (syntax-rules ()
    [(_ e) e]
    [(_ e* ... e) 
     (make-seq (seq* e* ...) e)]))



(include "pass-specify-rep.ss")


(define (insert-engine-checks x)
  (define (Tail x)
    (make-seq
      (make-primcall '$do-event '())
      x))
  (define (CaseExpr x)
    (record-case x 
      [(clambda-case info body)
       (make-clambda-case info (Tail body))]))
  (define (CodeExpr x)
    (record-case x
      [(clambda L cases free name)
       (make-clambda L (map CaseExpr cases) free name)]))
  (define (CodesExpr x)
    (record-case x 
      [(codes list body)
       (make-codes (map CodeExpr list) (Tail body))]))
  (CodesExpr x))

(define (insert-stack-overflow-check x)
  (define who 'insert-stack-overflow-check)
  
  (define (Tail x) #t)

  (define (insert-check x)
    (make-seq 
      (make-shortcut 
        (make-conditional 
          (make-primcall '< 
            (list esp (make-primcall 'mref (list pcr (make-constant 16)))))
          (make-primcall 'interrupt '())
          (make-primcall 'nop '()))
        (make-forcall "ik_stack_overflow" '()))
      x))

  (define (ClambdaCase x) 
    (record-case x
      [(clambda-case info body)
       (make-clambda-case info (Main body))]))
  ;;;
  (define (Clambda x)
    (record-case x
      [(clambda label case* free* name)
       (make-clambda label (map ClambdaCase case*) free* name)]))
  ;;;
  (define (Main x)
    (if (Tail x) 
        (insert-check x) 
        x))
  ;;;
  (define (Program x)
    (record-case x 
      [(codes code* body)
       (make-codes (map Clambda code*) (Main body))]))
  ;;;
  (Program x))



(define parameter-registers '(%edi)) 
(define return-value-register '%eax)
(define cp-register '%edi)
(define all-registers '(%eax %edi %ebx %edx %ecx)) ; %esi %esp %ebp))
(define argc-register '%eax)

;;; apr = %ebp
;;; esp = %esp
;;; pcr = %esi
;;; cpr = %edi

(define (register-index x)
  (cond
    [(assq x '([%eax 0] [%edi 1] [%ebx 2] [%edx 3] 
               [%ecx 4] [%esi 5] [%esp 6] [%ebp 7])) 
     => cadr]
    [else (error 'register-index "~s is not a register" x)]))


(define non-8bit-registers '(%edi))

(define (impose-calling-convention/evaluation-order x)
  (define who 'impose-calling-convention/evaluation-order)
  ;;;
  ;;;
  (define (S* x* k)
    (cond
      [(null? x*) (k '())]
      [else
       (S (car x*)
          (lambda (a)
            (S* (cdr x*)
                (lambda (d)
                  (k (cons a d))))))]))
  ;;;
  (define (S x k)
    (record-case x
      [(bind lhs* rhs* body)
       (do-bind lhs* rhs* (S body k))]
      [(seq e0 e1)
       (make-seq (E e0) (S e1 k))]
      [else
       (cond
         [(or (constant? x) (symbol? x)) (k x)]
         [(var? x) 
          (cond
            [(var-loc x) => k]
            [else (k x)])]
         [(or (funcall? x) (primcall? x) (jmpcall? x)
              (forcall? x) (shortcut? x)
              (conditional? x))
          (let ([t (unique-var 'tmp)])
            (do-bind (list t) (list x)
              (k t)))]
         [else (error who "invalid S ~s" x)])]))
  ;;;
  (define (do-bind lhs* rhs* body)
    (cond
      [(null? lhs*) body]
      [else
       (set! locals (cons (car lhs*) locals))
       (make-seq 
         (V (car lhs*) (car rhs*))
         (do-bind (cdr lhs*) (cdr rhs*) body))]))
  ;;;
  (define (nontail-locations args)
    (let f ([regs parameter-registers] [args args])
      (cond
        [(null? args) (values '() '() '())]
        [(null? regs) (values '() '() args)]
        [else
         (let-values ([(r* rl* f*) (f (cdr regs) (cdr args))])
            (values (cons (car regs) r*)
                    (cons (car args) rl*)
                    f*))])))
  (define (make-set lhs rhs)
    (make-asm-instr 'move lhs rhs))
  (define (do-bind-frmt* nf* v* ac)
    (cond
      [(null? nf*) ac]
      [else
       (make-seq
         (V (car nf*) (car v*))
         (do-bind-frmt* (cdr nf*) (cdr v*) ac))]))
  ;;;
  (define (handle-nontail-call rator rands value-dest call-targ)
    (let-values ([(reg-locs reg-args frm-args)
                  (nontail-locations (cons rator rands))])
      (let ([regt* (map (lambda (x) (unique-var 'rt)) reg-args)]
            [frmt* (map (lambda (x) (make-nfv 'unset-conflicts #f #f #f #f))
                        frm-args)])
        (let* ([call 
                (make-ntcall call-targ value-dest 
                  (cons* argc-register 
                         pcr esp apr
                         (append reg-locs frmt*))
                  #f #f)]
               [body
                (make-nframe frmt* #f
                  (do-bind-frmt* frmt* frm-args
                    (do-bind (cdr regt*) (cdr reg-args)
                      ;;; evaluate cpt last
                      (do-bind (list (car regt*)) (list (car reg-args))
                        (assign* reg-locs regt*
                          (make-seq 
                            (make-set argc-register 
                               (make-constant
                                 (argc-convention (length rands))))
                            call))))))])
          (if value-dest
              (make-seq body (make-set value-dest return-value-register))
              body)))))
  (define (alloc-check size)
    (E (make-conditional ;;; PCB ALLOC-REDLINE
         (make-primcall '<= 
           (list (make-primcall 'int+ (list apr size)) 
                 (make-primcall 'mref (list pcr (make-constant 4)))))
         (make-primcall 'nop '())
         (make-funcall 
           (make-primcall 'mref
              (list (make-constant 
                      (make-object
                        (primref->symbol 
                          'do-overflow)))
                    (make-constant (- disp-symbol-record-proc symbol-ptag))))
           (list size)))))
  ;;; impose value
  (define (V d x)
    (record-case x 
      [(constant) (make-set d x)]
      [(var)      
       (cond
         [(var-loc x) => (lambda (loc) (make-set d loc))]
         [else (make-set d x)])]
      [(bind lhs* rhs* e)
       (do-bind lhs* rhs* (V d e))]
      [(seq e0 e1)
       (make-seq (E e0) (V d e1))]
      [(conditional e0 e1 e2)
       (make-conditional (P e0) (V d e1) (V d e2))]
      [(primcall op rands)
       (case op
         [(alloc) 
          (S (car rands)
             (lambda (size)
               (make-seq
                 (alloc-check size)
                 (S (cadr rands)
                    (lambda (tag)
                      (make-seq
                        (make-seq 
                          (make-set d apr)
                          (make-asm-instr 'logor d tag))
                        (make-asm-instr 'int+ apr size)))))))]
         [(mref) 
          (S* rands
              (lambda (rands)
                (make-set d (make-disp (car rands) (cadr rands)))))]
         [(bref) 
          (S* rands
              (lambda (rands)
                (make-asm-instr 'move-byte d 
                  (make-disp (car rands) (cadr rands)))))]
         [(logand logxor logor int+ int- int*
                  int-/overflow int+/overflow int*/overflow)
          (make-seq
            (V d (car rands))
            (S (cadr rands)
               (lambda (s)
                 (make-asm-instr op d s))))]
         [(remainder)
          (S* rands
              (lambda (rands)
                (seq* 
                  (make-set eax (car rands))
                  (make-asm-instr 'cltd edx eax)
                  (make-asm-instr 'idiv eax (cadr rands))
                  (make-set d eax))))]
         [(quotient) 
          (S* rands
              (lambda (rands)
                (seq* 
                  (make-set eax (car rands))
                  (make-asm-instr 'cltd edx eax)
                  (make-asm-instr 'idiv edx (cadr rands))
                  (make-set d edx))))]
         [(sll sra srl)
          (let ([a (car rands)] [b (cadr rands)])
            (cond
              [(constant? b)
               (make-seq
                 (V d a)
                 (make-asm-instr op d b))]
              [else 
               (S b
                  (lambda (b)
                    (seq*
                      (V d a)
                      (make-set ecx b)
                      (make-asm-instr op d ecx))))]))]
         [else (error who "invalid value op ~s" op)])]
      [(funcall rator rands) 
       (handle-nontail-call rator rands d #f)]
      [(jmpcall label rator rands) 
       (handle-nontail-call rator rands d label)]
      [(forcall op rands)
       (handle-nontail-call 
         (make-constant (make-foreign-label op))
         rands d op)] 
      [(shortcut body handler)
       (make-shortcut 
          (V d body)
          (V d handler))] 
      [else 
       (if (symbol? x) 
           (make-set d x)
           (error who "invalid value ~s" (unparse x)))]))
  ;;;
  (define (assign* lhs* rhs* ac)
    (cond
      [(null? lhs*) ac]
      [else
       (make-seq 
         (make-set (car lhs*) (car rhs*))
         (assign* (cdr lhs*) (cdr rhs*) ac))]))
  ;;;
  (define (VT x)
    (S x
       (lambda (x)
         (make-seq
           (make-set return-value-register x)
           (make-primcall 'return (list return-value-register))))))
  ;;; impose effect
  (define (E x)
    (record-case x
      [(seq e0 e1) (make-seq (E e0) (E e1))]
      [(conditional e0 e1 e2)
       (make-conditional (P e0) (E e1) (E e2))]
      [(bind lhs* rhs* e)
       (do-bind lhs* rhs* (E e))]
      [(primcall op rands)
       (case op
         [(mset bset/c bset/h)
          (S* rands
              (lambda (s*)
                (make-asm-instr op
                  (make-disp (car s*) (cadr s*)) 
                  (caddr s*))))]
         [(fl:load fl:store fl:add! fl:sub! fl:mul! fl:div!
                   fl:from-int) 
          (S* rands
              (lambda (s*)
                (make-asm-instr op (car s*) (cadr s*))))]
         [(nop interrupt incr/zero?) x]
         [else (error 'impose-effect "invalid instr ~s" x)])]
      [(funcall rator rands)
       (handle-nontail-call rator rands #f #f)]
      [(jmpcall label rator rands) 
       (handle-nontail-call rator rands #f label)]
      [(forcall op rands)
       (handle-nontail-call 
         (make-constant (make-foreign-label op))
         rands #f op)]
      [(shortcut body handler)
       (make-shortcut (E body) (E handler))]
      [else (error who "invalid effect ~s" x)]))
  ;;; impose pred
  (define (P x)
    (record-case x
      [(constant) x]
      [(seq e0 e1) (make-seq (E e0) (P e1))]
      [(conditional e0 e1 e2)
       (make-conditional (P e0) (P e1) (P e2))]
      [(bind lhs* rhs* e)
       (do-bind lhs* rhs* (P e))]
      [(primcall op rands)
       (let ([a (car rands)] [b (cadr rands)])
         (cond
           [(and (constant? a) (constant? b))
            (let ([t (unique-var 'tmp)])
              (P (make-bind (list t) (list a)
                    (make-primcall op (list t b)))))]
           [else
            (S* rands
                (lambda (rands)
                  (let ([a (car rands)] [b (cadr rands)])
                    (make-asm-instr op a b))))]))]
        [(shortcut body handler)
         (make-shortcut (P body) (P handler))]
      [else (error who "invalid pred ~s" x)]))
  ;;;
  (define (handle-tail-call target rator rands)
    (let* ([args (cons rator rands)]
           [locs (formals-locations args)]
           [rest 
            (make-seq
              (make-set argc-register 
                (make-constant
                  (argc-convention (length rands))))
              (cond
                [target 
                 (make-primcall 'direct-jump 
                   (cons target 
                    (cons* argc-register
                           pcr esp apr
                           locs)))]
                [else 
                 (make-primcall 'indirect-jump 
                   (cons* argc-register 
                          pcr esp apr
                          locs))]))])
       (let f ([args (reverse args)] 
               [locs (reverse locs)] 
               [targs '()]
               [tlocs '()])
         (cond
           [(null? args) (assign* tlocs targs rest)]
           [(constant? (car args))
            (f (cdr args) (cdr locs)
               (cons (car args) targs) 
               (cons (car locs) tlocs))]
           [(and (fvar? (car locs)) 
                 (var? (car args))
                 (eq? (car locs) (var-loc (car args))))
            (f (cdr args) (cdr locs) targs tlocs)]
           [else
            (let ([t (unique-var 'tmp)])
              (set! locals (cons t locals))
              (make-seq
                (V t (car args))
                (f (cdr args) (cdr locs) 
                   (cons t targs) (cons (car locs) tlocs))))]))))
  (define (Tail x)
    (record-case x 
      [(constant) (VT x)]
      [(var)      (VT x)]
      [(primcall op rands) 
       (case op
         [($call-with-underflow-handler) 
          (let ([t0 (unique-var 't)]
                [t1 (unique-var 't)]
                [t2 (unique-var 't)]
                [handler (car rands)]
                [proc (cadr rands)]
                [k (caddr rands)])
            (set! locals (cons* t0 t1 t2 locals))
            (seq*
              (V t0 handler)
              (V t1 k)
              (V t2 proc)
              (make-set (mkfvar 1) t0)
              (make-set (mkfvar 2) t1)
              (make-set cpr t2)
              (make-set argc-register (make-constant (argc-convention 1)))
              (make-asm-instr 'int- fpr (make-constant wordsize))
              (make-primcall 'indirect-jump
                (list argc-register cpr pcr esp apr
                      (mkfvar 1) (mkfvar 2)))))]
         [else (VT x)])]
      [(bind lhs* rhs* e)
       (do-bind lhs* rhs* (Tail e))]
      [(seq e0 e1)
       (make-seq (E e0) (Tail e1))]
      [(conditional e0 e1 e2)
       (make-conditional (P e0) (Tail e1) (Tail e2))]
      [(funcall rator rands)
       (handle-tail-call #f rator rands)]
      [(jmpcall label rator rands)
       (handle-tail-call (make-code-loc label) rator rands)]
      [(forcall) (VT x)]
      [(shortcut body handler)
       (make-shortcut (Tail body) (Tail handler))]
      [else (error who "invalid tail ~s" x)]))
  ;;;
  (define (formals-locations args)
    (let f ([regs parameter-registers] [args args])
      (cond
        [(null? args) '()]
        [(null? regs) 
         (let f ([i 1] [args args])
           (cond
             [(null? args) '()]
             [else
              (cons (mkfvar i)
                (f (fxadd1 i) (cdr args)))]))]
        [else
         (cons (car regs) (f (cdr regs) (cdr args)))])))
  ;;;
  (define locals '())
  (define (partition-formals ls)
    (let f ([regs parameter-registers] [ls ls])
      (cond
        [(null? regs)
         (let ([flocs 
                (let f ([i 1] [ls ls])
                  (cond
                    [(null? ls) '()]
                    [else (cons (mkfvar i) (f (fxadd1 i) (cdr ls)))]))])
           (values '() '() ls flocs))]
        [(null? ls) 
         (values '() '() '() '())]
        [else 
         (let-values ([(rargs rlocs fargs flocs)
                       (f (cdr regs) (cdr ls))])
           (values (cons (car ls) rargs)
                   (cons (car regs) rlocs)
                   fargs flocs))])))
  ;;;
  (define (ClambdaCase x) 
    (record-case x
      [(clambda-case info body)
       (record-case info
         [(case-info label args proper)
          (let-values ([(rargs rlocs fargs flocs)
                        (partition-formals args)])
            (set! locals rargs)
            (for-each set-var-loc! fargs flocs)
            (let ([body (let f ([args rargs] [locs rlocs])
                           (cond
                             [(null? args) (Tail body)]
                             [else
                              (make-seq
                                (make-set (car args) (car locs))
                                (f (cdr args) (cdr locs)))]))])
              (make-clambda-case
                (make-case-info label (append rlocs flocs) proper)
                (make-locals locals body))))])]))
  ;;;
  (define (Clambda x)
    (record-case x
      [(clambda label case* free* name)
       (make-clambda label (map ClambdaCase case*) free* name)]))
  ;;;
  (define (Main x)
    (set! locals '())
    (let ([x (Tail x)])
      (make-locals locals x)))
  ;;;
  (define (Program x)
    (record-case x 
      [(codes code* body)
       (make-codes (map Clambda code*) (Main body))]))
  ;;;
;  (print-code x)
  (Program x))

(module ListySet 
  (make-empty-set set-member? set-add set-rem set-difference set-union
   empty-set?
   set->list list->set)

  (define-record set (v))

  (define (make-empty-set) (make-set '()))
  (define (set-member? x s) 
    ;(unless (fixnum? x) (error 'set-member? "~s is not a fixnum" x))
    (unless (set? s) (error 'set-member? "~s is not a set" s))
    (memq x (set-v s)))

  (define (empty-set? s)
    (unless (set? s) (error 'empty-set? "~s is not a set" s))
    (null? (set-v s)))
    
  (define (set->list s)
    (unless (set? s) (error 'set->list "~s is not a set" s))
    (set-v s))
    
  (define (set-add x s)
    ;(unless (fixnum? x) (error 'set-add "~s is not a fixnum" x))
    (unless (set? s) (error 'set-add "~s is not a set" s))
    (cond
      [(memq x (set-v s)) s]
      [else (make-set (cons x (set-v s)))]))
             
  (define (rem x s)
    (cond
      [(null? s) '()]
      [(eq? x (car s)) (cdr s)]
      [else (cons (car s) (rem x (cdr s)))])) 

  (define (set-rem x s)
    ;(unless (fixnum? x) (error 'set-rem "~s is not a fixnum" x))
    (unless (set? s) (error 'set-rem "~s is not a set" s))
    (make-set (rem x (set-v s))))
  
  (define (difference s1 s2)
    (cond
      [(null? s2) s1]
      [else (difference (rem (car s2) s1) (cdr s2))]))

  (define (set-difference s1 s2)
    (unless (set? s1) (error 'set-difference "~s is not a set" s1))
    (unless (set? s2) (error 'set-difference "~s is not a set" s2))
    (make-set (difference (set-v s1) (set-v s2))))
    
  (define (set-union s1 s2)
    (unless (set? s1) (error 'set-union "~s is not a set" s1))
    (unless (set? s2) (error 'set-union "~s is not a set" s2))
    (make-set (union (set-v s1) (set-v s2))))

  (define (list->set ls)
    ;(unless (andmap fixnum? ls) (error 'set-rem "~s is not a list of fixnum" ls))
    (make-set ls))

  (define (union s1 s2)
    (cond
      [(null? s1) s2]
      [(memq (car s1) s2) (union (cdr s1) s2)]
      [else (cons (car s1) (union (cdr s1) s2))])))

(module IntegerSet
  (make-empty-set set-member? set-add set-rem set-difference
   set-union empty-set? set->list list->set
   ;set-map set-for-each set-ormap set-andmap
   )
  
  (begin
    (define-syntax car      (identifier-syntax $car))
    (define-syntax cdr      (identifier-syntax $cdr))
    (define-syntax fxsll    (identifier-syntax $fxsll))
    (define-syntax fxsra    (identifier-syntax $fxsra))
    (define-syntax fxlogor  (identifier-syntax $fxlogor))
    (define-syntax fxlogand (identifier-syntax $fxlogand))
    (define-syntax fxlognot (identifier-syntax $fxlognot))
    (define-syntax fx+      (identifier-syntax $fx+))
    (define-syntax fxzero?  (identifier-syntax $fxzero?))
    (define-syntax fxeven?
      (syntax-rules ()
        [(_ x) ($fxzero? ($fxlogand x 1))])))

  (define bits 28)
  (define (index-of n) (fxquotient n bits))
  (define (mask-of n)  (fxsll 1 (fxremainder n bits)))

  (define (make-empty-set) 0)
  (define (empty-set? s) (eqv? s 0))
  
  (define (set-member? n s) 
    (unless (fixnum? n) (error 'set-member? "~s is not a fixnum" n))
    (let f ([s s] [i (index-of n)] [j (mask-of n)])
      (cond
        [(pair? s)
         (if (fxeven? i)
             (f (car s) (fxsra i 1) j)
             (f (cdr s) (fxsra i 1) j))]
        [(eq? i 0) (eq? j (fxlogand s j))]
        [else #f])))

  (define (set-add n s)
    (unless (fixnum? n) (error 'set-add "~s is not a fixnum" n))
    (let f ([s s] [i (index-of n)] [j (mask-of n)])
      (cond
        [(pair? s)
         (if (fxeven? i)
             (let ([a0 (car s)])
               (let ([a1 (f a0 (fxsra i 1) j)])
                 (if (eq? a0 a1) s (cons a1 (cdr s)))))
             (let ([d0 (cdr s)])
               (let ([d1 (f d0 (fxsra i 1) j)])
                 (if (eq? d0 d1) s (cons (car s) d1)))))]
        [(eq? i 0) (fxlogor s j)]
        [else
         (if (fxeven? i) 
             (cons (f s (fxsra i 1) j) 0)
             (cons s (f 0 (fxsra i 1) j)))])))

  (define (cons^ a d)
    (if (and (eq? d 0) (fixnum? a))
        a
        (cons a d)))

  (define (set-rem n s)
    (unless (fixnum? n) (error 'set-rem "~s is not a fixnum" n))
    (let f ([s s] [i (index-of n)] [j (mask-of n)])
      (cond
        [(pair? s)
         (if (fxeven? i)
             (let ([a0 (car s)])
               (let ([a1 (f a0 (fxsra i 1) j)])
                 (if (eq? a0 a1) s (cons^ a1 (cdr s)))))
             (let ([d0 (cdr s)])
               (let ([d1 (f d0 (fxsra i 1) j)])
                 (if (eq? d0 d1) s (cons^ (car s) d1)))))]
        [(eq? i 0) (fxlogand s (fxlognot j))]
        [else s])))
 
  (define (set-union^ s1 m2)
    (if (pair? s1)
        (let ([a0 (car s1)])
          (let ([a1 (set-union^ a0 m2)])
            (if (eq? a0 a1) s1 (cons a1 (cdr s1)))))
        (fxlogor s1 m2)))

  (define (set-union s1 s2)
    (if (pair? s1)
        (if (pair? s2)
            (if (eq? s1 s2)
                s1
                (cons (set-union (car s1) (car s2))
                      (set-union (cdr s1) (cdr s2))))
            (let ([a0 (car s1)])
              (let ([a1 (set-union^ a0 s2)])
                (if (eq? a0 a1) s1 (cons a1 (cdr s1))))))
        (if (pair? s2)
            (let ([a0 (car s2)])
              (let ([a1 (set-union^ a0 s1)])
                (if (eq? a0 a1) s2 (cons a1 (cdr s2)))))
            (fxlogor s1 s2))))

  (define (set-difference^ s1 m2)
    (if (pair? s1)
        (let ([a0 (car s1)])
          (let ([a1 (set-difference^ a0 m2)])
            (if (eq? a0 a1) s1 (cons^ a1 (cdr s1)))))
        (fxlogand s1 (fxlognot m2))))
  
  (define (set-difference^^ m1 s2)
    (if (pair? s2)
        (set-difference^^ m1 (car s2))
        (fxlogand m1 (fxlognot s2))))

  (define (set-difference s1 s2)
    (if (pair? s1)
        (if (pair? s2)
            (if (eq? s1 s2)
                0
                (cons^ (set-difference (car s1) (car s2))
                       (set-difference (cdr s1) (cdr s2))))
            (let ([a0 (car s1)])
              (let ([a1 (set-difference^ a0 s2)])
                (if (eq? a0 a1) s1 (cons^ a1 (cdr s1))))))
        (if (pair? s2) 
            (set-difference^^ s1 (car s2)) 
            (fxlogand s1 (fxlognot s2)))))

  (define (list->set ls)
    (unless (andmap fixnum? ls) (error 'list->set "~s is not a list of fixnum" ls))
    (let f ([ls ls] [s 0])
      (cond
        [(null? ls) s]
        [else (f (cdr ls) (set-add (car ls) s))])))

  (define (set->list s)
    (let f ([i 0] [j 1] [s s] [ac '()])
      (cond
        [(pair? s)
         (f i (fxsll j 1) (car s)
            (f (fxlogor i j) (fxsll j 1) (cdr s) ac))]
        [else
         (let f ([i (fx* i bits)] [m s] [ac ac])
           (cond
             [(fxeven? m)
              (if (fxzero? m)
                  ac
                  (f (fx+ i 1) (fxsra m 1) ac))]
             [else 
              (f (fx+ i 1) (fxsra m 1) (cons i ac))]))])))


;;;  (define (set-map proc s)
;;;    (let f ([i 0] [j (fxsll 1 shift)] [s s] [ac '()])
;;;      (cond
;;;        [(pair? s)
;;;         (f i (fxsll j 1) (car s)
;;;            (f (fxlogor i j) (fxsll j 1) (cdr s) ac))]
;;;        [else
;;;         (let f ([i i] [m s] [ac ac])
;;;           (cond
;;;             [(fxeven? m) 
;;;              (if (fxzero? m) 
;;;                  ac
;;;                  (f (fx+ i 1) (fxsra m 1) ac))]
;;;             [else 
;;;              (f (fx+ i 1) (fxsra m 1) (cons (proc i) ac))]))])))
;;;
;;;  (define (set-for-each proc s)
;;;    (let f ([i 0] [j (fxsll 1 shift)] [s s])
;;;      (cond
;;;        [(pair? s)
;;;         (f i (fxsll j 1) (car s))
;;;         (f (fxlogor i j) (fxsll j 1) (cdr s))]
;;;        [else
;;;         (let f ([i i] [m s])
;;;           (cond
;;;             [(fxeven? m) 
;;;              (unless (fxzero? m) 
;;;                (f (fx+ i 1) (fxsra m 1)))]
;;;             [else 
;;;              (proc i)
;;;              (f (fx+ i 1) (fxsra m 1))]))])))
;;;
;;;  (define (set-ormap proc s)
;;;    (let f ([i 0] [j (fxsll 1 shift)] [s s])
;;;      (cond
;;;        [(pair? s)
;;;         (or (f i (fxsll j 1) (car s))
;;;             (f (fxlogor i j) (fxsll j 1) (cdr s)))]
;;;        [else
;;;         (let f ([i i] [m s])
;;;           (cond
;;;             [(fxeven? m) 
;;;              (if (fxzero? m) 
;;;                  #f
;;;                  (f (fx+ i 1) (fxsra m 1)))]
;;;             [else 
;;;              (or (proc i)
;;;                  (f (fx+ i 1) (fxsra m 1)))]))])))
;;;
;;;  (define (set-andmap proc s)
;;;    (let f ([i 0] [j (fxsll 1 shift)] [s s])
;;;      (cond
;;;        [(pair? s)
;;;         (and (f i (fxsll j 1) (car s))
;;;              (f (fxlogor i j) (fxsll j 1) (cdr s)))]
;;;        [else
;;;         (let f ([i i] [m s])
;;;           (cond
;;;             [(fxeven? m) 
;;;              (if (fxzero? m) 
;;;                  #t
;;;                  (f (fx+ i 1) (fxsra m 1)))]
;;;             [else 
;;;              (and (proc i)
;;;                   (f (fx+ i 1) (fxsra m 1)))]))])))
#|IntegerSet|#)

(module ListyGraphs 
  (empty-graph add-edge! empty-graph? print-graph node-neighbors
   delete-node!)
  (import ListySet)
  ;;;
  (define-record graph (ls))
  ;;;
  (define (empty-graph) (make-graph '()))
  ;;;
  (define (empty-graph? g) 
    (andmap (lambda (x) (empty-set? (cdr x))) (graph-ls g)))
  ;;;
  (define (single x)
    (set-add x (make-empty-set)))

  (define (add-edge! g x y)
    (let ([ls (graph-ls g)])
      (cond
        [(assq x ls) =>
         (lambda (p0)
           (unless (set-member? y (cdr p0))
             (set-cdr! p0 (set-add y (cdr p0)))
             (cond
               [(assq y ls) => 
                (lambda (p1) 
                  (set-cdr! p1 (set-add x (cdr p1))))]
               [else
                (set-graph-ls! g 
                   (cons (cons y (single x)) ls))])))]
        [(assq y ls) =>
         (lambda (p1)
           (set-cdr! p1 (set-add x (cdr p1)))
           (set-graph-ls! g (cons (cons x (single y)) ls)))]
        [else 
         (set-graph-ls! g 
           (cons* (cons x (single y))
                  (cons y (single x))
                  ls))])))
  (define (print-graph g)
    (printf "G={\n")
    (parameterize ([print-gensym 'pretty])
      (for-each (lambda (x) 
                  (let ([lhs (car x)] [rhs* (cdr x)])
                    (printf "  ~s => ~s\n" 
                            (unparse lhs)
                            (map unparse (set->list rhs*)))))
        (graph-ls g)))
    (printf "}\n"))
  (define (node-neighbors x g)
    (cond
      [(assq x (graph-ls g)) => cdr]
      [else (make-empty-set)]))

  (define (delete-node! x g)
    (let ([ls (graph-ls g)])
      (cond
        [(assq x ls) =>
         (lambda (p)
           (for-each (lambda (y) 
                       (let ([p (assq y ls)])
                         (set-cdr! p (set-rem x (cdr p)))))
                     (set->list (cdr p)))
           (set-cdr! p (make-empty-set)))]
        [else (void)])))
  ;;;
  #|ListyGraphs|#)


(module IntegerGraphs 
  (empty-graph add-edge! empty-graph? print-graph node-neighbors
   delete-node!)
  (import IntegerSet)
  ;;;
  (define-record graph (ls))
  ;;;
  (define (empty-graph) (make-graph '()))
  ;;;
  (define (empty-graph? g) 
    (andmap (lambda (x) (empty-set? (cdr x))) (graph-ls g)))
  ;;;
  (define (single x)
    (set-add x (make-empty-set)))

  (define (add-edge! g x y)
    (let ([ls (graph-ls g)])
      (cond
        [(assq x ls) =>
         (lambda (p0)
           (unless (set-member? y (cdr p0))
             (set-cdr! p0 (set-add y (cdr p0)))
             (cond
               [(assq y ls) => 
                (lambda (p1) 
                  (set-cdr! p1 (set-add x (cdr p1))))]
               [else
                (set-graph-ls! g 
                   (cons (cons y (single x)) ls))])))]
        [(assq y ls) =>
         (lambda (p1)
           (set-cdr! p1 (set-add x (cdr p1)))
           (set-graph-ls! g (cons (cons x (single y)) ls)))]
        [else 
         (set-graph-ls! g 
           (cons* (cons x (single y))
                  (cons y (single x))
                  ls))])))
  (define (print-graph g)
    (printf "G={\n")
    (parameterize ([print-gensym 'pretty])
      (for-each (lambda (x) 
                  (let ([lhs (car x)] [rhs* (cdr x)])
                    (printf "  ~s => ~s\n" 
                            (unparse lhs)
                            (map unparse (set->list rhs*)))))
        (graph-ls g)))
    (printf "}\n"))
  (define (node-neighbors x g)
    (cond
      [(assq x (graph-ls g)) => cdr]
      [else (make-empty-set)]))

  (define (delete-node! x g)
    (let ([ls (graph-ls g)])
      (cond
        [(assq x ls) =>
         (lambda (p)
           (for-each (lambda (y) 
                       (let ([p (assq y ls)])
                         (set-cdr! p (set-rem x (cdr p)))))
                     (set->list (cdr p)))
           (set-cdr! p (make-empty-set)))]
        [else (void)])))
  ;;;
  #|IntegerGraphs|#)

(module conflict-helpers 
  (empty-var-set rem-var add-var union-vars mem-var? for-each-var init-vars!
   empty-nfv-set rem-nfv add-nfv union-nfvs mem-nfv? for-each-nfv init-nfv! 
   empty-frm-set rem-frm add-frm union-frms mem-frm?
   empty-reg-set rem-reg add-reg union-regs mem-reg?
   reg?)
  (import IntegerSet)
  (begin
    (define (add-frm x s)      (set-add (fvar-idx x) s))
    (define (rem-nfv x s) 
      (remq1 x s))
    (define (init-var! x i)
      (set-var-index! x i)
      (set-var-var-move! x (empty-var-set))
      (set-var-reg-move! x (empty-reg-set))
      (set-var-frm-move! x (empty-frm-set))
      (set-var-var-conf! x (empty-var-set))
      (set-var-reg-conf! x (empty-reg-set))
      (set-var-frm-conf! x (empty-frm-set)))
    (define (init-vars! ls)
      (let f ([ls ls] [i 0])
        (unless (null? ls)
          (init-var! (car ls) i)
          (f (cdr ls) (fxadd1 i)))))
    (define (init-nfv! x)
      (set-nfv-frm-conf! x (empty-frm-set))
      (set-nfv-nfv-conf! x (empty-nfv-set))
      (set-nfv-var-conf! x (empty-var-set)))
    (define (reg? x) (symbol? x))
    (define (empty-var-set)    (make-empty-set))
    (define (add-var x s)      (set-add (var-index x) s))
    (define (mem-var? x s)     (set-member? (var-index x) s))
    (define (rem-var x s)      (set-rem (var-index x) s))
    (define (union-vars s1 s2) (set-union s1 s2))
    (define (for-each-var s varvec f) 
      (for-each (lambda (i) (f (vector-ref varvec i))) 
        (set->list s)))
    (define (empty-reg-set)    (make-empty-set))
    (define (add-reg x s)      (set-add (register-index x) s))
    (define (rem-reg x s)      (set-rem (register-index x) s))
    (define (mem-reg? x s)     (set-member? (register-index x) s))
    (define (union-regs s1 s2) (set-union s1 s2))
    (define (empty-frm-set)    (make-empty-set))
    (define (mem-frm? x s)     (set-member? (fvar-idx x) s))
    (define (rem-frm x s)      (set-rem (fvar-idx x) s))
    (define (union-frms s1 s2) (set-union s1 s2))
    (define (empty-nfv-set) '())
    (define (add-nfv x s) 
      (cond
        [(memq x s) s]
        [else (cons x s)]))
    (define (mem-nfv? x s) 
      (memq x s))
    (define (union-nfvs s1 s2)
      (let f ([s1 s1] [s2 s2])
        (cond
          [(null? s1) s2]
          [(memq (car s1) s2) (f (cdr s1) s2)]
          [else (cons (car s1) (f (cdr s1) s2))])))
    (define (for-each-nfv s f) 
      (for-each f s))))

(define (uncover-frame-conflicts x varvec)
  (import IntegerSet)
  (import conflict-helpers)
  (define who 'uncover-frame-conflicts)
  (define spill-set (make-empty-set))
  (define (mark-reg/vars-conf! r vs)
    (for-each-var vs varvec
      (lambda (v)
        (set-var-reg-conf! v 
          (add-reg r (var-reg-conf v))))))
  (define (mark-frm/vars-conf! f vs) 
    (for-each-var vs varvec
      (lambda (v)
        (set-var-frm-conf! v 
          (add-frm f (var-frm-conf v))))))
  (define (mark-frm/nfvs-conf! f ns) 
    (for-each-nfv ns
      (lambda (n)
        (set-nfv-frm-conf! n
          (add-frm f (nfv-frm-conf n))))))
  (define (mark-var/vars-conf! v vs) 
    (for-each-var vs varvec
      (lambda (w)
        (set-var-var-conf! w
          (add-var v (var-var-conf w)))))
    (set-var-var-conf! v
      (union-vars vs (var-var-conf v))))
  (define (mark-var/frms-conf! v fs) 
    (set-var-frm-conf! v
      (union-frms fs (var-frm-conf v))))
  (define (mark-var/regs-conf! v rs) 
    (set-var-reg-conf! v
      (union-regs rs (var-reg-conf v))))
  (define (mark-var/nfvs-conf! v ns) 
    (for-each-nfv ns
      (lambda (n)
        (set-nfv-var-conf! n
          (add-var v (nfv-var-conf n))))))
  (define (mark-nfv/vars-conf! n vs)
    (set-nfv-var-conf! n
      (union-vars vs (nfv-var-conf n))))
  (define (mark-nfv/frms-conf! n fs)
    (set-nfv-frm-conf! n
      (union-frms fs (nfv-frm-conf n))))
  (define (mark-nfv/nfvs-conf! n ns)
    (set-nfv-nfv-conf! n
      (union-nfvs ns (nfv-nfv-conf n)))
    (for-each-nfv ns
      (lambda (m)
        (set-nfv-nfv-conf! m
          (add-nfv n (nfv-nfv-conf m))))))
  (define (mark-var/var-move! x y)
    (set-var-var-move! x 
      (add-var y (var-var-move x)))
    (set-var-var-move! y 
      (add-var x (var-var-move y))))
  (define (mark-var/frm-move! x y)
    (set-var-frm-move! x 
      (add-frm y (var-frm-move x))))
  (define (mark-var/reg-move! x y)
    (set-var-reg-move! x 
      (add-reg y (var-reg-move x))))
  (define (const? x)
    (or (constant? x)
        (code-loc? x)))
  (define (R x vs rs fs ns)
    (cond
      [(const? x) (values vs rs fs ns)]
      [(reg? x) 
       (values vs (add-reg x rs) fs ns)]
      [(fvar? x)
       (values vs rs (add-frm x fs) ns)]
      [(var? x)
       (values (add-var x vs) rs fs ns)]
      [(nfv? x)
       (values vs rs fs (add-nfv x ns))]
      [(disp? x)
       (let-values ([(vs rs fs ns) (R (disp-s0 x) vs rs fs ns)])
          (R (disp-s1 x) vs rs fs ns))]
      [else (error who "invalid R ~s" x)]))
  (define (R* ls vs rs fs ns)
    (cond
      [(null? ls) (values vs rs fs ns)]
      [else 
       (let-values ([(vs rs fs ns) (R (car ls) vs rs fs ns)])
          (R* (cdr ls) vs rs fs ns))]))
  (define (E x vs rs fs ns)
    (record-case x
      [(seq e0 e1) 
       (let-values ([(vs rs fs ns) (E e1 vs rs fs ns)])
         (E e0 vs rs fs ns))]
      [(conditional e0 e1 e2)
       (let-values ([(vs1 rs1 fs1 ns1) (E e1 vs rs fs ns)]
                    [(vs2 rs2 fs2 ns2) (E e2 vs rs fs ns)])
         (P e0
            vs1 rs1 fs1 ns1
            vs2 rs2 fs2 ns2
            (union-vars vs1 vs2)
            (union-regs rs1 rs2)
            (union-frms fs1 fs2)
            (union-nfvs ns1 ns2)))]
      [(asm-instr op d s)
       (case op
         [(move move-byte)
          (cond
            [(reg? d)
             (cond
               [(not (mem-reg? d rs)) 
                (set-asm-instr-op! x 'nop)
                (values vs rs fs ns)]
               [(or (const? s) (disp? s) (reg? s))
                (let ([rs (rem-reg d rs)])
                  (mark-reg/vars-conf! d vs)
                  (R s vs rs fs ns))]
               [(var? s)
                (let ([rs (rem-reg d rs)]
                      [vs (rem-var s vs)])
                  (mark-var/reg-move! s d)
                  (mark-reg/vars-conf! d vs)
                  (values (add-var s vs) rs fs ns))]
               [(fvar? s)
                (let ([rs (rem-reg d rs)])
                  (mark-reg/vars-conf! d vs)
                  (values vs rs (add-frm s fs) ns))]
               [else (error who "invalid rs ~s" (unparse x))])]
            [(fvar? d) 
             (cond
               [(not (mem-frm? d fs)) 
                (set-asm-instr-op! x 'nop)
                (values vs rs fs ns)]
               [(or (const? s) (disp? s) (reg? s))
                (let ([fs (rem-frm d fs)])
                  (mark-frm/vars-conf! d vs)
                  (mark-frm/nfvs-conf! d ns)
                  (R s vs rs fs ns))]
               [(var? s) 
                (let ([fs (rem-frm d fs)]
                      [vs (rem-var s vs)])
                  (mark-var/frm-move! s d)
                  (mark-frm/vars-conf! d vs)
                  (mark-frm/nfvs-conf! d ns)
                  (values (add-var s vs) rs fs ns))]
               [else (error who "invalid fs ~s" s)])]
            [(var? d)
             (cond
               [(not (mem-var? d vs)) 
                (set-asm-instr-op! x 'nop)
                (values vs rs fs ns)]
               [(or (disp? s) (constant? s))
                (let ([vs (rem-var d vs)])
                  (mark-var/vars-conf! d vs)
                  (mark-var/frms-conf! d fs)
                  (mark-var/regs-conf! d rs)
                  (mark-var/nfvs-conf! d ns)
                  (R s vs rs fs ns))]
               [(reg? s) 
                (let ([vs (rem-var d vs)]
                      [rs (rem-reg s rs)])
                  (mark-var/reg-move! d s)
                  (mark-var/vars-conf! d vs)
                  (mark-var/frms-conf! d fs)
                  (mark-var/regs-conf! d rs)
                  (mark-var/nfvs-conf! d ns)
                  (values vs (add-reg s rs) fs ns))]
               [(var? s) 
                (let ([vs (rem-var d (rem-var s vs))])
                  (mark-var/var-move! d s)
                  (mark-var/vars-conf! d vs)
                  (mark-var/frms-conf! d fs)
                  (mark-var/regs-conf! d rs)
                  (mark-var/nfvs-conf! d ns)
                  (values (add-var s vs) rs fs ns))]
               [(fvar? s) 
                (let ([vs (rem-var d vs)]
                      [fs (rem-frm s fs)])
                  (mark-var/frm-move! d s)
                  (mark-var/vars-conf! d vs)
                  (mark-var/frms-conf! d fs)
                  (mark-var/regs-conf! d rs)
                  (mark-var/nfvs-conf! d ns)
                  (values vs rs (add-frm s fs) ns))]
               [else (error who "invalid vs ~s" s)])]
            [(nfv? d)
             (cond
               [(not (mem-nfv? d ns)) (error who "dead nfv")]
               [(or (disp? s) (constant? s) (reg? s))
                (let ([ns (rem-nfv d ns)])
                  (mark-nfv/vars-conf! d vs)
                  (mark-nfv/frms-conf! d fs)
                  (R s vs rs fs ns))]
               [(var? s)
                (let ([ns (rem-nfv d ns)]
                      [vs (rem-var s vs)])
                  (mark-nfv/vars-conf! d vs)
                  (mark-nfv/frms-conf! d fs)
                  (values (add-var s vs) rs fs ns))]
               [(fvar? s) 
                (let ([ns (rem-nfv d ns)]
                      [fs (rem-frm s fs)])
                  (mark-nfv/vars-conf! d vs)
                  (mark-nfv/frms-conf! d fs)
                  (values vs rs (add-frm s fs) ns))]
               [else (error who "invalid ns ~s" s)])]
            [else (error who "invalid d ~s" d)])]
         [(int-/overflow int+/overflow int*/overflow)
          (let ([v (exception-live-set)])
            (unless (vector? v)
              (error who "unbound exception for ~s ~s" x v))
            (let ([vs (union-vars vs (vector-ref v 0))]
                  [rs (union-regs rs (vector-ref v 1))]
                  [fs (union-frms fs (vector-ref v 2))]
                  [ns (union-nfvs ns (vector-ref v 3))])
              (cond
                [(var? d) 
                 (cond
                   [(not (mem-var? d vs)) 
                    (set-asm-instr-op! x 'nop)
                    (values vs rs fs ns)]
                   [else
                    (let ([vs (rem-var d vs)])
                      (mark-var/vars-conf! d vs)
                      (mark-var/frms-conf! d fs)
                      (mark-var/nfvs-conf! d ns)
                      (mark-var/regs-conf! d rs)
                      (R s (add-var d vs) rs fs ns))])]
                [(reg? d)
                 (cond
                   [(not (mem-reg? d rs))
                    (values vs rs fs ns)]
                   [else
                    (let ([rs (rem-reg d rs)])
                      (mark-reg/vars-conf! d vs)
                      (R s vs (add-reg d rs) fs ns))])]
                [(nfv? d) 
                 (cond
                   [(not (mem-nfv? d ns)) (error who "dead nfv")]
                   [else
                    (let ([ns (rem-nfv d ns)])
                      (mark-nfv/vars-conf! d vs)
                      (mark-nfv/frms-conf! d fs)
                      (R s vs rs fs (add-nfv d ns)))])]
                [else (error who "invalid op d ~s" (unparse x))])))] 
         [(logand logor logxor sll sra srl int+ int- int*) 
          (cond
            [(var? d) 
             (cond
               [(not (mem-var? d vs)) 
                (set-asm-instr-op! x 'nop)
                (values vs rs fs ns)]
               [else
                (let ([vs (rem-var d vs)])
                  (mark-var/vars-conf! d vs)
                  (mark-var/frms-conf! d fs)
                  (mark-var/nfvs-conf! d ns)
                  (mark-var/regs-conf! d rs)
                  (R s (add-var d vs) rs fs ns))])]
            [(reg? d) 
             (cond
               [(not (mem-reg? d rs))
                (values vs rs fs ns)]
               [else
                (let ([rs (rem-reg d rs)])
                  (mark-reg/vars-conf! d vs)
                  (R s vs (add-reg d rs) fs ns))])]
            [(nfv? d) 
             (cond
               [(not (mem-nfv? d ns)) (error who "dead nfv")]
               [else
                (let ([ns (rem-nfv d ns)])
                  (mark-nfv/vars-conf! d vs)
                  (mark-nfv/frms-conf! d fs)
                  (R s vs rs fs (add-nfv d ns)))])]
            [else (error who "invalid op d ~s" (unparse x))])]
         [(idiv) 
          (mark-reg/vars-conf! eax vs)
          (mark-reg/vars-conf! edx vs)
          (R s vs (add-reg eax (add-reg edx rs)) fs ns)]
         [(cltd) 
          (mark-reg/vars-conf! edx vs)
          (R s vs (rem-reg edx rs) fs ns)]
         [(mset bset/c bset/h fl:load fl:store fl:add! fl:sub!
                fl:mul! fl:div! fl:from-int) 
          (R* (list s d) vs rs fs ns)]
         [else (error who "invalid effect op ~s" (unparse x))])]
      [(ntcall target value args mask size)
       (set! spill-set (union-vars vs spill-set))
       (for-each-var vs varvec (lambda (x) (set-var-loc! x #t)))
       (R* args vs (empty-reg-set) fs ns)]
      [(nframe nfvs live body)
       (for-each init-nfv! nfvs)
       (set-nframe-live! x (vector vs fs ns))
       (E body vs rs fs ns)]
      [(primcall op args)
       (case op
         [(nop) (values vs rs fs ns)]
         [(interrupt incr/zero?) 
          (let ([v (exception-live-set)])
            (unless (vector? v)
              (error who "unbound exception2"))
            (values (vector-ref v 0)
                    (vector-ref v 1)
                    (vector-ref v 2)
                    (vector-ref v 3)))]
         [else (error who "invalid effect op ~s" op)])]
      [(shortcut body handler)
       (let-values ([(vsh rsh fsh nsh) (E handler vs rs fs ns)])
          (parameterize ([exception-live-set
                          (vector vsh rsh fsh nsh)])
            (E body vs rs fs ns)))]
      [else (error who "invalid effect ~s" (unparse x))]))
  (define (P x vst rst fst nst 
               vsf rsf fsf nsf
               vsu rsu fsu nsu)
    (record-case x
      [(seq e0 e1) 
       (let-values ([(vs rs fs ns) 
                     (P e1 vst rst fst nst 
                        vsf rsf fsf nsf
                        vsu rsu fsu nsu)])
         (E e0 vs rs fs ns))]
      [(conditional e0 e1 e2)
       (let-values ([(vs1 rs1 fs1 ns1)
                     (P e1 vst rst fst nst 
                        vsf rsf fsf nsf
                        vsu rsu fsu nsu)]
                    [(vs2 rs2 fs2 ns2) 
                     (P e2 vst rst fst nst 
                        vsf rsf fsf nsf
                        vsu rsu fsu nsu)])
         (P e0
            vs1 rs1 fs1 ns1
            vs2 rs2 fs2 ns2
            (union-vars vs1 vs2)
            (union-regs rs1 rs2)
            (union-frms fs1 fs2)
            (union-nfvs ns1 ns2)))] 
      [(constant t)
       (if t
           (values vst rst fst nst)
           (values vsf rsf fsf nsf))]
      [(asm-instr op d s)
       (R* (list d s) vsu rsu fsu nsu)]
      [(shortcut body handler)
       (let-values ([(vsh rsh fsh nsh)
                     (P handler vst rst fst nst 
                                vsf rsf fsf nsf
                                vsu rsu fsu nsu)])
          (parameterize ([exception-live-set
                          (vector vsh rsh fsh nsh)])
            (P body vst rst fst nst 
                    vsf rsf fsf nsf
                    vsu rsu fsu nsu)))]
      [else (error who "invalid pred ~s" (unparse x))]))
  (define (T x)
    (record-case x
      [(seq e0 e1) 
       (let-values ([(vs rs fs ns) (T e1)])
         (E e0 vs rs fs ns))]
      [(conditional e0 e1 e2)
       (let-values ([(vs1 rs1 fs1 ns1) (T e1)]
                    [(vs2 rs2 fs2 ns2) (T e2)])
         (P e0
            vs1 rs1 fs1 ns1
            vs2 rs2 fs2 ns2
            (union-vars vs1 vs2)
            (union-regs rs1 rs2)
            (union-frms fs1 fs2)
            (union-nfvs ns1 ns2)))]
      [(primcall op arg*) 
       (case op
         [(return indirect-jump direct-jump) 
          (R* arg* (empty-var-set)
              (empty-reg-set) 
              (empty-frm-set)
              (empty-nfv-set))]
         [else (error who "invalid tail op ~s" x)])]
      [(shortcut body handler)
       (let-values ([(vsh rsh fsh nsh) (T handler)])
          (parameterize ([exception-live-set
                          (vector vsh rsh fsh nsh)])
             (T body)))]
      [else (error who "invalid tail ~s" x)]))
  (define exception-live-set 
    (make-parameter #f))
  (T x)
  spill-set)



(module (assign-frame-sizes)
  ;;; assign-frame-sizes module
  (define indent (make-parameter 0))
  (import IntegerSet)
  (import conflict-helpers)
  (define (rewrite x varvec)
    (define who 'rewrite)
    (define (assign x)
      (let ()
        (define (assign-any)
          (let ([frms (var-frm-conf x)]
                [vars (var-var-conf x)])
            (let f ([i 1])
              (cond
                [(set-member? i frms) (f (fxadd1 i))]
                [else 
                 (let ([fv (mkfvar i)])
                   (set-var-loc! x fv)
                   (for-each-var vars varvec
                     (lambda (var)
                       (set-var-frm-conf! var
                         (add-frm fv (var-frm-conf var)))))
                   fv)]))))
        (define (assign-move x)
          (let ([mr (set->list 
                      (set-difference 
                        (var-frm-move x) 
                        (var-frm-conf x)))])
            (cond
              [(null? mr) #f]
              [else 
               (let ([fv (mkfvar (car mr))])
                 (set-var-loc! x fv)
                 (for-each-var (var-var-conf x) varvec
                     (lambda (var)
                       (set-var-frm-conf! var
                         (add-frm fv (var-frm-conf var)))))
                 (for-each-var (var-var-move x) varvec
                   (lambda (var)
                     (set-var-frm-move! var
                       (add-frm fv (var-frm-move var)))))
                 fv)])))
        (or (assign-move x)
            (assign-any))))
    (define (NFE idx mask x)
      (record-case x
        [(seq e0 e1) 
         (let ([e0 (E e0)])
           (make-seq e0 (NFE idx mask e1)))]
        [(ntcall target value args mask^ size)
         (make-ntcall target value 
            (map (lambda (x) 
                   (cond
                     [(symbol? x) x]
                     [(nfv? x) (nfv-loc x)]
                     [else (error who "invalid arg")]))
                 args)
            mask idx)]
        [else (error who "invalid NF effect ~s" x)]))
    (define (Var x)
      (cond
        [(var-loc x) =>
         (lambda (loc)
           (if (fvar? loc)
               loc
               (assign x)))]
        [else x]))
    (define (R x)
      (cond
        [(or (constant? x) (reg? x) (fvar? x)) x]
        [(nfv? x)
         (or (nfv-loc x)
             (error who "unassigned nfv"))]
        [(var? x) (Var x)]
        [(disp? x)
         (make-disp (R (disp-s0 x)) (R (disp-s1 x)))]
        [else (error who "invalid R ~s" (unparse x))]))
    (define (E x)
      (record-case x
        [(seq e0 e1)
         (let ([e0 (E e0)])
           (make-seq e0 (E e1)))]
        [(conditional e0 e1 e2)
         (make-conditional (P e0) (E e1) (E e2))]
        [(asm-instr op d s)
         (case op
           [(move move-byte) 
            (let ([d (R d)] [s (R s)])
              (cond
                [(eq? d s) 
                 (make-primcall 'nop '())]
                [else
                 (make-asm-instr op d s)]))]
           [(logand logor logxor int+ int- int* mset bset/c bset/h 
              sll sra srl
              cltd idiv int-/overflow int+/overflow int*/overflow
              fl:load fl:store fl:add! fl:sub! fl:mul! fl:div!
              fl:from-int)
            (make-asm-instr op (R d) (R s))]
           [(nop) (make-primcall 'nop '())]
           [else (error who "invalid op ~s" op)])]
        [(nframe vars live body)
         (let ([live-frms1
                (map (lambda (i) (Var (vector-ref varvec i)))
                  (set->list (vector-ref live 0)))]
               [live-frms2 (set->list (vector-ref live 1))]
               [live-nfvs (vector-ref live 2)])
           (define (max-frm ls i)
             (cond
               [(null? ls) i]
               [else 
                (max-frm (cdr ls) 
                  (max i (fvar-idx (car ls))))]))
           (define (max-ls ls i)
             (cond
               [(null? ls) i]
               [else 
                (max-ls (cdr ls) (max i (car ls)))])) 
           (define (max-nfv ls i)
             (cond
               [(null? ls) i]
               [else
                (let ([loc (nfv-loc (car ls))])
                  (unless (fvar? loc) (error 'max-nfv "not assigned"))
                  (max-nfv (cdr ls) (max i (fvar-idx loc))))]))
           (define (actual-frame-size vars i)
             (define (var-conflict? i vs)
               (ormap (lambda (xi)
                         (let ([loc (var-loc (vector-ref varvec xi))])
                          (and (fvar? loc)
                               (fx= i (fvar-idx loc)))))
                      (set->list vs)))
             (define (frame-size-ok? i vars)
               (or (null? vars)
                   (let ([x (car vars)])
                     (and (not (set-member? i (nfv-frm-conf x)))
                          (not (var-conflict? i (nfv-var-conf x)))
                          (frame-size-ok? (fxadd1 i) (cdr vars))))))
              (cond
                [(frame-size-ok? i vars) i]
                [else (actual-frame-size vars (fxadd1 i))]))
           (define (assign-frame-vars! vars i)
             (unless (null? vars)
               (let ([v (car vars)] [fv (mkfvar i)])
                 (set-nfv-loc! v fv)
                 ;(for-each
                 ;  (lambda (j) 
                 ;    (when (fx= j i)
                 ;      (error who "invalid assignment")))
                 ;  (set->list (nfv-frm-conf v)))
                 (for-each
                   (lambda (x)
                     (let ([loc (nfv-loc x)])
                       (cond
                         [loc
                          (when (fx= (fvar-idx loc) i)
                            (error who "invalid assignment"))]
                         [else
                          (set-nfv-nfv-conf! x
                            (rem-nfv v (nfv-nfv-conf x)))
                          (set-nfv-frm-conf! x
                            (add-frm fv (nfv-frm-conf x)))])))
                   (nfv-nfv-conf v))
                 (for-each-var (nfv-var-conf v) varvec
                   (lambda (x)
                     (let ([loc (var-loc x)])
                       (cond
                         [(fvar? loc)
                          (when (fx= (fvar-idx loc) i)
                            (error who "invalid assignment"))]
                         [else
                          (set-var-frm-conf! x
                            (add-frm fv (var-frm-conf x)))])))))
               (assign-frame-vars! (cdr vars) (fxadd1 i))))
           (define (make-mask n)
             (let ([v (make-vector (fxsra (fx+ n 7) 3) 0)])
               (define (set-bit idx)
                 (let ([q (fxsra idx 3)]
                       [r (fxlogand idx 7)])
                   (vector-set! v q
                     (fxlogor (vector-ref v q) (fxsll 1 r)))))
               (for-each (lambda (x) (set-bit (fvar-idx x))) live-frms1)
               (for-each set-bit live-frms2)
               (for-each (lambda (x) 
                           (let ([loc (nfv-loc x)])
                             (when loc 
                               (set-bit (fvar-idx loc))))) 
                         live-nfvs) v))
           (let ([i (actual-frame-size vars
                      (fx+ 2 
                        (max-frm live-frms1
                          (max-nfv live-nfvs
                            (max-ls live-frms2 0)))))])
             (assign-frame-vars! vars i)
             (NFE (fxsub1 i) (make-mask (fxsub1 i)) body)))]
        [(primcall op args)
         (case op
           [(nop interrupt incr/zero?) x]
           [else (error who "invalid effect prim ~s" op)])]
        [(shortcut body handler)
         (make-shortcut (E body) (E handler))]
        [else (error who "invalid effect ~s" (unparse x))]))
    (define (P x)
      (record-case x
        [(seq e0 e1)
         (let ([e0 (E e0)])
           (make-seq e0 (P e1)))]
        [(conditional e0 e1 e2)
         (make-conditional (P e0) (P e1) (P e2))]
        [(asm-instr op d s) (make-asm-instr op (R d) (R s))]
        [(constant) x]
        [(shortcut body handler)
         (make-shortcut (P body) (P handler))]
        [else (error who "invalid pred ~s" (unparse x))]))
    (define (T x)
      (record-case x
        [(seq e0 e1)
         (let ([e0 (E e0)])
           (make-seq e0 (T e1)))]
        [(conditional e0 e1 e2)
         (make-conditional (P e0) (T e1) (T e2))]
        [(primcall op args) x]
        [(shortcut body handler)
         (make-shortcut (T body) (T handler))]
        [else (error who "invalid tail ~s" (unparse x))]))
    (T x))
  ;;;
  (define (Main x)
    (record-case x 
      [(locals vars body)
       (init-vars! vars)
       (let ([varvec (list->vector vars)])
         (let ([call-live* (uncover-frame-conflicts body varvec)])
           (let ([body (rewrite body varvec)])
             (make-locals 
               (cons varvec
                 (let f ([vars vars])
                   (cond
                     [(null? vars) '()]
                     [(var-loc (car vars)) (f (cdr vars))]
                     [else (cons (car vars) (f (cdr vars)))])))
               body))))]
      [else (error 'assign-frame-sizes "invalid main ~s" x)]))
  ;;;
  (define (ClambdaCase x) 
    (record-case x
      [(clambda-case info body)
       (make-clambda-case info (Main body))]))
  ;;;
  (define (Clambda x)
    (record-case x
      [(clambda label case* free* name)
       (make-clambda label (map ClambdaCase case*) free* name)]))
  ;;;
  (define (Program x)
    (record-case x 
      [(codes code* body)
       (make-codes (map Clambda code*) (Main body))]))
  ;;;
  (define (assign-frame-sizes x)
    (let ([v (Program x)])
      v)))




(module (color-by-chaitin)
  (import ListySet)
  (import ListyGraphs)
  ;(import IntegerSet)
  ;(import IntegerGraphs)
  ;;;
  (define (set-for-each f s)
    (for-each f (set->list s)))
  ;;;
  (define (build-graph x)
    (define who 'build-graph)
    (define g (empty-graph))
    (define (R* ls)
      (cond
        [(null? ls) (make-empty-set)]
        [else (set-union (R (car ls)) (R* (cdr ls)))]))
    (define (R x)
      (record-case x
        [(constant) (make-empty-set)]
        [(var) (list->set (list x))]
        [(disp s0 s1) (set-union (R s0) (R s1))]
        [(fvar) (make-empty-set)]
        [(code-loc) (make-empty-set)]
        [else
         (cond
           [(symbol? x) 
            (if (memq x all-registers) 
                (set-add x (make-empty-set))
                (make-empty-set))]
           [else (error who "invalid R ~s" x)])]))
    ;;; build effect
    (define (E x s)
      (record-case x
        [(asm-instr op d v)
         (case op
           [(move)
            (let ([s (set-rem d s)])
              (set-for-each (lambda (y) (add-edge! g d y)) s)
              (set-union (R v) s))]
           [(move-byte)
            (let ([s (set-rem d s)])
              (set-for-each (lambda (y) (add-edge! g d y)) s)
              (when (var? d)
                (for-each (lambda (r) (add-edge! g d r)) non-8bit-registers))
              (when (var? v)
                (for-each (lambda (r) (add-edge! g v r)) non-8bit-registers))
              (set-union (R v) s))]
           [(int-/overflow int+/overflow int*/overflow)
            (unless (exception-live-set)
              (error who "uninitialized live set"))
            (let ([s (set-rem d (set-union s (exception-live-set)))])
              (set-for-each (lambda (y) (add-edge! g d y)) s)
              (set-union (set-union (R v) (R d)) s))] 
           [(logand logxor int+ int- int* logor sll sra srl)
            (let ([s (set-rem d s)])
              (set-for-each (lambda (y) (add-edge! g d y)) s)
              (set-union (set-union (R v) (R d)) s))]
           [(bset/c)
            (set-union (set-union (R v) (R d)) s)]
           [(bset/h)
            (when (var? v)
              (for-each (lambda (r) (add-edge! g v r))
                non-8bit-registers))
            (set-union (set-union (R v) (R d)) s)]
           [(cltd)
            (let ([s (set-rem edx s)])
              (when (register? edx)
                (set-for-each (lambda (y) (add-edge! g edx y)) s))
              (set-union (R eax) s))]
           [(idiv) 
            (let ([s (set-rem eax (set-rem edx s))])
              (when (register? eax)
                (set-for-each
                  (lambda (y) (add-edge! g eax y) (add-edge! g edx y))
                  s))
              (set-union (set-union (R eax) (R edx))
                     (set-union (R v) s)))]
           [(mset fl:load fl:store fl:add! fl:sub! fl:mul! fl:div!
                  fl:from-int)
            (set-union (R v) (set-union (R d) s))]
           [else (error who "invalid effect ~s" x)])]
        [(seq e0 e1) (E e0 (E e1 s))]
        [(conditional e0 e1 e2)
         (let ([s1 (E e1 s)] [s2 (E e2 s)])
           (P e0 s1 s2 (set-union s1 s2)))]
        [(ntcall targ value args mask size)
         (set-union (R* args) s)]
        [(primcall op arg*)
         (case op
           [(nop) s]
           [(interrupt incr/zero?) 
            (or (exception-live-set) (error who "uninitialized exception"))]
           [else (error who "invalid effect primcall ~s" op)])]
        [(shortcut body handler)
         (let ([s2 (E handler s)])
           (parameterize ([exception-live-set s2])
             (E body s)))]
        [else (error who "invalid effect ~s" (unparse x))]))
    (define (P x st sf su)
      (record-case x
        [(constant c) (if c st sf)]
        [(seq e0 e1)
         (E e0 (P e1 st sf su))]
        [(conditional e0 e1 e2)
         (let ([s1 (P e1 st sf su)] [s2 (P e2 st sf su)])
           (P e0 s1 s2 (set-union s1 s2)))]
        [(asm-instr op s0 s1) 
         (set-union (set-union (R s0) (R s1)) su)]
        [(shortcut body handler)
         (let ([s2 (P handler st sf su)])
           (parameterize ([exception-live-set s2])
             (P body st sf su)))]
        [else (error who "invalid pred ~s" (unparse x))]))
    (define (T x)
      (record-case x
        [(conditional e0 e1 e2)
         (let ([s1 (T e1)] [s2 (T e2)])
           (P e0 s1 s2 (set-union s1 s2)))]
        [(primcall op rands) 
         (R* rands)]
        [(seq e0 e1) (E e0 (T e1))]
        [(shortcut body handler)
         (let ([s2 (T handler)])
           (parameterize ([exception-live-set s2])
              (T body)))]
        [else (error who "invalid tail ~s" (unparse x))]))
    (define exception-live-set (make-parameter #f))
    (let ([s (T x)])
      ;(pretty-print (unparse x))
      ;(print-graph g)
      g))
  ;;;
  (define (color-graph sp* un* g)
    (define (find-low-degree ls g)
      (cond
        [(null? ls) #f]
        [(fx< (length (set->list (node-neighbors (car ls) g)))
              (length all-registers))
         (car ls)]
        [else (find-low-degree (cdr ls) g)]))
    (define (find-color/maybe x confs env)
      (let ([cr (map (lambda (x)
                       (cond
                         [(symbol? x) x]
                         [(assq x env) => cdr]
                         [else #f]))
                     (set->list confs))])
        (let ([r* (set->list 
                    (set-difference 
                      (list->set all-registers)
                      (list->set cr)))])
          (if (null? r*) 
              #f
              (car r*)))))
    (define (find-color x confs env)
      (or (find-color/maybe x confs env)
          (error 'find-color "cannot find color for ~s" x)))
    (cond
      [(and (empty-set? sp*) (empty-set? un*)) 
       (values '() (make-empty-set) '())]
      [(find-low-degree (set->list un*) g) =>
       (lambda (un)
         (let ([n* (node-neighbors un g)])
           (delete-node! un g)
           (let-values ([(spills sp* env) 
                         (color-graph sp* (set-rem un un*) g)])
             (let ([r (find-color un n* env)])
               (values spills sp*
                  (cons (cons un r) env))))))]
      [(find-low-degree (set->list sp*) g) =>
       (lambda (sp)
         (let ([n* (node-neighbors sp g)])
           (delete-node! sp g)
           (let-values ([(spills sp* env) 
                         (color-graph (set-rem sp sp*) un* g)])
             (let ([r (find-color sp n* env)])
               (values spills (set-add sp sp*)
                  (cons (cons sp r) env))))))]
      [(pair? (set->list sp*))
       (let ([sp (car (set->list sp*))])
         (let ([n* (node-neighbors sp g)])
           (delete-node! sp g)
           (let-values ([(spills sp* env) 
                         (color-graph (set-rem sp sp*) un* g)])
             (let ([r (find-color/maybe sp n* env)])
               (if r
                   (values spills (set-add sp sp*)
                       (cons (cons sp r) env))
                   (values (cons sp spills) sp* env))))))]
      [else (error 'color-graph "whoaaa")]))
  ;;;
  (define (substitute env x)
    (define who 'substitute)
    (define (Var x)
      (cond
        [(assq x env) => cdr]
        [else x]))
    (define (Rhs x)
      (record-case x
        [(var) (Var x)]
        [(primcall op rand*)
         (make-primcall op (map Rand rand*))]
        [else x]))
    (define (Rand x) 
      (record-case x
        [(var) (Var x)]
        [else x]))
    (define (Lhs x)
      (record-case x
        [(var) (Var x)]
        [(nfv confs loc) 
         (or loc (error who "LHS not set ~s" x))]
        [else x]))
    (define (D x)
      (record-case x
        [(constant) x]
        [(var) (Var x)]
        [(fvar) x]
        [else
         (if (symbol? x) x (error who "invalid D ~s" x))]))
    (define (R x)
      (record-case x
        [(constant) x]
        [(var) (Var x)]
        [(fvar)     x]
        [(nfv c loc)
         (or loc (error who "unset nfv ~s in R" x))]
        [(disp s0 s1) (make-disp (D s0) (D s1))]
        [else
         (if (symbol? x) x (error who "invalid R ~s" x))]))
    ;;; substitute effect
    (define (E x)
      (record-case x
        [(seq e0 e1) (make-seq (E e0) (E e1))]
        [(conditional e0 e1 e2) 
         (make-conditional (P e0) (E e1) (E e2))]
        [(asm-instr op x v)
         (make-asm-instr op (R x) (R v))]
        [(primcall op rands) 
         (make-primcall op (map R rands))]
        [(ntcall) x]
        [(shortcut body handler)
         (make-shortcut (E body) (E handler))]
        [else (error who "invalid effect ~s" (unparse x))]))
    (define (P x)
      (record-case x
        [(constant) x]
        [(asm-instr op x v)
         (make-asm-instr op (R x) (R v))]
        [(conditional e0 e1 e2) 
         (make-conditional (P e0) (P e1) (P e2))]
        [(seq e0 e1) (make-seq (E e0) (P e1))]
        [(shortcut body handler)
         (make-shortcut (P body) (P handler))]
        [else (error who "invalid pred ~s" (unparse x))])) 
    (define (T x)
      (record-case x
        [(primcall op rands) x]
        [(conditional e0 e1 e2) 
         (make-conditional (P e0) (T e1) (T e2))]
        [(seq e0 e1) (make-seq (E e0) (T e1))]
        [(shortcut body handler)
         (make-shortcut (T body) (T handler))]
        [else (error who "invalid tail ~s" (unparse x))]))
    ;(print-code x)
    (T x))
  ;;;
  (define (do-spill sp* varvec)
    (import conflict-helpers)
    (define (find/set-loc x)
      (let f ([i 1] [conf (var-frm-conf x)])
        (let ([fv (mkfvar i)])
          (cond
            [(mem-frm? fv conf) (f (fxadd1 i) conf)]
            [else
             (for-each-var (var-var-conf x) varvec
               (lambda (y) 
                 (set-var-var-conf! y
                   (rem-var x (var-var-conf y)))
                 (set-var-frm-conf! y 
                   (add-frm fv (var-frm-conf y)))))
             (set-var-loc! x fv)
             (cons x fv)]))))
    (map find/set-loc sp*))
  ;;;
  (define (add-unspillables un* x)
    (define who 'add-unspillables)
    (define (mku)
      (let ([u (unique-var 'u)])
        (set! un* (set-add u un*))
        u))
    (define (S x k)
      (cond
        [(or (constant? x) (var? x) (symbol? x))
         (k x)]
        [else
         (let ([u (mku)])
           (make-seq (E (make-asm-instr 'move u x)) (k u)))]))
    (define (S* ls k)
      (cond
        [(null? ls) (k '())]
        [else
         (S (car ls) 
            (lambda (a)
              (S* (cdr ls) 
                  (lambda (d)
                    (k (cons a d))))))]))
    (define (mem? x)
      (or (disp? x) (fvar? x)))
    ;;; unspillable effect
    (define (E x)
      (record-case x
        [(seq e0 e1) (make-seq (E e0) (E e1))]
        [(conditional e0 e1 e2)
         (make-conditional (P e0) (E e1) (E e2))]
        [(asm-instr op a b) 
         (case op
           [(logor logxor logand int+ int- int* move move-byte
                   int-/overflow int+/overflow int*/overflow)
            (cond
              [(and (eq? op 'move) (eq? a b)) 
               (make-primcall 'nop '())]
              [(and (mem? a) (mem? b)) 
               (let ([u (mku)])
                 (make-seq
                   (E (make-asm-instr 'move u b))
                   (E (make-asm-instr op a u))))]
              [(disp? a) 
               (let ([s0 (disp-s0 a)] [s1 (disp-s1 a)])
                 (cond
                   [(mem? s0)
                    (let ([u (mku)])
                      (make-seq
                        (E (make-asm-instr 'move u s0))
                        (E (make-asm-instr op (make-disp u s1) b))))]
                   [(mem? s1)
                    (let ([u (mku)])
                      (make-seq
                        (E (make-asm-instr 'move u s1))
                        (E (make-asm-instr op (make-disp s0 u) b))))]
                   [else x]))]
              [(disp? b) 
               (let ([s0 (disp-s0 b)] [s1 (disp-s1 b)])
                 (cond
                   [(mem? s0)
                    (let ([u (mku)])
                      (make-seq
                        (E (make-asm-instr 'move u s0))
                        (E (make-asm-instr op a (make-disp u s1)))))]
                   [(mem? s1)
                    (let ([u (mku)])
                      (make-seq
                        (E (make-asm-instr 'move u s1))
                        (E (make-asm-instr op a (make-disp s0 u)))))]
                   [else x]))] 
              [else x])]
           [(cltd) 
            (unless (and (symbol? a) (symbol? b)) 
              (error who "invalid args to cltd"))
            x]
           [(idiv) 
            (unless (symbol? a) 
              (error who "invalid arg to idiv"))
            (cond
              [(disp? b)
               (error who "invalid arg to idiv ~s" b)]
              [else x])]
           [(sll sra srl)
            (unless (or (constant? b)
                        (eq? b ecx))
              (error who "invalid shift ~s" b))
            x]
           [(mset bset/c bset/h) 
            (cond
              [(mem? b) 
               (let ([u (mku)])
                 (make-seq
                   (E (make-asm-instr 'move u b))
                   (E (make-asm-instr op a u))))]
              [else
               (let ([s1 (disp-s0 a)] [s2 (disp-s1 a)])
                 (cond
                   [(and (mem? s1) (mem? s2))
                    (let ([u (mku)])
                      (make-seq
                        (make-seq
                          (E (make-asm-instr 'move u s1))
                          (E (make-asm-instr 'int+ u s2)))
                        (make-asm-instr op 
                           (make-disp u (make-constant 0))
                           b)))]
                   [(mem? s1)
                    (let ([u (mku)])
                      (make-seq
                        (E (make-asm-instr 'move u s1))
                        (E (make-asm-instr op (make-disp u s2) b))))]
                   [(mem? s2)
                    (let ([u (mku)])
                      (make-seq
                        (E (make-asm-instr 'move u s2))
                        (E (make-asm-instr op (make-disp u s1) b))))]
                   [else x]))])]
           [(fl:load fl:store fl:add! fl:sub! fl:mul! fl:div!) 
            (cond
              [(mem? a) 
               (let ([u (mku)])
                 (make-seq
                   (E (make-asm-instr 'move u a))
                   (E (make-asm-instr op u b))))]
              [else x])]
           [(fl:from-int) x]
           [else (error who "invalid effect ~s" op)])]
        [(primcall op rands) 
         (case op
           [(nop interrupt incr/zero?) x]
           [else (error who "invalid op in ~s" (unparse x))])]
        [(ntcall) x]
        [(shortcut body handler)
         (let ([body (E body)])
           (make-shortcut body (E handler)))]
        [else (error who "invalid effect ~s" (unparse x))]))
    (define (P x)
      (record-case x
        [(constant) x]
        [(primcall op rands)
         (let ([a0 (car rands)] [a1 (cadr rands)])
           (cond
             [(and (fvar? a0) (fvar? a1))
              (let ([u (mku)])
                (make-seq 
                  (make-asm-instr 'move  u a0)
                  (make-primcall op (list u a1))))]
             [else x]))]
        [(conditional e0 e1 e2)
         (make-conditional (P e0) (P e1) (P e2))]
        [(seq e0 e1) (make-seq (E e0) (P e1))]
        [(asm-instr op a b) 
         (cond
           [(memq op '(fl:= fl:< fl:<= fl:> fl:>=)) 
            (if (mem? a) 
                (let ([u (mku)])
                  (make-seq 
                    (E (make-asm-instr 'move u a))
                    (make-asm-instr op u b)))
                x)]
           [(and (mem? a) (mem? b)) 
            (let ([u (mku)])
              (make-seq
                (E (make-asm-instr 'move u b))
                (make-asm-instr op a u)))]
           [else x])]
        [(shortcut body handler)
         (let ([body (P body)])
           (make-shortcut body (P handler)))]
        [else (error who "invalid pred ~s" (unparse x))]))
    (define (T x)
      (record-case x
        [(primcall op rands) x]
        [(conditional e0 e1 e2)
         (make-conditional (P e0) (T e1) (T e2))]
        [(seq e0 e1) (make-seq (E e0) (T e1))]
        [(shortcut body handler)
         (make-shortcut (T body) (T handler))]
        [else (error who "invalid tail ~s" (unparse x))]))
    (let ([x (T x)])
      (values un* x)))
  ;;;
  (define (color-program x)
    (define who 'color-program)
    (record-case x 
      [(locals vars body)
       (let ([varvec (car vars)] [sp* (cdr vars)])
         (let loop ([sp* (list->set sp*)] [un* (make-empty-set)] [body body])
           (let-values ([(un* body) (add-unspillables un* body)])
             (let ([g (build-graph body)])
               (let-values ([(spills sp* env) (color-graph sp* un* g)])
                 (cond
                   [(null? spills) (substitute env body)]
                   [else 
                    (let* ([env (do-spill spills varvec)]
                           [body (substitute env body)])
                      (loop sp* un* body))]))))))]))
  ;;;
  (define (color-by-chaitin x)
    ;;;
    (define (ClambdaCase x) 
      (record-case x
        [(clambda-case info body)
         (make-clambda-case info (color-program body))]))
    ;;;
    (define (Clambda x)
      (record-case x
        [(clambda label case* free* name)
         (make-clambda label (map ClambdaCase case*) free* name)]))
    ;;;
    (define (Program x)
      (record-case x 
        [(codes code* body)
         (make-codes (map Clambda code*) (color-program body))]))
    ;;;
    (Program x))
  #|chaitin module|#)





(define (flatten-codes x)
  (define who 'flatten-codes)
  ;;;
  (define (FVar i)
    `(disp ,(* i (- wordsize)) ,fpr))
  ;;;
  (define (C x)
    (record-case x
      [(code-loc label) (label-address label)]
      [(foreign-label L) `(foreign-label ,L)]
      [(closure label free*)
       (unless (null? free*) (error who "nonempty closure"))
       `(obj ,x)]
      [(object o)
       `(obj ,o)]
      [else 
       (if (integer? x)
           x
           (error who "invalid constant C ~s" x))]))
  (define (BYTE x)
    (record-case x
      [(constant x)
       (unless (and (integer? x) (fx<= x 255) (fx<= -128 x))
         (error who "invalid byte ~s" x))
       x]
      [else (error who "invalid byte ~s" x)]))
  (define (D x)
    (record-case x
      [(constant c) (C c)]
      [else
       (if (symbol? x) x (error who "invalid D ~s" x))]))
  (define (R x)
    (record-case x
      [(constant c) (C c)]
      [(fvar i) (FVar i)]
      [(disp s0 s1) 
       (let ([s0 (D s0)] [s1 (D s1)])
         `(disp ,s0 ,s1))]
      [else
       (if (symbol? x) x (error who "invalid R ~s" x))]))
  (define (R/l x)
    (record-case x
      [(constant c) (C c)]
      [(fvar i) (FVar i)]
      [(disp s0 s1) 
       (let ([s0 (D s0)] [s1 (D s1)])
         `(disp ,s0 ,s1))]
      [else
       (if (symbol? x) (reg/l x) (error who "invalid R/l ~s" x))])) 
  (define (reg/h x)
    (cond
      [(assq x '([%eax %ah] [%ebx %bh] [%ecx %ch] [%edx %dh]))
       => cadr]
      [else (error who "invalid reg/h ~s" x)]))
  (define (reg/l x)
    (cond
      [(assq x '([%eax %al] [%ebx %bl] [%ecx %cl] [%edx %dl]))
       => cadr]
      [else (error who "invalid reg/l ~s" x)])) 
  (define (R/cl x)
    (record-case x
      [(constant i) 
       (unless (fixnum? i)
         (error who "invalid R/cl ~s" x))
       (fxlogand i 31)]
      [else
       (if (eq? x ecx)
           '%cl
           (error who "invalid R/cl ~s" x))]))
  (define (interrupt? x)
    (record-case x
      [(primcall op args) (eq? op 'interrupt)]
      [else #f]))
  ;;; flatten effect
  (define (E x ac)
    (record-case x
      [(seq e0 e1) (E e0 (E e1 ac))]
      [(conditional e0 e1 e2)
       (cond
         [(interrupt? e1)
          (let ([L (or (exception-label)
                       (error who "no exception label"))])
            (P e0 L #f (E e2 ac)))]
         [(interrupt? e2)
          (let ([L (or (exception-label)
                       (error who "no exception label"))])
            (P e0 #f L (E e1 ac)))]
         [else
          (let ([lf (unique-label)] [le (unique-label)])
            (P e0 #f lf
               (E e1 
                  (cons* `(jmp ,le) lf
                     (E e2 (cons le ac))))))])]
      [(ntcall target value args mask size) 
       (let ([LCALL (unique-label)])
         (define (rp-label value)
           (if value
               (label-address (sl-mv-error-rp-label))
               (label-address (sl-mv-ignore-rp-label))))
         (cond
           [(string? target) ;; foreign call
            (cons* `(subl ,(* (fxsub1 size) wordsize) ,fpr)
                   `(movl (foreign-label "ik_foreign_call") %ebx)
                   `(jmp ,LCALL)
                   `(byte-vector ,mask)
                   `(int ,(* size wordsize))
                   `(current-frame-offset)
                   (rp-label value)
                   '(byte 0)
                   '(byte 0)
                   '(byte 0)
                   LCALL
                   `(call %ebx)
                   `(addl ,(* (fxsub1 size) wordsize) ,fpr)
                   ac)]
           [target ;;; known call
            (cons* `(subl ,(* (fxsub1 size) wordsize) ,fpr)
                   `(jmp ,LCALL)
                   `(byte-vector ,mask)
                   `(int ,(* size wordsize))
                   `(current-frame-offset)
                   (rp-label value)
                   LCALL
                   `(call (label ,target))
                   `(addl ,(* (fxsub1 size) wordsize) ,fpr)
                   ac)]
           [else
            (cons* `(subl ,(* (fxsub1 size) wordsize) ,fpr)
                   `(jmp ,LCALL)
                   `(byte-vector ,mask)
                   `(int ,(* size wordsize))
                   `(current-frame-offset)
                   (rp-label value)
                   '(byte 0)
                   '(byte 0)
                   LCALL
                   `(call (disp ,(fx- disp-closure-code closure-tag) ,cp-register))
                   `(addl ,(* (fxsub1 size) wordsize) ,fpr)
                   ac)]))]
      [(asm-instr op d s)
       (case op
         [(logand) (cons `(andl ,(R s) ,(R d)) ac)]
         [(int+) (cons `(addl ,(R s) ,(R d)) ac)]
         [(int*) (cons `(imull ,(R s) ,(R d)) ac)]
         [(int-) (cons `(subl ,(R s) ,(R d)) ac)]
         [(logor)  (cons `(orl ,(R s) ,(R d)) ac)]
         [(logxor) (cons `(xorl ,(R s) ,(R d)) ac)]
         [(mset) (cons `(movl ,(R s) ,(R d)) ac)]
         [(move) 
          (if (eq? d s)
              ac
              (cons `(movl ,(R s) ,(R d)) ac))]
         [(move-byte) 
          (if (eq? d s)
              ac
              (cons `(movb ,(R/l s) ,(R/l d)) ac))]
         [(bset/c) (cons `(movb ,(BYTE s) ,(R d)) ac)]
         [(bset/h) (cons `(movb ,(reg/h s) ,(R d)) ac)]
         [(sll)  (cons `(sall ,(R/cl s) ,(R d)) ac)]
         [(sra)  (cons `(sarl ,(R/cl s) ,(R d)) ac)]
         [(srl)  (cons `(shrl ,(R/cl s) ,(R d)) ac)]
         [(idiv) (cons `(idivl ,(R s)) ac)]
         [(cltd) (cons `(cltd) ac)]
         [(int-/overflow)
          (let ([L (or (exception-label) 
                       (error who "no exception label"))])
            (cons* `(subl ,(R s) ,(R d)) 
                   `(jo ,L)
                   ac))]
         [(int*/overflow)
          (let ([L (or (exception-label) 
                       (error who "no exception label"))])
            (cons* `(imull ,(R s) ,(R d)) 
                   `(jo ,L)
                   ac))] 
         [(int+/overflow)
          (let ([L (or (exception-label) 
                       (error who "no exception label"))])
            (cons* `(addl ,(R s) ,(R d)) 
                   `(jo ,L)
                   ac))]
         [(fl:store) 
          (cons `(movsd xmm0 ,(R (make-disp s d))) ac)]
         [(fl:load) 
          (cons `(movsd ,(R (make-disp s d)) xmm0) ac)]
         [(fl:from-int) 
          (cons `(cvtsi2sd ,(R s) xmm0) ac)]
         [(fl:add!) 
          (cons `(addsd ,(R (make-disp s d)) xmm0) ac)]
         [(fl:sub!) 
          (cons `(subsd ,(R (make-disp s d)) xmm0) ac)]
         [(fl:mul!) 
          (cons `(mulsd ,(R (make-disp s d)) xmm0) ac)]
         [(fl:div!) 
          (cons `(divsd ,(R (make-disp s d)) xmm0) ac)]
         [else (error who "invalid instr ~s" x)])]
      [(primcall op rands)
       (case op
         [(nop) ac]
         [(interrupt) 
          (let ([l (or (exception-label)
                       (error who "no exception label"))])
            (cons `(jmp ,l) ac))]
         [(incr/zero?) 
          (let ([l (or (exception-label)
                       (error who "no exception label"))])
            (cons* 
              `(addl 1 ,(R (make-disp (car rands) (cadr rands))))
              `(je ,l)
              ac))]
         [else (error who "invalid effect ~s" (unparse x))])]
      [(shortcut body handler)
       (let ([L (unique-interrupt-label)] [L2 (unique-label)])
         (let ([hand (cons L (E handler `((jmp ,L2))))])
           (let ([tc (exceptions-conc)])
             (set-cdr! tc (append hand (cdr tc)))))
         (parameterize ([exception-label L])
           (E body (cons L2 ac))))]
      ;[(shortcut body handler) 
      ; (let ([L (unique-label)] [L2 (unique-label)])
      ;   (let ([ac (cons L (E handler (cons L2 ac)))])
      ;     (parameterize ([exception-label L])
      ;        (E body (cons `(jmp ,L2) ac)))))]
      [else (error who "invalid effect ~s" (unparse x))]))
  ;;;
  (define (unique-interrupt-label)
    (label (gensym "ERROR")))
  (define (unique-label)
    (label (gensym)))
  ;;;
  (define (P x lt lf ac)
    (record-case x
      [(constant c) 
       (if c
           (if lt (cons `(jmp ,lt) ac) ac)
           (if lf (cons `(jmp ,lf) ac) ac))]
      [(seq e0 e1)
       (E e0 (P e1 lt lf ac))]
      [(conditional e0 e1 e2)
       (cond
         [(and lt lf) 
          (let ([l (unique-label)])
            (P e0 #f l
               (P e1 lt lf
                  (cons l (P e2 lt lf ac)))))]
         [lt
          (let ([lf (unique-label)] [l (unique-label)])
            (P e0 #f l
               (P e1 lt lf
                  (cons l (P e2 lt #f (cons lf ac))))))]
         [lf 
          (let ([lt (unique-label)] [l (unique-label)])
            (P e0 #f l
               (P e1 lt lf
                  (cons l (P e2 #f lf (cons lt ac))))))]
         [else
          (let ([lf (unique-label)] [l (unique-label)])
            (P e0 #f l
               (P e1 #f #f
                  (cons `(jmp ,lf)
                    (cons l (P e2 #f #f (cons lf ac)))))))])]
      [(asm-instr op a0 a1)
       (let ()
         (define (notop x)
           (cond
             [(assq x '([= !=] [!= =] [< >=] [<= >] [> <=] [>= <]
                        [u< u>=] [u<= u>] [u> u<=] [u>= u<]
                        [fl:= fl:o!=] [fl:!= fl:o=] 
                        [fl:< fl:o>=] [fl:<= fl:o>] 
                        [fl:> fl:o<=] [fl:>= fl:o<]
                        ))
              => cadr]
             [else (error who "invalid notop ~s" x)]))
         (define (jmpname x)
           (cond
             [(assq x '([= je] [!= jne] [< jl] [<= jle] [> jg] [>= jge]
                        [u< jb] [u<= jbe] [u> ja] [u>= jae]
                        [fl:= je] [fl:!= jne]
                        [fl:< jb] [fl:> ja] [fl:<= jbe] [fl:>= jae]
                        [fl:o= je] [fl:o!= jne]
                        [fl:o< jb] [fl:o> ja] [fl:o<= jbe] [fl:o>= jae]
                        ))
              => cadr]
             [else (error who "invalid jmpname ~s" x)]))
         (define (revjmpname x)
           (cond
             [(assq x '([= je] [!= jne] [< jg] [<= jge] [> jl] [>= jle]
                        [u< ja] [u<= jae] [u> jb] [u>= jbe]))
              => cadr]
             [else (error who "invalid jmpname ~s" x)]))
         (define (cmp op a0 a1 lab ac)
           (cond
             [(memq op '(fl:= fl:!= fl:< fl:<= fl:> fl:>=))
              (cons* `(ucomisd ,(R (make-disp a0 a1)) xmm0)
                     `(,(jmpname op) ,lab)
                     ;;; BOGUS!
                     ac)]
             [(memq op '(fl:o= fl:o!= fl:o< fl:o<= fl:o> fl:o>=))
              (cons* `(ucomisd ,(R (make-disp a0 a1)) xmm0)
                     `(jp ,lab)
                     `(,(jmpname op) ,lab)
                     ac)]
             [(or (symbol? a0) (constant? a1))
              (cons* `(cmpl ,(R a1) ,(R a0))
                     `(,(jmpname op) ,lab)
                     ac)]
             [(or (symbol? a1) (constant? a0))
              (cons* `(cmpl ,(R a0) ,(R a1))
                     `(,(revjmpname op) ,lab)
                     ac)]
             [else (error who "invalid cmpops ~s ~s" a0 a1)]))
         (cond
           [(and lt lf)
            (cmp op a0 a1 lt
                (cons `(jmp ,lf) ac))]
           [lt 
            (cmp op a0 a1 lt ac)]
           [lf 
            (cmp (notop op) a0 a1 lf ac)]
           [else ac]))]
      [(shortcut body handler)
       (let ([L (unique-interrupt-label)] [lj (unique-label)])
         (let ([ac (if (and lt lf) ac (cons lj ac))])
           (let ([hand (cons L (P handler (or lt lj) (or lf lj) '()))])
             (let ([tc (exceptions-conc)])
               (set-cdr! tc (append hand (cdr tc)))))
           (parameterize ([exception-label L])
             (P body lt lf ac))))]
      [else (error who "invalid pred ~s" x)]))
  ;;;
  (define (T x ac)
    (record-case x
      [(seq e0 e1) (E e0 (T e1 ac))]
      [(conditional e0 e1 e2)
       (let ([L (unique-label)])
         (P e0 #f L (T e1 (cons L (T e2 ac)))))]
      [(primcall op rands)
       (case op
        [(return) (cons '(ret) ac)]
        [(indirect-jump) 
         (cons `(jmp (disp ,(fx- disp-closure-code closure-tag) ,cp-register))
               ac)]
        [(direct-jump)
         (cons `(jmp (label ,(code-loc-label (car rands)))) ac)]
        [else (error who "invalid tail ~s" x)])]
      [(shortcut body handler) 
       (let ([L (unique-interrupt-label)])
         (let ([hand (cons L (T handler '()))])
           (let ([tc (exceptions-conc)])
             (set-cdr! tc (append hand (cdr tc)))))
         (parameterize ([exception-label L])
           (T body ac)))]
      [else (error who "invalid tail ~s" x)]))
  (define exception-label (make-parameter #f))
  ;;;
  (define (handle-vararg fml-count ac)
    (define CONTINUE_LABEL (unique-label))
    (define DONE_LABEL (unique-label))
    (define CONS_LABEL (unique-label))
    (define LOOP_HEAD (unique-label))
    (define L_CALL (unique-label))
    (cons* (cmpl (int (argc-convention (fxsub1 fml-count))) eax)
           ;(jg (label SL_invalid_args))
           (jl CONS_LABEL)
           (movl (int nil) ebx)
           (jmp DONE_LABEL)
           CONS_LABEL
           (movl (pcb-ref 'allocation-redline) ebx)
           (addl eax ebx)
           (addl eax ebx)
           (cmpl ebx apr)
           (jle LOOP_HEAD)
           ; overflow
           (addl eax esp) ; advance esp to cover args
           (pushl cpr)    ; push current cp
           (pushl eax)    ; push argc
           (negl eax)     ; make argc positive
           (addl (int (fx* 4 wordsize)) eax) ; add 4 words to adjust frame size
           (pushl eax)    ; push frame size
           (addl eax eax) ; double the number of args
           (movl eax (mem (fx* -2 wordsize) fpr)) ; pass it as first arg
           (movl (int (argc-convention 1)) eax) ; setup argc
           (movl (primref-loc 'do-vararg-overflow) cpr) ; load handler
           (jmp L_CALL)   ; go to overflow handler
           ; NEW FRAME
           '(int 0)        ; if the framesize=0, then the framesize is dynamic
           '(current-frame-offset)
           '(int 0)        ; multiarg rp
           (byte 0)
           (byte 0)
           L_CALL
           (indirect-cpr-call)
           (popl eax)     ; pop framesize and drop it
           (popl eax)     ; reload argc
           (popl cpr)     ; reload cp
           (subl eax fpr) ; readjust fp
           LOOP_HEAD
           (movl (int nil) ebx)
           CONTINUE_LABEL
           (movl ebx (mem disp-cdr apr))
           (movl (mem fpr eax) ebx)
           (movl ebx (mem disp-car apr))
           (movl apr ebx)
           (addl (int pair-tag) ebx)
           (addl (int pair-size) apr)
           (addl (int (fxsll 1 fx-shift)) eax)
           (cmpl (int (fx- 0 (fxsll fml-count fx-shift))) eax)
           (jle CONTINUE_LABEL)
           DONE_LABEL
           (movl ebx (mem (fx- 0 (fxsll fml-count fx-shift)) fpr))
           ac))
  ;;;
  (define (properize args proper ac)
    (cond
      [proper ac]
      [else
       (handle-vararg (length (cdr args)) ac)]))
  ;;;
  (define (ClambdaCase x ac) 
    (record-case x
      [(clambda-case info body)
       (record-case info
         [(case-info L args proper)
          (let ([lothers (unique-label)])
            (cons* `(cmpl ,(argc-convention 
                             (if proper 
                                 (length (cdr args))
                                 (length (cddr args))))
                          ,argc-register)
                   (cond
                     [proper `(jne ,lothers)]
                     [(> (argc-convention 0) (argc-convention 1))
                      `(jg ,lothers)]
                     [else
                      `(jl ,lothers)])
               (properize args proper
                  (cons (label L) 
                        (T body (cons lothers ac))))))])]))
  ;;;
  (define (Clambda x)
    (record-case x
      [(clambda L case* free* name)
       (cons* (length free*) 
              `(name ,name)
              (label L)
          (let ([ac (list '(nop))])
            (parameterize ([exceptions-conc ac])
              (let f ([case* case*])
                (cond
                  [(null? case*) 
                   (cons `(jmp (label ,(sl-invalid-args-label))) ac)]
                  [else
                   (ClambdaCase (car case*) (f (cdr case*)))])))))]))
  ;;;
  (define exceptions-conc (make-parameter #f))
  ;;;
  (define (Program x)
    (record-case x 
      [(codes code* body)
       (cons (cons* 0 
                    (label (gensym))
                    (let ([ac (list '(nop))])
                      (parameterize ([exceptions-conc ac])
                        (T body ac))))
             (map Clambda code*))]))
  ;;;
  ;;; (print-code x)
  (Program x))

(define (print-code x)
  (parameterize ([print-gensym '#t])
    (pretty-print (unparse x))))

(define (alt-cogen x)
  (define (time-it name proc)
    (proc))
  (let* ([x (introduce-primcalls x)]
         [x (eliminate-fix x)]
         [x (insert-engine-checks x)]
         [x (specify-representation x)]
         [x (insert-stack-overflow-check x)]
         [x (impose-calling-convention/evaluation-order x)]
         [x (time-it "frame" (lambda () (assign-frame-sizes x)))]
         [x (time-it "register" (lambda () (color-by-chaitin x)))]
         [ls (flatten-codes x)])
    ls))
  

#|module alt-cogen|#)

