
(library (ikarus io-ports)
  (export make-input-port make-output-port make-input/output-port
          port-handler
          port-input-buffer  port-output-buffer 
          port-input-index   set-port-input-index!
          port-input-size    set-port-input-size!
          port-output-index  set-port-output-index!
          port-output-size   set-port-output-size!)
  (import 
    (only (scheme) $make-port/input $make-port/output
          $make-port/both     $port-handler 
          $port-input-buffer  $port-output-buffer 
          $port-input-index   $set-port-input-index!
          $port-input-size    $set-port-input-size!
          $port-output-index  $set-port-output-index!
          $port-output-size   $set-port-output-size!
          $string-length $fx<= $fx>=)
    (except (ikarus)  make-input-port make-output-port 
         make-input/output-port port-handler
         port-input-buffer  port-output-buffer
         port-input-index   set-port-input-index!
         port-input-size    set-port-input-size!
         port-output-index  set-port-output-index!
         port-output-size   set-port-output-size!))
  ;;; GENERIC PORTS: BASIC PRIMITIVES
  ;;;
  ;;; Exports: 
  ;;; * Constructors:
  ;;;   (make-input-port handler input-buffer)
  ;;;   (make-output-port handler output-buffer)
  ;;;   (make-input/output-port handler input-buffer output-buffer)
  ;;;
  ;;; * Predicates:
  ;;;   (port? x)
  ;;;   (input-port? x)
  ;;;   (output-port? x)
  ;;;
  ;;; * Accessors:
  ;;;   (port-handler port)
  ;;;   (port-input-buffer port)
  ;;;   (port-input-index port)
  ;;;   (port-input-size port)
  ;;;   (port-output-buffer port)
  ;;;   (port-output-index port)
  ;;;   (port-output-size port)
  ;;;
  ;;; * Mutators:
  ;;;   (set-port-handler! port proc)
  ;;;   (set-port-input-buffer! port string)
  ;;;   (set-port-input-index! port fixnum)
  ;;;   (set-port-input-size! port fixnum)
  ;;;   (set-port-output-buffer! port string)
  ;;;   (set-port-output-index! port fixnum)
  ;;;   (set-port-output-size! port fixnum)
  ;;;
  ;;;
  (define $make-input-port
    (lambda (handler buffer)
      ($make-port/input handler buffer 0 ($string-length buffer) #f 0 0)))
  ;;;
  (define make-input-port
    (lambda (handler buffer)
      (if (procedure? handler)
          (if (string? buffer)
              ($make-input-port handler buffer)
              (error 'make-input-port "~s is not a string" buffer))
          (error 'make-input-port "~s is not a procedure" handler))))
  ;;;
  (define $make-output-port
    (lambda (handler buffer)
      ($make-port/output handler #f 0 0 buffer 0 ($string-length buffer))))
  ;;;
  (define make-output-port
    (lambda (handler buffer)
      (if (procedure? handler)
          (if (string? buffer)
              ($make-output-port handler buffer)
              (error 'make-output-port "~s is not a string" buffer))
          (error 'make-output-port "~s is not a procedure" handler))))
  ;;;
  (define $make-input/output-port
    (lambda (handler input-buffer output-buffer)
       ($make-port/both handler
                  input-buffer 0 ($string-length input-buffer)
                  output-buffer 0 ($string-length output-buffer))))
  ;;;
  (define make-input/output-port
    (lambda (handler input-buffer output-buffer)
      (if (procedure? handler)
          (if (string? input-buffer)
              (if (string? output-buffer)
                  ($make-input/output-port handler input-buffer output-buffer) 
                  (error 'make-input/output-port 
                         "~s is not a string"
                         output-buffer))
              (error 'make-input/output-port "~s is not a string" input-buffer))
          (error 'make-input/output-port "~s is not a procedure" handler))))
  ;;;
  ;;; XXX (primitive-set! '$port-handler
  ;;; XXX   (lambda (x) ($port-handler x)))
  ;;;
  (define port-handler
    (lambda (x)
      (if (port? x)
          ($port-handler x)
          (error 'port-handler "~s is not a port" x))))
  ;;;
  ;;; XXX (define $port-input-buffer
  ;;; XXX   (lambda (x) ($port-input-buffer x)))
  ;;;
  (define port-input-buffer
    (lambda (x)
      (if (input-port? x)
          ($port-input-buffer x)
          (error 'port-input-buffer "~s is not an input-port" x))))
  ;;;
  ;;; XXX (primitive-set! '$port-input-index
  ;;; XXX   (lambda (x) ($port-input-index x)))
  ;;;
  (define port-input-index
    (lambda (x)
      (if (input-port? x)
          ($port-input-index x)
          (error 'port-input-index "~s is not an input-port" x))))
  ;;;
  ;;; XXX (primitive-set! '$port-input-size
  ;;; XXX   (lambda (x) ($port-input-size x)))
  ;;;
  (define port-input-size
    (lambda (x)
      (if (input-port? x)
          ($port-input-size x)
          (error 'port-input-size "~s is not an input-port" x))))
  ;;;
  ;;; XXX (define '$port-output-buffer
  ;;; XXX   (lambda (x) ($port-output-buffer x)))
  ;;;
  (define port-output-buffer
    (lambda (x)
      (if (output-port? x)
          ($port-output-buffer x)
          (error 'port-output-buffer "~s is not an output-port" x))))
  ;;;
  ;;; XXX (primitive-set! '$port-output-index
  ;;; XXX   (lambda (x) ($port-output-index x)))
  ;;;
  (define port-output-index
    (lambda (x)
      (if (output-port? x)
          ($port-output-index x)
          (error 'port-output-index "~s is not an output-port" x))))
  ;;;
  ;;; XXX (primitive-set! '$port-output-size
  ;;; XXX   (lambda (x) ($port-output-size x)))
  ;;;
  (define port-output-size
    (lambda (x)
      (if (output-port? x)
          ($port-output-size x)
          (error 'port-output-size "~s is not an output-port" x))))
  ;;;
  ;;; XXX (define '$set-port-input-index!
  ;;; XXX   (lambda (p i) ($set-port-input-index! p i)))
  ;;;
  (define set-port-input-index!
    (lambda (p i)
      (if (input-port? p)
          (if (fixnum? i)
              (if ($fx>= i 0)
                  (if ($fx<= i ($port-input-size p))
                      ($set-port-input-index! p i)
                      (error 'set-port-input-index! "index ~s is too big" i))
                  (error 'set-port-input-index! "index ~s is negative" i))
              (error 'set-port-input-index! "~s is not a valid index" i))
          (error 'set-port-input-index! "~s is not an input-port" p))))
  ;;;
  ;;; XXX (primitive-set! '$set-port-input-size!
  ;;; XXX   (lambda (p i) 
  ;;; XXX     ($set-port-input-index! p 0)
  ;;; XXX     ($set-port-input-size! p i)))
  ;;;
  (define set-port-input-size!
    (lambda (p i)
      (if (input-port? p)
          (if (fixnum? i)
              (if ($fx>= i 0)
                  (if ($fx<= i ($string-length ($port-input-buffer p)))
                      (begin
                        ($set-port-input-index! p 0)
                        ($set-port-input-size! p i))
                      (error 'set-port-input-size! "size ~s is too big" i))
                  (error 'set-port-input-size! "size ~s is negative" i))
              (error 'set-port-input-size! "~s is not a valid size" i))
          (error 'set-port-input-size! "~s is not an input-port" p))))
  ;;;
  ;;; XXX (primitive-set! '$set-port-output-index!
  ;;; XXX   (lambda (p i) ($set-port-output-index! p i)))
  ;;;
  (define set-port-output-index!
    (lambda (p i)
      (if (output-port? p)
          (if (fixnum? i)
              (if ($fx>= i 0)
                  (if ($fx<= i ($port-output-size p))
                      ($set-port-output-index! p i)
                      (error 'set-port-output-index! "index ~s is too big" i))
                  (error 'set-port-output-index! "index ~s is negative" i))
              (error 'set-port-output-index! "~s is not a valid index" i))
          (error 'set-port-output-index! "~s is not an output-port" p))))
  ;;;
  ;;; XXX (primitive-set! '$set-port-output-size!
  ;;; XXX   (lambda (p i) 
  ;;; XXX     ($set-port-output-index! p 0)
  ;;; XXX     ($set-port-output-size! p i)))
  ;;;
  (define set-port-output-size!
    (lambda (p i)
      (if (output-port? p)
          (if (fixnum? i)
              (if ($fx>= i 0)
                  (if ($fx<= i ($string-length ($port-output-buffer p)))
                      (begin
                        ($set-port-output-index! p 0)
                        ($set-port-output-size! p i))
                      (error 'set-port-output-size! "size ~s is too big" i))
                  (error 'set-port-output-size! "size ~s is negative" i))
              (error 'set-port-output-size! "~s is not a valid size" i))
          (error 'set-port-output-size! "~s is not an output-port" p)))))