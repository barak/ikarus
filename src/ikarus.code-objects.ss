
(library (ikarus code-objects)
  (export
    make-code code? code-reloc-vector code-freevars
    code-size code-ref code-set! set-code-reloc-vector!)
  (import
    (only (scheme) $fx< $fx>= 
          $code? $code-reloc-vector $code-freevars $code-size
          $code-ref $code-set! )
    (except (ikarus) make-code code? code-reloc-vector code-freevars
            code-size code-ref code-set! set-code-reloc-vector!))

  (define make-code
    (lambda (code-size freevars)
      (unless (and (fixnum? code-size) ($fx>= code-size 0))
        (error 'make-code "~s is not a valid code size" code-size))
      (unless (and (fixnum? freevars) ($fx>= freevars 0))
        (error 'make-code "~s is not a valid number of free vars" freevars))
      (foreign-call "ikrt_make_code" code-size freevars '#())))

  (define code?
    (lambda (x) ($code? x)))

  (define code-reloc-vector
    (lambda (x)
      (unless ($code? x) (error 'code-reloc-vector "~s is not a code" x))
      ($code-reloc-vector x)))

  (define code-freevars
    (lambda (x)
      (unless ($code? x) (error 'code-closure-size "~s is not a code" x))
      ($code-freevars x)))

  (define code-size
    (lambda (x)
      (unless ($code? x) (error 'code-size "~s is not a code" x))
      ($code-size x)))

  (define code-set!
    (lambda (x i v)
      (unless ($code? x) (error 'code-set! "~s is not a code" x))
      (unless (and (fixnum? i)
                   ($fx>= i 0)
                   ($fx< i ($code-size x)))
        (error 'code-set! "~s is not a valid index" i))
      (unless (and (fixnum? v)
                   ($fx>= v 0)
                   ($fx< v 256))
        (error 'code-set! "~s is not a valid byte" v))
      ($code-set! x i v)))

  (define code-ref
    (lambda (x i)
      (unless ($code? x) (error 'code-ref "~s is not a code" x))
      (unless (and (fixnum? i)
                   ($fx>= i 0)
                   ($fx< i ($code-size x)))
        (error 'code-ref "~s is not a valid index" i))
      ($code-ref x i)))

  (define set-code-reloc-vector!
    (lambda (x v)
      (unless ($code? x) 
        (error 'set-code-reloc-vector! "~s is not a code" x))
      (unless (vector? v)
        (error 'set-code-reloc-vector! "~s is not a vector" v))
      (foreign-call "ikrt_set_code_reloc_vector" x v)))
  )
